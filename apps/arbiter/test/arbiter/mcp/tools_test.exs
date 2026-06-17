defmodule Arbiter.MCP.ToolsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Convoy
  alias Arbiter.Beads.ConvoyMembership
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Messages.Message

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
