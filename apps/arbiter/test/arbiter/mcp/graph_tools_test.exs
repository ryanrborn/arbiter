defmodule Arbiter.MCP.GraphToolsTest do
  # async: false — graph_start spawns a Conductor GenServer that reads the DB;
  # the sandbox must be shared so that process can see test data.
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Graph
  alias Arbiter.Tasks.GraphMember
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.ConductorSupervisor

  # A no-op dispatcher so graph_start tests don't try to spawn real workers.
  defmodule NoopDispatcher do
    def dispatch(task_id, _opts), do: {:ok, %{task_id: task_id}}
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "graph-tools-ws-#{System.unique_integer([:positive])}",
        prefix: "gtt#{System.unique_integer([:positive])}"
      })

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id}

    # Use the noop dispatcher so the Conductor doesn't try to spawn real workers.
    Application.put_env(:arbiter, :conductor_dispatcher, NoopDispatcher)

    on_exit(fn -> Application.delete_env(:arbiter, :conductor_dispatcher) end)

    {:ok, ws: ws, coordinator: coordinator}
  end

  defp issue(ws, title \\ nil) do
    title = title || "issue-#{System.unique_integer([:positive])}"
    {:ok, i} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    i
  end

  defp graph(ws, name \\ nil) do
    name = name || "graph-#{System.unique_integer([:positive])}"
    {:ok, g} = Ash.create(Graph, %{name: name, workspace_id: ws.id})
    g
  end

  defp add_member(g, i) do
    {:ok, _} = Ash.create(GraphMember, %{graph_id: g.id, issue_id: i.id})
    :ok
  end

  defp dep(from, to, type) do
    {:ok, _} = Ash.create(Dependency, %{from_issue_id: from.id, to_issue_id: to.id, type: type})
    :ok
  end

  defp stop_conductor(graph_id) do
    ConductorSupervisor.stop_conductor(graph_id)
    # Allow DynamicSupervisor to process the termination before the next step.
    Process.sleep(20)
  end

  # ---- graph_create -------------------------------------------------------

  describe "graph_create/2" do
    test "creates a graph in the coordinator's workspace", ctx do
      assert {:ok, data} = Tools.graph_create(ctx.coordinator, %{"name" => "release-1.0"})
      assert data.name == "release-1.0"
      assert data.run_state == "draft"
      assert data.workspace_id == ctx.ws.id
      assert is_binary(data.id)
    end

    test "accepts an optional description", ctx do
      assert {:ok, data} =
               Tools.graph_create(ctx.coordinator, %{
                 "name" => "sprint",
                 "description" => "Q2 sprint"
               })

      assert data.description == "Q2 sprint"
    end

    test "rejects a missing name", ctx do
      assert {:error, {:invalid, _}} = Tools.graph_create(ctx.coordinator, %{})
    end

    test "coordinator-scoped: workspace-agnostic coordinator uses the default workspace", _ctx do
      {:ok, ws2} = Ash.create(Workspace, %{name: "solo-ws", prefix: "slw"})
      # With a single-workspace install we can't easily test default resolution,
      # but we verify a bound coordinator targets its own workspace.
      bound = %Scope{tier: :coordinator, workspace_id: ws2.id}
      assert {:ok, data} = Tools.graph_create(bound, %{"name" => "bounded"})
      assert data.workspace_id == ws2.id
    end
  end

  # ---- graph_add_directive ------------------------------------------------

  describe "graph_add_directive/2" do
    test "adds a directive to a graph", ctx do
      g = graph(ctx.ws)
      i = issue(ctx.ws)

      assert {:ok, data} =
               Tools.graph_add_directive(ctx.coordinator, %{
                 "graph_id" => g.id,
                 "issue_id" => i.id
               })

      assert data.graph_id == g.id
      assert data.issue_id == i.id
      assert is_binary(data.member_id)

      # Verify DB row exists.
      loaded = Ash.load!(g, :members)
      assert Enum.any?(loaded.members, &(&1.issue_id == i.id))
    end

    test "rejects a non-existent issue_id", ctx do
      g = graph(ctx.ws)

      assert {:error, {:not_found, _}} =
               Tools.graph_add_directive(ctx.coordinator, %{
                 "graph_id" => g.id,
                 "issue_id" => "gtt-000000"
               })
    end

    test "rejects an issue from a different workspace", ctx do
      g = graph(ctx.ws)
      {:ok, other_ws} = Ash.create(Workspace, %{name: "other-ws", prefix: "oth"})
      foreign = issue(other_ws, "foreign task")

      assert {:error, {:not_found, _}} =
               Tools.graph_add_directive(ctx.coordinator, %{
                 "graph_id" => g.id,
                 "issue_id" => foreign.id
               })
    end

    test "rejects a non-existent graph_id", ctx do
      i = issue(ctx.ws)

      assert {:error, {:not_found, _}} =
               Tools.graph_add_directive(ctx.coordinator, %{
                 "graph_id" => Ash.UUIDv7.generate(),
                 "issue_id" => i.id
               })
    end

    test "duplicate membership is rejected", ctx do
      g = graph(ctx.ws)
      i = issue(ctx.ws)
      add_member(g, i)

      assert {:error, {:invalid, _}} =
               Tools.graph_add_directive(ctx.coordinator, %{
                 "graph_id" => g.id,
                 "issue_id" => i.id
               })
    end
  end

  # ---- graph_remove_directive ---------------------------------------------

  describe "graph_remove_directive/2" do
    test "removes a directive from a graph", ctx do
      g = graph(ctx.ws)
      i = issue(ctx.ws)
      add_member(g, i)

      assert {:ok, data} =
               Tools.graph_remove_directive(ctx.coordinator, %{
                 "graph_id" => g.id,
                 "issue_id" => i.id
               })

      assert data.removed == 1

      loaded = Ash.load!(g, :members)
      assert loaded.members == []
    end

    test "idempotent when directive is not a member (removed: 0)", ctx do
      g = graph(ctx.ws)
      i = issue(ctx.ws)

      assert {:ok, %{removed: 0}} =
               Tools.graph_remove_directive(ctx.coordinator, %{
                 "graph_id" => g.id,
                 "issue_id" => i.id
               })
    end

    test "rejects a non-existent graph_id", ctx do
      i = issue(ctx.ws)

      assert {:error, {:not_found, _}} =
               Tools.graph_remove_directive(ctx.coordinator, %{
                 "graph_id" => Ash.UUIDv7.generate(),
                 "issue_id" => i.id
               })
    end
  end

  # ---- graph_add_edge -----------------------------------------------------

  describe "graph_add_edge/2" do
    test "adds a depends_on edge", ctx do
      g = graph(ctx.ws)
      a = issue(ctx.ws, "task-a")
      b = issue(ctx.ws, "task-b")

      assert {:ok, dep} =
               Tools.graph_add_edge(ctx.coordinator, %{
                 "graph_id" => g.id,
                 "from_issue_id" => a.id,
                 "to_issue_id" => b.id,
                 "type" => "depends_on"
               })

      assert dep.type == "depends_on"
      assert dep.from_issue_id == a.id
      assert dep.to_issue_id == b.id
    end

    test "adds a blocks edge", ctx do
      g = graph(ctx.ws)
      a = issue(ctx.ws, "blocker")
      b = issue(ctx.ws, "blocked")

      assert {:ok, dep} =
               Tools.graph_add_edge(ctx.coordinator, %{
                 "graph_id" => g.id,
                 "from_issue_id" => a.id,
                 "to_issue_id" => b.id,
                 "type" => "blocks"
               })

      assert dep.type == "blocks"
    end

    test "adds a conflicts_with edge", ctx do
      g = graph(ctx.ws)
      a = issue(ctx.ws, "mutex-a")
      b = issue(ctx.ws, "mutex-b")

      assert {:ok, dep} =
               Tools.graph_add_edge(ctx.coordinator, %{
                 "graph_id" => g.id,
                 "from_issue_id" => a.id,
                 "to_issue_id" => b.id,
                 "type" => "conflicts_with"
               })

      assert dep.type == "conflicts_with"
    end

    test "rejects an invalid edge type", ctx do
      g = graph(ctx.ws)
      a = issue(ctx.ws)
      b = issue(ctx.ws)

      assert {:error, {:invalid, msg}} =
               Tools.graph_add_edge(ctx.coordinator, %{
                 "graph_id" => g.id,
                 "from_issue_id" => a.id,
                 "to_issue_id" => b.id,
                 "type" => "parent_of"
               })

      assert msg =~ "type"
    end

    test "rejects a self-loop", ctx do
      g = graph(ctx.ws)
      a = issue(ctx.ws)

      assert {:error, {:invalid, _}} =
               Tools.graph_add_edge(ctx.coordinator, %{
                 "graph_id" => g.id,
                 "from_issue_id" => a.id,
                 "to_issue_id" => a.id,
                 "type" => "depends_on"
               })
    end
  end

  # ---- graph_start --------------------------------------------------------

  describe "graph_start/2" do
    test "starts a graph (happy path, no members → no dispatch needed)", ctx do
      g = graph(ctx.ws)
      on_exit(fn -> stop_conductor(g.id) end)

      assert {:ok, data} =
               Tools.graph_start(ctx.coordinator, %{"graph_id" => g.id})

      assert data.run_state == "running"
      assert data.id == g.id

      # Verify Conductor was started.
      assert is_pid(ConductorSupervisor.whereis(g.id))
    end

    test "rejects a non-existent graph_id", ctx do
      assert {:error, {:not_found, _}} =
               Tools.graph_start(ctx.coordinator, %{"graph_id" => Ash.UUIDv7.generate()})
    end

    test "rejects a graph not in :draft state", ctx do
      g = graph(ctx.ws)
      {:ok, _} = Ash.update(g, %{run_state: :running})
      on_exit(fn -> stop_conductor(g.id) end)

      assert {:error, {:invalid, msg}} =
               Tools.graph_start(ctx.coordinator, %{"graph_id" => g.id})

      assert msg =~ "not in draft state"
    end

    test "rejects a cyclic graph and names the offending cycle", ctx do
      g = graph(ctx.ws)
      a = issue(ctx.ws, "cycle-a")
      b = issue(ctx.ws, "cycle-b")
      add_member(g, a)
      add_member(g, b)
      # a depends_on b AND b depends_on a → cycle
      dep(a, b, :depends_on)
      dep(b, a, :depends_on)

      assert {:error, {:invalid, msg}} =
               Tools.graph_start(ctx.coordinator, %{"graph_id" => g.id})

      assert msg =~ "cycle"
      assert msg =~ a.id
      assert msg =~ b.id
      # Graph must still be in :draft after rejection.
      {:ok, refreshed} = Ash.get(Graph, g.id)
      assert refreshed.run_state == :draft
    end
  end

  # ---- graph_pause --------------------------------------------------------

  describe "graph_pause/2" do
    test "pauses a running graph and stops the conductor", ctx do
      g = graph(ctx.ws)
      {:ok, _pid} = Arbiter.Workflows.Conductor.kickoff(g.id)
      on_exit(fn -> stop_conductor(g.id) end)

      assert {:ok, data} = Tools.graph_pause(ctx.coordinator, %{"graph_id" => g.id})

      assert data.run_state == "paused"
      # Conductor should have been stopped.
      Process.sleep(30)
      assert is_nil(ConductorSupervisor.whereis(g.id))
    end

    test "rejects pause when graph is not running", ctx do
      g = graph(ctx.ws)
      # graph is in :draft, not :running

      assert {:error, {:invalid, msg}} =
               Tools.graph_pause(ctx.coordinator, %{"graph_id" => g.id})

      assert msg =~ "not running"
    end
  end

  # ---- graph_resume -------------------------------------------------------

  describe "graph_resume/2" do
    test "resumes a paused graph and starts a new conductor", ctx do
      g = graph(ctx.ws)
      {:ok, _pid} = Arbiter.Workflows.Conductor.kickoff(g.id)
      {:ok, _} = Ash.update(Ash.get!(Graph, g.id), %{run_state: :paused})
      stop_conductor(g.id)

      assert {:ok, data} = Tools.graph_resume(ctx.coordinator, %{"graph_id" => g.id})

      assert data.run_state == "running"
      on_exit(fn -> stop_conductor(g.id) end)
      # New conductor should be running.
      Process.sleep(30)
      assert is_pid(ConductorSupervisor.whereis(g.id))
    end

    test "rejects resume when graph is not paused", ctx do
      g = graph(ctx.ws)

      assert {:error, {:invalid, msg}} =
               Tools.graph_resume(ctx.coordinator, %{"graph_id" => g.id})

      assert msg =~ "not paused"
    end
  end

  # ---- graph_status -------------------------------------------------------

  describe "graph_status/2" do
    test "returns breakdown for a draft graph with members", ctx do
      g = graph(ctx.ws)
      a = issue(ctx.ws, "task-a")
      b = issue(ctx.ws, "task-b")
      add_member(g, a)
      add_member(g, b)
      # b blocks a → a is blocked, b is ready
      dep(b, a, :blocks)

      assert {:ok, status} = Tools.graph_status(ctx.coordinator, %{"graph_id" => g.id})

      assert status.run_state == "draft"
      assert status.total == 2
      # b is ready, a is blocked
      assert status.ready == 1
      assert status.blocked == 1
      assert status.running == 0
      assert status.closed == 0
      assert status.paused == 0
      assert status.failed == 0
    end

    test "counts in_progress directives as running", ctx do
      g = graph(ctx.ws)
      a = issue(ctx.ws, "in-progress-task")
      add_member(g, a)
      {:ok, _} = Ash.update(Ash.get!(Issue, a.id), %{status: :in_progress})

      assert {:ok, status} = Tools.graph_status(ctx.coordinator, %{"graph_id" => g.id})

      assert status.running == 1
      assert status.ready == 0
    end

    test "returns zero counts for an empty graph", ctx do
      g = graph(ctx.ws)

      assert {:ok, status} = Tools.graph_status(ctx.coordinator, %{"graph_id" => g.id})

      assert status.total == 0
      assert status.ready == 0
      assert status.running == 0
      assert status.closed == 0
    end

    test "rejects a non-existent graph_id", ctx do
      assert {:error, {:not_found, _}} =
               Tools.graph_status(ctx.coordinator, %{"graph_id" => Ash.UUIDv7.generate()})
    end

    test "returns a status payload (not a crash) when the Conductor doesn't answer :state in time",
         ctx do
      g = graph(ctx.ws)
      a = issue(ctx.ws, "task-a")
      add_member(g, a)

      # Register a stub "Conductor" that never replies to any call — this
      # reproduces the bug report's timing window, where the real Conductor
      # is mid-dispatch and can't service a :state call within the timeout.
      test_pid = self()

      {:ok, stub_pid} =
        Task.start(fn ->
          Registry.register(Arbiter.Workflows.ConductorRegistry, g.id, nil)
          send(test_pid, :registered)

          receive do
          end
        end)

      assert_receive :registered, 1_000

      assert {:ok, status} = Tools.graph_status(ctx.coordinator, %{"graph_id" => g.id})
      assert status.failed == 0
      assert status.paused == 0

      Process.exit(stub_pid, :kill)
    end
  end

  # ---- workspace isolation ------------------------------------------------

  describe "workspace isolation" do
    test "coordinator cannot access a graph from another workspace", ctx do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "other-ws2", prefix: "ow2"})
      {:ok, foreign_graph} = Ash.create(Graph, %{name: "foreign", workspace_id: other_ws.id})

      assert {:error, {:not_found, _}} =
               Tools.graph_status(ctx.coordinator, %{"graph_id" => foreign_graph.id})
    end
  end

  # ---- catalog registration -----------------------------------------------

  describe "catalog registration" do
    alias Arbiter.MCP.Catalog

    test "all 8 graph tools are registered as coordinator-only" do
      graph_tools = ~w(graph_create graph_add_directive graph_remove_directive graph_add_edge
                       graph_start graph_pause graph_resume graph_status)

      for name <- graph_tools do
        assert {:ok, tool} = Catalog.fetch(name),
               "expected #{name} to be registered in the catalog"

        assert :coordinator in tool.tiers,
               "expected #{name} to be coordinator-only"

        refute :worker in tool.tiers,
               "expected #{name} to not be available to workers"
      end
    end
  end
end
