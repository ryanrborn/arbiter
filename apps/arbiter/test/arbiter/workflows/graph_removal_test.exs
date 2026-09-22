defmodule Arbiter.Workflows.GraphRemovalTest do
  # bd-a14qd1: Graphs and the Conductor are gone — the board scheduler
  # (Autopilot) is the only dispatcher. These are the load-bearing invariants
  # of that removal: if any of them regress, a second dispatcher is back.
  use ExUnit.Case, async: true

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope

  @coordinator %Scope{tier: :coordinator, workspace_id: "w"}

  @removed_modules [
    Arbiter.Workflows.Conductor,
    Arbiter.Workflows.ConductorSupervisor,
    Arbiter.Workflows.ConductorReconciler,
    Arbiter.Workflows.QuotaGate,
    Arbiter.Workflows.QuotaGate.Default,
    Arbiter.Tasks.Graph,
    Arbiter.Tasks.GraphMember
  ]

  @removed_tools ~w(graph_create graph_add_directive graph_remove_directive graph_add_edge
                    graph_start graph_pause graph_resume graph_status queue_resume)

  describe "modules" do
    test "no Conductor, Graph, GraphMember or QuotaGate module is compiled" do
      for mod <- @removed_modules do
        refute Code.ensure_loaded?(mod), "#{inspect(mod)} should have been removed"
      end
    end

    test "the ConductorRegistry is not in the supervision tree" do
      refute Process.whereis(Arbiter.Workflows.ConductorRegistry)
    end

    test "the Tasks domain no longer exposes Graph resources" do
      names = Enum.map(Ash.Domain.Info.resources(Arbiter.Tasks), &inspect/1)
      refute Enum.any?(names, &String.contains?(&1, "Graph"))
    end
  end

  describe "MCP catalog" do
    test "every graph_* tool and queue_resume is gone" do
      names = Enum.map(Catalog.all(), & &1.name)

      for tool <- @removed_tools do
        refute tool in names, "#{tool} should have been removed from the catalog"
      end
    end

    test "calling a removed tool is an unknown-tool error" do
      for tool <- @removed_tools do
        assert {:rpc_error, -32_602, message} = Catalog.call(@coordinator, tool, %{})
        assert message =~ "Unknown tool"
      end
    end

    test "no surviving tool description mentions the Conductor or graph dispatch" do
      for tool <- Catalog.all() do
        refute tool.description =~ "Conductor",
               "#{tool.name}'s description still mentions the Conductor"

        refute tool.description =~ "graph-driven",
               "#{tool.name}'s description still mentions graph-driven dispatch"
      end
    end

    test "dep_add credits the board scheduler with enforcing conflicts_with" do
      %{description: description} =
        @coordinator |> Catalog.visible() |> Enum.find(&(&1.name == "dep_add"))

      assert description =~ "board scheduler"
      assert description =~ "conflicts_with"
    end
  end

  describe "settings and workspace config" do
    # The names stay (a column + a workspace-config key), but they belong to
    # the board scheduler's slot gate now, not the Conductor.
    test "conductor_system_max_concurrent still round-trips" do
      assert is_function(&Arbiter.Settings.conductor_system_max_concurrent/0, 0)
      assert is_function(&Arbiter.Settings.set_conductor_system_max_concurrent/1, 1)
    end

    test "the installation setting's description no longer says Conductor" do
      attr =
        Ash.Resource.Info.attribute(
          Arbiter.Settings.Installation,
          :conductor_system_max_concurrent
        )

      refute attr.description =~ "Conductor"
    end
  end
end
