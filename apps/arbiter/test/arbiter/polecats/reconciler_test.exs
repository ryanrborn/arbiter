defmodule Arbiter.Polecats.ReconcilerTest do
  # DataCase (async: false → shared sandbox) so the polecat process started
  # under the DynamicSupervisor reaches the same DB connection, mirroring
  # PolecatRunPersistenceTest.
  use Arbiter.DataCase, async: false

  alias Arbiter.Polecat
  alias Arbiter.Polecats.Reconciler
  alias Arbiter.Polecats.Run
  require Ash.Query

  defp create_run(bead_id, status) do
    Ash.create!(Run, %{
      bead_id: bead_id,
      rig: "arbiter",
      workspace_id: "ws-reconcile",
      status: status,
      started_at: DateTime.utc_now(),
      output_lines: []
    })
  end

  defp reload(bead_id) do
    Run
    |> Ash.Query.filter(bead_id == ^bead_id)
    |> Ash.read_one!()
  end

  test "marks an orphaned :running run :failed with a server-restarted reason" do
    bead_id = "bd-orphan-#{System.unique_integer([:positive])}"
    create_run(bead_id, :running)

    assert {:ok, 1} = Reconciler.reconcile_orphaned_runs()

    run = reload(bead_id)
    assert run.status == :failed
    assert run.failure_reason == "server restarted"
    assert %DateTime{} = run.completed_at
  end

  test "leaves a :running run with a live polecat untouched" do
    bead_id = "bd-live-#{System.unique_integer([:positive])}"

    # A live polecat both registers under Polecat.Registry and writes its own
    # :running Run row on init — exactly the case the sweep must skip.
    {:ok, pid} = Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: "ws-reconcile")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    assert {:ok, 0} = Reconciler.reconcile_orphaned_runs()

    run = reload(bead_id)
    assert run.status == :running
  end

  test "leaves already-terminal runs untouched" do
    bead_id = "bd-done-#{System.unique_integer([:positive])}"
    create_run(bead_id, :completed)

    assert {:ok, 0} = Reconciler.reconcile_orphaned_runs()

    run = reload(bead_id)
    assert run.status == :completed
    assert run.failure_reason == nil
  end

  test "after the sweep no orphaned :running row remains" do
    orphans =
      for _ <- 1..4 do
        bead_id = "bd-stale-#{System.unique_integer([:positive])}"
        create_run(bead_id, :running)
        bead_id
      end

    assert {:ok, 4} = Reconciler.reconcile_orphaned_runs()

    for bead_id <- orphans do
      assert reload(bead_id).status == :failed
    end

    # No :running row survives without a live polecat backing it.
    surviving =
      Run
      |> Ash.Query.filter(status == :running)
      |> Ash.read!()
      |> Enum.reject(fn run -> Polecat.whereis(run.bead_id) end)

    assert surviving == []
  end
end
