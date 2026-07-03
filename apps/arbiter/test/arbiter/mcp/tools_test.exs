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

  describe "coordinator_inbox_peek/2" do
    test "lists unread Admiral messages without marking them read", ctx do
      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "Escalation!"})

      assert {:ok, %{messages: [msg], count: 1}} =
               Tools.coordinator_inbox_peek(ctx.coordinator, %{})

      assert msg.body == "Escalation!"
      assert msg.to_ref == "admiral"

      # Second call still returns the message — it was not marked read.
      assert {:ok, %{messages: [msg2], count: 1}} =
               Tools.coordinator_inbox_peek(ctx.coordinator, %{})

      assert msg2.body == "Escalation!"
    end

    test "does not mutate unread count across calls", ctx do
      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "first"})

      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "second"})

      # First peek: both messages are there.
      assert {:ok, %{count: 2}} = Tools.coordinator_inbox_peek(ctx.coordinator, %{})

      # Second peek: still both — they were never marked read.
      assert {:ok, %{count: 2}} = Tools.coordinator_inbox_peek(ctx.coordinator, %{})

      # coordinator_inbox (mutating) marks them read; after that, peek is empty.
      {:ok, _} = Tools.coordinator_inbox(ctx.coordinator, %{})

      assert {:ok, %{count: 0}} = Tools.coordinator_inbox_peek(ctx.coordinator, %{})
    end

    test "does not surface messages from another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "ci-other", prefix: "cio"})

      {:ok, _} =
        Message.send_mail(%{workspace_id: other_ws.id, to_ref: "admiral", body: "foreign"})

      assert {:ok, %{count: 0}} = Tools.coordinator_inbox_peek(ctx.coordinator, %{})
    end

    test "worker tier is denied (catalog-level gating)", ctx do
      assert {:rpc_error, -32_003, message} =
               Catalog.call(ctx.worker, "coordinator_inbox_peek", %{})

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

      assert data.id == ctx.task.id
      assert data.status == "open"

      {:ok, full} = Tools.task_show(ctx.worker, %{"full" => true})
      assert full.qa_notes == "verify the login flow"
      assert full.deployment_notes == "None"
    end

    test "a worker records pr_body on its own task (bd-53xrmi)", ctx do
      body = "## Summary\nWorker-authored.\n\n## Test plan\n- [x] mix test"

      assert {:ok, data} = Tools.task_update_progress(ctx.worker, %{"pr_body" => body})
      assert data.id == ctx.task.id

      {:ok, full} = Tools.task_show(ctx.worker, %{"full" => true})
      assert full.pr_body == body
    end

    test "ignores non-progress fields (cannot flip status)", ctx do
      assert {:ok, data} =
               Tools.task_update_progress(ctx.worker, %{"notes" => "wip", "status" => "closed"})

      assert data.status == "open"

      {:ok, full} = Tools.task_show(ctx.worker, %{"full" => true})
      assert full.notes == "wip"
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

    test "accepts tracker_context_type and tracker_context_ref (bd-2eo4cg)", ctx do
      assert {:ok, data} =
               Tools.task_create(ctx.coordinator, %{
                 "title" => "review context task",
                 "tracker_type" => "none",
                 "tracker_context_type" => "jira",
                 "tracker_context_ref" => "VR-18004"
               })

      {:ok, reloaded} = Ash.get(Issue, data.id)
      assert reloaded.tracker_context_type == :jira
      assert reloaded.tracker_context_ref == "VR-18004"
      # tracker_type stays none — context ref is read-only and never claimed
      assert reloaded.tracker_type == :none
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

      {:ok, created} = Tools.task_show(ctx.coordinator, %{"id" => parent.id, "full" => true})
      assert created.auto_close == true

      assert {:ok, _updated} =
               Tools.task_update(ctx.coordinator, %{"id" => parent.id, "auto_close" => false})

      {:ok, updated_full} = Tools.task_show(ctx.coordinator, %{"id" => parent.id, "full" => true})
      assert updated_full.auto_close == false
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

    test "accepts optional kind parameter to override auto-derived kind", ctx do
      assert {:ok, msg} =
               Tools.message_send(ctx.coordinator, %{
                 "task_id" => ctx.task.id,
                 "body" => "escalation needed",
                 "kind" => "escalation"
               })

      assert msg.kind == "escalation"
      assert msg.from_ref == "coordinator"
      assert msg.to_ref == ctx.task.id
    end

    test "accepts optional directive_ref parameter", ctx do
      {:ok, other_task} = Ash.create(Issue, %{title: "other", workspace_id: ctx.ws.id})

      assert {:ok, msg} =
               Tools.message_send(ctx.coordinator, %{
                 "task_id" => ctx.task.id,
                 "body" => "issue with this task",
                 "directive_ref" => other_task.id
               })

      assert msg.directive_ref == other_task.id
    end

    test "rejects invalid kind values", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.message_send(ctx.coordinator, %{
                 "task_id" => ctx.task.id,
                 "body" => "message",
                 "kind" => "invalid_kind"
               })

      assert String.contains?(msg, "invalid kind")
    end

    test "kind=escalation sent by coordinator produces escalation message", ctx do
      assert {:ok, msg} =
               Tools.message_send(ctx.coordinator, %{
                 "task_id" => ctx.task.id,
                 "body" => "review failed — needs escalation",
                 "kind" => "escalation"
               })

      assert msg.kind == "escalation"

      # Verify it's stored correctly in the database
      {:ok, stored} = Ash.get(Message, msg.id)
      assert stored.kind == :escalation
    end
  end

  describe "task_reopen/2" do
    test "a coordinator reopens a closed task", ctx do
      {:ok, _} = Ash.update(ctx.task, %{reason: "done"}, action: :close)

      assert {:ok, data} = Tools.task_reopen(ctx.coordinator, %{"id" => ctx.task.id})
      assert data.status == "open"

      {:ok, full} = Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id, "full" => true})
      assert is_nil(full.closed_at)

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

  describe "workspace_config_get/2" do
    test "returns the full config when no key is given", ctx do
      {:ok, ws} =
        Ash.update(ctx.ws, %{patch: %{"merge" => %{"auto_merge" => true}}, unset_paths: []},
          action: :patch_config
        )

      assert {:ok, data} = Tools.workspace_config_get(ctx.worker, %{})
      assert data.workspace == ws.name
      assert is_nil(data.key)
      assert is_map(data.value)
      assert get_in(data.value, ["merge", "auto_merge"]) == true
      assert is_list(data.secret_keys)
    end

    test "returns a leaf value for a dotted key", ctx do
      {:ok, _} =
        Ash.update(ctx.ws, %{patch: %{"review" => %{"required" => true}}, unset_paths: []},
          action: :patch_config
        )

      assert {:ok, data} = Tools.workspace_config_get(ctx.worker, %{"key" => "review.required"})
      assert data.key == "review.required"
      assert data.value == true
    end

    test "returns a nested map for a non-leaf dotted key", ctx do
      {:ok, _} =
        Ash.update(
          ctx.ws,
          %{patch: %{"review" => %{"required" => true, "rounds" => 2}}, unset_paths: []},
          action: :patch_config
        )

      assert {:ok, data} = Tools.workspace_config_get(ctx.worker, %{"key" => "review"})
      assert data.value["required"] == true
      assert data.value["rounds"] == 2
    end

    test "errors when a key is not found", ctx do
      assert {:error, {:not_found, msg}} =
               Tools.workspace_config_get(ctx.worker, %{"key" => "nonexistent.key"})

      assert msg =~ "nonexistent.key"
    end

    test "a coordinator can read another workspace by name", _ctx do
      {:ok, other_ws} =
        Ash.create(Workspace, %{name: "cfg-get-other", prefix: "cgo"})

      {:ok, _} =
        Ash.update(
          other_ws,
          %{patch: %{"routing" => %{"policy" => "round_robin"}}, unset_paths: []},
          action: :patch_config
        )

      agnostic = %Scope{tier: :coordinator, workspace_id: nil}

      assert {:ok, data} =
               Tools.workspace_config_get(agnostic, %{"workspace" => "cfg-get-other"})

      assert data.workspace == "cfg-get-other"
      assert is_map(data.value)
    end
  end

  describe "workspace_config_overview/2" do
    test "returns the grouped overview map with all expected sections", ctx do
      {:ok, _} =
        Ash.update(
          ctx.ws,
          %{
            patch: %{
              "tracker" => %{"type" => "none"},
              "merge" => %{"strategy" => "direct", "auto_merge" => false},
              "routing" => %{"policy" => "static"}
            },
            unset_paths: []
          },
          action: :patch_config
        )

      assert {:ok, data} = Tools.workspace_config_overview(ctx.worker, %{})

      assert data.workspace.id == ctx.ws.id
      assert data.workspace.name == ctx.ws.name
      assert data.workspace.prefix == "mcp"
      assert is_map(data.tracker)
      assert is_map(data.merge)
      assert is_map(data.agent)
      assert is_map(data.review_agent)
      assert is_map(data.routing)
      assert is_map(data.review)
      assert is_map(data.review_gate)
      assert is_list(data.standing_orders)
      assert is_list(data.secret_keys)
    end

    test "a worker can call overview on its own workspace", ctx do
      assert {:ok, data} = Tools.workspace_config_overview(ctx.worker, %{})
      assert data.workspace.id == ctx.ws.id
    end
  end

  describe "workspace_config_set/2" do
    test "sets a scalar leaf and preserves siblings", ctx do
      {:ok, _} =
        Ash.update(
          ctx.ws,
          %{
            patch: %{"merge" => %{"strategy" => "direct", "auto_merge" => false}},
            unset_paths: []
          },
          action: :patch_config
        )

      assert {:ok, data} =
               Tools.workspace_config_set(ctx.coordinator, %{
                 "key" => "merge.auto_merge",
                 "value" => true
               })

      assert get_in(data.config, ["merge", "auto_merge"]) == true
      # sibling preserved
      assert get_in(data.config, ["merge", "strategy"]) == "direct"
      assert is_map(data.workspace)
      assert is_list(data.secret_keys)
    end

    test "sets a nested object, deep-merging into existing config", ctx do
      {:ok, _} =
        Ash.update(ctx.ws, %{patch: %{"routing" => %{"policy" => "static"}}, unset_paths: []},
          action: :patch_config
        )

      assert {:ok, data} =
               Tools.workspace_config_set(ctx.coordinator, %{
                 "key" => "routing.policy",
                 "value" => "round_robin"
               })

      assert get_in(data.config, ["routing", "policy"]) == "round_robin"
    end

    test "requires a key argument", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.workspace_config_set(ctx.coordinator, %{"value" => "x"})

      assert msg =~ "key"
    end

    test "requires a value argument", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.workspace_config_set(ctx.coordinator, %{"key" => "merge.auto_merge"})

      assert msg =~ "value"
    end

    test "blocks secret key prefix", ctx do
      assert {:error, {:unauthorized, msg}} =
               Tools.workspace_config_set(ctx.coordinator, %{
                 "key" => "secrets.my_token",
                 "value" => "tok_1234"
               })

      assert msg =~ "secrets"
    end

    test "blocks credentials key prefix", ctx do
      assert {:error, {:unauthorized, _}} =
               Tools.workspace_config_set(ctx.coordinator, %{
                 "key" => "credentials.api_key",
                 "value" => "x"
               })
    end
  end

  describe "workspace_config_unset/2" do
    test "removes a key and preserves siblings", ctx do
      {:ok, _} =
        Ash.update(
          ctx.ws,
          %{
            patch: %{"merge" => %{"strategy" => "direct", "auto_merge" => true}},
            unset_paths: []
          },
          action: :patch_config
        )

      assert {:ok, data} =
               Tools.workspace_config_unset(ctx.coordinator, %{"key" => "merge.auto_merge"})

      refute Map.has_key?(data.config["merge"] || %{}, "auto_merge")
      # sibling preserved
      assert get_in(data.config, ["merge", "strategy"]) == "direct"
    end

    test "errors if the key does not exist", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.workspace_config_unset(ctx.coordinator, %{"key" => "nonexistent.key"})

      assert msg =~ "nonexistent.key"
    end

    test "blocks secret key prefix", ctx do
      assert {:error, {:unauthorized, _}} =
               Tools.workspace_config_unset(ctx.coordinator, %{"key" => "secret.foo"})
    end

    test "requires a key argument", ctx do
      assert {:error, {:invalid, _}} = Tools.workspace_config_unset(ctx.coordinator, %{})
    end
  end

  describe "installation_config_get/2 + installation_config_set/2" do
    setup do
      on_exit(fn -> Arbiter.Settings.set_conductor_system_max_concurrent(nil) end)
      :ok
    end

    test "returns the full settings map when no key is given (worker tier)", ctx do
      assert {:ok, data} = Tools.installation_config_get(ctx.worker, %{})
      assert is_nil(data.key)
      assert data.value == %{conductor_system_max_concurrent: nil}
      assert data.settings == %{conductor_system_max_concurrent: nil}
    end

    test "returns a leaf value for a known key", ctx do
      {:ok, 5} = Arbiter.Settings.set_conductor_system_max_concurrent(5)

      assert {:ok, data} =
               Tools.installation_config_get(ctx.worker, %{
                 "key" => "conductor_system_max_concurrent"
               })

      assert data.key == "conductor_system_max_concurrent"
      assert data.value == 5
    end

    test "errors for an unknown key", ctx do
      assert {:error, {:not_found, msg}} =
               Tools.installation_config_get(ctx.worker, %{"key" => "nonexistent"})

      assert msg =~ "nonexistent"
    end

    test "coordinator can set a positive integer value", ctx do
      assert {:ok, data} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "conductor_system_max_concurrent",
                 "value" => 3
               })

      assert data.key == "conductor_system_max_concurrent"
      assert data.value == 3
      assert Arbiter.Settings.conductor_system_max_concurrent() == 3
    end

    test "coordinator can clear the override with a null value", ctx do
      {:ok, 3} = Arbiter.Settings.set_conductor_system_max_concurrent(3)

      assert {:ok, data} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "conductor_system_max_concurrent",
                 "value" => nil
               })

      assert data.value == nil
      assert Arbiter.Settings.conductor_system_max_concurrent() == nil
    end

    test "rejects an unknown key", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "nonexistent",
                 "value" => 1
               })

      assert msg =~ "nonexistent"
    end

    test "rejects a non-positive-integer value", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "conductor_system_max_concurrent",
                 "value" => 0
               })

      assert msg =~ "value"
    end

    test "requires a key argument", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.installation_config_set(ctx.coordinator, %{"value" => 1})

      assert msg =~ "key"
    end

    test "requires a value argument", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "conductor_system_max_concurrent"
               })

      assert msg =~ "value"
    end
  end

  describe "installation config tools — catalog visibility" do
    test "installation_config_get is visible to workers and coordinators", ctx do
      worker_names = Catalog.visible(ctx.worker) |> Enum.map(& &1.name)
      coord_names = Catalog.visible(ctx.coordinator) |> Enum.map(& &1.name)
      assert "installation_config_get" in worker_names
      assert "installation_config_get" in coord_names
    end

    test "installation_config_set is coordinator-only", ctx do
      worker_names = Catalog.visible(ctx.worker) |> Enum.map(& &1.name)
      coord_names = Catalog.visible(ctx.coordinator) |> Enum.map(& &1.name)
      assert "installation_config_set" in coord_names
      refute "installation_config_set" in worker_names
    end
  end

  describe "workspace config tools — catalog visibility" do
    test "workspace_config_get and workspace_config_overview are visible to workers", ctx do
      visible_names = Catalog.visible(ctx.worker) |> Enum.map(& &1.name)
      assert "workspace_config_get" in visible_names
      assert "workspace_config_overview" in visible_names
    end

    test "workspace_config_set and workspace_config_unset are coordinator-only", ctx do
      coord_names = Catalog.visible(ctx.coordinator) |> Enum.map(& &1.name)
      worker_names = Catalog.visible(ctx.worker) |> Enum.map(& &1.name)

      assert "workspace_config_set" in coord_names
      assert "workspace_config_unset" in coord_names
      refute "workspace_config_set" in worker_names
      refute "workspace_config_unset" in worker_names
    end

    test "all four config tools advertise the optional workspace field", _ctx do
      tools = Catalog.all()

      for name <-
            ~w(workspace_config_get workspace_config_overview workspace_config_set workspace_config_unset) do
        tool = Enum.find(tools, &(&1.name == name))
        assert tool != nil, "tool #{name} not found in catalog"

        assert Map.has_key?(tool.input_schema["properties"], "workspace"),
               "#{name} missing workspace field"
      end
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

    test "worker_review persists tracker_context_ref/type on task without claiming (bd-2eo4cg)",
         ctx do
      # A task with no tracker_ref — the review is for a coworker's ticket.
      {:ok, task} =
        Ash.create(Issue, %{
          title: "review for coworker PR",
          workspace_id: ctx.ws.id,
          tracker_type: :none
        })

      # worker_review with tracker_context_ref should set the fields without dispatch failing.
      # It will fail with a no-worktree/no-repo error (expected in the test env) but AFTER
      # persisting the tracker context on the task — that's what we verify.
      _result =
        Tools.worker_review(ctx.coordinator, %{
          "task_id" => task.id,
          "tracker_context_ref" => "VR-18004",
          "tracker_context_type" => "jira",
          "with_claude" => false
        })

      # The tracker context must be persisted on the task regardless of dispatch outcome.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.tracker_context_ref == "VR-18004"
      assert reloaded.tracker_context_type == :jira
      # tracker_type must remain :none — no claim, no write-back.
      assert reloaded.tracker_type == :none
    end

    test "task_show includes tracker_context_ref and tracker_context_type in full view (bd-2eo4cg)",
         ctx do
      {:ok, task} =
        Ash.update(ctx.task, %{tracker_context_type: :jira, tracker_context_ref: "VR-18004"},
          action: :update
        )

      {:ok, full} = Tools.task_show(ctx.coordinator, %{"id" => task.id, "full" => true})
      assert full.tracker_context_ref == "VR-18004"
      assert full.tracker_context_type == "jira"
    end

    test "worker_review persists :flag mode when no workspace review_automation config (bd-577w96)",
         ctx do
      {:ok, task} = Ash.create(Issue, %{title: "review mode default", workspace_id: ctx.ws.id})

      _result =
        Tools.worker_review(ctx.coordinator, %{
          "task_id" => task.id,
          "with_claude" => false
        })

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.review_automation == :flag
    end

    test "worker_review: explicit automation override wins over policy (bd-577w96)", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "review mode override", workspace_id: ctx.ws.id})

      _result =
        Tools.worker_review(ctx.coordinator, %{
          "task_id" => task.id,
          "automation" => "auto",
          "with_claude" => false
        })

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.review_automation == :auto
    end

    test "worker_review: author in auto_authors resolves to :auto (bd-577w96)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ra-tools-ws",
          prefix: "rat",
          config: %{
            "review_automation" => %{
              "default" => "flag",
              "auto_authors" => ["trusted-dev"]
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "review auto author", workspace_id: ws.id})
      coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

      _result =
        Tools.worker_review(coordinator, %{
          "task_id" => task.id,
          "pr_author" => "trusted-dev",
          "with_claude" => false
        })

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.review_automation == :auto
    end

    test "worker_review: author not in auto_authors falls back to default :flag (bd-577w96)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ra-tools-ws2",
          prefix: "ra2",
          config: %{
            "review_automation" => %{
              "default" => "flag",
              "auto_authors" => ["trusted-dev"]
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "review flag author", workspace_id: ws.id})
      coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

      _result =
        Tools.worker_review(coordinator, %{
          "task_id" => task.id,
          "pr_author" => "untrusted-dev",
          "with_claude" => false
        })

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.review_automation == :flag
    end

    test "worker_review: report_only automation persists :report_only mode (bd-36qzgx)", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "review report_only", workspace_id: ctx.ws.id})

      _result =
        Tools.worker_review(ctx.coordinator, %{
          "task_id" => task.id,
          "automation" => "report_only",
          "with_claude" => false
        })

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.review_automation == :report_only
    end

    test "worker_review: the propose alias persists :report_only mode (bd-36qzgx)", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "review propose", workspace_id: ctx.ws.id})

      _result =
        Tools.worker_review(ctx.coordinator, %{
          "task_id" => task.id,
          "automation" => "propose",
          "with_claude" => false
        })

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.review_automation == :report_only
    end

    test "worker_review: an infra repo_override resolves to :report_only (bd-36qzgx)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ra-infra-ws",
          prefix: "rai",
          config: %{
            "review_automation" => %{
              "default" => "auto",
              "repo_overrides" => %{"atlas" => "report_only"}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "infra review", workspace_id: ws.id})
      coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

      _result =
        Tools.worker_review(coordinator, %{
          "task_id" => task.id,
          "repo" => "atlas",
          "pr_author" => "anyone",
          "with_claude" => false
        })

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.review_automation == :report_only
    end
  end

  describe "review_greenlight/2 (bd-36qzgx)" do
    test "refuses a coordinator scope without can_dispatch", ctx do
      no_dispatch = %{ctx.coordinator | can_dispatch: false}

      assert {:error, {:unauthorized, _}} =
               Tools.review_greenlight(no_dispatch, %{"record_id" => "whatever"})
    end

    test "requires a record_id", ctx do
      assert {:error, {:invalid, msg}} = Tools.review_greenlight(ctx.coordinator, %{})
      assert msg =~ "record_id"
    end

    test "rejects a non-array, non-\"all\" select", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.review_greenlight(ctx.coordinator, %{
                 "record_id" => "r1",
                 "select" => "some"
               })

      assert msg =~ "select"
    end

    test "an unknown record_id is reported not-found", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.review_greenlight(ctx.coordinator, %{"record_id" => "no-such-record"})

      assert msg =~ "no review record" or msg =~ "not"
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

  describe "worker_show/2" do
    test "returns the live snapshot for a running worker", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "show-me", workspace_id: ctx.ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(task.id, :normal) end)

      :ok = Worker.report(pid, :output_lines, ["hello", "world"])

      assert {:ok, snap} = Tools.worker_show(ctx.coordinator, %{"task_id" => task.id})

      assert snap.source == "live"
      assert snap.task_id == task.id
      assert snap.repo == "test/repo"
      assert snap.output_lines == ["hello", "world"]
    end

    test "falls back to the most recent historical run when no live worker exists", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "hist target", workspace_id: ctx.ws.id})
      older = DateTime.add(DateTime.utc_now(), -60, :second)
      newer = DateTime.utc_now()

      {:ok, _old} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: older,
          completed_at: older,
          output_lines: ["stale"]
        })

      {:ok, _recent} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :failed,
          started_at: newer,
          completed_at: newer,
          exit_code: 2,
          failure_reason: "claude_crashed",
          output_lines: ["a", "b", "boom"]
        })

      assert {:ok, snap} = Tools.worker_show(ctx.coordinator, %{"task_id" => task.id})

      assert snap.source == "history"
      assert snap.status == "failed"
      assert snap.exit_status == 2
      assert snap.failure_reason == "claude_crashed"
      assert snap.output_lines == ["a", "b", "boom"]
    end

    test "a task with neither a live worker nor any run is reported not-found", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "no worker at all", workspace_id: ctx.ws.id})

      assert {:error, {:not_found, _}} =
               Tools.worker_show(ctx.coordinator, %{"task_id" => task.id})
    end

    test "cannot show a worker for a task in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "ws-other", prefix: "wso"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      {:ok, pid} = Worker.start(task_id: foreign.id, repo: "test/repo", workspace_id: other_ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(foreign.id, :normal) end)

      assert {:error, {:not_found, _}} =
               Tools.worker_show(ctx.coordinator, %{"task_id" => foreign.id})
    end
  end

  describe "worker_runs/2" do
    test "lists every historical run for a task, newest first", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "runs target", workspace_id: ctx.ws.id})
      older = DateTime.add(DateTime.utc_now(), -60, :second)
      newer = DateTime.utc_now()

      {:ok, old_run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: older,
          completed_at: older,
          output_lines: ["stale"]
        })

      {:ok, new_run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :failed,
          started_at: newer,
          completed_at: newer,
          exit_code: 2,
          failure_reason: "claude_crashed",
          output_lines: ["a", "b", "boom"]
        })

      assert {:ok, %{runs: [first, second]}} =
               Tools.worker_runs(ctx.coordinator, %{"task_id" => task.id})

      assert first.id == new_run.id
      assert first.status == "failed"
      assert first.exit_code == 2
      assert first.failure_reason == "claude_crashed"
      refute Map.has_key?(first, :output_lines)

      assert second.id == old_run.id
      assert second.status == "completed"
    end

    test "returns an empty list when no runs are recorded", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "no runs", workspace_id: ctx.ws.id})

      assert {:ok, %{runs: []}} = Tools.worker_runs(ctx.coordinator, %{"task_id" => task.id})
    end

    test "honors a bounded limit", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "many runs", workspace_id: ctx.ws.id})

      for i <- 1..3 do
        {:ok, _} =
          Ash.create(Arbiter.Workers.Run, %{
            task_id: task.id,
            repo: "arbiter",
            workspace_id: ctx.ws.id,
            status: :completed,
            started_at: DateTime.add(DateTime.utc_now(), -i, :second)
          })
      end

      assert {:ok, %{runs: runs}} =
               Tools.worker_runs(ctx.coordinator, %{"task_id" => task.id, "limit" => 2})

      assert length(runs) == 2
    end

    test "cannot list runs for a task in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "wr-other", prefix: "wro"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.worker_runs(ctx.coordinator, %{"task_id" => foreign.id})
    end
  end

  describe "worker_log/2" do
    test "reads the full durable transcript for the task's most recent run", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "log target", workspace_id: ctx.ws.id})

      {:ok, run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })

      {:ok, handle} = Arbiter.Worker.OutputLog.open(run.id)
      Arbiter.Worker.OutputLog.append(handle, "line one")
      Arbiter.Worker.OutputLog.append(handle, "line two")
      Arbiter.Worker.OutputLog.close(handle)
      on_exit(fn -> File.rm(Arbiter.Worker.OutputLog.path_for(run.id)) end)

      assert {:ok, data} = Tools.worker_log(ctx.coordinator, %{"task_id" => task.id})

      assert data.task_id == task.id
      assert data.run_id == run.id
      assert data.exists == true
      assert data.line_count == 2
      assert data.lines == ["line one", "line two"]
    end

    test "exists: false when the run row exists but no transcript was captured", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "no transcript", workspace_id: ctx.ws.id})

      {:ok, run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })

      assert {:ok, data} = Tools.worker_log(ctx.coordinator, %{"task_id" => task.id})

      assert data.run_id == run.id
      assert data.exists == false
      assert data.lines == []
    end

    test "not-found when the task has no run at all", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "no run at all", workspace_id: ctx.ws.id})

      assert {:error, {:not_found, _}} =
               Tools.worker_log(ctx.coordinator, %{"task_id" => task.id})
    end

    test "cannot read the log for a task in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "wl-other", prefix: "wlo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.worker_log(ctx.coordinator, %{"task_id" => foreign.id})
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

      {:ok, reloaded} = Ash.get(Issue, data.id)
      assert reloaded.workspace_id == ctx.other_ws.id
    end

    test "creates a task in the workspace named by the `workspace` param (by id)", ctx do
      assert {:ok, data} =
               Tools.task_create(ctx.agnostic, %{
                 "title" => "explicit by id",
                 "workspace" => ctx.other_ws.id
               })

      {:ok, reloaded} = Ash.get(Issue, data.id)
      assert reloaded.workspace_id == ctx.other_ws.id
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
      {:ok, reloaded} = Ash.get(Issue, data.id)
      assert reloaded.workspace_id == ctx.ws.id
    end

    test "a coordinator falls back to the workspace named \"default\" when several exist" do
      {:ok, default} = Ash.create(Workspace, %{name: "default", prefix: "def"})
      {:ok, _other} = Ash.create(Workspace, %{name: "another-ws", prefix: "anow"})
      agnostic = %Scope{tier: :coordinator, workspace_id: nil, can_dispatch: true}

      assert {:ok, data} = Tools.task_create(agnostic, %{"title" => "to default"})
      {:ok, reloaded} = Ash.get(Issue, data.id)
      assert reloaded.workspace_id == default.id
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

  describe "repo_list/2" do
    test "returns an empty list when no repos are configured", ctx do
      assert {:ok, data} = Tools.repo_list(ctx.coordinator, %{})
      assert is_list(data.repos)
      assert data.count == length(data.repos)
    end

    test "returns repos with expected fields", ctx do
      # Configure a repo in the workspace
      ws_config = ctx.ws.config || %{}

      repo_config = %{
        "repo_paths" => %{
          "test-repo" => "/tmp/test-repo"
        }
      }

      {:ok, _updated_ws} = Ash.update(ctx.ws, %{config: Map.merge(ws_config, repo_config)})

      assert {:ok, data} = Tools.repo_list(ctx.coordinator, %{})
      assert is_list(data.repos)
      assert data.count >= 1

      # Find the test repo
      repo = Enum.find(data.repos, fn r -> r.name == "test-repo" end)
      refute is_nil(repo)
      assert repo.path == "/tmp/test-repo"
      assert repo.source == ctx.ws.name
      assert is_integer(repo.workers)
      assert is_integer(repo.worktrees)
    end
  end

  describe "repo_show/2" do
    test "requires a repo name", ctx do
      assert {:error, {:invalid, _}} = Tools.repo_show(ctx.coordinator, %{})
    end

    test "returns not-found for unknown repo", ctx do
      assert {:error, {:not_found, msg}} =
               Tools.repo_show(ctx.coordinator, %{"name" => "unknown-repo"})

      assert msg =~ "unknown-repo"
    end

    test "returns repo details for a configured repo", ctx do
      # Configure a repo in the workspace
      ws_config = ctx.ws.config || %{}

      repo_config = %{
        "repo_paths" => %{
          "test-repo" => "/tmp/test-repo"
        }
      }

      {:ok, _updated_ws} = Ash.update(ctx.ws, %{config: Map.merge(ws_config, repo_config)})

      assert {:ok, repo} = Tools.repo_show(ctx.coordinator, %{"name" => "test-repo"})
      assert repo.name == "test-repo"
      assert repo.path == "/tmp/test-repo"
      assert repo.source == ctx.ws.name
      assert is_integer(repo.workers)
      assert is_integer(repo.worktrees)
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
