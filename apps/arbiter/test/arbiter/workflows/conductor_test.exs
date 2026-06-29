defmodule Arbiter.Workflows.ConductorTest do
  # async: false — the Conductor runs in its own process and reads the DB; the
  # DataCase sandbox is shared (not async) so that process can see committed
  # rows, and the "tasks" PubSub topic is global.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Graph
  alias Arbiter.Tasks.GraphMember
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.Conductor
  alias Arbiter.Workflows.ConductorSupervisor

  # Records every dispatch to the pid stashed in application env (mirrors the
  # MergeQueue tests' RecordingResolver). Returns {:ok, _} without spawning a
  # real worker. Leaves the dispatched issue :open so readiness is driven
  # explicitly by the test via close actions.
  defmodule RecordingDispatcher do
    def dispatch(task_id, opts) do
      if pid = Application.get_env(:arbiter, :test_conductor_pid),
        do: send(pid, {:dispatched, task_id, opts})

      {:ok, %{task_id: task_id}}
    end
  end

  setup do
    Application.put_env(:arbiter, :test_conductor_pid, self())

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "conductor-ws-#{System.unique_integer([:positive])}",
        prefix: "cnd#{System.unique_integer([:positive])}"
      })

    on_exit(fn ->
      Application.delete_env(:arbiter, :test_conductor_pid)
    end)

    %{ws: ws}
  end

  # ---- helpers ------------------------------------------------------------

  defp issue(ws, opts \\ []) do
    title = Keyword.get(opts, :title, "issue-#{System.unique_integer([:positive])}")
    {:ok, i} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
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

  defp dep(from, to, type) do
    {:ok, _} =
      Ash.create(Dependency, %{from_issue_id: from.id, to_issue_id: to.id, type: type})

    :ok
  end

  defp close(issue) do
    {:ok, closed} = Ash.update(issue, %{reason: "test close"}, action: :close)
    closed
  end

  # Kick off and ensure the conductor is torn down at test end.
  defp kickoff(graph, opts \\ []) do
    opts = Keyword.put_new(opts, :dispatcher, RecordingDispatcher)
    {:ok, pid} = Conductor.kickoff(graph.id, opts)
    on_exit(fn -> ConductorSupervisor.stop_conductor(graph.id) end)
    pid
  end

  # ---- acyclicity validation ----------------------------------------------

  describe "validate_acyclic/1" do
    test "a linear chain is acyclic", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # a depends_on b — a single forward edge, no cycle.
      dep(a, b, :depends_on)

      assert :ok = Conductor.validate_acyclic(g.id)
    end

    test "a 2-node depends_on cycle is detected and named", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      dep(a, b, :depends_on)
      dep(b, a, :depends_on)

      assert {:error, {:cyclic, cycle}} = Conductor.validate_acyclic(g.id)
      # Closed walk naming both offenders.
      assert a.id in cycle
      assert b.id in cycle
      assert List.first(cycle) == List.last(cycle)
    end

    test "a 3-node cycle across blocks + depends_on is detected", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      c = issue(ws)
      g = graph(ws)
      Enum.each([a, b, c], &add_member(g, &1))
      # a → b (a depends_on b), b → c (b depends_on c), c → a (a blocks c ⇒ edge c→a).
      dep(a, b, :depends_on)
      dep(b, c, :depends_on)
      dep(a, c, :blocks)

      assert {:error, {:cyclic, cycle}} = Conductor.validate_acyclic(g.id)
      assert a.id in cycle
      assert b.id in cycle
      assert c.id in cycle
    end

    test "conflicts_with is excluded from the cycle check", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # a depends_on b is a single forward edge. conflicts_with, if it were
      # treated as an ordering edge, would close the loop — but it must NOT.
      dep(a, b, :depends_on)
      dep(a, b, :conflicts_with)

      assert :ok = Conductor.validate_acyclic(g.id)
    end

    test "edges to non-members do not count", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      outsider = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # A cycle that runs through a non-member is not a cycle *within the graph*.
      dep(a, outsider, :depends_on)
      dep(outsider, a, :depends_on)

      assert :ok = Conductor.validate_acyclic(g.id)
    end
  end

  # ---- kickoff -------------------------------------------------------------

  describe "kickoff/2" do
    test "refuses a cyclic graph, names the cycle, and leaves it in :draft", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      dep(a, b, :depends_on)
      dep(b, a, :depends_on)

      assert {:error, {:cyclic, cycle}} =
               Conductor.kickoff(g.id, dispatcher: RecordingDispatcher)

      assert a.id in cycle and b.id in cycle

      # No transition, no process.
      assert Ash.get!(Graph, g.id).run_state == :draft
      assert ConductorSupervisor.whereis(g.id) == nil
      refute_received {:dispatched, _, _}
    end

    test "refuses a non-draft graph", %{ws: ws} do
      g = graph(ws)
      {:ok, running} = Ash.update(g, %{run_state: :running})

      assert {:error, {:not_draft, :running}} =
               Conductor.kickoff(running.id, dispatcher: RecordingDispatcher)
    end

    test "returns :graph_not_found for an unknown graph" do
      assert {:error, :graph_not_found} =
               Conductor.kickoff(Ash.UUIDv7.generate(), dispatcher: RecordingDispatcher)
    end

    test "transitions draft → running and dispatches the initial ready set",
         %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      kickoff(g)

      assert_receive {:dispatched, dispatched_id, opts}
      assert dispatched_id == a.id
      # Operator-equivalent root dispatch depth.
      assert opts[:depth] == 0
      assert Ash.get!(Graph, g.id).run_state == :running
    end
  end

  # ---- event-driven drain --------------------------------------------------

  describe "drain on close" do
    test "dispatches a directive once its gating blocker closes", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # b depends_on a — b is not ready until a closes.
      dep(b, a, :depends_on)

      kickoff(g)

      # Initial drain: only a is ready.
      assert_receive {:dispatched, a_id, _}
      assert a_id == a.id
      refute_receive {:dispatched, _, _}, 50

      # Close a → b becomes ready → drain dispatches b.
      close(a)

      assert_receive {:dispatched, b_id, _}
      assert b_id == b.id
    end

    test "ignores closes outside the graph's scope", %{ws: ws} do
      member = issue(ws)
      g = graph(ws)
      add_member(g, member)
      # An issue that is NOT a graph member.
      outsider = issue(ws)

      kickoff(g)

      assert_receive {:dispatched, member_id, _}
      assert member_id == member.id

      # Closing a non-member must not trigger another drain/dispatch.
      close(outsider)
      refute_receive {:dispatched, _, _}, 100
    end
  end

  # ---- conflicts_with serialization ----------------------------------------

  describe "conflicts_with serialization" do
    test "never co-dispatches two conflicting ready directives", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # Both ready (no gating deps), but mutually exclusive.
      dep(a, b, :conflicts_with)

      kickoff(g, max_concurrent: 5)

      # Exactly one of the pair is dispatched this pass.
      assert_receive {:dispatched, first_id, _}
      assert first_id in [a.id, b.id]
      refute_receive {:dispatched, _, _}, 100
    end

    test "honors a conflict regardless of stored edge direction", %{ws: ws} do
      a = issue(ws)
      b = issue(ws)
      g = graph(ws)
      add_member(g, a)
      add_member(g, b)
      # Edge stored b→a; symmetry must still serialize a vs b.
      dep(b, a, :conflicts_with)

      kickoff(g, max_concurrent: 5)

      assert_receive {:dispatched, _id, _}
      refute_receive {:dispatched, _, _}, 100
    end
  end

  # ---- fixed max_concurrent cap --------------------------------------------

  describe "max_concurrent cap" do
    test "dispatches no more than max_concurrent in a pass", %{ws: ws} do
      issues = for _ <- 1..3, do: issue(ws)
      g = graph(ws)
      Enum.each(issues, &add_member(g, &1))

      kickoff(g, max_concurrent: 2)

      assert_receive {:dispatched, id1, _}
      assert_receive {:dispatched, id2, _}
      refute_receive {:dispatched, _, _}, 100

      ids = MapSet.new([id1, id2])
      assert MapSet.size(ids) == 2
      assert MapSet.subset?(ids, MapSet.new(Enum.map(issues, & &1.id)))
    end
  end

  # ---- completion -----------------------------------------------------------

  describe "completion" do
    test "transitions running → drained and stops once all members close",
         %{ws: ws} do
      a = issue(ws)
      g = graph(ws)
      add_member(g, a)

      pid = kickoff(g)
      ref = Process.monitor(pid)

      assert_receive {:dispatched, a_id, _}
      assert a_id == a.id

      close(a)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert Ash.get!(Graph, g.id).run_state == :drained
      assert ConductorSupervisor.whereis(g.id) == nil
    end
  end
end
