defmodule GtElixir.Integration.Phase1SmokeTest do
  @moduledoc """
  End-to-end Phase 1 smoke test (gte-008 acceptance).

  Exercises the bead-ledger surface that the bd2 CLI relies on, end to end,
  using the Ash domain directly (the bd2 → REST → controllers → Ash chain is
  covered by the gt_elixir_web controller tests). Specifically:

    1. Create two issues A and B in a fresh workspace.
    2. Add a `:blocks` dependency: B blocks A. (i.e. A depends on B.)
    3. `Issue.ready/0` must NOT include A (gated by open B).
    4. `Issue.ready/0` must include B (no gating deps on B).
    5. Close B via the :close action.
    6. `Issue.ready/0` must now include A.
    7. Close A.
    8. `Issue.ready/0` must include neither A nor B.

  Plus a smaller convoy auto-close sanity check (gte-004 surface) — create a
  system_managed convoy with one member, close the member, expect convoy
  status :closed.
  """

  use GtElixir.DataCase, async: false

  alias GtElixir.Beads.{Convoy, ConvoyMembership, Dependency, Issue, Workspace}

  describe "ready/0 transitions across a blocking dependency" do
    setup do
      {:ok, ws} = Ash.create(Workspace, %{name: "phase1-smoke", prefix: "p1s"})
      {:ok, ws: ws}
    end

    test "open → blocked → unblocked → closed lifecycle", %{ws: ws} do
      {:ok, a} = Ash.create(Issue, %{title: "A (gated)", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "B (blocker)", workspace_id: ws.id})

      {:ok, _dep} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :blocks
        })

      ready_ids_1 = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()

      refute MapSet.member?(ready_ids_1, a.id),
             "A should be blocked by open B and not appear in ready"

      assert MapSet.member?(ready_ids_1, b.id),
             "B has no gating deps and should appear in ready"

      {:ok, _closed_b} = Ash.update(b, %{}, action: :close)

      ready_ids_2 = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.member?(ready_ids_2, a.id),
             "A should be unblocked once B is closed"

      refute MapSet.member?(ready_ids_2, b.id),
             "B is closed and should NOT appear in ready"

      {:ok, _closed_a} = Ash.update(a, %{}, action: :close)

      ready_ids_3 = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()

      refute MapSet.member?(ready_ids_3, a.id)
      refute MapSet.member?(ready_ids_3, b.id)
    end

    test "informational dep types (:relates_to, :discovered_from) do NOT gate readiness",
         %{ws: ws} do
      {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})

      {:ok, _rel} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :relates_to
        })

      ready_ids = Issue.ready() |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.member?(ready_ids, a.id),
             "relates_to should not gate readiness even when target is open"
    end
  end

  describe "convoy auto-close (gte-004 surface)" do
    setup do
      {:ok, ws} = Ash.create(Workspace, %{name: "convoy-smoke", prefix: "cs"})
      {:ok, ws: ws}
    end

    test "system_managed convoy auto-closes when its sole issue closes", %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "lone member", workspace_id: ws.id})

      {:ok, convoy} =
        Ash.create(Convoy, %{
          title: "Solo convoy",
          lifecycle: :system_managed,
          workspace_id: ws.id
        })

      {:ok, _m} =
        Ash.create(ConvoyMembership, %{
          convoy_id: convoy.id,
          issue_id: issue.id
        })

      {:ok, _closed_issue} = Ash.update(issue, %{}, action: :close)

      reloaded =
        Ash.get!(Convoy, convoy.id, load: [:total_issues, :closed_issues])

      assert reloaded.status == :closed,
             "system_managed convoy with all members closed should auto-close (was #{inspect(reloaded.status)})"
    end

    test "owned convoy does NOT auto-close even when all members close", %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "lone owned", workspace_id: ws.id})

      {:ok, convoy} =
        Ash.create(Convoy, %{title: "Owned convoy", lifecycle: :owned, workspace_id: ws.id})

      {:ok, _m} =
        Ash.create(ConvoyMembership, %{convoy_id: convoy.id, issue_id: issue.id})

      {:ok, _closed_issue} = Ash.update(issue, %{}, action: :close)

      reloaded = Ash.get!(Convoy, convoy.id)

      assert reloaded.status == :open,
             "owned convoys require explicit closure; should still be open"
    end
  end
end
