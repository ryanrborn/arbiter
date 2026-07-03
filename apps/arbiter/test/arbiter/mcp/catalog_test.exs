defmodule Arbiter.MCP.CatalogTest do
  use ExUnit.Case, async: true

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope

  @worker %Scope{tier: :worker, workspace_id: "w", task_id: "bd-1"}
  @coordinator %Scope{tier: :coordinator, workspace_id: "w"}

  # The both-tier tools a worker may also reach.
  @both_tier ~w(task_show inbox_check task_update_progress workspace_show quota_get
                message_send notify_list workspace_config_get workspace_config_overview)

  # Coordinator-only tools; never visible to a worker.
  @coordinator_only ~w(task_ready task_create task_update task_close task_reopen
                       task_sync_upstream_close dep_add dep_remove
                       worker_dispatch
                       worker_resume worker_review worker_stop worker_list worker_show worker_runs
                       worker_log task_list
                       tracker_claim tracker_sync workspace_list usage_summarize coordinator_inbox
                       workspace_config_set workspace_config_unset)

  # Tools that call resolve_workspace_id and thus expose the optional `workspace` param.
  @workspace_resolving_tools ~w(task_ready coordinator_inbox workspace_show quota_get task_create
                                worker_list task_list usage_summarize notify_list tracker_claim tracker_sync
                                worker_review graph_create workspace_config_get workspace_config_overview
                                workspace_config_set workspace_config_unset)

  describe "visible/1" do
    test "the worker tier sees the both-tier tools but no coordinator-only tool" do
      names = @worker |> Catalog.visible() |> Enum.map(& &1.name)

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
      for tool <- Catalog.all() do
        props = tool.input_schema["properties"]

        if tool.name in @workspace_resolving_tools do
          assert is_map(props["workspace"]), "#{tool.name} should have a `workspace` param"
          assert props["workspace"]["type"] == "string"
          # `workspace` is never required — every workspace resolution has a default.
          refute "workspace" in (tool.input_schema["required"] || [])
        else
          refute Map.has_key?(props, "workspace"),
                 "#{tool.name} should not have a `workspace` param"
        end
      end
    end

    test "worker_dispatch exposes a provider enum field and keeps the with_claude alias" do
      tool = Enum.find(Catalog.all(), &(&1.name == "worker_dispatch"))
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

    test "a worker calling a coordinator-only tool is a JSON-RPC not-permitted error" do
      assert {:rpc_error, -32_003, message} = Catalog.call(@worker, "task_ready", %{})
      assert message =~ "not permitted"
    end
  end
end
