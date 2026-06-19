defmodule Arbiter.Integration.Phase1SmokeTest do
  @moduledoc """
  End-to-end Phase 1 smoke test (gte-008 acceptance).

  Exercises the bead-ledger surface that the arb CLI relies on, end to end,
  using the Ash domain directly (the arb → REST → controllers → Ash chain is
  covered by the arbiter_web controller tests). Specifically:

    1. Create two issues A and B in a fresh workspace.
    2. Add a `:blocks` dependency: B blocks A. (i.e. A depends on B.)
    3. `Issue.ready/0` must NOT include A (gated by open B).
    4. `Issue.ready/0` must include B (no gating deps on B).
    5. Close B via the :close action.
    6. `Issue.ready/0` must now include A.
    7. Close A.
    8. `Issue.ready/0` must include neither A nor B.

  Plus a smaller parent-with-progress auto-close sanity check — create a parent
  bead with `auto_close: true` and one `:parent_of` child, close the child,
  expect the parent to auto-close.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Dependency, Issue, Workspace}

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

  describe "parent-with-progress auto-close" do
    setup do
      {:ok, ws} = Ash.create(Workspace, %{name: "parent-smoke", prefix: "ps"})
      {:ok, ws: ws}
    end

    test "an auto_close parent closes when its sole child closes", %{ws: ws} do
      {:ok, parent} =
        Ash.create(Issue, %{
          title: "Epic",
          issue_type: :epic,
          auto_close: true,
          workspace_id: ws.id
        })

      {:ok, child} = Ash.create(Issue, %{title: "child", workspace_id: ws.id})

      {:ok, _dep} =
        Ash.create(Dependency, %{
          from_issue_id: parent.id,
          to_issue_id: child.id,
          type: :parent_of
        })

      {:ok, _closed_child} = Ash.update(child, %{}, action: :close)

      reloaded = Ash.get!(Issue, parent.id, load: [:child_total, :child_closed])

      assert reloaded.status == :closed,
             "auto_close parent with all children closed should auto-close (was #{inspect(reloaded.status)})"

      assert reloaded.child_total == 1
      assert reloaded.child_closed == 1
    end

    test "a parent without auto_close does NOT close when its children close", %{ws: ws} do
      {:ok, parent} =
        Ash.create(Issue, %{title: "Owned epic", issue_type: :epic, workspace_id: ws.id})

      {:ok, child} = Ash.create(Issue, %{title: "child", workspace_id: ws.id})

      {:ok, _dep} =
        Ash.create(Dependency, %{
          from_issue_id: parent.id,
          to_issue_id: child.id,
          type: :parent_of
        })

      {:ok, _closed_child} = Ash.update(child, %{}, action: :close)

      reloaded = Ash.get!(Issue, parent.id)

      assert reloaded.status == :open,
             "a parent without auto_close requires explicit closure; should still be open"
    end

    test "an auto_close parent stays open while any child is still open", %{ws: ws} do
      {:ok, parent} =
        Ash.create(Issue, %{title: "Epic", auto_close: true, workspace_id: ws.id})

      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      {:ok, c2} = Ash.create(Issue, %{title: "c2", workspace_id: ws.id})

      for c <- [c1, c2] do
        {:ok, _} =
          Ash.create(Dependency, %{from_issue_id: parent.id, to_issue_id: c.id, type: :parent_of})
      end

      {:ok, _} = Ash.update(c1, %{}, action: :close)

      reloaded = Ash.get!(Issue, parent.id, load: [:child_total, :child_closed])

      assert reloaded.status == :open,
             "parent should stay open while child c2 is still open"

      assert reloaded.child_total == 2
      assert reloaded.child_closed == 1
    end
  end
end
