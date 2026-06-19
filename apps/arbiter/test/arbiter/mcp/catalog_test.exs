defmodule Arbiter.MCP.CatalogTest do
  use ExUnit.Case, async: true

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope

  @polecat %Scope{tier: :polecat, workspace_id: "w", bead_id: "bd-1"}
  @coordinator %Scope{tier: :coordinator, workspace_id: "w"}

  # The both-tier tools a polecat may also reach.
  @both_tier ~w(bead_show inbox_check bead_update_progress workspace_show
                message_send notify_list)

  # Coordinator-only tools; never visible to a polecat.
  @coordinator_only ~w(bead_ready bead_create bead_update bead_close bead_reopen dep_add dep_remove
                       polecat_sling
                       polecat_resume polecat_review polecat_stop polecat_list bead_list
                       tracker_claim tracker_sync workspace_list usage_summarize coordinator_inbox)

  describe "visible/1" do
    test "the polecat tier sees the both-tier tools but no coordinator-only tool" do
      names = @polecat |> Catalog.visible() |> Enum.map(& &1.name)

      for tool <- @both_tier, do: assert(tool in names)
      for tool <- @coordinator_only, do: refute(tool in names)
    end

    test "the coordinator tier sees every tool, including the coordinator-only tools" do
      names = @coordinator |> Catalog.visible() |> Enum.map(& &1.name)

      for tool <- @both_tier, do: assert(tool in names)
      for tool <- @coordinator_only, do: assert(tool in names)

      assert length(names) == length(Catalog.all())
    end

    test "every tool declares an object input schema" do
      for tool <- Catalog.all() do
        assert tool.input_schema["type"] == "object"
        assert is_map(tool.input_schema["properties"])
      end
    end

    test "workspace-resolving tools advertise an optional `workspace` param" do
      for tool <- Catalog.all(), tool.name != "workspace_list" do
        props = tool.input_schema["properties"]
        assert is_map(props["workspace"]), "#{tool.name} is missing the `workspace` param"
        assert props["workspace"]["type"] == "string"
        # `workspace` is never required — every workspace resolution has a default.
        refute "workspace" in (tool.input_schema["required"] || [])
      end
    end

    test "workspace_list does not take a `workspace` param (it enumerates all)" do
      tool = Enum.find(Catalog.all(), &(&1.name == "workspace_list"))
      refute Map.has_key?(tool.input_schema["properties"], "workspace")
    end

    test "polecat_sling exposes a provider enum field and keeps the with_claude alias" do
      tool = Enum.find(Catalog.all(), &(&1.name == "polecat_sling"))
      props = tool.input_schema["properties"]

      assert props["provider"]["enum"] == ["claude", "gemini"]
      # The deprecated boolean alias is still advertised so existing callers work.
      assert props["with_claude"]["type"] == "boolean"
    end
  end

  describe "call/3 capability gating" do
    test "an unknown tool is a JSON-RPC invalid-params error" do
      assert {:rpc_error, -32_602, message} = Catalog.call(@coordinator, "nope", %{})
      assert message =~ "Unknown tool"
    end

    test "a polecat calling a coordinator-only tool is a JSON-RPC not-permitted error" do
      assert {:rpc_error, -32_003, message} = Catalog.call(@polecat, "bead_ready", %{})
      assert message =~ "not permitted"
    end
  end
end
