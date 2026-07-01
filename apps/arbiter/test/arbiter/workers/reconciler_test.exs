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

  # An open-PR bead whose workspace has no patrol coverage (a bare test
  # workspace has no hosted-forge merger configured) can't be auto-watched, so
  # the default re-watch fails and the reconciler escalates as the fallback.
  test "escalates an open-PR task whose workspace has no patrol coverage (fallback)" do
    ws = create_workspace()

    issue =
      create_issue(ws.id, %{
        status: :in_progress,
        pr_ref: "#{System.unique_integer([:positive])}"
      })

    assert {:ok, %{rewatched: 0, escalated: 1}} = Reconciler.reconcile_open_pr_tasks()

    mail = Message.inbox("admiral", workspace_id: ws.id)
    assert length(mail) >= 1

    escalation = Enum.find(mail, &(&1.directive_ref == issue.id))
    assert escalation != nil
    assert escalation.kind == :escalation
    assert escalation.subject =~ issue.id
    assert escalation.subject =~ "stuck"
  end

  test "re-watches an open-PR (awaiting_review) bead via the patrol layer instead of escalating" do
    ws = create_workspace()

    issue =
      create_issue(ws.id, %{
        status: :in_progress,
        pr_ref: "#{System.unique_integer([:positive])}"
      })

    test_pid = self()

    rewatch = fn %Issue{} = i ->
      send(test_pid, {:rewatched, i.id})
      :ok
    end

    assert {:ok, %{rewatched: 1, escalated: 0}} =
             Reconciler.reconcile_open_pr_tasks(rewatch_fun: rewatch)

    assert_received {:rewatched, task_id}
    assert task_id == issue.id

    # Re-watched, NOT escalated — no mail lands in Admiral's inbox.
    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "re-watches a review-only engagement (no pr_ref) via the patrol layer" do
    ws = create_workspace()
    issue = create_issue(ws.id, %{status: :in_progress})
    {:ok, issue} = Ash.update(issue, %{review_only: true})

    test_pid = self()
    rewatch = fn %Issue{id: id} -> send(test_pid, {:rewatched, id}) && :ok end

    assert {:ok, %{rewatched: 1, escalated: 0}} =
             Reconciler.reconcile_open_pr_tasks(rewatch_fun: rewatch)

    assert_received {:rewatched, task_id}
    assert task_id == issue.id
  end

  test "does not touch an open-PR task when a live worker is running (worker_live? guard)" do
    ws = create_workspace()

    issue =
      create_issue(ws.id, %{
        status: :in_progress,
        pr_ref: "#{System.unique_integer([:positive])}"
      })

    # The Issue's id IS the task_id used to register workers.
    {:ok, pid} = Worker.start(task_id: issue.id, repo: "arbiter", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    test_pid = self()
    rewatch = fn %Issue{id: id} -> send(test_pid, {:rewatched, id}) && :ok end

    assert {:ok, %{rewatched: 0, escalated: 0}} =
             Reconciler.reconcile_open_pr_tasks(rewatch_fun: rewatch)

    refute_received {:rewatched, _}
    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "open-PR sweep leaves a bead with no pr_ref alone (that is the resume sweep's job)" do
    ws = create_workspace()
    _issue = create_issue(ws.id, %{status: :in_progress})

    assert {:ok, %{rewatched: 0, escalated: 0}} = Reconciler.reconcile_open_pr_tasks()

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "open-PR sweep ignores a :closed or :open task even if it somehow has a pr_ref" do
    ws = create_workspace()
    _issue = create_issue(ws.id, %{pr_ref: "99"})

    assert {:ok, %{rewatched: 0, escalated: 0}} = Reconciler.reconcile_open_pr_tasks()

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "open-PR sweep skips when primary?: false" do
    ws = create_workspace()

    _issue =
      create_issue(ws.id, %{
        status: :in_progress,
        pr_ref: "#{System.unique_integer([:positive])}"
      })

    assert {:ok, :skipped} = Reconciler.reconcile_open_pr_tasks(primary?: false)

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  # ---- reconcile_resumable_tasks (:running/revising resume) --------------

  test "resumes a mid-flight (:running) bead with no pr_ref via the resume path" do
    ws = create_workspace()
    issue = create_issue(ws.id, %{status: :in_progress})

    test_pid = self()

    resume = fn %Issue{} = i ->
      send(test_pid, {:resumed, i.id})
      {:ok, %{task_id: i.id}}
    end

    assert {:ok, %{resumed: 1, escalated: 0}} =
             Reconciler.reconcile_resumable_tasks(resume_fun: resume)

    assert_received {:resumed, task_id}
    assert task_id == issue.id
    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "escalates a mid-flight bead that cannot be safely resumed (no outpost)" do
    ws = create_workspace()
    issue = create_issue(ws.id, %{status: :in_progress})

    # Simulate Dispatch.resume/2 refusing because the worktree was cleaned up.
    resume = fn %Issue{} -> {:error, :no_outpost} end

    assert {:ok, %{resumed: 0, escalated: 1}} =
             Reconciler.reconcile_resumable_tasks(resume_fun: resume)

    mail = Message.inbox("admiral", workspace_id: ws.id)
    escalation = Enum.find(mail, &(&1.directive_ref == issue.id))
    assert escalation != nil
    assert escalation.kind == :escalation
    assert escalation.subject =~ "cannot be safely resumed"
  end

  test "resume sweep respects the worker_live? guard (never resumes a live bead)" do
    ws = create_workspace()
    issue = create_issue(ws.id, %{status: :in_progress})

    {:ok, pid} = Worker.start(task_id: issue.id, repo: "arbiter", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    test_pid = self()
    resume = fn %Issue{id: id} -> send(test_pid, {:resumed, id}) && {:ok, id} end

    assert {:ok, %{resumed: 0, escalated: 0}} =
             Reconciler.reconcile_resumable_tasks(resume_fun: resume)

    refute_received {:resumed, _}
    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "resume sweep does not touch open-PR or review-only beads" do
    ws = create_workspace()

    _open_pr =
      create_issue(ws.id, %{status: :in_progress, pr_ref: "#{System.unique_integer([:positive])}"})

    review = create_issue(ws.id, %{status: :in_progress})
    {:ok, _} = Ash.update(review, %{review_only: true})

    resume = fn %Issue{} -> flunk("resume must not be called for open-PR/review-only beads") end

    assert {:ok, %{resumed: 0, escalated: 0}} =
             Reconciler.reconcile_resumable_tasks(resume_fun: resume)

    assert Message.inbox("admiral", workspace_id: ws.id) == []
  end

  test "resume sweep skips when primary?: false" do
    ws = create_workspace()
    _issue = create_issue(ws.id, %{status: :in_progress})

    resume = fn %Issue{} -> flunk("must not resume on a non-primary boot") end

    assert {:ok, :skipped} =
             Reconciler.reconcile_resumable_tasks(primary?: false, resume_fun: resume)
  end

  # ---- acceptance regression: restart-with-in-flight-work ----------------

  test "restart with in-flight work: awaiting_review bead re-watched, un-resumable bead escalated" do
    ws = create_workspace()

    # One awaiting_review bead: in_progress with an open PR of its own.
    watched =
      create_issue(ws.id, %{
        status: :in_progress,
        pr_ref: "#{System.unique_integer([:positive])}"
      })

    # One mid-flight bead whose worktree is gone → cannot be safely resumed.
    unresumable = create_issue(ws.id, %{status: :in_progress})

    test_pid = self()
    rewatch = fn %Issue{id: id} -> send(test_pid, {:rewatched, id}) && :ok end
    resume = fn %Issue{} -> {:error, :no_outpost} end

    # Boot ordering: open-PR sweep first (re-watch), then resume sweep.
    assert {:ok, %{rewatched: 1, escalated: 0}} =
             Reconciler.reconcile_open_pr_tasks(rewatch_fun: rewatch)

    assert {:ok, %{resumed: 0, escalated: 1}} =
             Reconciler.reconcile_resumable_tasks(resume_fun: resume)

    # The awaiting_review bead was re-watched, not escalated.
    assert_received {:rewatched, watched_id}
    assert watched_id == watched.id

    mail = Message.inbox("admiral", workspace_id: ws.id)

    # Only the un-resumable bead escalated.
    assert Enum.find(mail, &(&1.directive_ref == watched.id)) == nil
    escalation = Enum.find(mail, &(&1.directive_ref == unresumable.id))
    assert escalation != nil
    assert escalation.kind == :escalation
  end
end
