defmodule Arbiter.Tasks.EdgeGateConformanceTest do
  @moduledoc """
  bd-6bax7s acceptance 4: every `Dependency` edge type, and what the dispatch
  path does with it.

  Each scenario builds issues and `Dependency` rows, then asks the **board
  path** — `Arbiter.Board.Snapshot` → `Arbiter.Board.Scheduler`, the one
  `Arbiter.Board.Autopilot` actually dispatches from — which cards it refuses
  to dispatch **because of an edge**, the question `Arbiter.Tasks.EdgeGate`
  owns.

  This used to compare that answer against a second scheduler (the graph
  Conductor), which is the drift bd-6bax7s was filed for. bd-a14qd1 removed
  that scheduler, so there is one path left and the table below pins its
  answer directly — the same scenarios, the same expectations.
  """
  use Arbiter.DataCase, async: true

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
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
  # queue, and the tie-break never enters into it.

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

    test "the board gates exactly the edge-blocked cards: #{scenario.name}", %{ws: ws} do
      world = build(ws, @scenario)
      expected = MapSet.new(@scenario.gated, &world.ids[&1])

      board_gated = board_path_gated(world)

      assert board_gated == expected, """
      the board gated #{inspect(MapSet.to_list(board_gated))}, expected \
      #{inspect(MapSet.to_list(expected))}
      """
    end
  end

  # ---- the dispatch path ---------------------------------------------------

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

    # A settled issue the Ready column never showed is not the board's to gate
    # — restrict to the overlap.
    MapSet.intersection(blocked, ready)
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
      Map.new(Map.get(scenario, :closed, []), &{&1, close(by_key[&1])})
      |> Map.merge(
        Map.new(Map.get(scenario, :awaiting_verification, []), &{&1, await(by_key[&1])})
      )

    final = Map.merge(by_key, parked)

    %{
      ids: Map.new(final, fn {k, i} -> {k, i.id} end),
      issues: Map.values(final)
    }
  end

  # Refined, because the board's Ready column requires it and the whole point
  # is to exercise the *dispatch* queue.
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
end
