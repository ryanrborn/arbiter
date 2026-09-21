defmodule Arbiter.WorkerTest do
  # async: false because the worker registry + dynamic supervisor are
  # singletons shared across tests; we use unique task_ids per test to keep
  # cases independent, but we still don't want parallel runs racing on the
  # registry itself.
  use ExUnit.Case, async: false

  alias Arbiter.Worker

  # Generate a unique task_id per test so tests don't collide on the registry.
  defp new_task_id, do: "gte-test-#{System.unique_integer([:positive])}"

  defp start_worker(opts \\ []) do
    task_id = Keyword.get(opts, :task_id, new_task_id())
    repo = Keyword.get(opts, :repo, "arbiter")

    opts =
      opts
      |> Keyword.put_new(:task_id, task_id)
      |> Keyword.put_new(:repo, repo)

    {:ok, pid} = Worker.start(opts)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    {pid, task_id}
  end

  describe "start/1 + lifecycle" do
    test "starts, registers in the registry, exposes defaults via state/1" do
      {pid, task_id} = start_worker(workspace_id: "ws-1")

      assert Worker.whereis(task_id) == pid

      snap = Worker.state(pid)
      assert snap.task_id == task_id
      assert snap.repo == "arbiter"
      assert snap.workspace_id == "ws-1"
      assert snap.current_step == :idle
      assert snap.status == :idle
      assert %DateTime{} = snap.started_at
      assert snap.step_started_at == nil
      assert snap.meta == %{}
    end

    # bd-aw2cyt: slot accounting and the phase model both read this off the
    # snapshot, so every consumer gets the same answer without a second call.
    test "the snapshot reports whether an agent subprocess is live" do
      {pid, task_id} = start_worker()

      snap = Worker.state(pid)
      assert snap.agent_live == false
      assert snap.agent_live == Worker.agent_session_live?(task_id)

      assert Enum.any?(
               Worker.list_children(),
               &(&1.task_id == task_id and &1.agent_live == false)
             )
    end

    test "state/1 accepts task_id strings" do
      {_pid, task_id} = start_worker()
      assert %{task_id: ^task_id} = Worker.state(task_id)
    end

    test "state/1 on unknown task_id returns nil (doesn't crash)" do
      assert Worker.state("gte-nope-#{System.unique_integer([:positive])}") == nil
    end

    test "start_link/1 without :task_id returns {:error, :missing_task_id}" do
      assert Worker.start_link(repo: "arbiter") == {:error, :missing_task_id}
    end

    test "start_link/1 without :repo returns {:error, :missing_repo}" do
      assert Worker.start_link(task_id: new_task_id()) == {:error, :missing_repo}
    end

    test "starting a second worker for the same task_id returns :already_started" do
      {pid, task_id} = start_worker()

      assert {:error, {:already_started, ^pid}} =
               Worker.start(task_id: task_id, repo: "arbiter")
    end
  end

  describe "advance/2" do
    test "from :idle → step transitions status to :running and sets step_started_at" do
      {pid, _} = start_worker()
      assert :ok = Worker.advance(pid, :load)

      snap = Worker.state(pid)
      assert snap.current_step == :load
      assert snap.status == :running
      assert %DateTime{} = snap.step_started_at
    end

    test "sequential advances update step but keep status=:running" do
      {pid, _} = start_worker()
      :ok = Worker.advance(pid, :load)
      first = Worker.state(pid).step_started_at
      # ensure a measurable tick between advances
      Process.sleep(5)
      :ok = Worker.advance(pid, :design)

      snap = Worker.state(pid)
      assert snap.current_step == :design
      assert snap.status == :running
      assert DateTime.compare(snap.step_started_at, first) == :gt
    end

    test "advance/2 by task_id works too" do
      {_pid, task_id} = start_worker()
      assert :ok = Worker.advance(task_id, :load)
      assert Worker.state(task_id).current_step == :load
    end

    test "advance/2 on unknown task_id returns {:error, :not_found}" do
      assert {:error, :not_found} = Worker.advance("nope-#{System.unique_integer()}", :load)
    end

    # bd-d70whv: redispatch a failed worker reuses the existing worker record.
    # advance/2 must transition :failed → :running so arb-done is processed
    # instead of being silently ignored by the guard in handle_info.
    test "advance/2 from :failed → :running (redispatch a failed worker)" do
      {pid, _} = start_worker()
      :ok = Worker.advance(pid, :load)
      :ok = Worker.fail(pid, :credentials_expired)
      assert Worker.state(pid).status == :failed

      assert :ok = Worker.advance(pid, :load)
      snap = Worker.state(pid)
      assert snap.status == :running
      assert snap.current_step == :load
    end
  end

  describe "await / resume" do
    test "await/2 from :running transitions to :awaiting and stores reason" do
      {pid, _} = start_worker()
      :ok = Worker.advance(pid, :verify)
      :ok = Worker.await(pid, :pr_review)

      snap = Worker.state(pid)
      assert snap.status == :awaiting
      assert snap.meta[:await_reason] == :pr_review
    end

    test "resume/1 from :awaiting transitions back to :running" do
      {pid, _} = start_worker()
      :ok = Worker.advance(pid, :verify)
      :ok = Worker.await(pid, :pr_review)
      :ok = Worker.resume(pid)

      snap = Worker.state(pid)
      assert snap.status == :running
      refute Map.has_key?(snap.meta, :await_reason)
    end

    test "await/2 from :idle is rejected" do
      {pid, _} = start_worker()
      assert {:error, {:invalid_transition, :idle, :awaiting}} = Worker.await(pid)
    end

    test "resume/1 from :running is rejected" do
      {pid, _} = start_worker()
      :ok = Worker.advance(pid, :load)
      assert {:error, {:invalid_transition, :running, :running}} = Worker.resume(pid)
    end
  end

  describe "complete / fail" do
    test "complete/2 from :running transitions to :completed" do
      {pid, _} = start_worker()
      :ok = Worker.advance(pid, :submit)
      :ok = Worker.complete(pid, %{pr: "https://example.com/pr/1"})

      snap = Worker.state(pid)
      assert snap.status == :completed
      assert snap.meta[:result] == %{pr: "https://example.com/pr/1"}
    end

    test "complete/2 broadcasts {:worker_done, task_id} on the workspace topic" do
      ws_id = "ws-broadcast-#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:done:" <> ws_id)

      {pid, task_id} = start_worker(workspace_id: ws_id)
      :ok = Worker.advance(pid, :submit)
      :ok = Worker.complete(pid)

      assert_receive {:worker_done, ^task_id}, 500
    end

    test "complete/2 without a workspace_id does not broadcast (no topic)" do
      {pid, _task_id} = start_worker()
      :ok = Worker.advance(pid, :submit)
      # Just assert this doesn't crash; with no workspace_id there's no
      # well-defined topic and the broadcast is skipped.
      assert :ok = Worker.complete(pid)
    end

    test "claude-session 'arb done' marker also broadcasts worker_done" do
      ws_id = "ws-claude-#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:done:" <> ws_id)

      {pid, task_id} = start_worker(workspace_id: ws_id)
      :ok = Worker.advance(pid, :run_claude)

      send(pid, {:__claude_session_done__, "arb done"})

      assert_receive {:worker_done, ^task_id}, 500
      assert Worker.state(pid).status == :completed
    end

    # bd-6v2my2: a `:task`-type directive (PRPatrol's reply/resolve follow-ups
    # among them) has no branch/PR of its own, even when a worktree WAS
    # provisioned for it (e.g. PRPatrol's `provision_worktree: true` override
    # so the worker has a real checkout to run `gh`/`git` from). Broadcasting
    # `{:worker_done}` here would hand it to the workspace MergeQueue, whose
    # `do_enqueue/2` has no issue_type awareness at all — it unconditionally
    # pushes the per-task branch and opens a PR for it. Without this guard, a
    # follow-up that replies/resolves and pushes zero commits would still get
    # a spurious/empty PR opened for it the instant `arb done` fires.
    test "a `:task`-type worker's arb-done does NOT broadcast worker_done" do
      ws_id = "ws-task-type-#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:done:" <> ws_id)

      {pid, task_id} = start_worker(workspace_id: ws_id, meta: %{issue_type: :task})

      :ok = Worker.advance(pid, :run_claude)

      send(pid, {:__claude_session_done__, "arb done"})

      refute_receive {:worker_done, ^task_id}, 500
      assert Worker.state(pid).status == :completed
    end

    test "advance/2 after complete/2 is rejected" do
      {pid, _} = start_worker()
      :ok = Worker.advance(pid, :submit)
      :ok = Worker.complete(pid)

      assert {:error, {:invalid_transition, :completed, {:advance, :design}}} =
               Worker.advance(pid, :design)
    end

    test "fail/2 from :running transitions to :failed" do
      {pid, _} = start_worker()
      :ok = Worker.advance(pid, :implement)
      :ok = Worker.fail(pid, :compile_error)

      snap = Worker.state(pid)
      assert snap.status == :failed
      assert snap.meta[:failure_reason] == :compile_error
    end

    test "fail/2 from :awaiting also transitions to :failed" do
      {pid, _} = start_worker()
      :ok = Worker.advance(pid, :verify)
      :ok = Worker.await(pid, :pr_review)
      :ok = Worker.fail(pid, :pr_rejected)

      assert Worker.state(pid).status == :failed
    end

    test "complete/2 from :idle is rejected" do
      {pid, _} = start_worker()
      assert {:error, {:invalid_transition, :idle, :completed}} = Worker.complete(pid)
    end
  end

  describe "report/3" do
    test "writes arbitrary key/value to :meta" do
      {pid, _} = start_worker()
      :ok = Worker.report(pid, :pr_url, "https://example.com/pr/42")
      :ok = Worker.report(pid, :files_changed, 7)

      snap = Worker.state(pid)
      assert snap.meta[:pr_url] == "https://example.com/pr/42"
      assert snap.meta[:files_changed] == 7
    end
  end

  describe "stop/2" do
    test "terminates the worker and the registry forgets it" do
      {pid, task_id} = start_worker()
      ref = Process.monitor(pid)
      assert :ok = Worker.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert Worker.whereis(task_id) == nil
      assert Worker.state(task_id) == nil
    end

    test "stop/2 by task_id works too" do
      {pid, task_id} = start_worker()
      ref = Process.monitor(pid)
      assert :ok = Worker.stop(task_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "stop/2 on unknown task_id returns {:error, :not_found}" do
      assert {:error, :not_found} = Worker.stop("nope-#{System.unique_integer()}")
    end
  end

  describe "supervisor behavior" do
    test "workers are :temporary children — a crash does not restart them" do
      {pid, task_id} = start_worker()
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
      # Give the supervisor a beat to (not) restart.
      Process.sleep(50)
      assert Worker.whereis(task_id) == nil
    end
  end

  describe "list_children/0" do
    test "lists active worker snapshots; crashed entries are omitted" do
      {_pid_a, task_a} = start_worker()
      {_pid_b, task_b} = start_worker()
      {pid_c, _task_c} = start_worker()

      ids = Worker.list_children() |> Enum.map(& &1.task_id) |> Enum.sort()
      assert task_a in ids
      assert task_b in ids
      assert length(ids) >= 3

      ref = Process.monitor(pid_c)
      Process.exit(pid_c, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid_c, :killed}, 1_000
      Process.sleep(50)

      after_ids = Worker.list_children() |> Enum.map(& &1.task_id)
      assert task_a in after_ids
      assert task_b in after_ids
      # crashed worker (task_c) is gone
    end

    test "snapshots include :pid and the standard state keys" do
      {pid, _task} = start_worker()
      [entry | _] = Worker.list_children() |> Enum.filter(&(&1.pid == pid))

      for key <- [:task_id, :workspace_id, :repo, :current_step, :status, :started_at, :meta] do
        assert Map.has_key?(entry, key), "missing #{inspect(key)} in #{inspect(entry)}"
      end
    end

    # bd-45tkhq: `worker_list` (and `arb worker list` / `arb prime`) read
    # straight off `list_children/0`. Its `safe_snapshot/1` gives a live
    # worker only 500ms to answer `:snapshot` before treating it the same as
    # a crashed child — silently dropping it from the list. A genuinely alive
    # worker mid-burst (e.g. draining a flood of `mix test` output lines
    # through its mailbox) can easily miss a 500ms window without being dead
    # or even unusually slow; `Worker.state/1` (what `worker_show` /
    # `worker_runs` use) has no such tight budget, which is exactly why those
    # kept reporting the worker as running at the same instant `worker_list`
    # reported zero.
    test "a live worker that is briefly slow to answer :snapshot is not dropped" do
      {pid, task_id} = start_worker()

      :sys.suspend(pid)

      spawn(fn ->
        Process.sleep(700)
        :sys.resume(pid)
      end)

      try do
        ids = Worker.list_children() |> Enum.map(& &1.task_id)
        assert task_id in ids
      after
        :sys.resume(pid)
      end
    end

    # bd-45tkhq: raising the probe budget only narrows the window a live
    # worker can miss it in — it does not remove the window. A worker that is
    # still alive but does not answer :snapshot even within the new (5s)
    # budget must degrade rather than vanish, the same way `active_sibling/2`
    # treats an unresponsive-but-alive sibling as busy, not gone.
    test "a live worker that never answers :snapshot is degraded, not dropped" do
      {pid, task_id} = start_worker()
      :sys.suspend(pid)

      try do
        [entry] = Worker.list_children() |> Enum.filter(&(&1.task_id == task_id))
        assert entry.status == :unknown
        assert entry.meta.stale_probe == true
        assert entry.pid == pid
      after
        :sys.resume(pid)
      end
    end

    # Mirrors the second observation in bd-45tkhq: the worker had already
    # been through `worker_stop` + `worker_resume` (which, at the `Worker`
    # level, is `stop/2` followed by a fresh `start/1` under the same
    # `task_id`) before it vanished from an unfiltered list. Same mechanism
    # as above — resume isn't special, any live worker can lose the race.
    test "a resumed worker (stopped, then restarted under the same task_id) is not dropped" do
      {pid, task_id} = start_worker()
      ref = Process.monitor(pid)
      :ok = Worker.stop(task_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      {resumed_pid, ^task_id} = start_worker(task_id: task_id)

      :sys.suspend(resumed_pid)

      spawn(fn ->
        Process.sleep(700)
        :sys.resume(resumed_pid)
      end)

      try do
        ids = Worker.list_children() |> Enum.map(& &1.task_id)
        assert task_id in ids
      after
        :sys.resume(resumed_pid)
      end
    end

    # bd-45tkhq round 2: a merge-queue subordinate pass (FixPassDispatcher,
    # ConflictResolver) registers under `<task_id>:fixpass` / `<task_id>:conflict`
    # while its durable Arbiter.Workers.Run row is keyed on the plain
    # `task_id`. degraded_snapshot/2 must strip the suffix before looking up
    # the run, or it falls into the no-run branch: workspace_id: nil, which
    # Tools.worker_list/2's workspace filter then silently drops — the exact
    # "live worker invisible" bug this ticket exists to fix, relocated to
    # subordinate workers.
    test "a wedged subordinate (suffixed registry key) still resolves the primary task's run" do
      # This module otherwise avoids the DB (see the plain `ExUnit.Case`
      # above), but this case needs `record_run_started/1`'s write to
      # actually land so `degraded_snapshot/2` has a Run row to resolve.
      # Shared mode so the separately-spawned Worker GenServer can use the
      # connection too.
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Arbiter.Repo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

      task_id = new_task_id()

      {pid, ^task_id} =
        start_worker(
          task_id: task_id,
          workspace_id: "ws-probe",
          registry_key: task_id <> ":fixpass"
        )

      :sys.suspend(pid)

      try do
        [entry] = Worker.list_children() |> Enum.filter(&(&1.pid == pid))
        assert entry.registry_key == task_id <> ":fixpass"
        assert entry.task_id == task_id
        assert entry.workspace_id == "ws-probe"
        assert entry.status == :unknown
      after
        :sys.resume(pid)
      end
    end
  end

  describe "provider/1" do
    test "reads an atom-keyed :provider" do
      assert Worker.provider(%{provider: :codex}) == "codex"
    end

    test "reads a string-keyed \"provider\"" do
      assert Worker.provider(%{"provider" => "gemini"}) == "gemini"
    end

    test "falls back to routing_config.provider (atom keys)" do
      assert Worker.provider(%{routing_config: %{provider: :claude}}) == "claude"
    end

    test "falls back to routing_config[\"provider\"] (string keys)" do
      assert Worker.provider(%{"routing_config" => %{"provider" => "codex"}}) == "codex"
    end

    test "returns nil for empty meta" do
      assert Worker.provider(%{}) == nil
    end

    test "returns nil for nil meta" do
      assert Worker.provider(nil) == nil
    end
  end
end
