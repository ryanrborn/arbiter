defmodule Arbiter.Board.DrainTest do
  @moduledoc """
  bd-9fgg04 / #1903: a paused scheduler must not look idle while it is still
  draining. `Drain.status/1` is the one definition of running / draining /
  quiescent that every surface reads.

  The load-bearing tests spawn real non-scheduler workers through their
  production entry points — `FixPassDispatcher.dispatch/1` and
  `ConflictResolver.resolve/1` (with `start_claude: false`, their documented
  test escape) — while the autopilot is paused, and assert both that the spawn
  still happens (a pause is not a freeze) and that the state is NOT quiescent.
  """

  # async: false — spawns workers under the global Arbiter.Worker.Supervisor and
  # flips :worktree_root / :repo_paths app env.
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Drain
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Workflows.MergeQueue.ConflictResolver
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  defp board(paused?, promote \\ nil) do
    %{
      ready: [],
      running: [],
      waiting: [],
      closed_today: [],
      promote: promote,
      slots_total: 4,
      slots_free: 4,
      quota: :ok,
      paused: paused?,
      now: DateTime.utc_now()
    }
  end

  defp start_autopilot!(opts) do
    defaults = [name: nil, interval_ms: :never, snapshot: fn o -> board(o[:paused]) end]
    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, opts))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    pid
  end

  # A private, empty stand-in for Arbiter.Worker.Supervisor, so a quiescence
  # assertion can't be tripped by another test's leftover worker.
  defp empty_supervisor! do
    name = :"drain_test_sup_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: name})
    name
  end

  describe "status/1 — the three states" do
    test "running: the autopilot is not paused" do
      ap = start_autopilot!(paused: false)

      status = Drain.status(autopilot: ap, supervisor: empty_supervisor!())

      assert status.state == :running
      assert status.paused == false
      refute status.safe_to_restart
    end

    test "quiescent: paused, and nothing of any kind is live" do
      ap = start_autopilot!(paused: true)

      status = Drain.status(autopilot: ap, supervisor: empty_supervisor!())

      assert status.state == :quiescent
      assert status.paused == true
      assert status.safe_to_restart
      assert status.in_flight == []
    end

    test "an unrecognised child of the worker supervisor is counted, not ignored (fail closed)" do
      ap = start_autopilot!(paused: true)
      sup = empty_supervisor!()
      {:ok, _pid} = DynamicSupervisor.start_child(sup, {Agent, fn -> nil end})

      status = Drain.status(autopilot: ap, supervisor: sup)

      assert status.state == :draining
      refute status.safe_to_restart
      assert [%{kind: :unclassified}] = status.in_flight
    end

    test "an autopilot promotion still in flight when the pause lands keeps it draining" do
      test_pid = self()

      dispatch = fn id ->
        send(test_pid, {:dispatching, id, self()})

        receive do
          :release -> {:ok, id}
        end
      end

      ap =
        start_autopilot!(
          paused: false,
          dispatch: dispatch,
          snapshot: fn o -> board(o[:paused], "bd-promo1") end
        )

      tick = Task.async(fn -> Autopilot.tick(ap, 10_000) end)
      assert_receive {:dispatching, "bd-promo1", dispatcher}, 5_000
      :ok = Autopilot.pause(ap, "test")

      status = Drain.status(autopilot: ap, supervisor: empty_supervisor!())

      assert status.state == :draining
      assert [%{task_id: "bd-promo1", kind: :board_promotion}] = status.in_flight

      send(dispatcher, :release)
      Task.await(tick, 10_000)

      assert Drain.status(autopilot: ap, supervisor: empty_supervisor!()).state == :quiescent
    end
  end

  describe "status/1 — worker classification" do
    test "a parked or terminal worker is not in flight; an active one is, with its kind" do
      ap = start_autopilot!(paused: true)
      id = "bd-drainkind#{System.unique_integer([:positive])}"

      {:ok, main} = Worker.start(task_id: id, repo: "r")
      on_exit(fn -> stop_quietly(main) end)

      {:ok, review} =
        Worker.start(
          task_id: id,
          registry_key: id <> "#review",
          repo: "r",
          meta: %{role: :reviewer},
          allow_concurrent_task_worker: true
        )

      on_exit(fn -> stop_quietly(review) end)

      mine = fn -> ap |> status_for(id) |> Enum.map(& &1.kind) |> Enum.sort() end
      assert mine.() == [:dispatch, :review_pass]

      # :idle → :completed is not a legal transition; run one step first.
      :ok = Worker.advance(main, :work)
      :ok = Worker.complete(main)
      assert mine.() == [:review_pass]
    end
  end

  describe "non-scheduler workers while paused (acceptance 4 + 7)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "drain-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)

      for args <- [
            ["init", "-q", "-b", "main", repo],
            ["-C", repo, "config", "user.email", "t@e.com"],
            ["-C", repo, "config", "user.name", "T"],
            ["-C", repo, "config", "commit.gpgsign", "false"]
          ] do
        {_, 0} = System.cmd("git", args)
      end

      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "drain-ws-#{System.unique_integer([:positive])}",
          prefix: "drn#{System.unique_integer([:positive])}"
        })

      {:ok, task} = Ash.create(Issue, %{title: "drain me", workspace_id: ws.id})
      {_, 0} = System.cmd("git", ["-C", repo, "branch", BranchNamer.derive(task)])

      ap = start_autopilot!(paused: true)
      %{ws: ws, task: task, repo: repo, ap: ap}
    end

    test "a CI fix_pass still dispatches while paused, and the state is NOT quiescent",
         %{ws: ws, task: task, repo: repo, ap: ap} do
      assert Autopilot.paused?(ap)

      assert {:ok, %{worker_pid: pid}} =
               FixPassDispatcher.dispatch(%{
                 task_id: task.id,
                 workspace_id: ws.id,
                 repo_path: repo,
                 repo: "test/repo",
                 checks: [],
                 start_claude: false
               })

      on_exit(fn -> stop_quietly(pid) end)

      status = Drain.status(autopilot: ap)

      assert status.paused
      assert status.state == :draining
      refute status.safe_to_restart

      assert [%{kind: :fix_pass, registry_key: key, pid: ^pid}] = status_for(ap, task.id)
      assert key == task.id <> ":fixpass"
    end

    test "a MergeQueue conflict resolver still spawns while paused, and the state is NOT quiescent",
         %{ws: ws, task: task, repo: repo, ap: ap} do
      assert {:ok, %{worker_pid: pid}} =
               ConflictResolver.resolve(%{
                 task_id: task.id,
                 workspace_id: ws.id,
                 repo_path: repo,
                 repo: "test/repo",
                 start_claude: false
               })

      on_exit(fn -> stop_quietly(pid) end)

      status = Drain.status(autopilot: ap)

      assert status.state == :draining
      refute status.safe_to_restart
      assert [%{kind: :conflict_resolver, pid: ^pid}] = status_for(ap, task.id)
    end
  end

  describe "to_json/1" do
    test "renders the state, the safe-to-restart verdict and each in-flight entry" do
      ap = start_autopilot!(paused: true)
      sup = empty_supervisor!()
      {:ok, _pid} = DynamicSupervisor.start_child(sup, {Agent, fn -> nil end})

      json = [autopilot: ap, supervisor: sup] |> Drain.status() |> Drain.to_json()

      assert %{
               state: "draining",
               paused: true,
               safe_to_restart: false,
               in_flight: [%{kind: "unclassified", task_id: nil}]
             } = json

      assert Jason.encode!(json)
    end
  end

  defp status_for(ap, task_id) do
    Drain.status(autopilot: ap).in_flight |> Enum.filter(&(&1.task_id == task_id))
  end

  defp stop_quietly(pid),
    do: Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, pid)
end
