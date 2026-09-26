defmodule Arbiter.Loop.FlakesTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Loop.FlakeEvent
  alias Arbiter.Loop.Flakes
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workers.Run

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "flakes-ws-#{System.unique_integer([:positive])}"})

    {:ok, task} =
      Ash.create(Issue, %{title: "flaky task", workspace_id: ws.id, acceptance: "- n/a"})

    {:ok, ws: ws, task: task}
  end

  defp base_attrs(task_id, overrides \\ %{}) do
    Map.merge(
      %{
        task_id: task_id,
        repo: "arbiter",
        ci_job: "mix test",
        signature: "DataCase teardown timeout"
      },
      overrides
    )
  end

  describe "record/1" do
    test "records a flake event with a test file:line", %{task: task} do
      assert {:ok, %FlakeEvent{} = event} =
               Flakes.record(
                 base_attrs(task.id, %{test_file: "test/coverage_test.exs", test_line: 150})
               )

      assert event.task_id == task.id
      assert event.repo == "arbiter"
      assert event.ci_job == "mix test"
      assert event.test_file == "test/coverage_test.exs"
      assert event.test_line == 150
      assert event.signature == "DataCase teardown timeout"
      assert %DateTime{} = event.recorded_at
    end

    test "records a flake event with no test location — signature alone is enough", %{
      task: task
    } do
      assert {:ok, %FlakeEvent{} = event} =
               Flakes.record(base_attrs(task.id, %{note: "DB connection timeout on runner"}))

      assert event.test_file == nil
      assert event.test_line == nil
      assert event.note == "DB connection timeout on runner"
    end

    test "resolves run_id from the task's most recent fix_pass run when not given", %{
      ws: ws,
      task: task
    } do
      {:ok, older} =
        Ash.create(Run, %{
          task_id: task.id,
          workspace_id: ws.id,
          repo: "arbiter",
          worker_type: :fix_pass,
          status: :running,
          started_at: DateTime.add(DateTime.utc_now(), -3_600, :second)
        })

      {:ok, newer} =
        Ash.create(Run, %{
          task_id: task.id,
          workspace_id: ws.id,
          repo: "arbiter",
          worker_type: :fix_pass,
          status: :running,
          started_at: DateTime.utc_now()
        })

      refute older.id == newer.id

      assert {:ok, event} = Flakes.record(base_attrs(task.id))
      assert event.run_id == newer.id
    end

    test "an explicit run_id is preferred over resolution", %{ws: ws, task: task} do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: task.id,
          workspace_id: ws.id,
          repo: "arbiter",
          worker_type: :fix_pass,
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, event} =
               Flakes.record(base_attrs(task.id, %{run_id: run.id}))

      assert event.run_id == run.id
    end

    test "no matching run leaves run_id nil rather than failing", %{task: task} do
      assert {:ok, event} = Flakes.record(base_attrs(task.id))
      assert event.run_id == nil
    end

    test "every call inserts a new row — the table is append-only", %{task: task} do
      assert {:ok, _} = Flakes.record(base_attrs(task.id))
      assert {:ok, _} = Flakes.record(base_attrs(task.id))

      assert Ash.count!(FlakeEvent) >= 2
    end
  end
end
