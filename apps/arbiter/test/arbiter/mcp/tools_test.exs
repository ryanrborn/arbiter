defmodule Arbiter.MCP.ToolsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Dependency
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.MCP
  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat

  require Ash.Query

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "mcp-tools-ws", prefix: "mcp"})
    {:ok, bead} = Ash.create(Issue, %{title: "the bound bead", workspace_id: ws.id})

    polecat = %Scope{tier: :polecat, workspace_id: ws.id, bead_id: bead.id, repo: "shipyard"}
    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

    {:ok, ws: ws, bead: bead, polecat: polecat, coordinator: coordinator}
  end

  describe "bead_show/2" do
    test "a polecat reads its own bead (id defaulted from the token)", ctx do
      assert {:ok, data} = Tools.bead_show(ctx.polecat, %{})
      assert data.id == ctx.bead.id
      assert data.title == "the bound bead"
      assert data.status == "open"
    end

    test "a polecat may not read another bead", ctx do
      {:ok, other} = Ash.create(Issue, %{title: "someone else", workspace_id: ctx.ws.id})
      assert {:error, {:unauthorized, _}} = Tools.bead_show(ctx.polecat, %{"id" => other.id})
    end

    test "a coordinator reads any bead in its workspace", ctx do
      assert {:ok, data} = Tools.bead_show(ctx.coordinator, %{"id" => ctx.bead.id})
      assert data.id == ctx.bead.id
    end

    test "a coordinator cannot see a bead in another workspace (reported not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "other-ws", prefix: "oth"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} = Tools.bead_show(ctx.coordinator, %{"id" => foreign.id})
    end

    test "a coordinator must supply an id", ctx do
      assert {:error, {:invalid, _}} = Tools.bead_show(ctx.coordinator, %{})
    end
  end

  describe "bead_ready/2" do
    test "lists open, unblocked beads in the workspace", ctx do
      assert {:ok, %{beads: beads, count: count}} = Tools.bead_ready(ctx.coordinator, %{})
      assert count >= 1
      assert Enum.any?(beads, &(&1.id == ctx.bead.id))
    end
  end

  describe "bead_show/2 child-progress rollup" do
    test "a parent bead reports child_total / child_closed over its parent_of children", ctx do
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

      assert {:ok, data} = Tools.bead_show(ctx.coordinator, %{"id" => parent.id})
      assert data.child_total == 2
      assert data.child_closed == 1
      assert data.child_open == 1
      assert data.auto_close == false
    end

    test "a leaf bead reports zero children", ctx do
      assert {:ok, data} = Tools.bead_show(ctx.coordinator, %{"id" => ctx.bead.id})
      assert data.child_total == 0
      assert data.child_closed == 0
    end
  end

  describe "inbox_check/2" do
    test "returns the unread mailbox for the polecat's bead and marks it read", ctx do
      {:ok, _} = Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: ctx.bead.id, body: "ping"})

      assert {:ok, %{messages: [msg], count: 1, bead_id: bead_id}} =
               Tools.inbox_check(ctx.polecat, %{})

      assert bead_id == ctx.bead.id
      assert msg.body == "ping"

      # Second check is empty — the first marked them read.
      assert {:ok, %{count: 0}} = Tools.inbox_check(ctx.polecat, %{})
    end
  end

  describe "coordinator_inbox/2" do
    test "lists unread Admiral messages and marks them read", ctx do
      {:ok, _} =
        Message.send_mail(%{workspace_id: ctx.ws.id, to_ref: "admiral", body: "Escalation!"})

      assert {:ok, %{messages: [msg], count: 1, cleared: 0}} =
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
      # messages. "first" and "second" are both read at this point, so cleared: 2.
      assert {:ok, %{count: 1, cleared: 2}} =
               Tools.coordinator_inbox(ctx.coordinator, %{"clear" => true})
    end

    test "does not surface messages from another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "ci-other", prefix: "cio"})

      {:ok, _} =
        Message.send_mail(%{workspace_id: other_ws.id, to_ref: "admiral", body: "foreign"})

      assert {:ok, %{count: 0}} = Tools.coordinator_inbox(ctx.coordinator, %{})
    end

    test "polecat tier is denied (catalog-level gating)", ctx do
      assert {:rpc_error, -32_003, message} =
               Catalog.call(ctx.polecat, "coordinator_inbox", %{})

      assert message =~ "not permitted"
    end
  end

  describe "workspace_show/2" do
    test "returns the scope's own workspace config + resolved security posture", ctx do
      assert {:ok, data} = Tools.workspace_show(ctx.polecat, %{})
      assert data.id == ctx.ws.id
      assert data.prefix == "mcp"
      assert is_map(data.config)
      assert is_binary(data.security["mode"])
    end
  end

  describe "bead_update_progress/2" do
    test "a polecat records qa/deployment notes on its own bead", ctx do
      assert {:ok, data} =
               Tools.bead_update_progress(ctx.polecat, %{
                 "qa_notes" => "verify the login flow",
                 "deployment_notes" => "None"
               })

      assert data.qa_notes == "verify the login flow"
      assert data.deployment_notes == "None"

      {:ok, reloaded} = Ash.get(Issue, ctx.bead.id)
      assert reloaded.qa_notes == "verify the login flow"
    end

    test "a polecat records pr_body on its own bead (bd-53xrmi)", ctx do
      body = "## Summary\nWorker-authored.\n\n## Test plan\n- [x] mix test"

      assert {:ok, data} = Tools.bead_update_progress(ctx.polecat, %{"pr_body" => body})
      assert data.pr_body == body

      {:ok, reloaded} = Ash.get(Issue, ctx.bead.id)
      assert reloaded.pr_body == body
    end

    test "ignores non-progress fields (cannot flip status)", ctx do
      assert {:ok, data} =
               Tools.bead_update_progress(ctx.polecat, %{"notes" => "wip", "status" => "closed"})

      assert data.status == "open"
      assert data.notes == "wip"
    end

    test "requires at least one progress field", ctx do
      assert {:error, {:invalid, _}} = Tools.bead_update_progress(ctx.polecat, %{})
    end

    test "a polecat may not progress another bead", ctx do
      {:ok, other} = Ash.create(Issue, %{title: "not yours", workspace_id: ctx.ws.id})

      assert {:error, {:unauthorized, _}} =
               Tools.bead_update_progress(ctx.polecat, %{"id" => other.id, "notes" => "x"})
    end
  end

  # ---- Phase 2: coordinator-only mutating tools --------------------------

  describe "bead_create/2" do
    test "a coordinator creates a bead forced into its own workspace", ctx do
      assert {:ok, data} =
               Tools.bead_create(ctx.coordinator, %{
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
      assert {:error, {:invalid, _}} = Tools.bead_create(ctx.coordinator, %{"priority" => 1})
    end

    test "rejects an unknown enum value", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.bead_create(ctx.coordinator, %{"title" => "x", "issue_type" => "nope"})

      assert msg =~ "issue_type"
    end
  end

  describe "bead_update/2" do
    test "a coordinator updates fields on a bead in its workspace", ctx do
      assert {:ok, data} =
               Tools.bead_update(ctx.coordinator, %{
                 "id" => ctx.bead.id,
                 "status" => "in_progress",
                 "priority" => 0
               })

      assert data.status == "in_progress"
      assert data.priority == 0
    end

    test "cannot close a bead through bead_update (closed status rejected)", ctx do
      assert {:error, {:invalid, _}} =
               Tools.bead_update(ctx.coordinator, %{"id" => ctx.bead.id, "status" => "closed"})

      {:ok, reloaded} = Ash.get(Issue, ctx.bead.id)
      assert reloaded.status == :open
    end

    test "requires at least one field to update", ctx do
      assert {:error, {:invalid, _}} = Tools.bead_update(ctx.coordinator, %{"id" => ctx.bead.id})
    end

    test "cannot update a bead in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "bu-other", prefix: "buo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.bead_update(ctx.coordinator, %{"id" => foreign.id, "notes" => "x"})
    end
  end

  describe "bead_close/2" do
    test "a coordinator closes a bead in its workspace", ctx do
      assert {:ok, data} =
               Tools.bead_close(ctx.coordinator, %{"id" => ctx.bead.id, "reason" => "done"})

      assert data.status == "closed"

      {:ok, reloaded} = Ash.get(Issue, ctx.bead.id)
      assert reloaded.status == :closed
    end
  end

  describe "dep_add/2 + dep_remove/2" do
    setup ctx do
      {:ok, other} = Ash.create(Issue, %{title: "blocker", workspace_id: ctx.ws.id})
      {:ok, other: other}
    end

    test "adds and removes a dependency edge between beads in the workspace", ctx do
      assert {:ok, dep} =
               Tools.dep_add(ctx.coordinator, %{
                 "from_issue_id" => ctx.bead.id,
                 "to_issue_id" => ctx.other.id,
                 "type" => "depends_on"
               })

      assert dep.from_issue_id == ctx.bead.id
      assert dep.to_issue_id == ctx.other.id
      assert dep.type == "depends_on"

      assert {:ok, %{removed: 1}} =
               Tools.dep_remove(ctx.coordinator, %{
                 "from_issue_id" => ctx.bead.id,
                 "to_issue_id" => ctx.other.id
               })

      assert Dependency |> Ash.read!() |> Enum.empty?()
    end

    test "rejects an unknown dependency type", ctx do
      assert {:error, {:invalid, _}} =
               Tools.dep_add(ctx.coordinator, %{
                 "from_issue_id" => ctx.bead.id,
                 "to_issue_id" => ctx.other.id,
                 "type" => "nonsense"
               })
    end

    test "cannot point an edge at a bead in another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "dep-other", prefix: "dpo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.dep_add(ctx.coordinator, %{
                 "from_issue_id" => ctx.bead.id,
                 "to_issue_id" => foreign.id,
                 "type" => "blocks"
               })
    end

    test "dep_remove is idempotent (absent edge → removed: 0)", ctx do
      assert {:ok, %{removed: 0}} =
               Tools.dep_remove(ctx.coordinator, %{
                 "from_issue_id" => ctx.bead.id,
                 "to_issue_id" => ctx.other.id
               })
    end
  end

  describe "parent/child grouping via dep_add parent_of + auto_close" do
    test "bead_create accepts auto_close and bead_update can toggle it", ctx do
      assert {:ok, parent} =
               Tools.bead_create(ctx.coordinator, %{
                 "title" => "epic",
                 "issue_type" => "epic",
                 "auto_close" => true
               })

      assert parent.issue_type == "epic"
      assert parent.auto_close == true

      assert {:ok, updated} =
               Tools.bead_update(ctx.coordinator, %{"id" => parent.id, "auto_close" => false})

      assert updated.auto_close == false
    end

    test "attaching a child with a parent_of edge auto-closes the parent when done", ctx do
      assert {:ok, parent} =
               Tools.bead_create(ctx.coordinator, %{"title" => "epic", "auto_close" => true})

      {:ok, child} = Ash.create(Issue, %{title: "child", workspace_id: ctx.ws.id})

      assert {:ok, _dep} =
               Tools.dep_add(ctx.coordinator, %{
                 "from_issue_id" => parent.id,
                 "to_issue_id" => child.id,
                 "type" => "parent_of"
               })

      {:ok, _} = Ash.update(child, %{}, action: :close)

      assert {:ok, data} = Tools.bead_show(ctx.coordinator, %{"id" => parent.id})
      assert data.status == "closed"
      assert data.child_closed == 1
      assert data.child_total == 1
    end
  end

  describe "message_send/2" do
    test "a coordinator sends a direction to a bead's mailbox, scoped to its workspace", ctx do
      assert {:ok, msg} =
               Tools.message_send(ctx.coordinator, %{
                 "bead_id" => ctx.bead.id,
                 "body" => "pick this up next"
               })

      assert msg.kind == "direction"
      assert msg.from_ref == "coordinator"
      assert msg.to_ref == ctx.bead.id

      # It lands in the bead's inbox.
      [inbox_msg] = Message.inbox(ctx.bead.id, workspace_id: ctx.ws.id)
      assert inbox_msg.body == "pick this up next"
    end

    test "a polecat raises a flag from its own bead to a sibling", ctx do
      {:ok, sibling} = Ash.create(Issue, %{title: "sibling", workspace_id: ctx.ws.id})

      assert {:ok, msg} =
               Tools.message_send(ctx.polecat, %{
                 "bead_id" => sibling.id,
                 "body" => "heads up — the API shape changed"
               })

      # The sender identity is the polecat's own bead, set from the scope — not
      # spoofable by the client.
      assert msg.kind == "flag"
      assert msg.from_ref == ctx.bead.id
      assert msg.to_ref == sibling.id

      [inbox_msg] = Message.inbox(sibling.id, workspace_id: ctx.ws.id)
      assert inbox_msg.body == "heads up — the API shape changed"
    end

    test "requires a recipient and a body", ctx do
      assert {:error, {:invalid, _}} =
               Tools.message_send(ctx.coordinator, %{"bead_id" => ctx.bead.id})
    end
  end

  describe "bead_reopen/2" do
    test "a coordinator reopens a closed bead", ctx do
      {:ok, _} = Ash.update(ctx.bead, %{reason: "done"}, action: :close)

      assert {:ok, data} = Tools.bead_reopen(ctx.coordinator, %{"id" => ctx.bead.id})
      assert data.status == "open"
      assert is_nil(data.closed_at)

      {:ok, reloaded} = Ash.get(Issue, ctx.bead.id)
      assert reloaded.status == :open
    end

    test "reopening a non-closed bead is rejected (FSM guard)", ctx do
      assert {:error, {:invalid, _}} = Tools.bead_reopen(ctx.coordinator, %{"id" => ctx.bead.id})
    end

    test "cannot reopen a bead in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "ro-other", prefix: "roo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.bead_reopen(ctx.coordinator, %{"id" => foreign.id})
    end
  end

  describe "notify_list/2" do
    test "lists recent notifications scoped to the workspace (both tiers)", ctx do
      {:ok, _} = Message.notify(%{workspace_id: ctx.ws.id, body: "a polecat finished"})

      assert {:ok, %{notifications: [n], count: 1}} = Tools.notify_list(ctx.coordinator, %{})
      assert n.body == "a polecat finished"
      assert n.kind == "notification"

      # A polecat sees the same workspace feed.
      assert {:ok, %{count: 1}} = Tools.notify_list(ctx.polecat, %{})
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

  describe "polecat_resume/2 + polecat_review/2 (dispatch-recursion guardrail, §4.3)" do
    test "resume refuses a coordinator scope without can_dispatch", ctx do
      no_dispatch = %{ctx.coordinator | can_dispatch: false}

      assert {:error, {:unauthorized, _}} =
               Tools.polecat_resume(no_dispatch, %{"bead_id" => ctx.bead.id})
    end

    test "review refuses a coordinator scope without can_dispatch", ctx do
      no_dispatch = %{ctx.coordinator | can_dispatch: false}

      assert {:error, {:unauthorized, _}} =
               Tools.polecat_review(no_dispatch, %{"bead_id" => ctx.bead.id})
    end

    test "resume refuses once the depth limit is reached", ctx do
      at_limit = %{ctx.coordinator | depth: MCP.max_depth()}

      assert {:error, {:unauthorized, msg}} =
               Tools.polecat_resume(at_limit, %{"bead_id" => ctx.bead.id})

      assert msg =~ "depth"
    end

    test "review cannot target a bead in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "rv-other", prefix: "rvo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.polecat_review(ctx.coordinator, %{"bead_id" => foreign.id})
    end

    test "resume surfaces the no-worktree error for a bead never slung", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "never slung", workspace_id: ctx.ws.id})

      # can_dispatch + in-workspace + below depth, but no preserved worktree exists.
      assert {:error, {:invalid, msg}} =
               Tools.polecat_resume(ctx.coordinator, %{"bead_id" => bead.id, "repo" => "test/repo"})

      assert msg =~ "worktree" or msg =~ "repo"
    end
  end

  describe "polecat_stop/2" do
    test "stops a running polecat in the workspace", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "stop target", workspace_id: ctx.ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Polecat.stop(bead.id, :normal) end)

      assert {:ok, %{bead_id: bead_id, stopped: true}} =
               Tools.polecat_stop(ctx.coordinator, %{"bead_id" => bead.id})

      assert bead_id == bead.id
    end

    test "a bead with no live polecat is reported not-found", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "no polecat", workspace_id: ctx.ws.id})

      assert {:error, {:not_found, _}} =
               Tools.polecat_stop(ctx.coordinator, %{"bead_id" => bead.id})
    end

    test "cannot stop a polecat for a bead in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "st-other", prefix: "sto"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      {:ok, pid} = Polecat.start(bead_id: foreign.id, repo: "test/repo", workspace_id: other_ws.id)
      on_exit(fn -> Process.alive?(pid) && Polecat.stop(foreign.id, :normal) end)

      assert {:error, {:not_found, _}} =
               Tools.polecat_stop(ctx.coordinator, %{"bead_id" => foreign.id})
    end
  end

  describe "usage_summarize/2" do
    test "requires a valid `by` grouping", ctx do
      assert {:error, {:invalid, _}} = Tools.usage_summarize(ctx.coordinator, %{})
      assert {:error, {:invalid, _}} = Tools.usage_summarize(ctx.coordinator, %{"by" => "nope"})
    end

    test "returns rollups for a valid grouping (empty ledger → no rows)", ctx do
      assert {:ok, %{by: "bead", rollups: rollups, count: 0}} =
               Tools.usage_summarize(ctx.coordinator, %{"by" => "bead"})

      assert rollups == []
    end
  end

  describe "polecat_dispatch/2 (dispatch-recursion guardrail, §4.3)" do
    test "refuses a coordinator scope without can_dispatch", ctx do
      no_dispatch = %{ctx.coordinator | can_dispatch: false}

      assert {:error, {:unauthorized, _}} =
               Tools.polecat_dispatch(no_dispatch, %{"bead_id" => ctx.bead.id})
    end

    test "refuses once the depth limit is reached", ctx do
      at_limit = %{ctx.coordinator | depth: MCP.max_depth()}

      assert {:error, {:unauthorized, msg}} =
               Tools.polecat_dispatch(at_limit, %{"bead_id" => ctx.bead.id})

      assert msg =~ "depth"
    end

    test "cannot dispatch a bead in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "sl-other", prefix: "slo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.polecat_dispatch(ctx.coordinator, %{"bead_id" => foreign.id})
    end

    test "parks the bead in_progress and reports the child depth", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "to dispatch", workspace_id: ctx.ws.id})

      assert {:ok, data} =
               Tools.polecat_dispatch(ctx.coordinator, %{"bead_id" => bead.id, "repo" => "test/repo"})

      assert data.bead.status == "in_progress"
      assert data.claude_started == false
      assert data.depth == ctx.coordinator.depth + 1

      on_exit(fn -> Polecat.stop(bead.id, :normal) end)
    end

    # `provider` (and the deprecated `with_claude` alias) take the real-work
    # dispatch path rather than parking. Without a configured repo that path
    # surfaces a repo error — which is exactly the signal that the provider was
    # honored as a worker dispatch (a park would have returned {:ok, ...} with
    # claude_started: false).
    test "provider: \"gemini\" takes the real-work path (not a park)", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "gem dispatch", workspace_id: ctx.ws.id})

      assert {:error, {:invalid, msg}} =
               Tools.polecat_dispatch(ctx.coordinator, %{
                 "bead_id" => bead.id,
                 "provider" => "gemini",
                 "repo" => "test/repo"
               })

      assert msg =~ "repo"

      on_exit(fn -> Polecat.stop(bead.id, :normal) end)
    end

    test "provider: \"claude\" takes the real-work path (not a park)", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "claude dispatch", workspace_id: ctx.ws.id})

      assert {:error, {:invalid, msg}} =
               Tools.polecat_dispatch(ctx.coordinator, %{
                 "bead_id" => bead.id,
                 "provider" => "claude",
                 "repo" => "test/repo"
               })

      assert msg =~ "repo"

      on_exit(fn -> Polecat.stop(bead.id, :normal) end)
    end

    test "the deprecated with_claude: true alias still dispatches a worker", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "alias dispatch", workspace_id: ctx.ws.id})

      assert {:error, {:invalid, msg}} =
               Tools.polecat_dispatch(ctx.coordinator, %{
                 "bead_id" => bead.id,
                 "with_claude" => true,
                 "repo" => "test/repo"
               })

      assert msg =~ "repo"

      on_exit(fn -> Polecat.stop(bead.id, :normal) end)
    end
  end

  describe "polecat_list/2" do
    test "returns an empty list when no polecats are running in the workspace", ctx do
      assert {:ok, %{polecats: [], count: 0}} = Tools.polecat_list(ctx.coordinator, %{})
    end

    test "returns active polecats scoped to the coordinator's workspace", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "polecat-list target", workspace_id: ctx.ws.id})

      {:ok, pid} = Polecat.start(bead_id: bead.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Polecat.stop(bead.id, :normal) end)

      assert {:ok, %{polecats: polecats, count: count}} = Tools.polecat_list(ctx.coordinator, %{})
      assert count >= 1
      assert Enum.any?(polecats, &(&1.bead_id == bead.id))

      entry = Enum.find(polecats, &(&1.bead_id == bead.id))
      assert is_binary(entry.repo)
      assert is_binary(entry.status)
      assert entry.repo == "test/repo"
    end

    test "does not include polecats from another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "pl-other", prefix: "plo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign pc", workspace_id: other_ws.id})

      {:ok, _pid} = Polecat.start(bead_id: foreign.id, repo: "test/repo", workspace_id: other_ws.id)
      on_exit(fn -> Polecat.stop(foreign.id, :normal) end)

      assert {:ok, %{polecats: polecats}} = Tools.polecat_list(ctx.coordinator, %{})
      refute Enum.any?(polecats, &(&1.bead_id == foreign.id))
    end

    test "surfaces the provider/model from the polecat's routing config", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "gemini polecat", workspace_id: ctx.ws.id})

      {:ok, pid} = Polecat.start(bead_id: bead.id, repo: "test/repo", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Polecat.stop(bead.id, :normal) end)

      # Stamp the routing config the way Dispatch does at dispatch time.
      :ok = Polecat.report(pid, :routing_config, %{provider: "gemini", model: "gemini-2.5-pro"})

      assert {:ok, %{polecats: polecats}} = Tools.polecat_list(ctx.coordinator, %{})
      entry = Enum.find(polecats, &(&1.bead_id == bead.id))

      assert entry.provider == "gemini"
      assert entry.model == "gemini-2.5-pro"
    end
  end

  describe "bead_list/2" do
    test "lists all beads in the workspace with no filters", ctx do
      assert {:ok, %{beads: beads, count: count}} = Tools.bead_list(ctx.coordinator, %{})
      assert count >= 1
      assert Enum.any?(beads, &(&1.id == ctx.bead.id))
    end

    test "filters by status", ctx do
      # `:create` does not accept `:status` (and `:open` is the default anyway).
      {:ok, _} = Ash.create(Issue, %{title: "another open bead", workspace_id: ctx.ws.id})

      assert {:ok, %{beads: open_beads}} = Tools.bead_list(ctx.coordinator, %{"status" => "open"})
      assert Enum.all?(open_beads, &(&1.status == "open"))

      assert {:ok, %{beads: closed_beads}} =
               Tools.bead_list(ctx.coordinator, %{"status" => "closed"})

      assert Enum.all?(closed_beads, &(&1.status == "closed"))
    end

    test "filters by issue_type", ctx do
      {:ok, bug} =
        Ash.create(Issue, %{title: "a bug", workspace_id: ctx.ws.id, issue_type: :bug})

      assert {:ok, %{beads: bugs}} =
               Tools.bead_list(ctx.coordinator, %{"issue_type" => "bug"})

      assert Enum.all?(bugs, &(&1.issue_type == "bug"))
      assert Enum.any?(bugs, &(&1.id == bug.id))
    end

    test "filters by priority", ctx do
      {:ok, p0} = Ash.create(Issue, %{title: "urgent", workspace_id: ctx.ws.id, priority: 0})

      assert {:ok, %{beads: p0_beads}} = Tools.bead_list(ctx.coordinator, %{"priority" => 0})
      assert Enum.any?(p0_beads, &(&1.id == p0.id))
    end

    test "does not include beads from another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "bl-other", prefix: "blo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign bead", workspace_id: other_ws.id})

      assert {:ok, %{beads: beads}} = Tools.bead_list(ctx.coordinator, %{})
      refute Enum.any?(beads, &(&1.id == foreign.id))
    end

    test "rejects an invalid status value", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.bead_list(ctx.coordinator, %{"status" => "bogus"})

      assert msg =~ "status"
    end

    test "rejects an invalid issue_type value", ctx do
      assert {:error, {:invalid, msg}} =
               Tools.bead_list(ctx.coordinator, %{"issue_type" => "bogus"})

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

    test "reads a bead in any workspace, inferring the workspace from the entity", ctx do
      assert {:ok, here} = Tools.bead_show(ctx.agnostic, %{"id" => ctx.bead.id})
      assert here.id == ctx.bead.id

      assert {:ok, there} = Tools.bead_show(ctx.agnostic, %{"id" => ctx.foreign.id})
      assert there.id == ctx.foreign.id
      assert there.workspace_id == ctx.other_ws.id
    end

    test "creates a bead in the workspace named by the `workspace` param (by name)", ctx do
      assert {:ok, data} =
               Tools.bead_create(ctx.agnostic, %{
                 "title" => "explicit by name",
                 "workspace" => ctx.other_ws.name
               })

      assert data.workspace_id == ctx.other_ws.id
    end

    test "creates a bead in the workspace named by the `workspace` param (by id)", ctx do
      assert {:ok, data} =
               Tools.bead_create(ctx.agnostic, %{
                 "title" => "explicit by id",
                 "workspace" => ctx.other_ws.id
               })

      assert data.workspace_id == ctx.other_ws.id
    end

    test "an unknown `workspace` ref is a not-found tool error", ctx do
      assert {:error, {:not_found, msg}} =
               Tools.bead_create(ctx.agnostic, %{"title" => "x", "workspace" => "nope-ws"})

      assert msg =~ "workspace"
    end

    test "lists beads in the workspace named by the `workspace` param", ctx do
      assert {:ok, %{beads: beads}} =
               Tools.bead_list(ctx.agnostic, %{"workspace" => ctx.other_ws.name})

      assert Enum.any?(beads, &(&1.id == ctx.foreign.id))
      refute Enum.any?(beads, &(&1.id == ctx.bead.id))
    end

    test "shows the workspace named by the `workspace` param", ctx do
      assert {:ok, data} = Tools.workspace_show(ctx.agnostic, %{"workspace" => ctx.other_ws.id})
      assert data.id == ctx.other_ws.id
      assert data.name == ctx.other_ws.name
    end

    test "directs a message to a bead in any workspace, pinned to that bead's workspace", ctx do
      assert {:ok, _msg} =
               Tools.message_send(ctx.agnostic, %{
                 "bead_id" => ctx.foreign.id,
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
               Tools.bead_create(ctx.agnostic, %{"title" => "ambiguous"})

      assert msg =~ "workspace"
    end
  end

  describe "default workspace resolution" do
    test "a workspace-agnostic coordinator with no `workspace` falls back to the lone workspace",
         ctx do
      # The module setup creates exactly one workspace (ctx.ws) in this sandbox,
      # so it is unambiguously the installation default.
      agnostic = %Scope{tier: :coordinator, workspace_id: nil, can_dispatch: true}

      assert {:ok, data} = Tools.bead_create(agnostic, %{"title" => "lands in the only ws"})
      assert data.workspace_id == ctx.ws.id
    end

    test "a coordinator falls back to the workspace named \"default\" when several exist" do
      {:ok, default} = Ash.create(Workspace, %{name: "default", prefix: "def"})
      {:ok, _other} = Ash.create(Workspace, %{name: "another-ws", prefix: "anow"})
      agnostic = %Scope{tier: :coordinator, workspace_id: nil, can_dispatch: true}

      assert {:ok, data} = Tools.bead_create(agnostic, %{"title" => "to default"})
      assert data.workspace_id == default.id
    end
  end

  describe "workspace-bound scope rejection" do
    test "a bound coordinator naming a different workspace is unauthorized", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "bound-other-ws", prefix: "bow"})

      assert {:error, {:unauthorized, _}} =
               Tools.bead_create(ctx.coordinator, %{"title" => "x", "workspace" => other_ws.id})
    end

    test "a polecat naming a different workspace is unauthorized", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "pc-other-ws", prefix: "pco"})

      assert {:error, {:unauthorized, _}} =
               Tools.bead_show(ctx.polecat, %{"id" => ctx.bead.id, "workspace" => other_ws.id})
    end
  end

  describe "Catalog.call/3 dispatch" do
    test "routes an authorized call to its handler and returns structured data", ctx do
      assert {:ok, data} = Catalog.call(ctx.polecat, "bead_show", %{})
      assert data.id == ctx.bead.id
    end

    test "maps a handler not-found into a tool error (not a JSON-RPC error)", ctx do
      assert {:tool_error, message} =
               Catalog.call(ctx.coordinator, "bead_show", %{"id" => "bd-does-not-exist"})

      assert message =~ "not found"
    end
  end
end
