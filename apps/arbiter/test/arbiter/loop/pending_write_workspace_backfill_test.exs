defmodule Arbiter.Loop.PendingWriteWorkspaceBackfillTest do
  @moduledoc """
  bd-3dasqm: the historical-repair half of the fix — `Arbiter.Loop.record/2`
  itself now refuses to write a nil `workspace_id` on a live insert (see
  `Arbiter.Loop.PendingWriteTest`); this covers repairing rows written before
  that, the same way `Arbiter.Usage.WorkspaceBackfillTest` covers its `#1016`
  precedent.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.{PendingWrite, PendingWriteWorkspaceBackfill}
  alias Arbiter.Tasks.{Issue, Workspace}

  require Ash.Query

  defp new_ws(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, ws} =
      Ash.create(
        Workspace,
        Map.merge(%{name: "pwb-#{n}", prefix: "pwb#{n}"}, attrs)
      )

    ws
  end

  defp insert_legacy_row!(attrs) do
    base = %{
      kind: :skill_patch,
      gist: "legacy pre-fix row",
      fingerprint: "fp-#{System.unique_integer([:positive])}",
      scope: :fleet,
      payload: %{}
    }

    {:ok, row} = Ash.create(PendingWrite, Map.merge(base, attrs), action: :propose)
    row
  end

  test "backfills a nil-workspace task-scoped row from its target task's workspace" do
    ws = new_ws()
    {:ok, task} = Ash.create(Issue, %{title: "override target", workspace_id: ws.id})

    row =
      insert_legacy_row!(%{
        kind: :difficulty_override,
        scope: :task,
        target: task.id,
        payload: %{"task_id" => task.id, "difficulty" => 3}
      })

    assert row.workspace_id == nil

    [task_report, _fleet_report] = PendingWriteWorkspaceBackfill.run()

    assert task_report.scope == "task"
    assert task_report.backfilled >= 1
    assert Ash.get!(PendingWrite, row.id).workspace_id == ws.id
  end

  test "leaves a task-scoped row NULL and counts it unresolved when the target can't be resolved" do
    row = insert_legacy_row!(%{kind: :difficulty_override, scope: :task, target: "bd-nope"})

    [task_report, _] = PendingWriteWorkspaceBackfill.run()

    assert task_report.unresolved >= 1
    assert Ash.get!(PendingWrite, row.id).workspace_id == nil
  end

  test "backfills a nil-workspace fleet row to the installation's sole workspace" do
    ws = new_ws()
    row = insert_legacy_row!(%{scope: :fleet})

    [_task_report, fleet_report] = PendingWriteWorkspaceBackfill.run()

    assert fleet_report.scope == "fleet"
    assert fleet_report.backfilled >= 1
    assert Ash.get!(PendingWrite, row.id).workspace_id == ws.id
  end

  test "backfills a nil-workspace fleet row to the workspace named \"default\" when ambiguous" do
    default_ws = new_ws(%{name: "default"})
    _other = new_ws()

    row = insert_legacy_row!(%{scope: :fleet})

    [_task_report, fleet_report] = PendingWriteWorkspaceBackfill.run()

    assert fleet_report.backfilled >= 1
    assert Ash.get!(PendingWrite, row.id).workspace_id == default_ws.id
  end

  test "leaves a fleet row NULL and counts it unresolved when the install is ambiguous" do
    _a = new_ws()
    _b = new_ws()

    row = insert_legacy_row!(%{scope: :fleet})

    [_task_report, fleet_report] = PendingWriteWorkspaceBackfill.run()

    assert fleet_report.unresolved >= 1
    assert Ash.get!(PendingWrite, row.id).workspace_id == nil
  end

  test "does not touch a row that already carries a workspace_id" do
    ws = new_ws()
    other_ws = new_ws()

    row = insert_legacy_row!(%{scope: :fleet, workspace_id: other_ws.id})

    PendingWriteWorkspaceBackfill.run()

    assert Ash.get!(PendingWrite, row.id).workspace_id == other_ws.id
    refute other_ws.id == ws.id
  end
end
