defmodule Arbiter.Worker.WatchdogAutoResumeIntegrationTest do
  @moduledoc """
  End-to-end proof of the bd-8eheb6 auto-resume loop with the REAL
  `Arbiter.Workflows.MergeQueue.AutoResumeDispatcher` wired into a REAL
  `Arbiter.Worker.Watchdog` — no stub dispatcher anywhere.

  `Arbiter.Worker.WatchdogTest` pins the Watchdog's *decisions* against a stub;
  this pins the *wiring* between the three real modules a stub necessarily hides:

    * Watchdog timeout -> real `AutoResumeDispatcher.resume/1` ->
      real `Arbiter.Worker.Dispatch.resume/2` -> a real worker on the real,
      preserved worktree carrying the re-stamped attempt counter;
    * the give-up legs -> real `escalate_exhausted/5` -> a real `:escalation`
      row in the coordinator's mailbox.
  """
  # async: false — shares the singleton Worker registry/supervisor, the named
  # StubMerger Agent, and VM-global app env (:worktree_root / :repo_paths).
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.{Dispatch, Watchdog}
  alias Arbiter.Workflows.MergeQueue.AutoResumeDispatcher

  require Ash.Query

  # A harmless stand-in for the agent subprocess. The dispatcher's documented
  # `:claude_command` escape hatch (same one ConflictResolver/FixPassDispatcher
  # carry) — everything else on the path is production code.
  @fake_agent ["sleep", "2"]

  setup do
    StubMerger.reset()

    tmp = Path.join(System.tmp_dir!(), "wd-autoresume-#{:erlang.unique_integer([:positive])}")
    repo = Path.join(tmp, "source")
    File.mkdir_p!(repo)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

    remote = Path.join(tmp, "remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

    worktree_root = Path.join(tmp, "worktrees")
    File.mkdir_p!(worktree_root)

    put_app_env(:arbiter, :worktree_root, worktree_root)
    put_app_env(:arbiter, :repo_paths, %{"ar/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "wd-autoresume-#{System.unique_integer([:positive])}",
        prefix: "ar"
      })

    {:ok, ws: ws}
  end

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(25)
        do_wait(fun, deadline)
    end
  end

  # A task with a real, dispatched worker sitting on a real provisioned
  # worktree — the state `Dispatch.resume/2` is built to recover from.
  defp task_with_outpost(ws, title \\ "auto-resume e2e") do
    {:ok, task} = Ash.create(Issue, %{title: title, workspace_id: ws.id})

    {:ok, first} = Dispatch.dispatch(task.id, repo: "ar/repo", start_driver: false)
    assert is_binary(first.worktree_path)

    on_exit(fn -> if Process.alive?(first.worker_pid), do: Worker.stop(first.worker_pid) end)

    {task, first}
  end

  # The real Watchdog, wired to the real dispatcher, with a poll budget small
  # enough that it times out immediately. Only the forge adapter is a stub —
  # there is no real GitLab to poll.
  defp start_watchdog(worker_pid, task_id, mr_ref, ws, opts) do
    base = [
      task_id: task_id,
      worker: worker_pid,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: ws,
      auto_merge: true,
      interval_ms: 10,
      initial_delay_ms: 0,
      max_polls: 2,
      auto_resume_dispatcher: AutoResumeDispatcher
    ]

    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> if Process.alive?(wpid), do: GenServer.stop(wpid, :normal) end)
    wpid
  end

  defp escalations(ws) do
    Message
    |> Ash.Query.filter(workspace_id == ^ws.id and kind == :escalation)
    |> Ash.read!()
  end

  describe "the real resume leg" do
    test "re-attaches a real worker to the preserved worktree and re-stamps the counter",
         %{ws: ws} do
      {task, first} = task_with_outpost(ws)

      # The Watchdog fails the timed-out worker before resuming it; do the same
      # so this exercises resume/1 from exactly the state it sees in production.
      :ok = Worker.fail(first.worker_pid, {:awaiting_review_timeout, 30})

      assert {:ok, result} =
               AutoResumeDispatcher.resume(%{
                 task_id: task.id,
                 attempt: 1,
                 workspace_id: ws.id,
                 mr_ref: "!e2e-1",
                 claude_command: @fake_agent
               })

      on_exit(fn -> if Process.alive?(result.worker_pid), do: Worker.stop(result.worker_pid) end)

      # A resume, not a fresh dispatch: same worktree, new worker.
      assert result.worktree_path == first.worktree_path
      assert result.worker_pid != first.worker_pid

      snap = Worker.state(result.worker_pid)
      assert snap.meta[:resume] == true

      # The load-bearing assertion. Without this re-stamp the NEXT Watchdog
      # episode would read 0, the cap would never bind, and a never-converging
      # review would auto-resume forever.
      assert snap.meta[:awaiting_review_resume_attempts] == 1

      # Self-healing means silent: no coordinator page for an in-budget resume.
      assert escalations(ws) == []
    end
  end

  describe "the real Watchdog driving the real dispatcher" do
    test "a spent budget escalates to the real coordinator mailbox instead of resuming",
         %{ws: ws} do
      # 3 auto-resumes already spent against the default cap of 3.
      {task, first} = task_with_outpost(ws, "budget spent")
      :ok = Worker.report(first.worker_pid, :awaiting_review_resume_attempts, 3)

      start_watchdog(first.worker_pid, task.id, "!e2e-2", ws, [])

      wait_until(fn -> Worker.state(first.worker_pid).status == :failed end)
      wait_until(fn -> escalations(ws) != [] end)

      # The timeout is still recorded on the run — worker_show must still say so.
      assert Worker.state(first.worker_pid).meta.failure_reason ==
               {:awaiting_review_timeout, 2}

      # No fourth resume: the same worker is still the registered one.
      assert Worker.whereis(task.id) == first.worker_pid

      exhausted = Enum.find(escalations(ws), &(&1.subject =~ "auto-resume exhausted"))
      assert exhausted, "expected an auto-resume-exhausted escalation in the coordinator inbox"
      assert exhausted.subject =~ "after 3 attempts"
      assert exhausted.task_ref == task.id
      assert exhausted.to_ref == Message.coordinator_ref()
      assert exhausted.body =~ "NOT a fresh failure"
      assert exhausted.body =~ "!e2e-2"
    end

    test "a resume that cannot run escalates with the real reason, not a bogus exhaustion",
         %{ws: ws} do
      {task, first} = task_with_outpost(ws, "worktree gone")

      # The worktree was cleaned up out from under the task, so the real
      # Dispatch.resume/2 has nothing to re-attach to: {:error, :no_outpost}.
      File.rm_rf!(first.worktree_path)

      start_watchdog(first.worker_pid, task.id, "!e2e-3", ws, [])

      wait_until(fn -> Worker.state(first.worker_pid).status == :failed end)
      wait_until(fn -> escalations(ws) != [] end)

      failed = Enum.find(escalations(ws), &(&1.subject =~ "auto-resume FAILED"))

      assert failed,
             "expected a resume-failed escalation, got: #{inspect(Enum.map(escalations(ws), & &1.subject))}"

      # Budget was still available — this must NOT read as "we tried 3 times".
      assert failed.subject =~ "after 0 attempts"
      assert failed.body =~ "no_outpost"
      assert failed.body =~ "fresh dispatch is needed rather than a resume"
      assert failed.task_ref == task.id
    end
  end
end
