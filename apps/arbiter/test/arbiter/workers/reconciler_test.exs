defmodule Arbiter.Workers.ReconcilerTest do
  # DataCase (async: false → shared sandbox) so the worker process started
  # under the DynamicSupervisor reaches the same DB connection, mirroring
  # WorkerRunPersistenceTest.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Workers.Reconciler
  alias Arbiter.Workers.Run
  require Ash.Query

  defp create_run(task_id, status) do
    Ash.create!(Run, %{
      task_id: task_id,
      repo: "arbiter",
      workspace_id: "ws-reconcile",
      status: status,
      started_at: DateTime.utc_now(),
      output_lines: []
    })
  end

  defp reload(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read_one!()
  end

  test "marks an orphaned :running run :failed with a server-restarted reason" do
    task_id = "bd-orphan-#{System.unique_integer([:positive])}"
    create_run(task_id, :running)

    assert {:ok, 1} = Reconciler.reconcile_orphaned_runs()

    run = reload(task_id)
    assert run.status == :failed
    assert run.failure_reason == "server restarted"
    assert %DateTime{} = run.completed_at
  end

  test "leaves a :running run with a live worker untouched" do
    task_id = "bd-live-#{System.unique_integer([:positive])}"

    # A live worker both registers under Worker.Registry and writes its own
    # :running Run row on init — exactly the case the sweep must skip.
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-reconcile")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    assert {:ok, 0} = Reconciler.reconcile_orphaned_runs()

    run = reload(task_id)
    assert run.status == :running
  end

  test "a non-primary (second) instance does not sweep live runs" do
    # The bug: a transient/duplicate app boot against the shared DB has an
    # empty local Worker.Registry, so every :running row looks orphaned — it
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
    task_id = "bd-orphan-primary-#{System.unique_integer([:positive])}"
    create_run(task_id, :running)

    assert {:ok, 1} = Reconciler.reconcile_orphaned_runs(primary?: true)

    assert reload(task_id).status == :failed
  end

  test "leaves already-terminal runs untouched" do
    task_id = "bd-done-#{System.unique_integer([:positive])}"
    create_run(task_id, :completed)

    assert {:ok, 0} = Reconciler.reconcile_orphaned_runs()

    run = reload(task_id)
    assert run.status == :completed
    assert run.failure_reason == nil
  end

  test "after the sweep no orphaned :running row remains" do
    orphans =
      for _ <- 1..4 do
        task_id = "bd-stale-#{System.unique_integer([:positive])}"
        create_run(task_id, :running)
        task_id
      end

    assert {:ok, 4} = Reconciler.reconcile_orphaned_runs()

    for task_id <- orphans do
      assert reload(task_id).status == :failed
    end

    # No :running row survives without a live worker backing it.
    surviving =
      Run
      |> Ash.Query.filter(status == :running)
      |> Ash.read!()
      |> Enum.reject(fn run -> Worker.whereis(run.task_id) end)

    assert surviving == []
  end

  # ---- reconcile_open_pr_tasks (bd-crqku8 regression) -------------------

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

  test "escalates an :in_progress task with a pr_ref and no live worker to Admiral" do
    ws = create_workspace()

    issue =
      create_issue(ws.id, %{
        status: :in_progress,
        pr_ref: "#{System.unique_integer([:positive])}"
      })

    assert {:ok, 1} = Reconciler.reconcile_open_pr_tasks()

    mail = Message.inbox("admiral", workspace_id: ws.id)
    assert length(mail) >= 1

    escalation = Enum.find(mail, &(&1.directive_ref == issue.id))
    assert escalation != nil
    assert escalation.kind == :escalation
    assert escalation.subject =~ issue.id
    assert escalation.subject =~ "stuck"
  end

  test "does not escalate an :in_progress task with a pr_ref when a live worker is running" do
    ws = create_workspace()

    issue =
      create_issue(ws.id, %{
        status: :in_progress,
        pr_ref: "#{System.unique_integer([:positive])}"
      })

    # The Issue's id IS the task_id used to register workers.
    {:ok, pid} = Worker.start(task_id: issue.id, repo: "arbiter", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    assert {:ok, 0} = Reconciler.reconcile_open_pr_tasks()

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "does not escalate an :in_progress task with no pr_ref" do
    ws = create_workspace()
    _issue = create_issue(ws.id, %{status: :in_progress})

    assert {:ok, 0} = Reconciler.reconcile_open_pr_tasks()

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "does not escalate a :closed or :open task even if it somehow has a pr_ref" do
    ws = create_workspace()
    _issue = create_issue(ws.id, %{pr_ref: "99"})

    assert {:ok, 0} = Reconciler.reconcile_open_pr_tasks()

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "skips when primary?: false" do
    ws = create_workspace()

    _issue =
      create_issue(ws.id, %{
        status: :in_progress,
        pr_ref: "#{System.unique_integer([:positive])}"
      })

    assert {:ok, :skipped} = Reconciler.reconcile_open_pr_tasks(primary?: false)

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end
end
