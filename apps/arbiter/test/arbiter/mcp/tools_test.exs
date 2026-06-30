defmodule Arbiter.MCP.ToolsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.MCP
  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Messages.Message
  alias Arbiter.Worker

  require Ash.Query

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "mcp-tools-ws", prefix: "mcp"})
    {:ok, task} = Ash.create(Issue, %{title: "the bound task", workspace_id: ws.id})

    worker = %Scope{tier: :worker, workspace_id: ws.id, task_id: task.id, repo: "shipyard"}
    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

    {:ok, ws: ws, task: task, worker: worker, coordinator: coordinator}
  end

  describe "task_show/2" do
    test "a worker reads its own task (id defaulted from the token)", ctx do
      assert {:ok, data} = Tools.task_show(ctx.worker, %{})
      assert data.id == ctx.task.id
      assert data.title == "the bound task"
      assert data.status == "open"
    end

    test "a worker may not read another task", ctx do
      {:ok, other} = Ash.create(Issue, %{title: "someone else", workspace_id: ctx.ws.id})
      assert {:error, {:unauthorized, _}} = Tools.task_show(ctx.worker, %{"id" => other.id})
    end

    test "a coordinator reads any task in its workspace", ctx do
      assert {:ok, data} = Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id})
      assert data.id == ctx.task.id
    end

    test "a coordinator cannot see a task in another workspace (reported not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "other-ws", prefix: "oth"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} = Tools.task_show(ctx.coordinator, %{"id" => foreign.id})
    end

    test "a coordinator must supply an id", ctx do
      assert {:error, {:invalid, _}} = Tools.task_show(ctx.coordinator, %{})
    end
  end

  describe "task_ready/2" do
    test "lists open, unblocked tasks in the workspace", ctx do
      assert {:ok, %{tasks: tasks, count: count}} = Tools.task_ready(ctx.coordinator, %{})
      assert count >= 1
      assert Enum.any?(tasks, &(&1.id == ctx.task.id))
    end
  end

  describe "task_show/2 child-progress rollup" do
    test "a parent task reports child_total / child_closed over its parent_of children", ctx do
      {:ok, parent} =
        Ash.create(Issue, %{title: "epic parent", issue_type: :epic, workspace_id: ctx.ws.id})

      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ctx.ws.id})
      {:ok, c2} = Ash.create(Issue, %{title: "c2", workspace_id: ctx.ws.id})

      for c <- [c1, c2] do
        {:ok, _} =
          Ash.create(Dependency, %{
            from_issue_id: parent.id,
            to_issue_id: c.id,
            type: :parent_of
          })
      end

      {:ok, _} = Ash.update(c1, %{}, action: :close)

      assert {:ok, data} = Tools.task_show(ctx.coordinator, %{"id" => parent.id, "full" => true})
      assert data.child_total == 2
      assert data.child_closed == 1
      assert data.child_open == 1
      assert data.auto_close == false
    end

    test "a leaf task reports zero children", ctx do
      assert {:ok, data} = Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id})
      assert data.child_total == 0
      assert data.child_closed == 0
    end
  end

  describe "task_show/2 slim vs full payload" do
    test "default (no full param) returns slim fields only", ctx do
      assert {:ok, data} = Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id})
      assert Map.has_key?(data, :id)
      assert Map.has_key?(data, :title)
      assert Map.has_key?(data, :description)
      assert Map.has_key?(data, :acceptance)
      assert Map.has_key?(data, :status)
      assert Map.has_key?(data, :priority)
      assert Map.has_key?(data, :difficulty)
      assert Map.has_key?(data, :issue_type)
      refute Map.has_key?(data, :notes)
      refute Map.has_key?(data, :qa_notes)
      refute Map.has_key?(data, :deployment_notes)
      refute Map.has_key?(data, :pr_body)
      refute Map.has_key?(data, :auto_close)
      refute Map.has_key?(data, :created_at)
    end

    test "full: false returns slim fields only", ctx do
      assert {:ok, data} =
               Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id, "full" => false})

      refute Map.has_key?(data, :notes)
      refute Map.has_key?(data, :auto_close)
    end

    test "full: true returns complete record including review fields", ctx do
      assert {:ok, data} =
               Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id, "full" => true})

      assert Map.has_key?(data, :notes)
      assert Map.has_key?(data, :qa_notes)
      assert Map.has_key?(data, :deployment_notes)
      refute Map.has_key?(data, :pr_body)
      assert Map.has_key?(data, :auto_close)
      assert Map.has_key?(data, :created_at)
      assert Map.has_key?(data, :updated_at)
    end
  end

  describe "inbox_check/2" do
    test "returns the unread mailbox for the worker's task and marks it read", ctx do
      {:ok, _} = Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: ctx.task.id, body: "ping"})

      assert {:ok, %{messages: [msg], count: 1, task_id: task_id}} =
               Tools.inbox_check(ctx.worker, %{})

      assert task_id == ctx.task.id
      assert msg.body == "ping"

      # Second check is empty — the first marked them read.
      assert {:ok, %{count: 0}} = Tools.inbox_check(ctx.worker, %{})
    end
  end

  describe "coordinator_inbox/2" do
    test "lists unread Admiral messages and marks them read", ctx do
      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "Escalation!"})

      assert {:ok,
              %{
                messages: [msg],
                count: 1,
                deleted_read: 0,
                deleted_unread: 0,
                remaining_unread: 0
              }} =
               Tools.coordinator_inbox(ctx.coordinator, %{})

      assert msg.body == "Escalation!"
      assert msg.to_ref == "admiral"

      # Second call is empty — the first marked them read.
      assert {:ok, %{count: 0}} = Tools.coordinator_inbox(ctx.coordinator, %{})
    end

    test "clear: true destroys already-read messages (including the ones just marked read)",
         ctx do
      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "first"})

      # First call: lists "first" and marks it read.
      {:ok, %{count: 1}} = Tools.coordinator_inbox(ctx.coordinator, %{})

      # Send a second unread message.
      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "second"})

      # With clear: true — lists "second" (count: 1), marks it read, then clears all already-read
      # messages. "first" and "second" are both read at this point, so deleted_read: 2.
      assert {:ok, %{count: 1, deleted_read: 2, deleted_unread: 0, remaining_unread: 0}} =
               Tools.coordinator_inbox(ctx.coordinator, %{"clear" => true})
    end

    test "does not surface messages from another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "ci-other", prefix: "cio"})

      {:ok, _} =
        Message.send_mail(%{workspace_id: other_ws.id, to_ref: "admiral", body: "foreign"})

      assert {:ok, %{count: 0}} = Tools.coordinator_inbox(ctx.coordinator, %{})
    end

    test "worker tier is denied (catalog-level gating)", ctx do
      assert {:rpc_error, -32_003, message} =
               Catalog.call(ctx.worker, "coordinator_inbox", %{})

      assert message =~ "not permitted"
    end
  end

  describe "workspace_show/2" do
    test "returns the scope's own workspace config + resolved security posture", ctx do
      assert {:ok, data} = Tools.workspace_show(ctx.worker, %{})
      assert data.id == ctx.ws.id
      assert data.prefix == "mcp"
      assert is_map(data.config)
      assert is_binary(data.security["mode"])
    end
  end

  describe "quota_get/2" do
    test "returns null claude quota before anything is captured", ctx do
      assert {:ok, %{claude: nil}} = Tools.quota_get(ctx.worker, %{})
    end

    test "returns the captured snapshot for the scope's workspace", ctx do
      {:ok, _} =
        Arbiter.Quota.capture(ctx.ws.id, [
          {"anthropic-ratelimit-unified-5h-utilization", "0.42"},
          {"anthropic-ratelimit-unified-5h-status", "allowed"},
          {"anthropic-ratelimit-unified-representative-claim", "five_hour"}
        ])

      assert {:ok, %{claude: claude}} = Tools.quota_get(ctx.worker, %{})
      assert claude.utilization_5h == 0.42
      assert claude.representative_claim == "five_hour"
    end
  end

  describe "task_update_progress/2" do
    test "a worker records qa/deployment notes on its own task", ctx do
      assert {:ok, data} =
               Tools.task_update_progress(ctx.worker, %{
                 "qa_notes" => "verify the login flow",
                 "deployment_notes" => "None"
               })

      assert data.qa_notes == "verify the login flow"
      assert data.deployment_notes == "None"

      {:ok, reloaded} = Ash.get(Issue, ctx.task.id)
      assert reloaded.qa_notes == "verify the login flow"
    end

    test "a worker records pr_body on its own task (bd-53xrmi)", ctx do
      body = "## Summary\nWorker-authored.\n\n## Test plan\n- [x] mix test"

      assert {:ok, data} = Tools.task_update_progress(ctx.worker, %{"pr_body" => body})
      assert data.pr_body == body

      {:ok, reloaded} = Ash.get(Issue, ctx.task.id)
      assert reloaded.pr_body == body
    end

    test "ignores non-progress fields (cannot flip status)", ctx do
      assert {:ok, data} =
               Tools.task_update_progress(ctx.worker, %{"notes" => "wip", "status" => "closed"})

      assert data.status == "open"
      assert data.notes == "wip"
    end

    test "requires at least one progress field", ctx do
      assert {:error, {:invalid, _}} = Tools.task_update_progress(ctx.worker, %{})
    end

    test "a worker may not progress another task", ctx do
      {:ok, other} = Ash.create(Issue, %{title: "not yours", workspace_id: ctx.ws.id})

      assert {:error, {:unauthorized, _}} =
               Tools.task_update_progress(ctx.worker, %{"id" => other.id, "notes" => "x"})
    end
  end

  # ---- Phase 2: coordinator-only mutating tools --------------------------

  describe "task_create/2" do
    test "a coordinator creates a task forced into its own workspace", ctx do
      assert {:ok, data} =
               Tools.task_create(ctx.coordinator, %{
                 "title" => "new work",
                 "priority" => 1,
                 "issue_type" => "bug"
               })

      assert data.title == "new work"
      assert data.priority == 1
      assert data.issue_type == "bug"
      assert data.status == "open"
      assert data.workspace_id == ctx.ws.id

      {:ok, reloaded} = Ash.get(Issue, data.id)
      assert reloaded.workspace_id == ctx.ws.id
    end

    test "requires a title", ctx do
      assert {:error, {:invalid, _}} = Tools.task_create(ctx.coordinator, %{"priority" => 1})
    end

    test "rejects an unknown enum value", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.task_create(ctx.coordinator, %{"title" => "x", "issue_type" => "nope"})

      assert msg =~ "issue_type"
    end
  end

  describe "task_update/2" do
    test "a coordinator updates fields on a task in its workspace", ctx do
      assert {:ok, data} =
               Tools.task_update(ctx.coordinator, %{
                 "id" => ctx.task.id,
                 "status" => "in_progress",
                 "priority" => 0
               })

      assert data.status == "in_progress"
      assert data.priority == 0
    end

    test "cannot close a task through task_update (closed status rejected)", ctx do
      assert {:error, {:invalid, _}} =
               Tools.task_update(ctx.coordinator, %{"id" => ctx.task.id, "status" => "closed"})

      {:ok, reloaded} = Ash.get(Issue, ctx.task.id)
      assert reloaded.status == :open
    end

    test "requires at least one field to update", ctx do
      assert {:error, {:invalid, _}} = Tools.task_update(ctx.coordinator, %{"id" => ctx.task.id})
    end

    test "cannot update a task in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "bu-other", prefix: "buo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.task_update(ctx.coordinator, %{"id" => foreign.id, "notes" => "x"})
    end
  end

  describe "task_close/2" do
    test "a coordinator closes a task in its workspace", ctx do
      assert {:ok, data} =
               Tools.task_close(ctx.coordinator, %{"id" => ctx.task.id, "reason" => "done"})

      assert data.status == "closed"

      {:ok, reloaded} = Ash.get(Issue, ctx.task.id)
      assert reloaded.status == :closed
    end
  end

  describe "dep_add/2 + dep_remove/2" do
    setup ctx do
      {:ok, other} = Ash.create(Issue, %{title: "blocker", workspace_id: ctx.ws.id})
      {:ok, other: other}
    end

    test "adds and removes a dependency edge between tasks in the workspace", ctx do
      assert {:ok, dep} =
               Tools.dep_add(ctx.coordinator, %{
                 "from_issue_id" => ctx.task.id,
                 "to_issue_id" => ctx.other.id,
                 "type" => "depends_on"
               })

      assert dep.from_issue_id == ctx.task.id
      assert dep.to_issue_id == ctx.other.id
      assert dep.type == "depends_on"

      assert {:ok, %{removed: 1}} =
               Tools.dep_remove(ctx.coordinator, %{
                 "from_issue_id" => ctx.task.id,
                 "to_issue_id" => ctx.other.id
               })

      assert Dependency |> Ash.read!() |> Enum.empty?()
    end

    test "rejects an unknown dependency type", ctx do
      assert {:error, {:invalid, _}} =
               Tools.dep_add(ctx.coordinator, %{
                 "from_issue_id" => ctx.task.id,
                 "to_issue_id" => ctx.other.id,
                 "type" => "nonsense"
               })
    end

    test "cannot point an edge at a task in another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "dep-other", prefix: "dpo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.dep_add(ctx.coordinator, %{
                 "from_issue_id" => ctx.task.id,
                 "to_issue_id" => foreign.id,
                 "type" => "blocks"
               })
    end

    test "dep_remove is idempotent (absent edge → removed: 0)", ctx do
      assert {:ok, %{removed: 0}} =
               Tools.dep_remove(ctx.coordinator, %{
                 "from_issue_id" => ctx.task.id,
                 "to_issue_id" => ctx.other.id
               })
    end
  end

  describe "parent/child grouping via dep_add parent_of + auto_close" do
    test "task_create accepts auto_close and task_update can toggle it", ctx do
      assert {:ok, parent} =
               Tools.task_create(ctx.coordinator, %{
                 "title" => "epic",
                 "issue_type" => "epic",
                 "auto_close" => true
               })

      assert parent.issue_type == "epic"
      assert parent.auto_close == true

      assert {:ok, updated} =
               Tools.task_update(ctx.coordinator, %{"id" => parent.id, "auto_close" => false})

      assert updated.auto_close == false
    end

    test "attaching a child with a parent_of edge auto-closes the parent when done", ctx do
      assert {:ok, parent} =
               Tools.task_create(ctx.coordinator, %{"title" => "epic", "auto_close" => true})

      {:ok, child} = Ash.create(Issue, %{title: "child", workspace_id: ctx.ws.id})

      assert {:ok, _dep} =
               Tools.dep_add(ctx.coordinator, %{
                 "from_issue_id" => parent.id,
                 "to_issue_id" => child.id,
                 "type" => "parent_of"
               })

      {:ok, _} = Ash.update(child, %{}, action: :close)

      assert {:ok, data} = Tools.task_show(ctx.coordinator, %{"id" => parent.id})
      assert data.status == "closed"
      assert data.child_closed == 1
      assert data.child_total == 1
    end
  end

  describe "message_send/2" do
    test "a coordinator sends a direction to a task's mailbox, scoped to its workspace", ctx do
      assert {:ok, msg} =
               Tools.message_send(ctx.coordinator, %{
                 "task_id" => ctx.task.id,
                 "body" => "pick this up next"
               })

      assert msg.kind == "direction"
      assert msg.from_ref == "coordinator"
      assert msg.to_ref == ctx.task.id

      # It lands in the task's inbox.
      [inbox_msg] = Message.inbox(ctx.task.id, workspace_id: ctx.ws.id)
      assert inbox_msg.body == "pick this up next"
    end

    test "a worker raises a flag from its own task to a sibling", ctx do
      {:ok, sibling} = Ash.create(Issue, %{title: "sibling", workspace_id: ctx.ws.id})

      assert {:ok, msg} =
               Tools.message_send(ctx.worker, %{
                 "task_id" => sibling.id,
                 "body" => "heads up — the API shape changed"
               })

      # The sender identity is the worker's own task, set from the scope — not
      # spoofable by the client.
      assert msg.kind == "flag"
      assert msg.from_ref == ctx.task.id
      assert msg.to_ref == sibling.id

      [inbox_msg] = Message.inbox(sibling.id, workspace_id: ctx.ws.id)
      assert inbox_msg.body == "heads up — the API shape changed"
    end

    test "requires a recipient and a body", ctx do
      assert {:error, {:invalid, _}} =
               Tools.message_send(ctx.coordinator, %{"task_id" => ctx.task.id})
    end
  end

  describe "task_reopen/2" do
    test "a coordinator reopens a closed task", ctx do
      {:ok, _} = Ash.update(ctx.task, %{reason: "done"}, action: :close)

      assert {:ok, data} = Tools.task_reopen(ctx.coordinator, %{"id" => ctx.task.id})
      assert data.status == "open"
      assert is_nil(data.closed_at)

      {:ok, reloaded} = Ash.get(Issue, ctx.task.id)
      assert reloaded.status == :open
    end

    test "reopening a non-closed task is rejected (FSM guard)", ctx do
      assert {:error, {:invalid, _}} = Tools.task_reopen(ctx.coordinator, %{"id" => ctx.task.id})
    end

    test "cannot reopen a task in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "ro-other", prefix: "roo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.task_reopen(ctx.coordinator, %{"id" => foreign.id})
    end
  end

  describe "notify_list/2" do
    test "lists recent notifications scoped to the workspace (both tiers)", ctx do
      {:ok, _} = Message.notify(%{workspace_id: ctx.ws.id, body: "a worker finished"})

      assert {:ok, %{notifications: [n], count: 1}} = Tools.notify_list(ctx.coordinator, %{})
      assert n.body == "a worker finished"
      assert n.kind == "notification"

      # A worker sees the same workspace feed.
      assert {:ok, %{count: 1}} = Tools.notify_list(ctx.worker, %{})
    end

    test "does not leak notifications from another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "nf-other", prefix: "nfo"})
      {:ok, _} = Message.notify(%{workspace_id: other_ws.id, body: "elsewhere"})
      {:ok, _} = Message.notify(%{workspace_id: ctx.ws.id, body: "here"})

      assert {:ok, %{notifications: notifications}} = Tools.notify_list(ctx.coordinator, %{})
      assert Enum.all?(notifications, &(&1.body == "here"))
    end

    test "honors a limit", ctx do
      for i <- 1..3, do: Message.notify(%{workspace_id: ctx.ws.id, body: "n#{i}"})

      assert {:ok, %{count: 2}} = Tools.notify_list(ctx.coordinator, %{"limit" => 2})
    end
  end

  describe "tracker_claim/2 + tracker_sync/2 (tracker = none)" do
    test "claim refuses when the workspace tracker does not support it", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.tracker_claim(ctx.coordinator, %{"ref" => "42"})

      assert msg =~ "tracker"
    end

    test "claim requires a ref", ctx do
      assert {:error, {:invalid, _}} = Tools.tracker_claim(ctx.coordinator, %{})
    end

    test "sync (dry) returns an empty plan for a none-tracker workspace", ctx do
      assert {:ok, %{applied: false, actions: [], count: 0}} =
               Tools.tracker_sync(ctx.coordinator, %{"dry" => true})
    end

    test "sync (apply) no-ops cleanly for a none-tracker workspace", ctx do
      assert {:ok, %{applied: true, actions: [], results: []}} =
               Tools.tracker_sync(ctx.coordinator, %{})
    end
  end

  describe "workspace_list/2" do
    test "enumerates workspaces with summary fields", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "wl-other", prefix: "wlo"})

      assert {:ok, %{workspaces: workspaces, count: count}} =
               Tools.workspace_list(ctx.coordinator, %{})

      assert count >= 2
      entry = Enum.find(workspaces, &(&1.id == ctx.ws.id))
      assert entry.name == "mcp-tools-ws"
      assert entry.prefix == "mcp"
      assert is_binary(entry.tracker_type)
      assert Enum.any?(workspaces, &(&1.id == other_ws.id))

      # Summary only — no config / security posture leaks through.
      refute Map.has_key?(entry, :config)
      refute Map.has_key?(entry, :security)
    end
  end

  describe "worker_resume/2 + worker_review/2 (dispatch-recursion guardrail, §4.3)" do
    test "resume refuses a coordinator scope without can_dispatch", ctx do
      no_dispatch = %{ctx.coordinator | can_dispatch: false}

      assert {:error, {:unauthorized, _}} =
               Tools.worker_resume(no_dispatch, %{"task_id" => ctx.task.id})
    end

    test "review refuses a coordinator scope without can_dispatch", ctx do
      no_dispatch = %{ctx.coordinator | can_dispatch: false}

      assert {:error, {:unauthorized, _}} =
               Tools.worker_review(no_dispatch, %{"task_id" => ctx.task.id})
    end

    test "resume refuses once the depth limit is reached", ctx do
      at_limit = %{ctx.coordinator | depth: MCP.max_depth()}

      assert {:error, {:unauthorized, msg}} =
               Tools.worker_resume(at_limit, %{"task_id" => ctx.task.id})

      assert msg =~ "depth"
    end

    test "review cannot target a task in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "rv-other", prefix: "rvo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.worker_review(ctx.coordinator, %{"task_id" => foreign.id})
    end

    test "external review (pr) refuses a coordinator scope without can_dispatch", ctx do
      no_dispatch = %{ctx.coordinator | can_dispatch: false}

      assert {:error, {:unauthorized, _}} =
               Tools.worker_review(no_dispatch, %{"pr" => "octo/widget#5"})
    end

    test "external review (pr) on a direct-strategy workspace is unsupported", ctx do
      # The bound workspace has no merge config → :direct, which can't review an
      # external PR. The dispatch gate passes; the strategy check rejects it.
      assert {:error, {:invalid, msg}} =
               Tools.worker_review(ctx.coordinator, %{"pr" => "octo/widget#5"})

      assert msg =~ "not supported"
    end

    test "external review (pr) acks against a github-strategy workspace" do
      {:ok, gh_ws} =
        Ash.create(Workspace, %{
          name: "rv-github",
          prefix: "rvg",
          config: %{"merge" => %{"strategy" => "github", "config" => %{}}}
        })

      coordinator = %Scope{tier: :coordinator, workspace_id: gh_ws.id, can_dispatch: true}

      assert {:ok, ack} =
               Tools.worker_review(coordinator, %{
                 "pr" => "https://github.com/leo/verus_sigv4/pull/5"
               })

      assert ack.external == true
      assert ack.status == "dispatched"
      assert ack.mr_ref == "leo/verus_sigv4#5"
      assert ack.strategy == :github
    end

    test "resume surfaces the no-worktree error for a task never slung", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "never slung", workspace_id: ctx.ws.id})

      # can_dispatch + in-workspace + below depth, but no preserved worktree exists.
      assert {:error, {:invalid, msg}} =
               Tools.worker_resume(ctx.coordinator, %{"task_id" => task.id, "repo" => "test/repo"})

      assert msg =~ "worktree" or msg =~ "repo"
    end
  end

  describe "worker_stop/2" do
    test "stops a running worker in the workspace", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "stop target", workspace_id: ctx.ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(task.id, :normal) end)

      assert {:ok, %{task_id: task_id, stopped: true}} =
               Tools.worker_stop(ctx.coordinator, %{"task_id" => task.id})

      assert task_id == task.id
    end

    test "a task with no live worker is reported not-found", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "no worker", workspace_id: ctx.ws.id})

      assert {:error, {:not_found, _}} =
               Tools.worker_stop(ctx.coordinator, %{"task_id" => task.id})
    end

    test "cannot stop a worker for a task in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "st-other", prefix: "sto"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      {:ok, pid} = Worker.start(task_id: foreign.id, repo: "test/repo", workspace_id: other_ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(foreign.id, :normal) end)

      assert {:error, {:not_found, _}} =
               Tools.worker_stop(ctx.coordinator, %{"task_id" => foreign.id})
    end
  end

  describe "usage_summarize/2" do
    test "requires a valid `by` grouping", ctx do
      assert {:error, {:invalid, _}} = Tools.usage_summarize(ctx.coordinator, %{})
      assert {:error, {:invalid, _}} = Tools.usage_summarize(ctx.coordinator, %{"by" => "nope"})
    end

    test "returns rollups for a valid grouping (empty ledger → no rows)", ctx do
      assert {:ok, %{by: "task", rollups: rollups, count: 0}} =
               Tools.usage_summarize(ctx.coordinator, %{"by" => "task"})

      assert rollups == []
    end
  end

  describe "worker_dispatch/2 (dispatch-recursion guardrail, §4.3)" do
    test "refuses a coordinator scope without can_dispatch", ctx do
      no_dispatch = %{ctx.coordinator | can_dispatch: false}

      assert {:error, {:unauthorized, _}} =
               Tools.worker_dispatch(no_dispatch, %{"task_id" => ctx.task.id})
    end

    test "refuses once the depth limit is reached", ctx do
      at_limit = %{ctx.coordinator | depth: MCP.max_depth()}

      assert {:error, {:unauthorized, msg}} =
               Tools.worker_dispatch(at_limit, %{"task_id" => ctx.task.id})

      assert msg =~ "depth"
    end

    test "cannot dispatch a task in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "sl-other", prefix: "slo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.worker_dispatch(ctx.coordinator, %{"task_id" => foreign.id})
    end

    # Without a provider, the workspace's `agent.type` config is used — the same
    # real-work path as an explicit `provider`. Without a configured repo that
    # path surfaces a repo error, proving the workspace default was honored (a
    # park would return {:ok, ...} with claude_started: false).
    test "omitting provider takes the workspace-default real-work path (not a park)", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "default dispatch", workspace_id: ctx.ws.id})

      assert {:error, {:invalid, msg}} =
               Tools.worker_dispatch(ctx.coordinator, %{
                 "task_id" => task.id,
                 "repo" => "test/repo"
               })

      assert msg =~ "repo"

      on_exit(fn -> Worker.stop(task.id, :normal) end)
    end

    test "no_agent: true parks the task in_progress (explicit hand-off)", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "parked dispatch", workspace_id: ctx.ws.id})

      assert {:ok, data} =
               Tools.worker_dispatch(ctx.coordinator, %{
                 "task_id" => task.id,
                 "repo" => "test/repo",
                 "no_agent" => true
               })

      assert data.task.status == "in_progress"
      assert data.claude_started == false
      assert data.depth == ctx.coordinator.depth + 1

      on_exit(fn -> Worker.stop(task.id, :normal) end)
    end

    # `provider` (and the deprecated `with_claude` alias) take the real-work
    # dispatch path. Without a configured repo that path surfaces a repo error —
    # which is exactly the signal that the provider was honored as a worker
    # dispatch (a park would have returned {:ok, ...} with claude_started: false).
    test "provider: \"gemini\" takes the real-work path (not a park)", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "gem dispatch", workspace_id: ctx.ws.id})

      assert {:error, {:invalid, msg}} =
               Tools.worker_dispatch(ctx.coordinator, %{
                 "task_id" => task.id,
                 "provider" => "gemini",
                 "repo" => "test/repo"
               })

      assert msg =~ "repo"

      on_exit(fn -> Worker.stop(task.id, :normal) end)
    end

    test "provider: \"claude\" takes the real-work path (not a park)", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "claude dispatch", workspace_id: ctx.ws.id})

      assert {:error, {:invalid, msg}} =
               Tools.worker_dispatch(ctx.coordinator, %{
                 "task_id" => task.id,
                 "provider" => "claude",
                 "repo" => "test/repo"
               })

      assert msg =~ "repo"

      on_exit(fn -> Worker.stop(task.id, :normal) end)
    end

    test "the deprecated with_claude: true alias still dispatches a worker", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "alias dispatch", workspace_id: ctx.ws.id})

      assert {:error, {:invalid, msg}} =
               Tools.worker_dispatch(ctx.coordinator, %{
                 "task_id" => task.id,
                 "with_claude" => true,
                 "repo" => "test/repo"
               })

      assert msg =~ "repo"

      on_exit(fn -> Worker.stop(task.id, :normal) end)
    end
  end

  describe "worker_list/2" do
    test "returns an empty list when no workers are running in the workspace", ctx do
      assert {:ok, %{workers: [], count: 0}} = Tools.worker_list(ctx.coordinator, %{})
    end

    test "returns active workers scoped to the coordinator's workspace", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "worker-list target", workspace_id: ctx.ws.id})

      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(task.id, :normal) end)

      assert {:ok, %{workers: workers, count: count}} = Tools.worker_list(ctx.coordinator, %{})
      assert count >= 1
      assert Enum.any?(workers, &(&1.task_id == task.id))

      entry = Enum.find(workers, &(&1.task_id == task.id))
      assert is_binary(entry.repo)
      assert is_binary(entry.status)
      assert entry.repo == "test/repo"
    end

    test "does not include workers from another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "pl-other", prefix: "plo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign pc", workspace_id: other_ws.id})

      {:ok, _pid} =
        Worker.start(task_id: foreign.id, repo: "test/repo", workspace_id: other_ws.id)

      on_exit(fn -> Worker.stop(foreign.id, :normal) end)

      assert {:ok, %{workers: workers}} = Tools.worker_list(ctx.coordinator, %{})
      refute Enum.any?(workers, &(&1.task_id == foreign.id))
    end

    test "surfaces the provider/model from the worker's routing config", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "gemini worker", workspace_id: ctx.ws.id})

      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(task.id, :normal) end)

      # Stamp the routing config the way Dispatch does at dispatch time.
      :ok = Worker.report(pid, :routing_config, %{provider: "gemini", model: "gemini-2.5-pro"})

      assert {:ok, %{workers: workers}} = Tools.worker_list(ctx.coordinator, %{})
      entry = Enum.find(workers, &(&1.task_id == task.id))

      assert entry.provider == "gemini"
      assert entry.model == "gemini-2.5-pro"
    end
  end

  describe "task_list/2" do
    test "lists all tasks in the workspace with no filters", ctx do
      assert {:ok, %{tasks: tasks, count: count}} = Tools.task_list(ctx.coordinator, %{})
      assert count >= 1
      assert Enum.any?(tasks, &(&1.id == ctx.task.id))
    end

    test "filters by status", ctx do
      # `:create` does not accept `:status` (and `:open` is the default anyway).
      {:ok, _} = Ash.create(Issue, %{title: "another open task", workspace_id: ctx.ws.id})

      assert {:ok, %{tasks: open_tasks}} = Tools.task_list(ctx.coordinator, %{"status" => "open"})
      assert Enum.all?(open_tasks, &(&1.status == "open"))

      assert {:ok, %{tasks: closed_tasks}} =
               Tools.task_list(ctx.coordinator, %{"status" => "closed"})

      assert Enum.all?(closed_tasks, &(&1.status == "closed"))
    end

    test "filters by issue_type", ctx do
      {:ok, bug} =
        Ash.create(Issue, %{title: "a bug", workspace_id: ctx.ws.id, issue_type: :bug})

      assert {:ok, %{tasks: bugs}} =
               Tools.task_list(ctx.coordinator, %{"issue_type" => "bug"})

      assert Enum.all?(bugs, &(&1.issue_type == "bug"))
      assert Enum.any?(bugs, &(&1.id == bug.id))
    end

    test "filters by priority", ctx do
      {:ok, p0} = Ash.create(Issue, %{title: "urgent", workspace_id: ctx.ws.id, priority: 0})

      assert {:ok, %{tasks: p0_tasks}} = Tools.task_list(ctx.coordinator, %{"priority" => 0})
      assert Enum.any?(p0_tasks, &(&1.id == p0.id))
    end

    test "does not include tasks from another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "bl-other", prefix: "blo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign task", workspace_id: other_ws.id})

      assert {:ok, %{tasks: tasks}} = Tools.task_list(ctx.coordinator, %{})
      refute Enum.any?(tasks, &(&1.id == foreign.id))
    end

    test "rejects an invalid status value", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.task_list(ctx.coordinator, %{"status" => "bogus"})

      assert msg =~ "status"
    end

    test "rejects an invalid issue_type value", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.task_list(ctx.coordinator, %{"issue_type" => "bogus"})

      assert msg =~ "issue_type"
    end
  end

  describe "workspace-agnostic coordinator" do
    setup ctx do
      # A coordinator token with no bound workspace (workspace_id: nil) — the
      # shape `arb mcp token mint` / POST /api/mcp/tokens now produce.
      agnostic = %Scope{tier: :coordinator, workspace_id: nil, can_dispatch: true}

      {:ok, other_ws} = Ash.create(Workspace, %{name: "agnostic-other-ws", prefix: "agw"})
      {:ok, foreign} = Ash.create(Issue, %{title: "in the other ws", workspace_id: other_ws.id})

      {:ok, Map.merge(ctx, %{agnostic: agnostic, other_ws: other_ws, foreign: foreign})}
    end

    test "reads a task in any workspace, inferring the workspace from the entity", ctx do
      assert {:ok, here} = Tools.task_show(ctx.agnostic, %{"id" => ctx.task.id})
      assert here.id == ctx.task.id

      assert {:ok, there} =
               Tools.task_show(ctx.agnostic, %{"id" => ctx.foreign.id, "full" => true})

      assert there.id == ctx.foreign.id
      assert there.workspace_id == ctx.other_ws.id
    end

    test "creates a task in the workspace named by the `workspace` param (by name)", ctx do
      assert {:ok, data} =
               Tools.task_create(ctx.agnostic, %{
                 "title" => "explicit by name",
                 "workspace" => ctx.other_ws.name
               })

      assert data.workspace_id == ctx.other_ws.id
    end

    test "creates a task in the workspace named by the `workspace` param (by id)", ctx do
      assert {:ok, data} =
               Tools.task_create(ctx.agnostic, %{
                 "title" => "explicit by id",
                 "workspace" => ctx.other_ws.id
               })

      assert data.workspace_id == ctx.other_ws.id
    end

    test "an unknown `workspace` ref is a not-found tool error", ctx do
      assert {:error, {:not_found, msg}} =
               Tools.task_create(ctx.agnostic, %{"title" => "x", "workspace" => "nope-ws"})

      assert msg =~ "workspace"
    end

    test "lists tasks in the workspace named by the `workspace` param", ctx do
      assert {:ok, %{tasks: tasks}} =
               Tools.task_list(ctx.agnostic, %{"workspace" => ctx.other_ws.name})

      assert Enum.any?(tasks, &(&1.id == ctx.foreign.id))
      refute Enum.any?(tasks, &(&1.id == ctx.task.id))
    end

    test "shows the workspace named by the `workspace` param", ctx do
      assert {:ok, data} = Tools.workspace_show(ctx.agnostic, %{"workspace" => ctx.other_ws.id})
      assert data.id == ctx.other_ws.id
      assert data.name == ctx.other_ws.name
    end

    test "directs a message to a task in any workspace, pinned to that task's workspace", ctx do
      assert {:ok, _msg} =
               Tools.message_send(ctx.agnostic, %{
                 "task_id" => ctx.foreign.id,
                 "body" => "do this"
               })

      [mail] = Message.inbox(ctx.foreign.id, workspace_id: ctx.other_ws.id)
      assert mail.workspace_id == ctx.other_ws.id
      assert mail.from_ref == "coordinator"
    end

    test "with no `workspace` and multiple workspaces, create needs an explicit workspace", ctx do
      # The setup created several workspaces and none is named "default", so the
      # installation default is ambiguous.
      assert {:error, {:invalid, msg}} =
               Tools.task_create(ctx.agnostic, %{"title" => "ambiguous"})

      assert msg =~ "workspace"
    end
  end

  describe "default workspace resolution" do
    test "a workspace-agnostic coordinator with no `workspace` falls back to the lone workspace",
         ctx do
      # The module setup creates exactly one workspace (ctx.ws) in this sandbox,
      # so it is unambiguously the installation default.
      agnostic = %Scope{tier: :coordinator, workspace_id: nil, can_dispatch: true}

      assert {:ok, data} = Tools.task_create(agnostic, %{"title" => "lands in the only ws"})
      assert data.workspace_id == ctx.ws.id
    end

    test "a coordinator falls back to the workspace named \"default\" when several exist" do
      {:ok, default} = Ash.create(Workspace, %{name: "default", prefix: "def"})
      {:ok, _other} = Ash.create(Workspace, %{name: "another-ws", prefix: "anow"})
      agnostic = %Scope{tier: :coordinator, workspace_id: nil, can_dispatch: true}

      assert {:ok, data} = Tools.task_create(agnostic, %{"title" => "to default"})
      assert data.workspace_id == default.id
    end
  end

  describe "workspace-bound scope rejection" do
    test "a bound coordinator naming a different workspace is unauthorized", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "bound-other-ws", prefix: "bow"})

      assert {:error, {:unauthorized, _}} =
               Tools.task_create(ctx.coordinator, %{"title" => "x", "workspace" => other_ws.id})
    end

    test "a worker naming a different workspace is unauthorized", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "pc-other-ws", prefix: "pco"})

      assert {:error, {:unauthorized, _}} =
               Tools.task_show(ctx.worker, %{"id" => ctx.task.id, "workspace" => other_ws.id})
    end
  end

  describe "Catalog.call/3 dispatch" do
    test "routes an authorized call to its handler and returns structured data", ctx do
      assert {:ok, data} = Catalog.call(ctx.worker, "task_show", %{})
      assert data.id == ctx.task.id
    end

    test "maps a handler not-found into a tool error (not a JSON-RPC error)", ctx do
      assert {:tool_error, message} =
               Catalog.call(ctx.coordinator, "task_show", %{"id" => "bd-does-not-exist"})

      assert message =~ "not found"
    end
  end
end
