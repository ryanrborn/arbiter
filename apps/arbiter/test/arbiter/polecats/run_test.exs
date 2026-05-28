defmodule Arbiter.Polecats.RunTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Polecats.Run

  @ws "ws-run-test"

  describe "create/validation" do
    test "creates a running run with the required fields" do
      now = DateTime.utc_now()

      {:ok, run} =
        Ash.create(Run, %{
          bead_id: "bd-aaa",
          bead_title: "do a thing",
          rig: "arbiter",
          workspace_id: @ws,
          status: :running,
          started_at: now
        })

      assert run.bead_id == "bd-aaa"
      assert run.status == :running
      assert run.output_lines == []
      assert %DateTime{} = run.inserted_at
    end

    test "rejects an unknown status" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 bead_id: "bd-x",
                 rig: "arbiter",
                 status: :bogus,
                 started_at: DateTime.utc_now()
               })
    end

    test "rejects a missing bead_id" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 rig: "arbiter",
                 status: :running,
                 started_at: DateTime.utc_now()
               })
    end
  end

  describe "update" do
    test "stamps completed_at, exit_code, output_lines, failure_reason" do
      {:ok, run} =
        Ash.create(Run, %{
          bead_id: "bd-bbb",
          rig: "arbiter",
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
end
