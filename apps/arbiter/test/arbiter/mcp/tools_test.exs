defmodule Arbiter.MCP.ToolsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Convoy
  alias Arbiter.Beads.ConvoyMembership
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

    polecat = %Scope{tier: :polecat, workspace_id: ws.id, bead_id: bead.id, rig: "shipyard"}
    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_sling: true}

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

  describe "convoy_status/2" do
    setup ctx do
      {:ok, convoy} = Ash.create(Convoy, %{title: "release convoy", workspace_id: ctx.ws.id})

      {:ok, _} =
        Ash.create(ConvoyMembership, %{convoy_id: convoy.id, issue_id: ctx.bead.id}, action: :add)

      {:ok, convoy: convoy}
    end

    test "a coordinator sees member counts", ctx do
      assert {:ok, data} = Tools.convoy_status(ctx.coordinator, %{"id" => ctx.convoy.id})
      assert data.id == ctx.convoy.id
      assert data.total_issues == 1
      assert data.closed_issues == 0
      assert data.open_issues == 1
    end

    test "a polecat sees a convoy it belongs to", ctx do
      assert {:ok, data} = Tools.convoy_status(ctx.polecat, %{"id" => ctx.convoy.id})
      assert data.id == ctx.convoy.id
    end

    test "a polecat may not query a convoy it is not a member of", ctx do
      {:ok, other_bead} = Ash.create(Issue, %{title: "outsider", workspace_id: ctx.ws.id})
      outsider = %{ctx.polecat | bead_id: other_bead.id}

      assert {:error, {:unauthorized, _}} =
               Tools.convoy_status(outsider, %{"id" => ctx.convoy.id})
    end

    test "requires a convoy id", ctx do
      assert {:error, {:invalid, _}} = Tools.convoy_status(ctx.coordinator, %{})
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

  describe "convoy_create/2 + convoy_add_member/2 + convoy_close/2 + convoy_list/2" do
    test "create, attach a member, list, and close a convoy", ctx do
      assert {:ok, convoy} =
               Tools.convoy_create(ctx.coordinator, %{
                 "title" => "release",
                 "lifecycle" => "owned"
               })

      assert convoy.title == "release"
      assert convoy.lifecycle == "owned"
      assert convoy.total_issues == 0

      assert {:ok, with_member} =
               Tools.convoy_add_member(ctx.coordinator, %{
                 "id" => convoy.id,
                 "issue_id" => ctx.bead.id
               })

      assert with_member.total_issues == 1

      assert {:ok, %{convoys: convoys}} = Tools.convoy_list(ctx.coordinator, %{})
      assert Enum.any?(convoys, &(&1.id == convoy.id))

      assert {:ok, closed} = Tools.convoy_close(ctx.coordinator, %{"id" => convoy.id})
      assert closed.status == "closed"
    end

    test "convoy_list does not leak convoys from another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "cv-other", prefix: "cvo"})
      {:ok, _foreign} = Ash.create(Convoy, %{title: "foreign cv", workspace_id: other_ws.id})

      assert {:ok, %{convoys: convoys}} = Tools.convoy_list(ctx.coordinator, %{})
      refute Enum.any?(convoys, &(&1.title == "foreign cv"))
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

  describe "polecat_resume/2 + polecat_review/2 (sling-recursion guardrail, §4.3)" do
    test "resume refuses a coordinator scope without can_sling", ctx do
      no_sling = %{ctx.coordinator | can_sling: false}

      assert {:error, {:unauthorized, _}} =
               Tools.polecat_resume(no_sling, %{"bead_id" => ctx.bead.id})
    end

    test "review refuses a coordinator scope without can_sling", ctx do
      no_sling = %{ctx.coordinator | can_sling: false}

      assert {:error, {:unauthorized, _}} =
               Tools.polecat_review(no_sling, %{"bead_id" => ctx.bead.id})
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

    test "resume surfaces the no-outpost error for a bead never slung", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "never slung", workspace_id: ctx.ws.id})

      # can_sling + in-workspace + below depth, but no preserved worktree exists.
      assert {:error, {:invalid, msg}} =
               Tools.polecat_resume(ctx.coordinator, %{"bead_id" => bead.id, "rig" => "test/rig"})

      assert msg =~ "outpost" or msg =~ "rig"
    end
  end

  describe "polecat_stop/2" do
    test "stops a running polecat in the workspace", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "stop target", workspace_id: ctx.ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "test/rig", workspace_id: ctx.ws.id)
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

      {:ok, pid} = Polecat.start(bead_id: foreign.id, rig: "test/rig", workspace_id: other_ws.id)
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

  describe "polecat_sling/2 (sling-recursion guardrail, §4.3)" do
    test "refuses a coordinator scope without can_sling", ctx do
      no_sling = %{ctx.coordinator | can_sling: false}

      assert {:error, {:unauthorized, _}} =
               Tools.polecat_sling(no_sling, %{"bead_id" => ctx.bead.id})
    end

    test "refuses once the depth limit is reached", ctx do
      at_limit = %{ctx.coordinator | depth: MCP.max_depth()}

      assert {:error, {:unauthorized, msg}} =
               Tools.polecat_sling(at_limit, %{"bead_id" => ctx.bead.id})

      assert msg =~ "depth"
    end

    test "cannot sling a bead in another workspace (not-found)", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "sl-other", prefix: "slo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.polecat_sling(ctx.coordinator, %{"bead_id" => foreign.id})
    end

    test "parks the bead in_progress and reports the child depth", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "to sling", workspace_id: ctx.ws.id})

      assert {:ok, data} =
               Tools.polecat_sling(ctx.coordinator, %{"bead_id" => bead.id, "rig" => "test/rig"})

      assert data.bead.status == "in_progress"
      assert data.claude_started == false
      assert data.depth == ctx.coordinator.depth + 1

      on_exit(fn -> Polecat.stop(bead.id, :normal) end)
    end
  end

  describe "polecat_list/2" do
    test "returns an empty list when no polecats are running in the workspace", ctx do
      assert {:ok, %{polecats: [], count: 0}} = Tools.polecat_list(ctx.coordinator, %{})
    end

    test "returns active polecats scoped to the coordinator's workspace", ctx do
      {:ok, bead} = Ash.create(Issue, %{title: "polecat-list target", workspace_id: ctx.ws.id})

      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "test/rig", workspace_id: ctx.ws.id)
      on_exit(fn -> Process.alive?(pid) && Polecat.stop(bead.id, :normal) end)

      assert {:ok, %{polecats: polecats, count: count}} = Tools.polecat_list(ctx.coordinator, %{})
      assert count >= 1
      assert Enum.any?(polecats, &(&1.bead_id == bead.id))

      entry = Enum.find(polecats, &(&1.bead_id == bead.id))
      assert is_binary(entry.rig)
      assert is_binary(entry.status)
      assert entry.rig == "test/rig"
    end

    test "does not include polecats from another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "pl-other", prefix: "plo"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign pc", workspace_id: other_ws.id})

      {:ok, _pid} = Polecat.start(bead_id: foreign.id, rig: "test/rig", workspace_id: other_ws.id)
      on_exit(fn -> Polecat.stop(foreign.id, :normal) end)

      assert {:ok, %{polecats: polecats}} = Tools.polecat_list(ctx.coordinator, %{})
      refute Enum.any?(polecats, &(&1.bead_id == foreign.id))
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
