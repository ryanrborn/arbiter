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

  defp create_usage_event!(ctx, attrs) do
    base = %{
      task_id: ctx.task.id,
      repo: "shipyard",
      workspace_id: ctx.ws.id,
      step: :work,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Arbiter.Usage.Event, base |> Map.merge(Map.new(attrs)))
    ev
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

    test "state: \"outstanding\" returns read-but-uncleared messages without mutating", ctx do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(ctx.ws.id))

      # Create and read a message
      {:ok, msg1} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: ctx.task.id, body: "first"})

      {:ok, _} = Tools.inbox_check(ctx.worker, %{})
      assert_receive {:message_read, _}

      # Create another unread message
      {:ok, _msg2} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: ctx.task.id, body: "second"})

      assert_receive {:new_message, _}

      # Get the pre-call state for comparison
      {:ok, pre_call_msg1} = Ash.get(Message, msg1.id)

      # Get the outstanding message (the first one, which is now read but uncleared)
      assert {:ok, %{messages: [returned_msg], count: 1}} =
               Tools.inbox_check(ctx.worker, %{"state" => "outstanding"})

      assert returned_msg.body == "first"

      # Verify the message was not mutated
      {:ok, refreshed_msg1} = Ash.get(Message, msg1.id)

      assert returned_msg.read_at == DateTime.to_iso8601(refreshed_msg1.read_at)
      assert returned_msg.cleared_at == refreshed_msg1.cleared_at
      assert refreshed_msg1.updated_at == pre_call_msg1.updated_at

      # Verify no PubSub broadcasts fired
      refute_receive {:message_read, _}, 100
      refute_receive {:mailbox_cleared, _}, 100

      # Verify the second (unread) message is still there
      assert {:ok, %{messages: [unread_msg]}} =
               Tools.inbox_check(ctx.worker, %{})

      assert unread_msg.body == "second"
    end

    test "invalid state value is rejected", ctx do
      {:ok, _} = Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: ctx.task.id, body: "test"})

      assert {:error, {kind, message}} =
               Tools.inbox_check(ctx.worker, %{"state" => "invalid_state"})

      assert kind == :invalid_args
      assert message =~ "state"
    end

    test "default (omitted state) reproduces today's behaviour: returns unread, marks them read",
         ctx do
      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: ctx.task.id, body: "test"})

      # Default behaviour: returns unread messages and marks them read
      assert {:ok, %{messages: [msg], count: 1}} =
               Tools.inbox_check(ctx.worker, %{})

      assert msg.body == "test"

      # Second call is empty
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

    test "state: \"outstanding\" returns read-but-uncleared messages without mutating", ctx do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(ctx.ws.id))

      # Create and read a message
      {:ok, msg1} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "first"})

      {:ok, _} = Tools.coordinator_inbox(ctx.coordinator, %{})
      assert_receive {:message_read, _}

      # Create another unread message
      {:ok, _msg2} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "second"})

      assert_receive {:new_message, _}

      # Get the pre-call state for comparison
      {:ok, pre_call_msg1} = Ash.get(Message, msg1.id)

      # Get the outstanding message (the first one, which is now read but uncleared)
      assert {:ok, %{messages: [returned_msg], count: 1}} =
               Tools.coordinator_inbox(ctx.coordinator, %{"state" => "outstanding"})

      assert returned_msg.body == "first"

      # Verify the message was not mutated (read_at and cleared_at unchanged)
      {:ok, refreshed_msg1} = Ash.get(Message, msg1.id)

      assert returned_msg.read_at == DateTime.to_iso8601(refreshed_msg1.read_at)
      assert returned_msg.cleared_at == refreshed_msg1.cleared_at
      assert refreshed_msg1.updated_at == pre_call_msg1.updated_at

      # Verify no PubSub broadcasts fired
      refute_receive {:message_read, _}, 100
      refute_receive {:mailbox_cleared, _}, 100

      # Verify the second (unread) message is not included
      assert {:ok, %{messages: [unread_msg]}} =
               Tools.coordinator_inbox(ctx.coordinator, %{})

      assert unread_msg.body == "second"
    end

    test "state: \"outstanding\" with clear: true is rejected", ctx do
      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "test"})

      {:ok, _} = Tools.coordinator_inbox(ctx.coordinator, %{})

      # Try to combine state: outstanding with clear: true
      assert {:error, {kind, message}} =
               Tools.coordinator_inbox(ctx.coordinator, %{
                 "state" => "outstanding",
                 "clear" => true
               })

      assert kind == :invalid_args
      assert message =~ "outstanding"
    end

    test "invalid state value is rejected", ctx do
      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "test"})

      assert {:error, {kind, message}} =
               Tools.coordinator_inbox(ctx.coordinator, %{"state" => "invalid_state"})

      assert kind == :invalid_args
      assert message =~ "state"
    end

    test "default (omitted state) reproduces today's behaviour: returns unread, marks them read",
         ctx do
      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "test"})

      # Default behaviour: returns unread messages and marks them read
      assert {:ok, %{messages: [msg], count: 1}} =
               Tools.coordinator_inbox(ctx.coordinator, %{})

      assert msg.body == "test"

      # Second call is empty
      assert {:ok, %{count: 0}} = Tools.coordinator_inbox(ctx.coordinator, %{})
    end
  end

  describe "coordinator_inbox_peek/2 removed (bd-9kmq04)" do
    test "the tool no longer exists in the catalog", ctx do
      refute Enum.any?(Catalog.all(), &(&1.name == "coordinator_inbox_peek"))

      assert {:rpc_error, -32_602, message} =
               Catalog.call(ctx.coordinator, "coordinator_inbox_peek", %{})

      assert message =~ "Unknown tool"
    end
  end

  describe "coordinator_inbox/2 serialization (bd-9kmq04)" do
    test "surfaces read_at and cleared_at so the three states are visible", ctx do
      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "state check"})

      assert {:ok, %{messages: [msg]}} = Tools.coordinator_inbox(ctx.coordinator, %{})
      assert Map.has_key?(msg, :read_at)
      assert Map.has_key?(msg, :cleared_at)
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
      assert {:ok, %{claude: nil} = payload} = Tools.quota_get(ctx.worker, %{})
      # Gemini/Antigravity fetch is disabled in test → present but nil.
      assert payload.gemini == nil
      assert payload.antigravity == nil
    end

    test "includes a graceful codex no-op when Codex is not authenticated", ctx do
      assert {:ok, result} = Tools.quota_get(ctx.worker, %{})
      assert result.codex == nil
      assert is_binary(result.codex_message)
    end

    test "surfaces the persisted Codex snapshot from the DB (no live fetch, bd-ajh7bd)", ctx do
      # quota_get is now a pure DB read: the periodic CloudProbe is the only
      # thing that fetches Codex live. Persist a snapshot the way the probe
      # would, then assert quota_get reads it straight back.
      Ash.create!(Arbiter.Quota.CodexQuota, %{
        workspace_id: ctx.ws.id,
        provider: "codex",
        plan: "plus",
        session_used_percent: 33.0,
        session_reset_at: DateTime.utc_now() |> DateTime.truncate(:second),
        captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      assert {:ok, result} = Tools.quota_get(ctx.worker, %{})
      assert result.codex.session.used == 33.0
      assert result.codex_message == nil
    end

    test "surfaces the persisted Gemini CLI snapshot from the DB (bd-ajh7bd)", ctx do
      Ash.create!(Arbiter.Quota.GoogleQuota, %{
        workspace_id: ctx.ws.id,
        provider: "gemini_cli",
        plan: "Free",
        used_percent: 75.0,
        snapshot: %{"provider" => "gemini-cli", "plan" => "Free", "models" => []},
        captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      assert {:ok, result} = Tools.quota_get(ctx.worker, %{})
      assert result.gemini["plan"] == "Free"
      assert result.gemini["models"] == []
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

    test "accepts a repo assignment, and task_update can retarget it (bd-2jum8j)", ctx do
      assert {:ok, created} =
               Tools.task_create(ctx.coordinator, %{
                 "title" => "belongs to tonic",
                 "repo" => "emricare/tonic"
               })

      assert Ash.get!(Issue, created.id).repo == "emricare/tonic"

      {:ok, shown} = Tools.task_show(ctx.coordinator, %{"id" => created.id, "full" => true})
      assert shown.repo == "emricare/tonic"

      assert {:ok, _} =
               Tools.task_update(ctx.coordinator, %{
                 "id" => created.id,
                 "repo" => "emricare/tonic_device"
               })

      assert Ash.get!(Issue, created.id).repo == "emricare/tonic_device"
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

    test "persists pr_ref", ctx do
      assert {:ok, _data} =
               Tools.task_update(ctx.coordinator, %{
                 "id" => ctx.task.id,
                 "pr_ref" => "owner/repo#1"
               })

      {:ok, reloaded} = Ash.get(Issue, ctx.task.id)
      assert reloaded.pr_ref == "owner/repo#1"
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

    test "preserves source_pr (a PRPatrol/lifecycle-owned attribute) when updating unrelated fields (bd-ag9pq3)",
         ctx do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "PR ##{3266}: needs follow-up",
          workspace_id: ctx.ws.id,
          tracker_type: :none,
          source_pr: "3266"
        })

      assert task.source_pr == "3266"

      assert {:ok, data} =
               Tools.task_update(ctx.coordinator, %{
                 "id" => task.id,
                 "title" => "retasked title",
                 "description" => "retasked description"
               })

      assert data.title == "retasked title"

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.source_pr == "3266"
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

    test "accepts optional task_ref parameter", ctx do
      {:ok, other_task} = Ash.create(Issue, %{title: "other", workspace_id: ctx.ws.id})

      assert {:ok, msg} =
               Tools.message_send(ctx.coordinator, %{
                 "task_id" => ctx.task.id,
                 "body" => "issue with this task",
                 "task_ref" => other_task.id
               })

      assert msg.task_ref == other_task.id
      assert msg.directive_ref == other_task.id
    end

    test "accepts the deprecated directive_ref alias for task_ref", ctx do
      {:ok, other_task} = Ash.create(Issue, %{title: "other", workspace_id: ctx.ws.id})

      assert {:ok, msg} =
               Tools.message_send(ctx.coordinator, %{
                 "task_id" => ctx.task.id,
                 "body" => "issue with this task",
                 "directive_ref" => other_task.id
               })

      assert msg.task_ref == other_task.id
      assert msg.directive_ref == other_task.id
    end

    test "task_ref wins over directive_ref when both are given", ctx do
      {:ok, canonical_task} = Ash.create(Issue, %{title: "canonical", workspace_id: ctx.ws.id})
      {:ok, legacy_task} = Ash.create(Issue, %{title: "legacy", workspace_id: ctx.ws.id})

      assert {:ok, msg} =
               Tools.message_send(ctx.coordinator, %{
                 "task_id" => ctx.task.id,
                 "body" => "issue with this task",
                 "task_ref" => canonical_task.id,
                 "directive_ref" => legacy_task.id
               })

      assert msg.task_ref == canonical_task.id
      assert msg.directive_ref == canonical_task.id
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

  describe "task_promote/2" do
    test "a coordinator promotes a task from Backlog to Ready", ctx do
      assert ctx.task.refined == false

      assert {:ok, data} = Tools.task_promote(ctx.coordinator, %{"id" => ctx.task.id})
      assert data.refined == true

      {:ok, reloaded} = Ash.get(Issue, ctx.task.id)
      assert reloaded.refined == true
    end

    test "promoting an already-refined task is a no-op success", ctx do
      {:ok, _} = Ash.update(ctx.task, %{}, action: :promote_to_ready)
      assert ctx.task.refined == false
      {:ok, task} = Ash.get(Issue, ctx.task.id)
      assert task.refined == true

      assert {:ok, data} = Tools.task_promote(ctx.coordinator, %{"id" => ctx.task.id})
      assert data.refined == true
    end

    test "cannot promote a task in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "pt-other", prefix: "pto"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.task_promote(ctx.coordinator, %{"id" => foreign.id})
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

    test "sets an array leaf (multi-provider agent.type)", ctx do
      assert {:ok, data} =
               Tools.workspace_config_set(ctx.coordinator, %{
                 "key" => "agent.type",
                 "value" => ["claude", "gemini"]
               })

      assert get_in(data.config, ["agent", "type"]) == ["claude", "gemini"]
    end

    test "unwraps a stringified JSON array value (bd-1dtufq)", ctx do
      assert {:ok, data} =
               Tools.workspace_config_set(ctx.coordinator, %{
                 "key" => "agent.type",
                 "value" => "[\"claude\", \"gemini\"]"
               })

      assert get_in(data.config, ["agent", "type"]) == ["claude", "gemini"]
    end

    test "unwraps a stringified JSON object value (bd-1dtufq)", ctx do
      assert {:ok, data} =
               Tools.workspace_config_set(ctx.coordinator, %{
                 "key" => "agent.config",
                 "value" => "{\"vernacular\": \"terse\"}"
               })

      assert get_in(data.config, ["agent", "config"]) == %{"vernacular" => "terse"}
    end

    test "leaves a genuine scalar string value that happens to start with [ untouched", ctx do
      assert {:ok, data} =
               Tools.workspace_config_set(ctx.coordinator, %{
                 "key" => "tracker.config.label",
                 "value" => "[urgent]"
               })

      assert get_in(data.config, ["tracker", "config", "label"]) == "[urgent]"
    end

    test "preserves JSON-scalar-shaped string values as strings, not numbers/booleans (regression: bd-7lmjc5)",
         ctx do
      # workspace_config_set's schema explicitly allows string type. A client sending
      # "5", "true", "5.0" as legitimate string config values should NOT be decoded
      # to numbers/booleans. The unwrap helper only unwraps structural types (list/map)
      # for workspace_config_set, not scalars.
      assert {:ok, data} =
               Tools.workspace_config_set(ctx.coordinator, %{
                 "key" => "version.constraint",
                 "value" => "5.0"
               })

      # Should be stored as string "5.0", not float 5.0
      assert get_in(data.config, ["version", "constraint"]) == "5.0"

      assert {:ok, data} =
               Tools.workspace_config_set(ctx.coordinator, %{
                 "key" => "feature.flag",
                 "value" => "true"
               })

      # Should be stored as string "true", not boolean true
      assert get_in(data.config, ["feature", "flag"]) == "true"

      assert {:ok, data} =
               Tools.workspace_config_set(ctx.coordinator, %{
                 "key" => "count.value",
                 "value" => "5"
               })

      # Should be stored as string "5", not integer 5
      assert get_in(data.config, ["count", "value"]) == "5"
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
      on_exit(fn ->
        Arbiter.Settings.set_conductor_system_max_concurrent(nil)
        Arbiter.Settings.set_credential_watchdog_adapters(nil)
        Arbiter.Settings.set_credential_watchdog_interval_ms(nil)
        Arbiter.Settings.set_credential_watchdog_recovery_interval_ms(nil)
      end)

      :ok
    end

    @empty_settings %{
      conductor_system_max_concurrent: nil,
      credential_watchdog_adapters: nil,
      credential_watchdog_interval_ms: nil,
      credential_watchdog_recovery_interval_ms: nil
    }

    test "returns the full settings map when no key is given (worker tier)", ctx do
      assert {:ok, data} = Tools.installation_config_get(ctx.worker, %{})
      assert is_nil(data.key)
      assert data.value == @empty_settings
      assert data.settings == @empty_settings
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

    test "coordinator can set the credential watchdog adapter list", ctx do
      assert {:ok, data} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "credential_watchdog_adapters",
                 "value" => ["claude", "gemini"]
               })

      assert data.value == ["claude", "gemini"]
      assert Arbiter.Settings.credential_watchdog_adapters() == ["claude", "gemini"]

      assert {:ok, read} =
               Tools.installation_config_get(ctx.worker, %{
                 "key" => "credential_watchdog_adapters"
               })

      assert read.value == ["claude", "gemini"]
    end

    test "coordinator can clear the credential watchdog adapter list", ctx do
      {:ok, _} = Arbiter.Settings.set_credential_watchdog_adapters(["claude"])

      assert {:ok, %{value: nil}} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "credential_watchdog_adapters",
                 "value" => nil
               })

      assert Arbiter.Settings.credential_watchdog_adapters() == nil
    end

    test "rejects an unknown adapter name", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "credential_watchdog_adapters",
                 "value" => ["claude", "not-an-agent"]
               })

      assert msg =~ "value"
    end

    test "rejects a non-list value for the adapter list", ctx do
      assert {:error, {:invalid, _msg}} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "credential_watchdog_adapters",
                 "value" => "claude"
               })
    end

    test "coordinator can set the credential watchdog intervals", ctx do
      assert {:ok, %{value: 900_000}} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "credential_watchdog_interval_ms",
                 "value" => 900_000
               })

      assert {:ok, %{value: 120_000}} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "credential_watchdog_recovery_interval_ms",
                 "value" => 120_000
               })

      assert Arbiter.Settings.credential_watchdog_interval_ms() == 900_000
      assert Arbiter.Settings.credential_watchdog_recovery_interval_ms() == 120_000
    end

    test "rejects a non-positive interval", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "credential_watchdog_interval_ms",
                 "value" => 0
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

  describe "installation_config_set — schema validation" do
    test "value property must have an explicit type (not bare/untyped)", ctx do
      tool = Enum.find(Catalog.visible(ctx.coordinator), &(&1.name == "installation_config_set"))
      assert tool != nil

      value_schema = tool.input_schema["properties"]["value"]
      assert value_schema != nil
      # The value property must have a "type" key or "oneOf"/"anyOf" for proper MCP type coercion
      assert Map.has_key?(value_schema, "type") or Map.has_key?(value_schema, "oneOf") or
               Map.has_key?(value_schema, "anyOf"),
             "value property must declare a type (via 'type', 'oneOf', or 'anyOf') so MCP clients send native types, not JSON strings"
    end

    test "schema permits native integer, array, and null types for value", ctx do
      tool = Enum.find(Catalog.visible(ctx.coordinator), &(&1.name == "installation_config_set"))
      value_schema = tool.input_schema["properties"]["value"]

      # Verify oneOf contains the three expected type schemas
      one_of = value_schema["oneOf"]
      assert one_of != nil
      assert length(one_of) == 3

      types = Enum.map(one_of, & &1["type"])
      assert "null" in types
      assert "integer" in types
      assert "array" in types

      # Verify integer has minimum constraint
      integer_schema = Enum.find(one_of, &(&1["type"] == "integer"))
      assert integer_schema["minimum"] == 1

      # Verify array items are constrained to known agent types
      array_schema = Enum.find(one_of, &(&1["type"] == "array"))
      items_enum = array_schema["items"]["enum"]
      assert items_enum == ["claude", "gemini", "codex"]
    end

    test "native integer value round-trips successfully (coordinator)", ctx do
      # This verifies the backend validation accepts native integers (what well-formed MCP clients send)
      assert {:ok, data} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "conductor_system_max_concurrent",
                 "value" => 5
               })

      assert data.value == 5
      assert Arbiter.Settings.conductor_system_max_concurrent() == 5
    end

    test "native list value round-trips successfully for adapter key (coordinator)", ctx do
      # This verifies the backend validation accepts native lists (what well-formed MCP clients send)
      assert {:ok, data} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "credential_watchdog_adapters",
                 "value" => ["claude", "gemini"]
               })

      assert data.value == ["claude", "gemini"]
      assert Arbiter.Settings.credential_watchdog_adapters() == ["claude", "gemini"]
    end

    test "native null value round-trips successfully (coordinator)", ctx do
      # Set a value first
      {:ok, _} = Arbiter.Settings.set_credential_watchdog_adapters(["claude"])

      # Clear with native null
      assert {:ok, data} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "credential_watchdog_adapters",
                 "value" => nil
               })

      assert data.value == nil
      assert Arbiter.Settings.credential_watchdog_adapters() == nil
    end

    test "unwraps a stringified JSON array value for credential_watchdog_adapters", ctx do
      assert {:ok, data} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "credential_watchdog_adapters",
                 "value" => "[\"claude\", \"gemini\"]"
               })

      assert data.value == ["claude", "gemini"]
      assert Arbiter.Settings.credential_watchdog_adapters() == ["claude", "gemini"]
    end

    test "unwraps a stringified integer value for conductor_system_max_concurrent", ctx do
      assert {:ok, data} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "conductor_system_max_concurrent",
                 "value" => "5"
               })

      assert data.value == 5
      assert Arbiter.Settings.conductor_system_max_concurrent() == 5
    end

    test "malformed string for credential_watchdog_adapters fails validation", ctx do
      # A stringified object where a list was expected should still fail
      assert {:error, {:invalid, "value must be a list of agent type strings or null"}} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "credential_watchdog_adapters",
                 "value" => "{\"invalid\": \"object\"}"
               })
    end

    test "malformed string for conductor_system_max_concurrent fails validation", ctx do
      # A non-integer string should fail validation
      assert {:error, {:invalid, "value must be a positive integer or null"}} =
               Tools.installation_config_set(ctx.coordinator, %{
                 "key" => "conductor_system_max_concurrent",
                 "value" => "not a number"
               })
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

    test "external review (pr) accepts a scope: \"repo\" override (bd-5xsp25)" do
      {:ok, gh_ws} =
        Ash.create(Workspace, %{
          name: "rv-github-scope",
          prefix: "rvgs",
          config: %{"merge" => %{"strategy" => "github", "config" => %{}}}
        })

      coordinator = %Scope{tier: :coordinator, workspace_id: gh_ws.id, can_dispatch: true}

      assert {:ok, ack} =
               Tools.worker_review(coordinator, %{
                 "pr" => "https://github.com/leo/verus_sigv4/pull/6",
                 "scope" => "repo"
               })

      assert ack.external == true
      assert ack.status == "dispatched"
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

    test "worker_review: an :off repo_override refuses before dispatch, no persist (bd-7opdaf)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ra-off-ws",
          prefix: "raof",
          config: %{
            "review_automation" => %{
              "default" => "auto",
              "repo_overrides" => %{"quiet_repo" => "off"}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "off review", workspace_id: ws.id})
      coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

      assert {:error, {:invalid, msg}} =
               Tools.worker_review(coordinator, %{
                 "task_id" => task.id,
                 "repo" => "quiet_repo",
                 "with_claude" => false
               })

      assert msg =~ "quiet_repo"
      assert msg =~ "repo_overrides"
      assert msg =~ "force"

      # No agent spawned, nothing persisted — review_automation stays unset.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.review_automation == nil
    end

    test "worker_review: an explicit automation: \"off\" refuses regardless of policy (bd-7opdaf)",
         ctx do
      {:ok, task} = Ash.create(Issue, %{title: "explicit off review", workspace_id: ctx.ws.id})

      assert {:error, {:invalid, msg}} =
               Tools.worker_review(ctx.coordinator, %{
                 "task_id" => task.id,
                 "automation" => "off",
                 "with_claude" => false
               })

      assert msg =~ "off"
    end

    test "worker_review: force: true overrides an :off repo_override refusal (bd-7opdaf)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ra-off-force-ws",
          prefix: "raoff",
          config: %{
            "review_automation" => %{
              "default" => "auto",
              "repo_overrides" => %{"quiet_repo" => "off"}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "off review forced", workspace_id: ws.id})
      coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

      _result =
        Tools.worker_review(coordinator, %{
          "task_id" => task.id,
          "repo" => "quiet_repo",
          "force" => true,
          "with_claude" => false
        })

      # force bypasses the refusal — dispatch proceeds (fails later on no-worktree
      # in this test env, which is expected and irrelevant here).
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.review_automation == :off
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

    # bd-cgmidt: `worker_stop` is teardown — it must NEVER transition the bead to
    # `:closed`. A bead only reaches `:closed` via a real completion or an
    # explicit close, never from tearing down a zombie/idle worker.
    test "stopping a worker leaves the bead not-:closed (bd-cgmidt Guard 1)", ctx do
      {:ok, task} =
        Ash.create(Issue, %{title: "stop teardown", workspace_id: ctx.ws.id})

      {:ok, in_progress} = Ash.update(task, %{status: :in_progress}, action: :update)
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(task.id, :normal) end)

      assert {:ok, %{stopped: true}} =
               Tools.worker_stop(ctx.coordinator, %{"task_id" => task.id})

      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.status == :closed
      assert reloaded.status == in_progress.status
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

    test "surfaces resumable/blocked_reason for a live worker", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "resumable-test", workspace_id: ctx.ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(task.id, :normal) end)

      # Worker in :failed status should be resumable
      :ok = Worker.fail(pid)
      assert {:ok, snap} = Tools.worker_show(ctx.coordinator, %{"task_id" => task.id})
      assert snap.resumable == true
      assert snap.blocked_reason == nil
    end

    test "surfaces blocked_reason for a worker in awaiting_review status", ctx do
      alias Arbiter.Test.StubMerger

      {:ok, task} = Ash.create(Issue, %{title: "awaiting-review-test", workspace_id: ctx.ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(task.id, :normal) end)

      :ok = Worker.advance(pid, :implement)
      StubMerger.next_open_ref("!test")

      open_opts = %{
        adapter: StubMerger,
        workspace: nil,
        interval_ms: 1_000_000,
        initial_delay_ms: 1_000_000
      }

      assert {:ok, "!test"} = Worker.open_mr(pid, "feature/guard", "Test", "", open_opts)

      assert {:ok, snap} = Tools.worker_show(ctx.coordinator, %{"task_id" => task.id})
      assert snap.resumable == false
      assert is_binary(snap.blocked_reason)
      assert String.contains?(snap.blocked_reason, "awaiting_review")
    end

    test "surfaces resumable/blocked_reason for worker_list", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "list-resumable-test", workspace_id: ctx.ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(task.id, :normal) end)

      # Worker in :failed status should be resumable
      :ok = Worker.fail(pid)
      assert {:ok, %{workers: workers}} = Tools.worker_list(ctx.coordinator, %{})
      entry = Enum.find(workers, &(&1.task_id == task.id))
      assert entry.resumable == true
      assert entry.blocked_reason == nil
    end

    test "returns only the tail of output_lines when lines parameter is provided (live worker)",
         ctx do
      {:ok, task} = Ash.create(Issue, %{title: "show-tail-live", workspace_id: ctx.ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Worker.stop(task.id, :normal) end)

      lines = ["line 1", "line 2", "line 3", "line 4", "line 5"]
      :ok = Worker.report(pid, :output_lines, lines)

      assert {:ok, snap} =
               Tools.worker_show(ctx.coordinator, %{"task_id" => task.id, "lines" => 2})

      assert snap.output_lines == ["line 4", "line 5"]
    end

    test "returns only the tail of output_lines when lines parameter is provided (historical run)",
         ctx do
      {:ok, task} = Ash.create(Issue, %{title: "show-tail-hist", workspace_id: ctx.ws.id})

      {:ok, _run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now(),
          output_lines: ["line 1", "line 2", "line 3", "line 4", "line 5"]
        })

      assert {:ok, snap} =
               Tools.worker_show(ctx.coordinator, %{"task_id" => task.id, "lines" => 2})

      assert snap.output_lines == ["line 4", "line 5"]
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
          failure_reason: "review_gate_rejected",
          failure_summary: "VERDICT: REQUEST_CHANGES — needs a guard",
          output_lines: ["a", "b", "boom"]
        })

      assert {:ok, %{runs: [first, second]}} =
               Tools.worker_runs(ctx.coordinator, %{"task_id" => task.id})

      assert first.id == new_run.id
      assert first.status == "failed"
      assert first.exit_code == 2
      assert first.failure_reason == "review_gate_rejected"
      # bd-2ddf2x: `worker_runs` surfaces failure_summary directly, so a
      # ReviewGate rejection doesn't require a separate review_gate_rounds_list
      # call just to see why.
      assert first.failure_summary == "VERDICT: REQUEST_CHANGES — needs a guard"
      refute Map.has_key?(first, :output_lines)

      assert second.id == old_run.id
      assert second.status == "completed"
    end

    test "returns an empty list when no runs are recorded", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "no runs", workspace_id: ctx.ws.id})

      assert {:ok, %{runs: []}} = Tools.worker_runs(ctx.coordinator, %{"task_id" => task.id})
    end

    # bd-dzz6ly: "which runs had skill X active, grouped by outcome" must be
    # answerable straight off this MCP surface, without reading a transcript.
    test "surfaces run provenance (resolved_skills/routing_policy/model_tier/thinking/standing_orders_digest/difficulty_at_dispatch)",
         ctx do
      {:ok, task} = Ash.create(Issue, %{title: "provenance target", workspace_id: ctx.ws.id})

      {:ok, run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: DateTime.utc_now(),
          resolved_skills: [
            %{"name" => "tdd", "activation_mode" => "always_on", "skill_version" => "v1"}
          ],
          standing_orders_digest: String.duplicate("a", 64),
          routing_policy: "by_difficulty",
          model_tier: "premium",
          thinking: "high",
          difficulty_at_dispatch: 3
        })

      assert {:ok, %{runs: [entry]}} =
               Tools.worker_runs(ctx.coordinator, %{"task_id" => task.id})

      assert entry.id == run.id

      assert entry.resolved_skills == [
               %{"name" => "tdd", "activation_mode" => "always_on", "skill_version" => "v1"}
             ]

      assert entry.standing_orders_digest == String.duplicate("a", 64)
      assert entry.routing_policy == "by_difficulty"
      assert entry.model_tier == "premium"
      assert entry.thinking == "high"
      assert entry.difficulty_at_dispatch == 3
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

    test "run_id: reads a specific run's transcript, independent of which run is latest", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "multi-run", workspace_id: ctx.ws.id})
      older = DateTime.add(DateTime.utc_now(), -60, :second)
      newer = DateTime.utc_now()

      {:ok, failed_run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :failed,
          started_at: older,
          completed_at: older
        })

      {:ok, latest} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: newer,
          completed_at: newer
        })

      {:ok, handle} = Arbiter.Worker.OutputLog.open(failed_run.id)
      Arbiter.Worker.OutputLog.append(handle, "the failed attempt's learning signal")
      Arbiter.Worker.OutputLog.close(handle)
      on_exit(fn -> File.rm(Arbiter.Worker.OutputLog.path_for(failed_run.id)) end)

      assert {:ok, data} = Tools.worker_log(ctx.coordinator, %{"run_id" => failed_run.id})

      assert data.run_id == failed_run.id
      assert data.task_id == task.id
      assert data.lines == ["the failed attempt's learning signal"]
      refute data.run_id == latest.id
    end

    test "run_id: not-found for a run in another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "wl-run-other", prefix: "wlro"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      {:ok, foreign_run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: foreign.id,
          repo: "arbiter",
          workspace_id: other_ws.id,
          status: :completed,
          started_at: DateTime.utc_now()
        })

      assert {:error, {:not_found, _}} =
               Tools.worker_log(ctx.coordinator, %{"run_id" => foreign_run.id})
    end

    test "task_id: accepts a ReviewGate synthetic id (reviewer corpus, bd-cuy75r)", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "reviewed task", workspace_id: ctx.ws.id})
      review_id = task.id <> "#review"

      {:ok, run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: review_id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          worker_type: :review,
          status: :completed,
          started_at: DateTime.utc_now()
        })

      {:ok, handle} = Arbiter.Worker.OutputLog.open(run.id)
      Arbiter.Worker.OutputLog.append(handle, "reviewer verdict")
      Arbiter.Worker.OutputLog.close(handle)
      on_exit(fn -> File.rm(Arbiter.Worker.OutputLog.path_for(run.id)) end)

      assert {:ok, data} = Tools.worker_log(ctx.coordinator, %{"task_id" => review_id})

      assert data.task_id == review_id
      assert data.lines == ["reviewer verdict"]
    end
  end

  describe "worker_prompt/2 (bd-9rdwe4)" do
    test "reads the persisted prompt for the task's most recent run", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "prompt target", workspace_id: ctx.ws.id})

      {:ok, run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })

      :ok = Arbiter.Worker.PromptLog.write(run.id, "you are a worker\n\ndo the thing")
      on_exit(fn -> File.rm(Arbiter.Worker.PromptLog.path_for(run.id)) end)

      digest =
        Ash.update!(
          run,
          %{prompt_sha256: Arbiter.Worker.PromptLog.sha256("you are a worker\n\ndo the thing")},
          action: :update
        ).prompt_sha256

      assert {:ok, data} = Tools.worker_prompt(ctx.coordinator, %{"task_id" => task.id})

      assert data.task_id == task.id
      assert data.run_id == run.id
      assert data.exists == true
      assert data.prompt == "you are a worker\n\ndo the thing"
      assert data.prompt_sha256 == digest
    end

    test "exists: false when the run row exists but no prompt was captured", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "no prompt", workspace_id: ctx.ws.id})

      {:ok, run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })

      assert {:ok, data} = Tools.worker_prompt(ctx.coordinator, %{"task_id" => task.id})

      assert data.run_id == run.id
      assert data.exists == false
      assert data.prompt == nil
    end

    test "not-found when the task has no run at all", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "no run at all", workspace_id: ctx.ws.id})

      assert {:error, {:not_found, _}} =
               Tools.worker_prompt(ctx.coordinator, %{"task_id" => task.id})
    end

    test "cannot read the prompt for a task in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "wp-other", prefix: "wpo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.worker_prompt(ctx.coordinator, %{"task_id" => foreign.id})
    end

    test "run_id: reads a specific run's prompt, independent of which run is latest", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "multi-run prompt", workspace_id: ctx.ws.id})
      older = DateTime.add(DateTime.utc_now(), -60, :second)
      newer = DateTime.utc_now()

      {:ok, older_run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :failed,
          started_at: older,
          completed_at: older
        })

      {:ok, _latest} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: newer,
          completed_at: newer
        })

      :ok = Arbiter.Worker.PromptLog.write(older_run.id, "the earlier attempt's prompt")
      on_exit(fn -> File.rm(Arbiter.Worker.PromptLog.path_for(older_run.id)) end)

      assert {:ok, data} = Tools.worker_prompt(ctx.coordinator, %{"run_id" => older_run.id})

      assert data.run_id == older_run.id
      assert data.prompt == "the earlier attempt's prompt"
    end
  end

  describe "worker_runs/2 with ReviewGate synthetic ids (bd-cuy75r)" do
    test "resolves auth against the base task while matching the synthetic id's own runs", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "reviewed task", workspace_id: ctx.ws.id})
      review_id = task.id <> "#review"

      {:ok, _author_run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          worker_type: :main,
          status: :completed,
          started_at: DateTime.utc_now()
        })

      {:ok, review_run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: review_id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          worker_type: :review,
          status: :completed,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %{runs: [only]}} =
               Tools.worker_runs(ctx.coordinator, %{"task_id" => review_id})

      assert only.id == review_run.id
    end

    test "not-found when the base task is in another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "wr-synth-other", prefix: "wrso"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.worker_runs(ctx.coordinator, %{"task_id" => foreign.id <> "#review"})
    end
  end

  describe "run_log_list/2 (bd-cuy75r)" do
    test "enumerates the base task's own runs plus its synthetic children", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "full corpus", workspace_id: ctx.ws.id})

      {:ok, author_run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          worker_type: :main,
          status: :completed,
          model: "sonnet",
          started_at: DateTime.add(DateTime.utc_now(), -30, :second)
        })

      {:ok, review_run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id <> "#review",
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          worker_type: :review,
          status: :completed,
          model: "opus",
          started_at: DateTime.add(DateTime.utc_now(), -20, :second)
        })

      {:ok, reprompt_run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: task.id <> "#review#t2",
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          worker_type: :review,
          status: :failed,
          started_at: DateTime.add(DateTime.utc_now(), -10, :second)
        })

      {:ok, unrelated} = Ash.create(Issue, %{title: "unrelated", workspace_id: ctx.ws.id})

      {:ok, _unrelated_run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: unrelated.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: DateTime.utc_now()
        })

      {:ok, handle} = Arbiter.Worker.OutputLog.open(review_run.id)
      Arbiter.Worker.OutputLog.append(handle, "line a")
      Arbiter.Worker.OutputLog.append(handle, "line b")
      Arbiter.Worker.OutputLog.close(handle)
      on_exit(fn -> File.rm(Arbiter.Worker.OutputLog.path_for(review_run.id)) end)

      assert {:ok, %{runs: runs}} = Tools.run_log_list(ctx.coordinator, %{"task_id" => task.id})

      ids = Enum.map(runs, & &1.run_id)
      assert Enum.sort(ids) == Enum.sort([author_run.id, review_run.id, reprompt_run.id])

      review_entry = Enum.find(runs, &(&1.run_id == review_run.id))
      assert review_entry.transcript_exists == true
      assert review_entry.line_count == 2
      assert review_entry.worker_type == "review"
      assert review_entry.task_id == task.id <> "#review"

      author_entry = Enum.find(runs, &(&1.run_id == author_run.id))
      assert author_entry.transcript_exists == false
      assert author_entry.line_count == 0
    end

    test "not-found when the task is in another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "rll-other", prefix: "rllo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.run_log_list(ctx.coordinator, %{"task_id" => foreign.id})
    end
  end

  describe "transcript_capture_stats/2 (bd-9wotbo)" do
    test "reports capture rate over Claude-driven runs only, excluding workflow-only runs", ctx do
      base = ~U[2026-07-01 00:00:00Z]

      {:ok, captured} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: ctx.task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          session_id: "sess-captured",
          started_at: base
        })

      {:ok, handle} = Arbiter.Worker.OutputLog.open(captured.id)
      Arbiter.Worker.OutputLog.append(handle, "line")
      Arbiter.Worker.OutputLog.close(handle)
      on_exit(fn -> File.rm(Arbiter.Worker.OutputLog.path_for(captured.id)) end)

      {:ok, missing} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: ctx.task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          session_id: "sess-missing",
          started_at: DateTime.add(base, 60, :second)
        })

      {:ok, _workflow_only} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: ctx.task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          started_at: DateTime.add(base, 120, :second)
        })

      {:ok, _pre_corpus} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: ctx.task.id,
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          status: :completed,
          session_id: "sess-pre-corpus",
          started_at: ~U[2026-06-10 00:00:00Z]
        })

      assert {:ok, stats} = Tools.transcript_capture_stats(ctx.coordinator, %{})

      assert stats.corpus_start_date == "2026-06-20"
      assert stats.claude_sessions == 2
      assert stats.transcript_missing == 1
      assert stats.workflow_only_runs == 1
      assert stats.capture_rate_pct == 50.0
      assert is_binary(missing.id)
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

    test "campaign is accepted as a deprecated alias and normalized to epic", ctx do
      assert {:ok, %{by: "epic", rollups: []}} =
               Tools.usage_summarize(ctx.coordinator, %{"by" => "campaign"})
    end

    test "returns no warnings when every provider has at least one non-zero row", ctx do
      create_usage_event!(ctx, provider: "claude", tokens_in: 100, tokens_out: 50)

      assert {:ok, %{warnings: []}} = Tools.usage_summarize(ctx.coordinator, %{"by" => "task"})
    end

    test "warns when a provider's rows are wholly zero-token (bd-2fzwlc)", ctx do
      create_usage_event!(ctx, provider: "gemini", tokens_in: 0, tokens_out: 0)
      create_usage_event!(ctx, provider: "gemini", tokens_in: nil, tokens_out: nil)
      create_usage_event!(ctx, provider: "claude", tokens_in: 100, tokens_out: 50)

      assert {:ok, %{warnings: [warning]}} =
               Tools.usage_summarize(ctx.coordinator, %{"by" => "task"})

      assert warning =~ "gemini"
      assert warning =~ "2 usage_events row"
      refute warning =~ "claude"
    end

    test "does not flag a provider with at least one non-zero row", ctx do
      create_usage_event!(ctx, provider: "gemini", tokens_in: 0, tokens_out: 0)
      create_usage_event!(ctx, provider: "gemini", tokens_in: 42, tokens_out: 10)

      assert {:ok, %{warnings: []}} = Tools.usage_summarize(ctx.coordinator, %{"by" => "task"})
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

    # bd-dcvo3n: an unrecognized `provider` value must fail LOUDLY rather than
    # silently falling back to the workspace-default agent. Before the fix the
    # `dispatch_provider/1` catch-all mapped any unknown provider to `nil`
    # ("use the workspace default"), so a typo — or `provider: "codex"` against
    # a server too old to know it — silently spawned the default agent (Claude)
    # with zero error/warning. The tell: the error is about the bad provider,
    # NOT the (also-unconfigured) repo, proving we reject before dispatching.
    test "an unrecognized provider is rejected loudly (not a silent default)", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "bad provider", workspace_id: ctx.ws.id})

      assert {:error, {:invalid, msg}} =
               Tools.worker_dispatch(ctx.coordinator, %{
                 "task_id" => task.id,
                 "provider" => "kodex",
                 "repo" => "test/repo"
               })

      assert msg =~ "provider"
      assert msg =~ "kodex"
      # It must NOT have fallen through to the real-work path (whose failure
      # would be about the missing repo).
      refute msg =~ "repo"

      on_exit(fn -> Worker.stop(task.id, :normal) end)
    end
  end

  describe "worker_dispatch/2 provider: \"codex\" writes the Codex MCP config (bd-bi5t54)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "mcp-codex-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      stub_dir = Path.join(tmp, "stub-bin")
      File.mkdir_p!(stub_dir)
      codex_file = Path.join(tmp, "codex-argv.txt")
      stub = Path.join(stub_dir, "codex")

      File.write!(stub, """
      #!/bin/sh
      for a in "$@"; do echo "$a" >> #{codex_file}; done
      exit 0
      """)

      File.chmod!(stub, 0o755)
      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", "#{stub_dir}:#{old_path}")
      on_exit(fn -> System.put_env("PATH", old_path) end)

      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "x\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      remote = Path.join(tmp, "repo-remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
      put_app_env(:arbiter, :repo_paths, %{"mcp/codex-repo" => repo})

      prior_mcp = Application.get_env(:arbiter, Arbiter.MCP)
      put_app_env(:arbiter, Arbiter.MCP, Keyword.put(prior_mcp || [], :inject_config, true))

      %{tmp: tmp, codex_file: codex_file}
    end

    test "the dispatched worktree gets .codex/config.toml, not .mcp.json", ctx do
      # Workspace's `agent.type` pool deliberately excludes codex, mirroring the
      # live `default` workspace — the explicit `provider` override must win.
      {:ok, ws} =
        Ash.update(ctx.ws, %{config: %{"agent" => %{"type" => ["claude", "gemini"]}}})

      {:ok, task} = Ash.create(Issue, %{title: "codex mcp dispatch", workspace_id: ws.id})
      coordinator = %{ctx.coordinator | workspace_id: ws.id}

      assert {:ok, data} =
               Tools.worker_dispatch(coordinator, %{
                 "task_id" => task.id,
                 "provider" => "codex",
                 "repo" => "mcp/codex-repo"
               })

      on_exit(fn -> Worker.stop(task.id, :normal) end)

      worktree_path = data.worktree_path
      assert is_binary(worktree_path)

      # Give the async worker a moment to reach the MCP-config-injection step.
      Process.sleep(200)

      assert File.exists?(Path.join(worktree_path, ".codex/config.toml")),
             "provider: \"codex\" dispatch must write .codex/config.toml, not fall back to .mcp.json"

      refute File.exists?(Path.join(worktree_path, ".mcp.json"))
    end
  end

  # bd-2aslx6 (#1428): `Dispatch.dispatch/2` refuses a second agent-spawning
  # dispatch onto a task whose worker is already mid-session. The coordinator
  # calls this tool, so the refusal has to arrive as a sentence it can act on —
  # not the raw `{:agent_session_active, id}` tuple the generic fallback renders.
  describe "worker_dispatch/2 onto a task with a live agent session" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "mcp-live-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      stub_dir = Path.join(tmp, "stub-bin")
      File.mkdir_p!(stub_dir)
      stub = Path.join(stub_dir, "claude")

      # Answers the cheap `claude --print ping` auth pre-flight immediately, then
      # stays alive for the real session — so the first dispatch's agent is still
      # running when the second one lands.
      File.write!(stub, """
      #!/bin/sh
      for a in "$@"; do
        if [ "$a" = "ping" ]; then echo pong; exit 0; fi
      done
      sleep 30
      """)

      File.chmod!(stub, 0o755)
      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", "#{stub_dir}:#{old_path}")
      on_exit(fn -> System.put_env("PATH", old_path) end)

      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "x\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      remote = Path.join(tmp, "repo-remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
      put_app_env(:arbiter, :repo_paths, %{"mcp/live-repo" => repo})

      :ok
    end

    test "the refusal names the live session and how to clear it", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "live session dispatch", workspace_id: ctx.ws.id})

      args = %{
        "task_id" => task.id,
        "provider" => "claude",
        "repo" => "mcp/live-repo"
      }

      assert {:ok, _} = Tools.worker_dispatch(ctx.coordinator, args)
      on_exit(fn -> Worker.stop(task.id, :normal) end)

      :ok =
        wait_until(fn -> Worker.agent_session_live?(task.id) end)

      assert {:error, {:invalid, msg}} = Tools.worker_dispatch(ctx.coordinator, args)

      assert msg =~ "live agent session"
      assert msg =~ "arb worker stop #{task.id}"
    end
  end

  describe "worker_dispatch/2 with force_quota: true" do
    test "force_quota: true is accepted in the schema", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "force quota dispatch", workspace_id: ctx.ws.id})

      # Use no_agent: true to test the force_quota flag without dealing with repo setup
      assert {:ok, data} =
               Tools.worker_dispatch(ctx.coordinator, %{
                 "task_id" => task.id,
                 "no_agent" => true,
                 "force_quota" => true
               })

      assert data.task.status == "in_progress"
      assert data.depth == ctx.coordinator.depth + 1

      on_exit(fn -> Worker.stop(task.id, :normal) end)
    end

    test "force_quota: true with force_quota_reason creates audit event with reason via MCP args",
         ctx do
      {:ok, task} =
        Ash.create(Issue, %{title: "force quota with reason", workspace_id: ctx.ws.id})

      # Call Tools.worker_dispatch (the MCP tool handler) with force_quota_reason
      assert {:ok, data} =
               Tools.worker_dispatch(ctx.coordinator, %{
                 "task_id" => task.id,
                 "no_agent" => true,
                 "force_quota" => true,
                 "force_quota_reason" => "critical path test via MCP"
               })

      assert data.task.status == "in_progress"

      # Verify the audit event was created with the reason from the MCP argument
      events =
        Arbiter.Events.Record
        |> Ash.Query.filter(workspace_id == ^ctx.ws.id and topic == "quota_gate_bypass")
        |> Ash.read!()

      assert length(events) == 1
      event = List.first(events)
      payload = event.payload

      assert payload["task_id"] == task.id
      assert payload["actor"] == "coordinator"
      assert payload["reason"] == "critical path test via MCP"

      on_exit(fn -> Worker.stop(task.id, :normal) end)
    end

    test "force_quota: false is accepted in the schema", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "normal quota dispatch", workspace_id: ctx.ws.id})

      assert {:ok, data} =
               Tools.worker_dispatch(ctx.coordinator, %{
                 "task_id" => task.id,
                 "no_agent" => true,
                 "force_quota" => false
               })

      assert data.task.status == "in_progress"

      on_exit(fn -> Worker.stop(task.id, :normal) end)
    end
  end

  describe "worker_resume/2 with force_quota: true" do
    test "force_quota: true is accepted in the schema on resume", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "force quota resume", workspace_id: ctx.ws.id})

      # First dispatch with no_agent to park the task
      {:ok, _dispatch_result} =
        Tools.worker_dispatch(ctx.coordinator, %{
          "task_id" => task.id,
          "no_agent" => true
        })

      # Resume with force_quota: true
      # Note: This will fail because there's no actual worktree to resume from,
      # but we're testing that the flag is accepted in the schema, not the full logic
      result =
        Tools.worker_resume(ctx.coordinator, %{
          "task_id" => task.id,
          "force_quota" => true
        })

      # The schema should accept force_quota, so we shouldn't get an "additional properties" error
      case result do
        {:ok, _} ->
          :ok

        {:error, {:invalid, msg}} ->
          # Should not complain about force_quota being unknown
          refute msg =~ "force_quota"

        {:error, _} ->
          # Other errors are fine (e.g., no worktree to resume from)
          :ok
      end

      on_exit(fn -> Worker.stop(task.id, :normal) end)
    end

    test "force_quota_reason is accepted in the schema and does not cause additional properties error",
         ctx do
      {:ok, task} =
        Ash.create(Issue, %{title: "force quota resume with reason", workspace_id: ctx.ws.id})

      # First dispatch with no_agent to park the task
      {:ok, _dispatch_result} =
        Tools.worker_dispatch(ctx.coordinator, %{
          "task_id" => task.id,
          "no_agent" => true
        })

      # Resume with force_quota: true and force_quota_reason
      result =
        Tools.worker_resume(ctx.coordinator, %{
          "task_id" => task.id,
          "force_quota" => true,
          "force_quota_reason" => "resume for critical fix via MCP"
        })

      # The schema should accept force_quota_reason, so we shouldn't get an "additional properties" error
      case result do
        {:ok, _} ->
          :ok

        {:error, {:invalid, msg}} ->
          # Should not complain about force_quota_reason being unknown
          refute msg =~ "force_quota_reason"

        {:error, _} ->
          # Other errors are fine (e.g., no worktree to resume from)
          :ok
      end

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

    test "labels a subordinate pass so two rows for one task_id are legible (bd-8lq2g7)", ctx do
      {:ok, task} = Ash.create(Issue, %{title: "two rows one task", workspace_id: ctx.ws.id})

      {:ok, primary} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ctx.ws.id)

      {:ok, fixpass} =
        Worker.start(
          task_id: task.id,
          registry_key: task.id <> ":fixpass",
          repo: "test/repo",
          workspace_id: ctx.ws.id,
          meta: %{role: :fix_pass}
        )

      on_exit(fn ->
        Process.alive?(primary) && GenServer.stop(primary, :normal)
        Process.alive?(fixpass) && GenServer.stop(fixpass, :normal)
      end)

      assert {:ok, %{workers: workers}} = Tools.worker_list(ctx.coordinator, %{})
      rows = Enum.filter(workers, &(&1.task_id == task.id))
      assert length(rows) == 2

      primary_row = Enum.find(rows, &(&1.registry_key == task.id))
      fixpass_row = Enum.find(rows, &(&1.registry_key == task.id <> ":fixpass"))

      assert primary_row.role == nil
      assert fixpass_row.role == "fix_pass"
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

  describe "external_review_list/2 (bd-dmy4pk: workspace: arg)" do
    setup ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "erl-other-ws", prefix: "erl"})

      {:ok, here} =
        Ash.create(Arbiter.Reviews.Record, %{
          pr_ref: "github:acme/here#1",
          pr: "1",
          workspace_id: ctx.ws.id,
          strategy: "github",
          status: :completed,
          started_at: DateTime.utc_now()
        })

      {:ok, there} =
        Ash.create(Arbiter.Reviews.Record, %{
          pr_ref: "github:acme/there#2",
          pr: "2",
          workspace_id: other_ws.id,
          strategy: "github",
          status: :completed,
          started_at: DateTime.utc_now()
        })

      {:ok, Map.merge(ctx, %{other_ws: other_ws, here: here, there: there})}
    end

    test "with no `workspace` arg, lists only the scope's own workspace", ctx do
      assert {:ok, %{external_reviews: records}} =
               Tools.external_review_list(ctx.coordinator, %{})

      assert Enum.any?(records, &(&1.id == ctx.here.id))
      refute Enum.any?(records, &(&1.id == ctx.there.id))
    end

    test "passing `workspace:` scopes the list to that workspace", ctx do
      agnostic = %Scope{tier: :coordinator, workspace_id: nil, can_dispatch: true}

      assert {:ok, %{external_reviews: records}} =
               Tools.external_review_list(agnostic, %{"workspace" => ctx.other_ws.name})

      assert Enum.any?(records, &(&1.id == ctx.there.id))
      refute Enum.any?(records, &(&1.id == ctx.here.id))
    end

    test "the catalog advertises the optional `workspace` param", _ctx do
      tool = Enum.find(Catalog.all(), &(&1.name == "external_review_list"))
      assert is_map(tool.input_schema["properties"]["workspace"])
      refute "workspace" in (tool.input_schema["required"] || [])
    end
  end

  describe "external_review_show/2 (bd-dmy4pk: pre-greenlight findings read)" do
    test "returns a record's full proposed_comments regardless of workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "ers-other-ws", prefix: "ers"})

      {:ok, record} =
        Ash.create(Arbiter.Reviews.Record, %{
          pr_ref: "github:acme/there#3",
          pr: "3",
          workspace_id: other_ws.id,
          strategy: "github",
          status: :completed,
          mode: :report_only,
          proposed_comments: [
            %{"file" => "lib/foo.ex", "line" => 12, "severity" => "warn", "body" => "fix this"}
          ],
          started_at: DateTime.utc_now()
        })

      assert {:ok, data} =
               Tools.external_review_show(ctx.coordinator, %{"record_id" => record.id})

      assert data.id == record.id
      assert data.workspace_id == other_ws.id
      assert [%{"file" => "lib/foo.ex"}] = data.proposed_comments
    end

    test "an unknown record_id is not-found", ctx do
      assert {:error, {:not_found, msg}} =
               Tools.external_review_show(ctx.coordinator, %{"record_id" => "no-such-record"})

      assert msg =~ "no external review record"
    end

    test "requires record_id", ctx do
      assert {:error, {:invalid, msg}} = Tools.external_review_show(ctx.coordinator, %{})
      assert msg =~ "record_id"
    end
  end

  describe "external_review transcript retrieval (bd-7efini)" do
    setup ctx do
      prev = Application.get_env(:arbiter, :output_log_root)

      root =
        Path.join(
          System.tmp_dir!(),
          "review-transcript-mcp-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:arbiter, :output_log_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if prev,
          do: Application.put_env(:arbiter, :output_log_root, prev),
          else: Application.delete_env(:arbiter, :output_log_root)
      end)

      {:ok, record} =
        Ash.create(Arbiter.Reviews.Record, %{
          pr_ref: "github:acme/here#77",
          pr: "77",
          workspace_id: ctx.ws.id,
          strategy: "github",
          status: :completed,
          started_at: DateTime.utc_now()
        })

      stream_json =
        Enum.join(
          [
            ~s({"type":"system","subtype":"init","model":"claude-opus-5","session_id":"s-1"}),
            ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"lib/a.ex"}}]}}),
            ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"contents"}]}}),
            ~s({"type":"result","subtype":"success","result":"done"})
          ],
          "\n"
        )

      {:ok, Map.merge(ctx, %{record: record, stream_json: stream_json})}
    end

    test "external_review_show reports transcript capture state and the tool histogram", ctx do
      :ok = Arbiter.Worker.PromptLog.write(ctx.record.id, "You are a code reviewer.")
      :ok = Arbiter.Reviews.Transcript.write(ctx.record.id, ctx.stream_json)

      assert {:ok, data} =
               Tools.external_review_show(ctx.coordinator, %{"record_id" => ctx.record.id})

      assert data.transcript_exists
      assert data.prompt_exists
      assert data.transcript_line_count == 4
      assert data.tool_use_count == 1
      assert data.tools_used == [%{name: "Read", count: 1}]
    end

    test "external_review_show reports absence for a review with no captured transcript", ctx do
      assert {:ok, data} =
               Tools.external_review_show(ctx.coordinator, %{"record_id" => ctx.record.id})

      refute data.transcript_exists
      refute data.prompt_exists
      assert data.transcript_line_count == 0
      assert data.tools_used == []
    end

    test "external_review_list stays summary-only (no per-row disk reads)", ctx do
      :ok = Arbiter.Reviews.Transcript.write(ctx.record.id, ctx.stream_json)

      assert {:ok, %{external_reviews: [record | _]}} =
               Tools.external_review_list(ctx.coordinator, %{})

      refute Map.has_key?(record, :transcript_line_count)
    end

    test "external_review_transcript returns the prompt, the raw lines and the tool uses", ctx do
      :ok = Arbiter.Worker.PromptLog.write(ctx.record.id, "You are a code reviewer.")
      :ok = Arbiter.Reviews.Transcript.write(ctx.record.id, ctx.stream_json)

      assert {:ok, data} =
               Tools.external_review_transcript(ctx.coordinator, %{"record_id" => ctx.record.id})

      assert data.record_id == ctx.record.id
      assert data.pr_ref == ctx.record.pr_ref
      assert data.exists
      assert data.path == Arbiter.Reviews.Transcript.path_for(ctx.record.id)
      assert data.prompt == "You are a code reviewer."
      assert data.line_count == 4
      assert length(data.lines) == 4
      assert [%{name: "Read", tool_use_id: "t1", result: "contents"}] = data.tool_uses
    end

    test "external_review_transcript survives a multibyte tool result straddling the preview cutoff",
         ctx do
      # A `Read` of a real source file: ASCII right up to the 2000-char preview
      # cap, then an em-dash spanning it. A byte-offset slice would hand
      # `Jason.encode!/1` (ArbiterWeb.MCP.Plug) invalid UTF-8 — a transport
      # failure the handler's own `rescue` never sees.
      long = String.duplicate("a", 1999) <> "— rest of the file " <> String.duplicate("b", 200)

      stream_json =
        Enum.join(
          [
            ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"lib/a.ex"}}]}}),
            Jason.encode!(%{
              "type" => "user",
              "message" => %{
                "content" => [
                  %{"type" => "tool_result", "tool_use_id" => "t1", "content" => long}
                ]
              }
            })
          ],
          "\n"
        )

      :ok = Arbiter.Reviews.Transcript.write(ctx.record.id, stream_json)

      assert {:ok, data} =
               Tools.external_review_transcript(ctx.coordinator, %{"record_id" => ctx.record.id})

      assert [%{name: "Read", result: result}] = data.tool_uses
      assert String.valid?(result)
      assert String.ends_with?(result, "… [truncated]")
      # What the MCP plug does with the handler's return value.
      assert is_binary(Jason.encode!(data))
    end

    test "external_review_transcript can omit the prompt and tail the lines", ctx do
      :ok = Arbiter.Worker.PromptLog.write(ctx.record.id, "You are a code reviewer.")
      :ok = Arbiter.Reviews.Transcript.write(ctx.record.id, ctx.stream_json)

      assert {:ok, data} =
               Tools.external_review_transcript(ctx.coordinator, %{
                 "record_id" => ctx.record.id,
                 "include_prompt" => false,
                 "tail" => 2
               })

      assert data.prompt == nil
      assert data.line_count == 4
      assert length(data.lines) == 2
      assert data.truncated
      assert List.last(data.lines) =~ ~s("type":"result")
    end

    test "external_review_transcript distinguishes uncaptured from empty", ctx do
      assert {:ok, data} =
               Tools.external_review_transcript(ctx.coordinator, %{"record_id" => ctx.record.id})

      refute data.exists
      assert data.lines == []
      assert data.line_count == 0
      assert data.tool_uses == []
    end

    test "external_review_transcript is not-found for an unknown record", ctx do
      assert {:error, {:not_found, msg}} =
               Tools.external_review_transcript(ctx.coordinator, %{"record_id" => "nope"})

      assert msg =~ "no external review record"
    end

    test "external_review_transcript requires record_id", ctx do
      assert {:error, {:invalid, msg}} = Tools.external_review_transcript(ctx.coordinator, %{})
      assert msg =~ "record_id"
    end

    test "the catalog advertises external_review_transcript to coordinators", _ctx do
      tool = Enum.find(Catalog.all(), &(&1.name == "external_review_transcript"))
      assert tool, "external_review_transcript missing from the MCP catalog"
      assert "record_id" in tool.input_schema["required"]
      assert is_map(tool.input_schema["properties"]["tail"])
      assert is_map(tool.input_schema["properties"]["include_prompt"])
    end
  end

  describe "review_gate_rounds_list/2 (bd-aqyjuc)" do
    test "returns rounds for a task, oldest-first, distinguishing round-1 reject from round-2 approve",
         ctx do
      {:ok, _r1} =
        Ash.create(Arbiter.ReviewGate.Round, %{
          task_id: ctx.task.id,
          round: 1,
          role: :review,
          verdict: :request_changes,
          findings: "VERDICT: REQUEST_CHANGES\n1. fix the thing",
          finding_count: 1,
          reviewer_model: "claude-sonnet-5",
          reviewer_tier: "standard",
          cost_usd: 0.12,
          converged: false
        })

      {:ok, _r2} =
        Ash.create(Arbiter.ReviewGate.Round, %{
          task_id: ctx.task.id,
          round: 2,
          role: :review,
          verdict: :approve,
          findings: "VERDICT: APPROVE",
          finding_count: 0,
          reviewer_model: "claude-sonnet-5",
          cost_usd: 0.09,
          converged: true
        })

      assert {:ok, %{rounds: rounds, count: 2}} =
               Tools.review_gate_rounds_list(ctx.coordinator, %{"task_id" => ctx.task.id})

      assert [round1, round2] = rounds
      assert round1.round == 1
      assert round1.verdict == :request_changes
      assert round1.converged == false
      # bd-3xultf: the resolved reviewer tier is exposed alongside
      # reviewer_model so analysis can control for the judge.
      assert round1.reviewer_tier == "standard"
      assert round2.round == 2
      assert round2.verdict == :approve
      assert round2.converged == true
    end

    test "requires task_id", ctx do
      assert {:error, {:invalid, msg}} = Tools.review_gate_rounds_list(ctx.coordinator, %{})
      assert msg =~ "task_id"
    end

    test "an unknown task_id returns an empty list", ctx do
      assert {:ok, %{rounds: [], count: 0}} =
               Tools.review_gate_rounds_list(ctx.coordinator, %{"task_id" => "no-such-task"})
    end

    test "limit caps the returned rows to the most recent N, oldest-first (bd-dp7hiw)", ctx do
      for round <- 1..3 do
        {:ok, _} =
          Ash.create(Arbiter.ReviewGate.Round, %{
            task_id: ctx.task.id,
            round: round,
            role: :review,
            verdict: :request_changes,
            findings: "VERDICT: REQUEST_CHANGES round #{round}",
            finding_count: 1,
            reviewer_model: "claude-sonnet-5",
            cost_usd: 0.1,
            converged: false
          })
      end

      assert {:ok, %{rounds: rounds, count: 2, total_count: 3}} =
               Tools.review_gate_rounds_list(ctx.coordinator, %{
                 "task_id" => ctx.task.id,
                 "limit" => 2
               })

      assert [round2, round3] = rounds
      assert round2.round == 2
      assert round3.round == 3
    end

    test "omitting limit preserves full-history behavior (bd-dp7hiw)", ctx do
      for round <- 1..3 do
        {:ok, _} =
          Ash.create(Arbiter.ReviewGate.Round, %{
            task_id: ctx.task.id,
            round: round,
            role: :review,
            verdict: :request_changes,
            findings: "VERDICT: REQUEST_CHANGES round #{round}",
            finding_count: 1,
            reviewer_model: "claude-sonnet-5",
            cost_usd: 0.1,
            converged: false
          })
      end

      assert {:ok, %{rounds: rounds, count: 3, total_count: 3}} =
               Tools.review_gate_rounds_list(ctx.coordinator, %{"task_id" => ctx.task.id})

      assert Enum.map(rounds, & &1.round) == [1, 2, 3]
    end

    test "limit rejects a non-positive value", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.review_gate_rounds_list(ctx.coordinator, %{
                 "task_id" => ctx.task.id,
                 "limit" => 0
               })

      assert msg =~ "limit"
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

  # bd-9j2g3x — the loop proposal queue over MCP. Coordinator-only tiering is
  # asserted in Arbiter.MCP.CatalogTest; here we check the handlers themselves.
  describe "loop_pending_* (bd-9j2g3x)" do
    setup ctx do
      {:ok, target} =
        Ash.create(Issue, %{title: "loop target", difficulty: 2, workspace_id: ctx.ws.id})

      {:ok, row} =
        Arbiter.Loop.record(%{
          kind: :difficulty_override,
          scope: :task,
          gist: "raise difficulty on #{target.id}: D2 → D3",
          category: "difficulty misestimate (rework)",
          target: target.id,
          difficulty: 2,
          repo: "arbiter",
          incident_refs: [target.id],
          task_refs: [target.id],
          payload: %{"task_id" => target.id, "difficulty" => 3},
          diff: "--- a/task\n+++ b/task\n@@ @@\n-difficulty: 2\n+difficulty: 3\n",
          workspace_id: ctx.ws.id
        })

      {:ok, target: target, row: row}
    end

    test "loop_pending_list returns the live queue and the evidence bar", ctx do
      assert {:ok, data} = Tools.loop_pending_list(ctx.coordinator, %{})

      summary = Enum.find(data.pending, &(&1.id == ctx.row.id))
      assert summary
      assert data.count == length(data.pending)
      assert data.evidence_bar == Arbiter.Loop.default_evidence_bar()
      # Amendment D: a coordinator deciding over MCP sees the same recurring
      # price a human sees in the CLI. A per-task override is free forever.
      assert summary.context_cost_tokens == 0
    end

    test "loop_pending_list rejects an unknown state rather than silently returning nothing",
         ctx do
      assert {:error, {:invalid, message}} =
               Tools.loop_pending_list(ctx.coordinator, %{"state" => "propsed"})

      assert message =~ "`state` must be one of"
    end

    test "loop_pending_diff returns the full row including the unified diff", ctx do
      assert {:ok, data} = Tools.loop_pending_diff(ctx.coordinator, %{"id" => ctx.row.id})

      assert data.diff =~ "+difficulty: 3"
      assert data.fingerprint == ctx.row.fingerprint
      assert data.applicable == true
    end

    test "loop_pending_apply goes through the domain API and paper-trails the proposal id", ctx do
      assert {:ok, data} = Tools.loop_pending_apply(ctx.coordinator, %{"id" => ctx.row.id})
      assert data.state == :applied

      {:ok, target} = Ash.get(Issue, ctx.target.id)
      assert target.difficulty == 3

      versions =
        Arbiter.Tasks.Issue.Version
        |> Ash.Query.filter(version_source_id == ^ctx.target.id)
        |> Ash.read!()

      assert Enum.any?(
               versions,
               &(&1.version_action_inputs["change_origin"] == "loop:proposal:#{ctx.row.id}")
             )
    end

    test "loop_pending_reject is soft — the row persists as rejected", ctx do
      assert {:ok, data} =
               Tools.loop_pending_reject(ctx.coordinator, %{
                 "id" => ctx.row.id,
                 "reason" => "handled in CLAUDE.md"
               })

      assert data.state == :rejected
      assert {:ok, still_there} = Arbiter.Loop.get_pending(ctx.row.id)
      assert still_there.rejection_reason == "handled in CLAUDE.md"
    end

    test "a scope bound to another workspace cannot reach the row", ctx do
      {:ok, other} = Ash.create(Workspace, %{name: "other-loop-ws", prefix: "olw"})
      intruder = %Scope{tier: :coordinator, workspace_id: other.id}

      assert {:error, {:not_found, message}} =
               Tools.loop_pending_diff(intruder, %{"id" => ctx.row.id})

      assert message =~ "no loop proposal matching"
    end

    test "an unknown id is a tool error, not a crash", ctx do
      assert {:error, {:not_found, message}} =
               Tools.loop_pending_apply(ctx.coordinator, %{"id" => Ecto.UUID.generate()})

      assert message =~ "no loop proposal matching"
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

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end
end
