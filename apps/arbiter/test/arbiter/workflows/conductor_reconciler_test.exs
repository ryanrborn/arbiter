defmodule Arbiter.Workflows.ConductorReconcilerTest do
  # async: false — shares global PubSub topic and drives GenServers against a
  # sandboxed but non-async DB connection.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Graph
  alias Arbiter.Tasks.GraphMember
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.Conductor
  alias Arbiter.Workflows.ConductorReconciler
  alias Arbiter.Workflows.ConductorSupervisor

  defmodule RecordingDispatcher do
    def dispatch(task_id, opts) do
      if pid = Application.get_env(:arbiter, :test_conductor_reconciler_pid),
        do: send(pid, {:dispatched, task_id, opts})

      {:ok, %{task_id: task_id}}
    end
  end

  setup do
    Application.put_env(:arbiter, :test_conductor_reconciler_pid, self())

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "cr-ws-#{System.unique_integer([:positive])}",
        prefix: "cr#{System.unique_integer([:positive])}"
      })

    on_exit(fn ->
      Application.delete_env(:arbiter, :test_conductor_reconciler_pid)
    end)

    %{ws: ws}
  end

  defp issue(ws) do
    {:ok, i} = Ash.create(Issue, %{title: "i-#{System.unique_integer([:positive])}", workspace_id: ws.id})
    i
  end

  defp graph(ws) do
    {:ok, g} =
      Ash.create(Graph, %{name: "g-#{System.unique_integer([:positive])}", workspace_id: ws.id})

    g
  end

  defp add_member(graph, issue) do
    {:ok, _} = Ash.create(GraphMember, %{graph_id: graph.id, issue_id: issue.id})
    :ok
  end

  defp kickoff(graph, opts \\ []) do
    opts = Keyword.put_new(opts, :dispatcher, RecordingDispatcher)
    {:ok, pid} = Conductor.kickoff(graph.id, opts)
    on_exit(fn -> ConductorSupervisor.stop_conductor(graph.id) end)
    pid
  end

  # ---- skip when not primary -----------------------------------------------

  describe "reconcile_running_graphs/1 with primary?: false" do
    test "skips sweep without touching any process", %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)
      # Transition to :running without starting a Conductor.
      {:ok, _} = Ash.update(g, %{run_state: :running})

      assert {:ok, :skipped} =
               ConductorReconciler.reconcile_running_graphs(primary?: false)

      # No Conductor was started.
      assert ConductorSupervisor.whereis(g.id) == nil
      refute_receive {:dispatched, _, _}, 50
    end
  end

  # ---- happy path ----------------------------------------------------------

  describe "reconcile_running_graphs/1 with primary?: true" do
    test "returns {:ok, 0} when no graphs are running", %{} do
      assert {:ok, 0} = ConductorReconciler.reconcile_running_graphs(primary?: true)
    end

    test "starts a Conductor for a running graph and resumes the drain", %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      # Manually put the graph into :running without starting a Conductor.
      {:ok, _} = Ash.update(g, %{run_state: :running})

      assert {:ok, 1} =
               ConductorReconciler.reconcile_running_graphs(
                 primary?: true,
                 dispatcher: RecordingDispatcher
               )

      # A Conductor is now running for the graph.
      assert ConductorSupervisor.whereis(g.id) != nil

      # The initial drain dispatches the ready task.
      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id

      on_exit(fn -> ConductorSupervisor.stop_conductor(g.id) end)
    end

    test "skips graphs that already have a running Conductor", %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      pid = kickoff(g)
      assert_receive {:dispatched, _, _}

      # A Conductor is already live. reconcile should skip it.
      assert {:ok, 0} =
               ConductorReconciler.reconcile_running_graphs(
                 primary?: true,
                 dispatcher: RecordingDispatcher
               )

      # Still the same pid.
      assert ConductorSupervisor.whereis(g.id) == pid
    end

    test "does not start Conductors for :draft or :drained graphs", %{ws: ws} do
      draft_g = graph(ws)
      # draft is the default run_state — no change needed

      drained_g = graph(ws)
      {:ok, running} = Ash.update(drained_g, %{run_state: :running})
      {:ok, _} = Ash.update(running, %{run_state: :drained})

      assert {:ok, 0} =
               ConductorReconciler.reconcile_running_graphs(
                 primary?: true,
                 dispatcher: RecordingDispatcher
               )

      assert ConductorSupervisor.whereis(draft_g.id) == nil
      assert ConductorSupervisor.whereis(drained_g.id) == nil
    end
  end

  # ---- restart simulation ---------------------------------------------------

  describe "restart simulation: no lost or duplicated dispatch" do
    test "a conductor stopped mid-run is recovered; in-progress tasks are NOT re-dispatched",
         %{ws: ws} do
      # Graph with two tasks: a (blocks b, so b depends on a).
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)

      {:ok, _} = Ash.create(Arbiter.Tasks.Dependency, %{
        from_issue_id: b.id,
        to_issue_id: a.id,
        type: :depends_on
      })

      # Kickoff: initial drain dispatches a (b is blocked).
      pid = kickoff(g, max_concurrent: 10)
      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id

      # Simulate worker claiming task a: mark it :in_progress in the DB.
      {:ok, _} = Ash.update(a, %{status: :in_progress})

      # Simulate a server crash: stop the Conductor process forcibly.
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # Graph is still :running in the DB; a is :in_progress; b is :open but blocked.
      assert Ash.get!(Graph, g.id).run_state == :running
      assert ConductorSupervisor.whereis(g.id) == nil

      # Boot recovery: reconcile restarts the Conductor.
      assert {:ok, 1} =
               ConductorReconciler.reconcile_running_graphs(
                 primary?: true,
                 dispatcher: RecordingDispatcher
               )

      new_pid = ConductorSupervisor.whereis(g.id)
      assert new_pid != nil
      assert new_pid != pid

      on_exit(fn -> ConductorSupervisor.stop_conductor(g.id) end)

      # The initial drain MUST NOT re-dispatch a (it is :in_progress, not :open).
      refute_receive {:dispatched, _, _}, 150

      # b remains blocked because a has not yet closed.
      snap = Conductor.state(new_pid)
      assert MapSet.member?(snap.member_ids, a.id)
      assert MapSet.member?(snap.member_ids, b.id)
    end

    test "tasks that were :open (not yet claimed) at crash time are re-dispatched on recovery",
         %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      # Manually put the graph in :running (simulating a crash before the
      # Conductor dispatched anything — task is still :open).
      {:ok, _} = Ash.update(g, %{run_state: :running})

      # No prior Conductor, a is still :open.
      assert {:ok, 1} =
               ConductorReconciler.reconcile_running_graphs(
                 primary?: true,
                 dispatcher: RecordingDispatcher
               )

      # The recovered Conductor dispatches the ready task.
      assert_receive {:dispatched, dispatched_id, _}
      assert dispatched_id == a.id

      on_exit(fn -> ConductorSupervisor.stop_conductor(g.id) end)
    end

    test "multiple running graphs each get a Conductor on recovery", %{ws: ws} do
      g1 = graph(ws)
      g2 = graph(ws)
      a1 = issue(ws)
      a2 = issue(ws)
      add_member(g1, a1)
      add_member(g2, a2)
      {:ok, _} = Ash.update(g1, %{run_state: :running})
      {:ok, _} = Ash.update(g2, %{run_state: :running})

      assert {:ok, 2} =
               ConductorReconciler.reconcile_running_graphs(
                 primary?: true,
                 dispatcher: RecordingDispatcher
               )

      assert ConductorSupervisor.whereis(g1.id) != nil
      assert ConductorSupervisor.whereis(g2.id) != nil

      dispatched_ids =
        for _ <- 1..2, do: (assert_receive({:dispatched, id, _}); id)

      assert MapSet.new(dispatched_ids) == MapSet.new([a1.id, a2.id])

      on_exit(fn ->
        ConductorSupervisor.stop_conductor(g1.id)
        ConductorSupervisor.stop_conductor(g2.id)
      end)
    end
  end
end
