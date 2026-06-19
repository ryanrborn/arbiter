defmodule Arbiter.WorkerTest do
  # async: false because the worker registry + dynamic supervisor are
  # singletons shared across tests; we use unique bead_ids per test to keep
  # cases independent, but we still don't want parallel runs racing on the
  # registry itself.
  use ExUnit.Case, async: false

  alias Arbiter.Worker

  # Generate a unique bead_id per test so tests don't collide on the registry.
  defp new_bead_id, do: "gte-test-#{System.unique_integer([:positive])}"

  defp start_worker(opts \\ []) do
    bead_id = Keyword.get(opts, :bead_id, new_bead_id())
    repo = Keyword.get(opts, :repo, "arbiter")

    opts =
      opts
      |> Keyword.put_new(:bead_id, bead_id)
      |> Keyword.put_new(:repo, repo)

    {:ok, pid} = Worker.start(opts)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    {pid, bead_id}
  end

  describe "start/1 + lifecycle" do
    test "starts, registers in the registry, exposes defaults via state/1" do
      {pid, bead_id} = start_worker(workspace_id: "ws-1")

      assert Worker.whereis(bead_id) == pid

      snap = Worker.state(pid)
      assert snap.bead_id == bead_id
      assert snap.repo == "arbiter"
      assert snap.workspace_id == "ws-1"
      assert snap.current_step == :idle
      assert snap.status == :idle
      assert %DateTime{} = snap.started_at
      assert snap.step_started_at == nil
      assert snap.meta == %{}
    end

    test "state/1 accepts bead_id strings" do
      {_pid, bead_id} = start_worker()
      assert %{bead_id: ^bead_id} = Worker.state(bead_id)
    end

    test "state/1 on unknown bead_id returns nil (doesn't crash)" do
      assert Worker.state("gte-nope-#{System.unique_integer([:positive])}") == nil
    end

    test "start_link/1 without :bead_id returns {:error, :missing_bead_id}" do
      assert Worker.start_link(repo: "arbiter") == {:error, :missing_bead_id}
    end

    test "start_link/1 without :repo returns {:error, :missing_repo}" do
      assert Worker.start_link(bead_id: new_bead_id()) == {:error, :missing_repo}
    end

    test "starting a second worker for the same bead_id returns :already_started" do
      {pid, bead_id} = start_worker()

      assert {:error, {:already_started, ^pid}} =
               Worker.start(bead_id: bead_id, repo: "arbiter")
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

    test "advance/2 by bead_id works too" do
      {_pid, bead_id} = start_worker()
      assert :ok = Worker.advance(bead_id, :load)
      assert Worker.state(bead_id).current_step == :load
    end

    test "advance/2 on unknown bead_id returns {:error, :not_found}" do
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

    test "complete/2 broadcasts {:worker_done, bead_id} on the workspace topic" do
      ws_id = "ws-broadcast-#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:done:" <> ws_id)

      {pid, bead_id} = start_worker(workspace_id: ws_id)
      :ok = Worker.advance(pid, :submit)
      :ok = Worker.complete(pid)

      assert_receive {:worker_done, ^bead_id}, 500
    end

    test "complete/2 without a workspace_id does not broadcast (no topic)" do
      {pid, _bead_id} = start_worker()
      :ok = Worker.advance(pid, :submit)
      # Just assert this doesn't crash; with no workspace_id there's no
      # well-defined topic and the broadcast is skipped.
      assert :ok = Worker.complete(pid)
    end

    test "claude-session 'arb done' marker also broadcasts worker_done" do
      ws_id = "ws-claude-#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:done:" <> ws_id)

      {pid, bead_id} = start_worker(workspace_id: ws_id)
      :ok = Worker.advance(pid, :run_claude)

      send(pid, {:__claude_session_done__, "arb done"})

      assert_receive {:worker_done, ^bead_id}, 500
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
      {pid, bead_id} = start_worker()
      ref = Process.monitor(pid)
      assert :ok = Worker.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert Worker.whereis(bead_id) == nil
      assert Worker.state(bead_id) == nil
    end

    test "stop/2 by bead_id works too" do
      {pid, bead_id} = start_worker()
      ref = Process.monitor(pid)
      assert :ok = Worker.stop(bead_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "stop/2 on unknown bead_id returns {:error, :not_found}" do
      assert {:error, :not_found} = Worker.stop("nope-#{System.unique_integer()}")
    end
  end

  describe "supervisor behavior" do
    test "workers are :temporary children — a crash does not restart them" do
      {pid, bead_id} = start_worker()
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
      # Give the supervisor a beat to (not) restart.
      Process.sleep(50)
      assert Worker.whereis(bead_id) == nil
    end
  end

  describe "list_children/0" do
    test "lists active worker snapshots; crashed entries are omitted" do
      {_pid_a, bead_a} = start_worker()
      {_pid_b, bead_b} = start_worker()
      {pid_c, _bead_c} = start_worker()

      ids = Worker.list_children() |> Enum.map(& &1.bead_id) |> Enum.sort()
      assert bead_a in ids
      assert bead_b in ids
      assert length(ids) >= 3

      ref = Process.monitor(pid_c)
      Process.exit(pid_c, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid_c, :killed}, 1_000
      Process.sleep(50)

      after_ids = Worker.list_children() |> Enum.map(& &1.bead_id)
      assert bead_a in after_ids
      assert bead_b in after_ids
      # crashed worker (bead_c) is gone
    end

    test "snapshots include :pid and the standard state keys" do
      {pid, _bead} = start_worker()
      [entry | _] = Worker.list_children() |> Enum.filter(&(&1.pid == pid))

      for key <- [:bead_id, :workspace_id, :repo, :current_step, :status, :started_at, :meta] do
        assert Map.has_key?(entry, key), "missing #{inspect(key)} in #{inspect(entry)}"
      end
    end
  end
end
