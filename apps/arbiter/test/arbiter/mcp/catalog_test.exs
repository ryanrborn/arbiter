defmodule Arbiter.MCP.CatalogTest do
  use ExUnit.Case, async: true

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope

  @polecat %Scope{tier: :polecat, workspace_id: "w", bead_id: "bd-1"}
  @coordinator %Scope{tier: :coordinator, workspace_id: "w"}

  describe "visible/1" do
    test "the polecat tier cannot see coordinator-only tools" do
      names = @polecat |> Catalog.visible() |> Enum.map(& &1.name)

      assert "bead_show" in names
      assert "inbox_check" in names
      assert "bead_update_progress" in names
      assert "workspace_show" in names
      assert "convoy_status" in names
      refute "bead_ready" in names

      # Phase 2 mutating tools are coordinator-only; never visible to a polecat.
      for tool <- ~w(bead_create bead_update bead_close dep_add dep_remove convoy_create
                     convoy_add_member convoy_close convoy_list polecat_sling polecat_message
                     usage_summarize) do
        refute tool in names
      end
    end

    test "the coordinator tier sees every tool, including the Phase 2 mutating tools" do
      names = @coordinator |> Catalog.visible() |> Enum.map(& &1.name)
      assert "bead_ready" in names

      for tool <- ~w(bead_create bead_update bead_close dep_add dep_remove convoy_create
                     convoy_add_member convoy_close convoy_list polecat_sling polecat_message
                     usage_summarize) do
        assert tool in names
      end

      assert length(names) == length(Catalog.all())
    end

    test "every tool declares an object input schema" do
      for tool <- Catalog.all() do
        assert tool.input_schema["type"] == "object"
        assert is_map(tool.input_schema["properties"])
      end
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
