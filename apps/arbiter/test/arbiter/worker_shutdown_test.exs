defmodule Arbiter.WorkerShutdownTest do
  # bd-aje6fj / #1896: a server stop must reach `Arbiter.Worker.terminate/2`.
  #
  # Every test here shuts a worker down the way the application does on
  # `systemctl restart` — by stopping the supervisor it lives under, which sends
  # each child the `:shutdown` exit signal and waits the child spec's
  # `:shutdown` budget — rather than through `Worker.stop/3`, which goes through
  # the `sys` terminate path and always ran `terminate/2`.
  #
  # async: false — shared sandbox (the worker writes its Run row from its own
  # process), the global worker registry, and real OS processes.
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.OsProcess
  alias Arbiter.Workers.Reconciler
  alias Arbiter.Workers.Run
  require Ash.Query

  @fixture Path.expand("../fixtures/echo_with_done.sh", __DIR__)

  defp new_task_id, do: "bd-shutdown-#{System.unique_integer([:positive])}"

  # A private stand-in for `Arbiter.Worker.Supervisor`. Stopping it is exactly
  # what the application does to the real one on shutdown.
  defp start_sup! do
    start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :shutdown_test_sup)
  end

  defp stop_sup!, do: :ok = stop_supervised(:shutdown_test_sup)

  defp start_worker!(sup, spec_overrides \\ []) do
    task_id = new_task_id()

    spec =
      Supervisor.child_spec(
        {Worker, [task_id: task_id, repo: "arbiter", workspace_id: "ws-shutdown"]},
        spec_overrides
      )

    {:ok, pid} = DynamicSupervisor.start_child(sup, spec)
    {pid, task_id}
  end

  defp run_for(task_id) do
    [run] = Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
    run
  end

  defp tmp_dir!(tag) do
    dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp os_process_alive?(os_pid) do
    {_, code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    code == 0
  end

  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("eventually/2 timed out")
        else
          Process.sleep(20)
          do_eventually(fun, deadline)
        end

      value ->
        value
    end
  end

  # Save-and-restore, never put+delete: deleting would also wipe a value
  # config/test.exs set.
  defp put_env!(key, value) do
    previous = Application.fetch_env(:arbiter, key)
    Application.put_env(:arbiter, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:arbiter, key, v)
        :error -> Application.delete_env(:arbiter, key)
      end
    end)
  end

  describe "child spec" do
    test "declares an explicit shutdown grace that fits inside the unit's 45s stop timeout" do
      spec = Worker.child_spec(task_id: "t", repo: "arbiter")

      assert spec.shutdown == Worker.shutdown_grace_ms()
      assert is_integer(spec.shutdown)
      # arbiter.service inherits TimeoutStopUSec=45s; the grace is spent in
      # parallel for every worker, and the rest of the tree needs the remainder.
      assert spec.shutdown <= 20_000
    end
  end

  describe "supervised shutdown" do
    test "runs terminate/2: the run is recorded :interrupted, not :completed or :failed" do
      sup = start_sup!()
      {pid, task_id} = start_worker!(sup)
      :ok = Worker.advance(pid, :implement)

      ref = Process.monitor(pid)
      stop_sup!()
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}

      run = run_for(task_id)
      assert run.status == :interrupted
      assert run.failure_reason == "server shutdown"
      assert %DateTime{} = run.completed_at
      assert Worker.whereis(task_id) == nil
    end

    test "SIGKILLs the live agent and its descendants" do
      sup = start_sup!()
      {pid, task_id} = start_worker!(sup)
      :ok = Worker.advance(pid, :implement)
      cwd = tmp_dir!("shutdown-live")

      # An agent that has itself spawned a long-running child — the `mix test`
      # under `claude` shape that outlives a bare port close.
      {:ok, port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "sleep 60 & wait"]
        )

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      [child_pid | _] = eventually(fn -> OsProcess.descendants(os_pid) |> non_empty() end)
      assert os_process_alive?(os_pid)
      assert os_process_alive?(child_pid)

      stop_sup!()

      refute os_process_alive?(os_pid)
      refute os_process_alive?(child_pid)
      assert run_for(task_id).status == :interrupted
    end

    test "a worker that ignores the shutdown is killed after its grace and the supervisor still stops" do
      sup = start_sup!()
      {pid, task_id} = start_worker!(sup, shutdown: 200)
      ref = Process.monitor(pid)

      # Wedge the worker inside a callback so the shutdown exit signal sits in
      # its mailbox unread — a terminate/2 that never gets to run.
      wedger =
        spawn(fn -> :sys.replace_state(pid, fn s -> Process.sleep(:infinity) && s end) end)

      on_exit(fn -> Process.exit(wedger, :kill) end)
      eventually(fn -> match?({:current_function, {Process, :sleep, 1}}, current(pid)) end)

      {micros, :ok} = :timer.tc(fn -> stop_sup!() end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert micros < 5_000_000

      # terminate/2 never ran, so the row is still :running — the boot
      # reconciler's "server restarted" sweep is the backstop for exactly this.
      assert run_for(task_id).status == :running
      assert {:ok, n} = Reconciler.reconcile_orphaned_runs(primary?: true)
      assert n >= 1
      run = run_for(task_id)
      assert run.status == :failed
      assert run.failure_reason == "server restarted"
    end
  end

  describe "trapped exits" do
    test "the {:EXIT, port, :normal} a finished session leaves behind does not crash the worker" do
      sup = start_sup!()
      {pid, _task_id} = start_worker!(sup)
      :ok = Worker.advance(pid, :implement)
      cwd = tmp_dir!("shutdown-exit")

      {:ok, _port} = ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture])

      eventually(fn -> Worker.state(pid).meta[:exit_status] end)
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end

    test "System.cmd / Port.close exits from a failure teardown do not crash the worker" do
      sup = start_sup!()
      {pid, _task_id} = start_worker!(sup)
      :ok = Worker.advance(pid, :implement)
      cwd = tmp_dir!("shutdown-fail")

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: ["sh", "-c", "sleep 60"])

      # fail_now/2 SIGKILLs via System.cmd("kill") and closes the port — both
      # linked to the worker, both leave an {:EXIT, port, :normal} behind.
      :ok = Worker.fail(pid, :simulated_failure)
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
      assert Worker.state(pid).status == :failed
    end

    test "an abnormal exit from a linked process stops the worker through terminate/2 as a crash" do
      sup = start_sup!()
      {pid, task_id} = start_worker!(sup)
      :ok = Worker.advance(pid, :implement)
      ref = Process.monitor(pid)

      :sys.replace_state(pid, fn s ->
        spawn_link(fn -> exit(:boom) end)
        s
      end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:linked_exit, _from, :boom}}

      run = run_for(task_id)
      assert run.status == :failed
      assert run.failure_reason =~ "worker crashed"
      assert run.failure_reason =~ "boom"
    end

    test "a huge crash reason is bounded before it lands in failure_reason" do
      sup = start_sup!()
      {pid, task_id} = start_worker!(sup)
      :ok = Worker.advance(pid, :implement)
      ref = Process.monitor(pid)

      huge = {:boom, List.duplicate(String.duplicate("x", 100), 50)}

      :sys.replace_state(pid, fn s ->
        spawn_link(fn -> exit(huge) end)
        s
      end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:linked_exit, _from, _}}

      run = run_for(task_id)
      assert run.status == :failed
      assert run.failure_reason =~ "worker crashed"
      assert run.failure_reason =~ "boom"
      assert String.length(run.failure_reason) < 2_000
    end
  end

  describe "agent exits while the node is stopping" do
    test "is left for the shutdown to record as :interrupted, not failed and escalated" do
      put_env!(:worker_node_stopping_override, true)

      sup = start_sup!()
      {pid, task_id} = start_worker!(sup)
      :ok = Worker.advance(pid, :implement)
      cwd = tmp_dir!("shutdown-sigterm")

      # systemd's control-group SIGTERM reaches the agent at the same moment
      # as the BEAM, so the agent usually exits before the worker is told.
      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: ["sh", "-c", "exit 143"])

      eventually(fn -> Worker.state(pid).meta[:exit_status] end)
      # Past the (test-config) exit grace, so the deferred stop check has run.
      Process.sleep(150)
      _ = :sys.get_state(pid)
      assert Worker.state(pid).status == :running

      stop_sup!()
      assert run_for(task_id).status == :interrupted
    end
  end

  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp current(pid), do: Process.info(pid, :current_function)
end
