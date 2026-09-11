defmodule Arbiter.Worker.ReviewGateFixRoundTest do
  @moduledoc """
  bd-a9zb7w / #1544: after a ReviewGate `request_changes` verdict, nothing
  dispatched the implementer to address the findings.

  The review itself ran fine — the gate burned its internal revise rounds,
  reported `{:request_changes, findings}` back to the author, and
  `park_rejected/3` recorded the run `:failed` with
  `failure_reason: :review_gate_rejected`. From there the task sat
  `:in_progress` with no live worker until a human ran `worker_resume`, which
  always worked immediately (7 occurrences over 2026-09-09/10). Nothing was
  structurally blocking the implementer; it simply was never scheduled.

  This is the mirror of bd-di4t6d / #1537, which re-dispatches the *reviewer*
  from `:awaiting_review`. Here the reviewer already ran and produced a verdict;
  the missing actor is the implementer.

  These tests pin the whole decision table of the auto fix round:

    * a `:request_changes` rejection dispatches a bounded fix round,
    * an inconclusive (`:no_verdict`) rejection does NOT,
    * the budget binds and escalates once instead of retrying forever,
    * an unchanged finding set (the gate said the same thing twice) is treated
      as converged and escalates rather than dispatching again,
    * a workspace can turn the whole thing off with `max_fix_rounds: 0`.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.StubFixRoundDispatcher
  alias Arbiter.Worker

  @findings "VERDICT: REQUEST_CHANGES\n- [high] feature.txt:1 needs a guard"
  @other_findings "VERDICT: REQUEST_CHANGES\n- [high] feature.txt:9 leaks a pid"

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    {_, 0} = git(["remote", "add", "origin", bare], repo)
    {_, 0} = git(["fetch", "-q", "origin"], repo)
    repo
  end

  defp seed_feature_branch(repo, branch) do
    {_, 0} = git(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "worker work\n")
    {_, 0} = git(["add", "feature.txt"], repo)
    {_, 0} = git(["commit", "-q", "-m", "feature work"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)
    :ok
  end

  defp wait_until(fun, timeout \\ 2_000) do
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
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  setup do
    StubFixRoundDispatcher.reset()

    tmp = Path.join(System.tmp_dir!(), "rg_fixround-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{repo: repo, tmp: tmp}
  end

  defp new_workspace(review_gate_config \\ %{}) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "fixround-ws-#{System.unique_integer([:positive])}",
        prefix: "fr",
        config: %{
          "review" => %{"required" => true},
          "review_gate" => review_gate_config
        }
      })

    ws
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "fix round task", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  # An author parked at :awaiting_review_gate with `review_spawn: false`, so a
  # verdict can be delivered directly (exactly as the gate would).
  defp start_parked_author(task, repo, extra_meta \\ %{}) do
    branch = "feature/fixround-#{System.unique_integer([:positive])}"
    :ok = seed_feature_branch(repo, branch)

    meta =
      Map.merge(
        %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        },
        extra_meta
      )

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: task.workspace_id,
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)
    pid
  end

  defp reject(pid, verdict \\ :request_changes, findings \\ @findings) do
    :ok = Worker.review_gate_verdict(pid, {verdict, findings})
    wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)
    :ok
  end

  describe "a REQUEST_CHANGES verdict" do
    test "auto-dispatches a bounded implementer fix round", %{repo: repo} do
      ws = new_workspace()
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      reject(pid)

      wait_until(fn -> StubFixRoundDispatcher.dispatch_count() == 1 end)

      assert [args] = StubFixRoundDispatcher.dispatches()
      assert args.task_id == task.id
      assert args.workspace_id == ws.id
      assert args.attempt == 1
      assert args.verdict == :request_changes
      assert args.findings =~ "needs a guard"
      assert is_binary(args.findings_digest)

      # No escalation: the fleet is self-healing, not paging.
      assert StubFixRoundDispatcher.escalations() == []
    end

    test "counts an already-used fix round and stops at the budget", %{repo: repo} do
      ws = new_workspace()
      task = new_task(ws)
      # A prior fix round already ran (the counter rides the worker's meta
      # across the resume, like :awaiting_review_resume_attempts).
      pid = start_parked_author(task, repo, %{review_gate_fix_round_attempts: 1})

      reject(pid, :request_changes, @other_findings)

      wait_until(fn -> StubFixRoundDispatcher.escalations() != [] end)

      assert StubFixRoundDispatcher.dispatch_count() == 0
      assert [{task_id, ws_id, 1, :budget_exhausted}] = StubFixRoundDispatcher.escalations()
      assert task_id == task.id
      assert ws_id == ws.id
    end

    test "treats an unchanged finding set as converged and escalates instead", %{repo: repo} do
      ws = new_workspace(%{"max_fix_rounds" => 3})
      task = new_task(ws)

      digest = Arbiter.Workflows.ReviewGateFixRoundDispatcher.findings_digest(@findings)

      pid =
        start_parked_author(task, repo, %{
          review_gate_fix_round_attempts: 1,
          review_gate_findings_digest: digest
        })

      reject(pid, :request_changes, @findings)

      wait_until(fn -> StubFixRoundDispatcher.escalations() != [] end)

      assert StubFixRoundDispatcher.dispatch_count() == 0
      assert [{_task_id, _ws_id, 1, :not_converging}] = StubFixRoundDispatcher.escalations()
    end

    test "a dispatch that cannot run escalates rather than silently parking", %{repo: repo} do
      ws = new_workspace()
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      StubFixRoundDispatcher.arm_dispatch_error(:no_outpost)

      reject(pid)

      wait_until(fn -> StubFixRoundDispatcher.escalations() != [] end)

      assert StubFixRoundDispatcher.dispatch_count() == 1

      assert [{_task_id, _ws_id, 0, {:dispatch_failed, :no_outpost}}] =
               StubFixRoundDispatcher.escalations()
    end

    test "a workspace can disable the fix round entirely with max_fix_rounds: 0",
         %{repo: repo} do
      ws = new_workspace(%{"max_fix_rounds" => 0})
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      reject(pid)

      # Nothing dispatched, and no second escalation on top of the ReviewGate's
      # own rejection page — an operator who turned this off asked for the
      # pre-bd-a9zb7w behaviour exactly.
      Process.sleep(120)
      assert StubFixRoundDispatcher.dispatch_count() == 0
      assert StubFixRoundDispatcher.escalations() == []
    end
  end

  describe "an inconclusive verdict" do
    test "does NOT dispatch a fix round", %{repo: repo} do
      ws = new_workspace()
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      reject(pid, :no_verdict, "reviewer crashed")

      assert Worker.state(pid).meta.failure_reason == :review_gate_inconclusive

      Process.sleep(120)
      assert StubFixRoundDispatcher.dispatch_count() == 0
      assert StubFixRoundDispatcher.escalations() == []
    end
  end
end
