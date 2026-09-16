defmodule Arbiter.Tasks.EdgeGateConformanceTest do
  @moduledoc """
  bd-6bax7s acceptance 4: Arbiter has two schedulers, and they must answer the
  edge question the same way.

  Each scenario builds the *same* issues and the *same* `Dependency` rows once,
  then asks both paths what they would dispatch:

    * the **graph path** — `Arbiter.Workflows.Conductor`, over a graph whose
      members are those issues.
    * the **board path** — `Arbiter.Board.Snapshot` → `Arbiter.Board.Scheduler`,
      the one `Arbiter.Board.Autopilot` actually dispatches from.

  The two have different *shapes* — the Conductor fills every free slot in one
  pass, the board deliberately promotes one card per plan (see
  `Arbiter.Board.Scheduler`'s moduledoc) — so what is compared is the set each
  refuses to dispatch **because of an edge**, which is the question
  `Arbiter.Tasks.EdgeGate` owns.
  """
  # async: false — the Conductor runs in its own process and reads the DB.
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Graph
  alias Arbiter.Tasks.GraphMember
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.Conductor
  alias Arbiter.Workflows.ConductorSupervisor

  defmodule RecordingDispatcher do
    @moduledoc false
    def dispatch(task_id, opts) do
      if pid = Application.get_env(:arbiter, :test_conformance_pid),
        do: send(pid, {:dispatched, task_id, opts})

      {:ok, %{task_id: task_id}}
    end
  end

  setup do
    Application.put_env(:arbiter, :test_conformance_pid, self())
    on_exit(fn -> Application.delete_env(:arbiter, :test_conformance_pid) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "conformance-#{System.unique_integer([:positive])}",
        prefix: "cfm#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  # ---- the scenarios -------------------------------------------------------
  #
  # `:a` always carries the lower priority number, so it is the head of the
  # queue on both paths and the tie-break never enters into it.

  @scenarios [
    %{
      name: "depends_on — the dependent waits",
      edges: [{:a, :depends_on, :b}],
      gated: [:a]
    },
    %{
      name: "blocks — same rule, stored the other way round",
      edges: [{:b, :blocks, :a}],
      gated: [:a]
    },
    %{
      name: "depends_on a closed blocker — nothing waits",
      edges: [{:a, :depends_on, :b}],
      closed: [:b],
      gated: []
    },
    %{
      name: "depends_on a blocker at awaiting_verification — the dependent still waits",
      edges: [{:a, :depends_on, :b}],
      awaiting_verification: [:b],
      gated: [:a]
    },
    %{
      name: "conflicts_with — exactly one of the pair goes",
      edges: [{:a, :conflicts_with, :b}],
      gated: [:b]
    },
    %{
      name: "conflicts_with stored the other way round — still the same one",
      edges: [{:b, :conflicts_with, :a}],
      gated: [:b]
    },
    %{
      name: "parent_of is non-gating",
      edges: [{:a, :parent_of, :b}],
      gated: []
    },
    %{
      name: "relates_to is non-gating",
      edges: [{:a, :relates_to, :b}],
      gated: []
    },
    %{
      name: "discovered_from is non-gating",
      edges: [{:a, :discovered_from, :b}],
      gated: []
    }
  ]

  for scenario <- @scenarios do
    @scenario scenario

    test "both schedulers agree: #{scenario.name}", %{ws: ws} do
      world = build(ws, @scenario)
      expected = MapSet.new(@scenario.gated, &world.ids[&1])

      graph_gated = graph_path_gated(ws, world)
      board_gated = board_path_gated(world)

      assert graph_gated == expected, """
      the Conductor gated #{inspect(MapSet.to_list(graph_gated))}, expected \
      #{inspect(MapSet.to_list(expected))}
      """

      assert board_gated == graph_gated, """
      the board gated #{inspect(MapSet.to_list(board_gated))} but the Conductor \
      gated #{inspect(MapSet.to_list(graph_gated))} — the two schedulers have drifted
      """
    end
  end

  # ---- the two paths -------------------------------------------------------

  # What the Conductor refuses to dispatch, given more slots than members.
  defp graph_path_gated(ws, world) do
    g = graph(ws)
    Enum.each(world.dispatchable, &add_member(g, &1))

    {:ok, _pid} = Conductor.kickoff(g.id, dispatcher: RecordingDispatcher, max_concurrent: 10)
    on_exit(fn -> ConductorSupervisor.stop_conductor(g.id) end)

    MapSet.difference(MapSet.new(world.dispatchable), collect_dispatched())
  end

  # What the board refuses to dispatch. The board promotes one card per plan by
  # design, so `:queued` — "waiting its turn, nothing wrong with it" — counts as
  # dispatchable; only `:blocked` is a refusal. Every board-wide hold is off
  # (slots, quota, pause), so a refusal can only be an edge.
  defp board_path_gated(world) do
    board =
      Snapshot.load(
        issues: world.issues,
        workers: [],
        slots_total: 10,
        quota: :ok,
        paused: false
      )

    ready = MapSet.new(board.ready, & &1.id)
    blocked = for e <- board.ready, e.state == :blocked, into: MapSet.new(), do: e.id

    # Anything the Conductor could see but the Ready column never showed (a
    # non-open issue) is not the board's to gate — restrict to the overlap.
    MapSet.intersection(blocked, ready)
  end

  defp collect_dispatched(acc \\ MapSet.new()) do
    receive do
      {:dispatched, id, _opts} -> collect_dispatched(MapSet.put(acc, id))
    after
      150 -> acc
    end
  end

  # ---- the world -----------------------------------------------------------

  defp build(ws, scenario) do
    a = issue(ws, priority: 1)
    b = issue(ws, priority: 2)
    by_key = %{a: a, b: b}

    for {from, type, to} <- scenario.edges do
      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: by_key[from].id,
          to_issue_id: by_key[to].id,
          type: type
        })
    end

    parked =
      Map.new(Map.get(scenario, :closed, []), &{&1, close(by_key[&1])}) |> Map.merge(
        Map.new(Map.get(scenario, :awaiting_verification, []), &{&1, await(by_key[&1])})
      )

    final = Map.merge(by_key, parked)
    settled = Map.keys(parked)

    %{
      ids: Map.new(final, fn {k, i} -> {k, i.id} end),
      issues: Map.values(final),
      # A settled issue is nobody's to dispatch: the Conductor would refuse it
      # for a reason that is not an edge, so it is not part of the comparison.
      dispatchable: for({k, i} <- final, k not in settled, do: i.id)
    }
  end

  # Refined, because the board's Ready column requires it and the whole point
  # is to compare two *dispatch* queues.
  defp issue(ws, opts) do
    {:ok, i} =
      Ash.create(Issue, %{
        title: "conformance-#{System.unique_integer([:positive])}",
        workspace_id: ws.id,
        priority: Keyword.fetch!(opts, :priority),
        acceptance: "- [ ] conformance fixture"
      })

    {:ok, refined} = Ash.update(i, %{}, action: :promote_to_ready)
    refined
  end

  defp close(issue) do
    {:ok, closed} = Ash.update(issue, %{reason: "conformance"}, action: :close)
    closed
  end

  # Merged, waiting on the coordinator's restart-and-observe. Reachable from
  # `:open` directly (see `Issue.Changes.GuardStatus`).
  defp await(issue) do
    {:ok, parked} = Ash.update(issue, %{}, action: :await_verification)
    parked
  end

  defp graph(ws) do
    {:ok, g} =
      Ash.create(Graph, %{
        name: "cfm-#{System.unique_integer([:positive])}",
        workspace_id: ws.id
      })

    g
  end

  defp add_member(graph, issue_id) do
    {:ok, _} = Ash.create(GraphMember, %{graph_id: graph.id, issue_id: issue_id})
    :ok
  end
end
