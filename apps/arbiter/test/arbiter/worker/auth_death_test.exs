defmodule Arbiter.Worker.AuthDeathTest do
  # bd-21bmdh: a worker dying with `:auth_expired` returns its task to Ready,
  # leaves no debris, and the auth hold stops the reopen from becoming a loop.
  #
  # Everything here is the real path: a real git repo + bare origin, the real
  # `Dispatch.dispatch/2` (worktree provisioning, Driver, routing), a stub
  # `claude` on PATH that prints the CLI's 401 and exits 1, and — for the loop
  # test — the real `Arbiter.Board.Autopilot` reading the real board.
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.{AuthHold, Claude, CredentialWatchdog}
  alias Arbiter.Board.{Autopilot, Snapshot}
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, Dispatch, Worktree}
  alias Arbiter.Workers.Run
  require Ash.Query

  @auth_stub """
  #!/bin/sh
  echo 'API Error: 401 Invalid authentication credentials'
  exit 1
  """

  @crash_stub """
  #!/bin/sh
  echo 'error: unknown option --reasoning-effort'
  exit 1
  """

  setup do
    tmp = Path.join(System.tmp_dir!(), "auth-death-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    repo = seed_repo!(tmp, "ad-repo")
    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
    put_app_env(:arbiter, :repo_paths, %{"ad/repo" => repo})

    {:ok, _} = AuthHold.reset(:all)
    CredentialWatchdog.reset()

    on_exit(fn ->
      {:ok, _} = AuthHold.reset(:all)
      CredentialWatchdog.reset()
    end)

    {:ok, ws} = Ash.create(Workspace, %{name: "auth-death-ws", prefix: "ad"})
    {:ok, ws: ws, tmp: tmp, repo: repo}
  end

  describe "a worker that dies with :auth_expired (acceptance 3, 5)" do
    test "returns its task to Ready, keeps the failed run, escalates, and leaves no debris",
         %{ws: ws, tmp: tmp, repo: repo} do
      stub_claude!(tmp, @auth_stub)
      task = ready_task!(ws, "dies on auth")

      assert {:ok, %{worker_pid: pid}} = dispatch(task.id)
      worktree = Worktree.worktree_path(BranchNamer.derive(task))
      branch = BranchNamer.derive(task)

      eventually(fn -> reload(task).status == :open end)

      # The run is still recorded as the failure it was.
      assert [run] = runs(task.id)
      assert run.status == :failed
      assert run.stop_category == "auth_expired"

      # The failed worker is gone from the registry, or the board would file
      # the card under Waiting rather than Ready.
      eventually(fn -> Worker.whereis(task.id) == nil end)
      refute Process.alive?(pid)
      assert Snapshot.classify_columns([reload(task)], Worker.list_children())[task.id] == :ready

      # Escalation still fires.
      assert Enum.any?(
               Message.inbox("admiral", workspace_id: ws.id),
               &(&1.kind == :escalation and &1.directive_ref == task.id)
             )

      # It never produced a commit: no worktree, no branch.
      refute File.dir?(worktree)
      assert branch_list(repo, branch) == ""

      # One death is a retry, not a hold.
      refute AuthHold.open?(Claude)
    end

    test "a worktree with a commit on it is kept, branch and all", %{ws: ws, tmp: tmp, repo: repo} do
      # A worker that got far enough to commit before its credential died
      # produced something; that is not debris.
      stub_claude!(tmp, """
      #!/bin/sh
      echo work > work.txt
      git add work.txt
      git -c user.email=t@e.com -c user.name=T -c commit.gpgsign=false commit -q -m work
      echo 'API Error: 401 Invalid authentication credentials'
      exit 1
      """)

      task = ready_task!(ws, "commits then dies")
      assert {:ok, _} = dispatch(task.id)
      worktree = Worktree.worktree_path(BranchNamer.derive(task))

      eventually(fn -> reload(task).status == :open end)

      assert File.dir?(worktree)
      assert branch_list(repo, BranchNamer.derive(task)) != ""
    end

    test "a task stops being reopened after max_task_reopens auth deaths", %{ws: ws, tmp: tmp} do
      put_app_env(:arbiter, :auth_hold, threshold: 100, max_task_reopens: 2)
      stub_claude!(tmp, @auth_stub)
      task = ready_task!(ws, "keeps dying")

      assert {:ok, _} = dispatch(task.id)
      eventually(fn -> reload(task).status == :open end)

      assert {:ok, _} = dispatch(task.id)
      eventually(fn -> length(runs(task.id)) == 2 and Worker.whereis(task.id) != nil end)
      eventually(fn -> Enum.all?(runs(task.id), &(&1.status == :failed)) end)

      # Second auth death on this task: today's behaviour, it stays put.
      assert_stays(fn -> reload(task).status == :in_progress end)
    end
  end

  describe "other failure shapes are unchanged (acceptance 6)" do
    test "a non-auth death leaves the task :in_progress and does not count toward the hold",
         %{ws: ws, tmp: tmp} do
      stub_claude!(tmp, @crash_stub)
      task = ready_task!(ws, "crashes")

      assert {:ok, %{worker_pid: pid}} = dispatch(task.id)
      eventually(fn -> Worker.state(pid).status == :failed end)
      assert Worker.state(pid).meta.stop_reason.category == :crashed

      assert_stays(fn -> reload(task).status == :in_progress end)
      assert AuthHold.status(Claude).deaths == 0
    end

    # bd-8praoz: a worker SIGTERMed by the unit's cgroup kill (e.g. a server
    # restart) must never be treated as an auth death just because its own
    # transcript happens to contain auth-shaped vocabulary (a worker touching
    # credential/resume code prints "401"/"invalid"/"credentials expired" in
    # its own normal output). Before the fix, this stub reproduced the exact
    # false page from the ticket: the run classified `:auth_expired` from the
    # output despite dying on signal 15, which both notified
    # `CredentialWatchdog` and counted toward the `AuthHold` streak.
    test "a signal-killed worker with an auth-shaped transcript leaves the task " <>
           ":in_progress and does not count toward the hold or notify the watchdog",
         %{ws: ws, tmp: tmp} do
      stub_claude!(tmp, """
      #!/bin/sh
      echo 'investigating a 401 error and invalid API key handling'
      echo 'credentials expired in the fixture, session token invalid'
      kill -TERM $$
      sleep 5
      """)

      task = ready_task!(ws, "killed mid-auth-investigation")

      assert {:ok, %{worker_pid: pid}} = dispatch(task.id)
      eventually(fn -> Worker.state(pid).status == :failed end)

      reason = Worker.state(pid).meta.stop_reason
      assert reason.category == :killed
      assert reason.signal == 15

      assert_stays(fn -> reload(task).status == :in_progress end)
      assert AuthHold.status(Claude).deaths == 0
      refute CredentialWatchdog.expired?(Claude)
    end
  end

  describe "the hold (acceptance 1)" do
    test "N consecutive auth deaths refuse further dispatch without a worker or a worktree",
         %{ws: ws, tmp: tmp} do
      stub_claude!(tmp, @auth_stub)
      t1 = ready_task!(ws, "death 1")
      t2 = ready_task!(ws, "death 2")
      t3 = ready_task!(ws, "refused")

      assert {:ok, _} = dispatch(t1.id)
      eventually(fn -> reload(t1).status == :open end)
      refute AuthHold.open?(Claude)

      assert {:ok, _} = dispatch(t2.id)
      eventually(fn -> reload(t2).status == :open end)
      assert AuthHold.open?(Claude)

      assert {:error, {:auth_check_failed, reason}} = dispatch(t3.id)
      assert reason.category == :auth_expired
      assert reload(t3).status == :open
      assert Worker.whereis(t3.id) == nil
      refute File.dir?(Worktree.worktree_path(BranchNamer.derive(t3)))

      # The reopened tasks are refused just the same.
      assert {:error, {:auth_check_failed, _}} = dispatch(t1.id)
    end

    test "an operator reset lets dispatch through again", %{ws: ws, tmp: tmp} do
      put_app_env(:arbiter, :auth_hold, threshold: 1)
      stub_claude!(tmp, @auth_stub)
      task = ready_task!(ws, "reset me")

      assert {:ok, _} = dispatch(task.id)
      eventually(fn -> reload(task).status == :open end)
      assert AuthHold.open?(Claude)
      assert {:error, {:auth_check_failed, _}} = dispatch(task.id)

      assert {:ok, [Claude]} = AuthHold.reset(Claude)
      eventually(fn -> not CredentialWatchdog.expired?(Claude) end)

      stub_claude!(tmp, "#!/bin/sh\nsleep 5\n")
      assert {:ok, _} = dispatch(task.id)
    end
  end

  describe "no dispatch loop (acceptance 4)" do
    test "with credentials dead, Autopilot dispatches exactly N times and the queue survives",
         %{ws: ws, tmp: tmp} do
      stub_claude!(tmp, @auth_stub)
      tasks = for i <- 1..4, do: ready_task!(ws, "queued #{i}")
      test_pid = self()

      autopilot =
        start_supervised!(
          {Autopilot,
           name: nil,
           paused: false,
           interval_ms: :never,
           snapshot: fn opts ->
             Snapshot.load(Keyword.merge(opts, workspace_id: ws.id, slots_total: 4))
           end,
           dispatch: fn id ->
             send(test_pid, {:dispatch_attempt, id})
             dispatch(id)
           end}
        )

      outcomes =
        for _tick <- 1..10 do
          outcome = Autopilot.tick(autopilot, 30_000)

          # Let whatever just died settle (reopen + cleanup) before the next
          # tick reads the board, as a 15s tick would.
          eventually(fn -> Enum.all?(tasks, &(reload(&1).status == :open)) end, 10_000)
          eventually(fn -> Enum.all?(tasks, &(Worker.whereis(&1.id) == nil)) end, 10_000)
          outcome
        end

      attempts = drain_attempts()

      assert length(attempts) == AuthHold.threshold(),
             "expected exactly #{AuthHold.threshold()} dispatch attempts, got " <>
               "#{length(attempts)}: #{inspect(outcomes)}"

      assert AuthHold.open?(Claude)

      # Every later tick saw the hold on the board and never tried.
      assert Enum.count(outcomes, &match?({:ok, _}, &1)) == AuthHold.threshold()
      assert Enum.all?(Enum.drop(outcomes, AuthHold.threshold()), &(&1 == :idle))

      # Nothing burned: every task is back in Ready, none stranded.
      assert Enum.all?(tasks, &(reload(&1).status == :open))
      assert Snapshot.quota_hold(ws.id) |> elem(0) == :hold
    end
  end

  # ---- helpers --------------------------------------------------------------

  defp dispatch(id),
    do: Dispatch.dispatch(id, repo: "ad/repo", start_claude: true, interval_ms: 20)

  defp ready_task!(ws, title) do
    {:ok, task} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "It works."})

    {:ok, task} = Ash.update(task, %{}, action: :promote_to_ready)
    task
  end

  defp reload(task), do: Ash.get!(Issue, task.id)

  defp runs(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  defp branch_list(repo, branch) do
    {out, 0} = System.cmd("git", ["-C", repo, "branch", "--list", branch])
    String.trim(out)
  end

  defp drain_attempts(acc \\ []) do
    receive do
      {:dispatch_attempt, id} -> drain_attempts([id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp stub_claude!(tmp, script) do
    stub_dir = Path.join(tmp, "stub-bin")
    File.mkdir_p!(stub_dir)
    stub = Path.join(stub_dir, "claude")
    File.write!(stub, script)
    File.chmod!(stub, 0o755)

    old_path = System.get_env("PATH") || ""

    unless String.starts_with?(old_path, "#{stub_dir}:") do
      System.put_env("PATH", "#{stub_dir}:#{old_path}")
      on_exit(fn -> System.put_env("PATH", old_path) end)
    end

    :ok
  end

  defp seed_repo!(tmp, sub) do
    repo = Path.join(tmp, sub)
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "x\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

    remote = Path.join(tmp, sub <> "-remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])
    repo
  end

  defp eventually(fun, timeout_ms \\ 5_000, step_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, step_ms)
  end

  defp do_eventually(fun, deadline, step_ms) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("eventually/2 timed out")

      true ->
        Process.sleep(step_ms)
        do_eventually(fun, deadline, step_ms)
    end
  end

  # The negative of `eventually/2`: `fun` must hold for the whole window. Used
  # where the thing under test is that nothing happens.
  defp assert_stays(fun, window_ms \\ 500, step_ms \\ 25) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    do_stays(fun, deadline, step_ms)
  end

  defp do_stays(fun, deadline, step_ms) do
    assert fun.()

    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(step_ms)
      do_stays(fun, deadline, step_ms)
    end
  end
end
