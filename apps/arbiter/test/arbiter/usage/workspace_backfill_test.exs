defmodule Arbiter.Usage.WorkspaceBackfillTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.WorkspaceBackfill

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "wb-#{System.unique_integer([:positive])}",
        prefix: "wb#{System.unique_integer([:positive])}"
      })

    {:ok, task} = Ash.create(Issue, %{title: "author task", workspace_id: ws.id})

    {:ok, ws: ws, task: task}
  end

  defp insert_event!(task_id, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          task_id: task_id,
          repo: "arbiter",
          step: :review,
          occurred_at: DateTime.utc_now()
        },
        extra
      )

    {:ok, ev} = Ash.create(Arbiter.Usage.Event, attrs)
    ev
  end

  defp insert_run!(task_id, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          task_id: task_id,
          repo: "arbiter",
          status: :running,
          started_at: DateTime.utc_now(),
          output_lines: []
        },
        extra
      )

    {:ok, run} = Ash.create(Arbiter.Workers.Run, attrs)
    run
  end

  test "backfills a nil-workspace review row from its authoring task's workspace", %{
    ws: ws,
    task: task
  } do
    ev = insert_event!("#{task.id}#review")
    assert ev.workspace_id == nil

    [events_report, _runs_report] = WorkspaceBackfill.run()

    assert events_report.table == "usage_events"
    assert events_report.backfilled >= 1

    reloaded = Ash.get!(Arbiter.Usage.Event, ev.id)
    assert reloaded.workspace_id == ws.id
  end

  test "backfills a nil-workspace impl row through a chained synthetic id", %{
    ws: ws,
    task: task
  } do
    ev = insert_event!("#{task.id}#review#impl1", %{step: :impl})

    WorkspaceBackfill.run()

    assert Ash.get!(Arbiter.Usage.Event, ev.id).workspace_id == ws.id
  end

  test "backfills worker_runs the same way", %{ws: ws, task: task} do
    run = insert_run!("#{task.id}#review")

    [_events_report, runs_report] = WorkspaceBackfill.run()

    assert runs_report.table == "worker_runs"
    assert runs_report.backfilled >= 1
    assert Ash.get!(Arbiter.Workers.Run, run.id).workspace_id == ws.id
  end

  test "leaves a row NULL and counts it unresolved when the base task can't be resolved" do
    ev = insert_event!("bd-does-not-exist#review")

    [events_report, _] = WorkspaceBackfill.run()

    assert events_report.unresolved >= 1
    assert Ash.get!(Arbiter.Usage.Event, ev.id).workspace_id == nil
  end

  test "does not touch a row that already carries a workspace_id", %{task: task} do
    {:ok, other_ws} =
      Ash.create(Workspace, %{
        name: "wb-other-#{System.unique_integer([:positive])}",
        prefix: "wbo#{System.unique_integer([:positive])}"
      })

    ev = insert_event!("#{task.id}#review", %{workspace_id: other_ws.id})

    WorkspaceBackfill.run()

    assert Ash.get!(Arbiter.Usage.Event, ev.id).workspace_id == other_ws.id
  end

  test "a plain (non-synthetic) task id with no workspace resolves via its own row" do
    {:ok, ws2} =
      Ash.create(Workspace, %{
        name: "wb-plain-#{System.unique_integer([:positive])}",
        prefix: "wbp#{System.unique_integer([:positive])}"
      })

    {:ok, plain_task} = Ash.create(Issue, %{title: "plain task", workspace_id: ws2.id})
    ev = insert_event!(plain_task.id)

    WorkspaceBackfill.run()

    assert Ash.get!(Arbiter.Usage.Event, ev.id).workspace_id == ws2.id
  end
end
