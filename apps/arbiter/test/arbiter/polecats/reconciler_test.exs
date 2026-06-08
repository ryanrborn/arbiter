defmodule Arbiter.Polecats.ReconcilerTest do
  # DataCase (async: false → shared sandbox) so the polecat process started
  # under the DynamicSupervisor reaches the same DB connection, mirroring
  # PolecatRunPersistenceTest.
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Messages.Message
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

  test "a non-primary (second) instance does not sweep live runs" do
    # The bug: a transient/duplicate app boot against the shared DB has an
    # empty local Polecat.Registry, so every :running row looks orphaned — it
    # would fail the PRIMARY instance's live runs. The boot path gates the
    # sweep on Arbiter.SingleInstance.primary?/0; a non-primary boot passes
    # primary?: false and must touch nothing.
    live = "bd-primary-live-#{System.unique_integer([:positive])}"
    create_run(live, :running)

    assert {:ok, :skipped} = Reconciler.reconcile_orphaned_runs(primary?: false)

    run = reload(live)
    assert run.status == :running
    assert run.failure_reason == nil
    assert run.completed_at == nil
  end

  test "the primary instance still performs the crash-recovery sweep" do
    # The legitimate single-server-restart path: primary?: true reconciles as
    # before, so genuine orphans are still swept.
    bead_id = "bd-orphan-primary-#{System.unique_integer([:positive])}"
    create_run(bead_id, :running)

    assert {:ok, 1} = Reconciler.reconcile_orphaned_runs(primary?: true)

    assert reload(bead_id).status == :failed
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

  # ---- reconcile_open_pr_beads (bd-crqku8 regression) -------------------

  defp create_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "reconcile-ws-#{System.unique_integer([:positive])}",
        prefix: "rw"
      })

    ws
  end

  defp create_issue(workspace_id, attrs) do
    {create_attrs, update_attrs} = Map.split(attrs, [:status, :pr_ref])

    base = %{
      title: "test-issue-#{System.unique_integer([:positive])}",
      workspace_id: workspace_id
    }

    {:ok, issue} = Ash.create(Issue, Map.merge(base, update_attrs))

    if map_size(create_attrs) > 0 do
      {:ok, issue} = Ash.update(issue, create_attrs)
      issue
    else
      issue
    end
  end

  test "escalates an :in_progress bead with a pr_ref and no live polecat to Admiral" do
    ws = create_workspace()

    issue =
      create_issue(ws.id, %{
        status: :in_progress,
        pr_ref: "#{System.unique_integer([:positive])}"
      })

    assert {:ok, 1} = Reconciler.reconcile_open_pr_beads()

    mail = Message.inbox("admiral", workspace_id: ws.id)
    assert length(mail) >= 1

    escalation = Enum.find(mail, &(&1.directive_ref == issue.id))
    assert escalation != nil
    assert escalation.kind == :escalation
    assert escalation.subject =~ issue.id
    assert escalation.subject =~ "stuck"
  end

  test "does not escalate an :in_progress bead with a pr_ref when a live polecat is running" do
    ws = create_workspace()

    issue =
      create_issue(ws.id, %{
        status: :in_progress,
        pr_ref: "#{System.unique_integer([:positive])}"
      })

    # The Issue's id IS the bead_id used to register polecats.
    {:ok, pid} = Polecat.start(bead_id: issue.id, rig: "arbiter", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    assert {:ok, 0} = Reconciler.reconcile_open_pr_beads()

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "does not escalate an :in_progress bead with no pr_ref" do
    ws = create_workspace()
    _issue = create_issue(ws.id, %{status: :in_progress})

    assert {:ok, 0} = Reconciler.reconcile_open_pr_beads()

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "does not escalate a :closed or :open bead even if it somehow has a pr_ref" do
    ws = create_workspace()
    _issue = create_issue(ws.id, %{pr_ref: "99"})

    assert {:ok, 0} = Reconciler.reconcile_open_pr_beads()

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "skips when primary?: false" do
    ws = create_workspace()

    _issue =
      create_issue(ws.id, %{
        status: :in_progress,
        pr_ref: "#{System.unique_integer([:positive])}"
      })

    assert {:ok, :skipped} = Reconciler.reconcile_open_pr_beads(primary?: false)

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end
end
