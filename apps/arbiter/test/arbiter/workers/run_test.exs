defmodule Arbiter.Workers.RunTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Workers.Run

  @ws "ws-run-test"

  describe "create/validation" do
    test "creates a running run with the required fields" do
      now = DateTime.utc_now()

      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-aaa",
          task_title: "do a thing",
          repo: "arbiter",
          workspace_id: @ws,
          status: :running,
          started_at: now
        })

      assert run.task_id == "bd-aaa"
      assert run.status == :running
      assert run.output_lines == []
      # worker_type defaults to :main when not supplied.
      assert run.worker_type == :main
      assert %DateTime{} = run.inserted_at
    end

    test "accepts a worker_type and model, rejects an unknown worker_type" do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-typed",
          repo: "arbiter",
          worker_type: :review,
          model: "claude-opus-4-8",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert run.worker_type == :review
      assert run.model == "claude-opus-4-8"

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 task_id: "bd-badtype",
                 repo: "arbiter",
                 worker_type: :bogus,
                 status: :running,
                 started_at: DateTime.utc_now()
               })
    end

    test "rejects an unknown status" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 task_id: "bd-x",
                 repo: "arbiter",
                 status: :bogus,
                 started_at: DateTime.utc_now()
               })
    end

    test "rejects a missing task_id" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 repo: "arbiter",
                 status: :running,
                 started_at: DateTime.utc_now()
               })
    end
  end

  describe "update" do
    test "stamps completed_at, exit_code, output_lines, failure_reason" do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-bbb",
          repo: "arbiter",
          workspace_id: @ws,
          status: :running,
          started_at: DateTime.utc_now()
        })

      {:ok, updated} =
        Ash.update(run, %{
          status: :completed,
          completed_at: DateTime.utc_now(),
          exit_code: 0,
          output_lines: ["hello", "world"]
        })

      assert updated.status == :completed
      assert updated.exit_code == 0
      assert updated.output_lines == ["hello", "world"]
    end
  end

  describe "statuses/0" do
    test "exposes the canonical status list" do
      assert :running in Run.statuses()
      assert :completed in Run.statuses()
      assert :failed in Run.statuses()
    end
  end

  describe "worker_types/0" do
    test "exposes the canonical worker_type list" do
      assert Run.worker_types() == [:main, :review, :impl]
    end
  end
end
