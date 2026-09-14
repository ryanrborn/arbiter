defmodule Arbiter.Worker.ReviewGateParkTest do
  @moduledoc """
  Guard class C applied to the ReviewGate's terminal paths (design #1635 §5.3,
  phase P9 / bd-9zuvbh).

  `:review_gate_inconclusive` alone accounted for 52 failed runs / $226.97 in 31
  days, and every one of chain B's four incidents ended the same way: **a failed
  run on work that was fine**. Class C splits the gate's two questions:

    * *"Should this APPROVE merge?"* stays **fail-closed** — a malformed or
      guard-rejected APPROVE is still never merged and never recorded approved.
    * *"Should this run be marked failed?"* now **fails open** — a terminal
      no-verdict state parks the task and pages the coordinator once instead of
      writing `Run.status = :failed` on work nobody has found a problem with.

  These tests pin the Worker half of that split: the durable run row, the park
  stamped on the task, the single escalation, and the one outcome that must
  still fail — a genuine REQUEST_CHANGES at the round cap.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.StubFixRoundDispatcher
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  @findings "VERDICT: REQUEST_CHANGES\n- [high] feature.txt:1 needs a guard"

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

  defp merge_commit_count(repo) do
    {out, 0} = git(["log", "--oneline", "--merges", "main"], repo)
    out |> String.split("\n", trim: true) |> length()
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

    tmp = Path.join(System.tmp_dir!(), "rg_park-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "park-ws-#{System.unique_integer([:positive])}",
        prefix: "pk",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws}
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "park task", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  # An author parked at `:awaiting_review_gate` with `review_spawn: false`, so a
  # verdict can be handed to it directly — exactly as the gate would.
  defp start_parked_author(task, repo) do
    branch = "feature/park-#{System.unique_integer([:positive])}"
    :ok = seed_feature_branch(repo, branch)

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: task.workspace_id,
        meta: %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)
    pid
  end

  defp deliver(pid, verdict) do
    :ok = Worker.review_gate_verdict(pid, verdict)
    wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)
    :ok
  end

  defp run_for(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
    |> List.first()
  end

  defp reload(task), do: Ash.get!(Issue, task.id)

  defp escalations(ws, task) do
    "admiral"
    |> Message.inbox(workspace_id: ws.id)
    |> Enum.filter(&(&1.directive_ref == task.id and &1.kind == :escalation))
  end

  describe "a terminal no-verdict outcome (AC1, AC2)" do
    test "records the run as :review_parked rather than :failed", %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      deliver(pid, {:no_verdict, "Reviewer produced no parseable VERDICT line."})

      run = run_for(task.id)
      assert run.status == :review_parked

      # The FSM status is untouched: `Dispatch.resume/2` and the Watchdog's
      # bounded auto-resume both require a terminal worker (the C4 shape).
      assert Worker.state(pid).status == :failed
      assert Worker.state(pid).meta.failure_reason == :review_gate_inconclusive
    end

    test "parks the task with a named, visible reason", %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      deliver(pid, {:parked, :reviewer_timeout, "ReviewGate reviewing pass timed out"})

      parked = reload(task)
      assert parked.review_park_reason == "reviewer_timeout"
      assert %DateTime{} = parked.review_parked_at
    end

    test "escalates to the coordinator exactly once per episode", %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      deliver(pid, {:parked, :inconclusive, "no parseable VERDICT line"})

      assert [one] = escalations(ws, task)
      assert one.subject =~ "parked"

      # A second report of the same episode must not page again.
      Worker.review_gate_verdict(pid, {:parked, :inconclusive, "no parseable VERDICT line"})
      Process.sleep(50)

      assert length(escalations(ws, task)) == 1
    end

    test "never merges the branch (content stays fail-closed, AC3)", %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      deliver(pid, {:parked, :verdict_guard_exhausted, "VERDICT: APPROVE\nbut F1.1 is open"})

      assert merge_commit_count(repo) == 0
      refute Worker.state(pid).meta.review_gate_verdict == :approve
    end

    test "a guard-rejected APPROVE does not dispatch another fix round", %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      deliver(pid, {:parked, :verdict_guard_exhausted, "VERDICT: APPROVE\nbut F1.1 is open"})
      Process.sleep(50)

      assert StubFixRoundDispatcher.dispatch_count() == 0
    end
  end

  describe "every park reason, one per path (AC1)" do
    # AC1 is a statement about the whole terminal surface, not about four
    # examples: no ReviewGate outcome with an approving or no-verdict result may
    # write `Run.status = :failed`. The reasons below are exactly
    # `ReviewPark.reasons/0`, so a new class-C terminal that forgets to park
    # fails here rather than quietly costing a run.
    for {reason, _explanation} <- Arbiter.Tasks.ReviewPark.reasons() do
      @reason reason

      test "#{reason} parks the run and never merges", %{repo: repo, ws: ws} do
        task = new_task(ws)
        pid = start_parked_author(task, repo)

        deliver(pid, {:parked, @reason, "VERDICT: APPROVE\nterminal reached: #{@reason}"})

        assert run_for(task.id).status == :review_parked
        assert reload(task).review_park_reason == Atom.to_string(@reason)
        assert merge_commit_count(repo) == 0
        assert [_exactly_one] = escalations(ws, task)
      end
    end

    test "the ReviewGate dying before a verdict parks too", %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      # The `{:DOWN, …}` arm the author uses when the gate process exits without
      # reporting (bd-2y0gd5) routes through `{:no_verdict, …}`.
      deliver(pid, {:no_verdict, "ReviewGate process exited before delivering a verdict."})

      assert run_for(task.id).status == :review_parked
      assert reload(task).review_park_reason == "inconclusive"
    end
  end

  describe "a genuine REQUEST_CHANGES (AC1)" do
    test "still fails the run and does not park the task", %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      deliver(pid, {:request_changes, @findings})

      run = run_for(task.id)
      assert run.status == :failed
      assert Worker.state(pid).meta.failure_reason == :review_gate_rejected

      assert reload(task).review_park_reason == nil
    end
  end

  describe "clearing the park (AC4)" do
    test "closing the task clears it", %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      deliver(pid, {:parked, :inconclusive, "no parseable VERDICT line"})
      assert reload(task).review_park_reason == "inconclusive"

      {:ok, closed} = Ash.update(reload(task), %{}, action: :close)

      assert closed.review_park_reason == nil
      assert closed.review_parked_at == nil
    end

    test "re-running the review clears it", %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      deliver(pid, {:parked, :inconclusive, "no parseable VERDICT line"})
      assert reload(task).review_park_reason == "inconclusive"

      assert {:ok, cleared} = Arbiter.Tasks.ReviewPark.clear(task.id, :review_rerun)
      assert cleared.review_park_reason == nil
    end

    test "Issue.review_parked/1 lists parked tasks for arb prime", %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      deliver(pid, {:parked, :inconclusive, "no parseable VERDICT line"})

      assert [listed] = Issue.review_parked(workspace_id: ws.id)
      assert listed.id == task.id
      assert listed.review_park_reason == "inconclusive"
    end
  end

  describe "the park is one decision wide" do
    test "a later round approving clears the park and reconciles the run forward",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      deliver(pid, {:parked, :inconclusive, "no parseable VERDICT line"})
      assert reload(task).review_park_reason == "inconclusive"

      # bd-3wumco: the same gate's next round converges. The worker is at
      # :failed; the approval reconciles it forward and must take the park with
      # it, or the merged task keeps showing up in `arb prime`.
      :ok = Worker.review_gate_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})

      assert reload(task).review_park_reason == nil
      assert reload(task).review_parked_at == nil
      refute Map.has_key?(Worker.state(pid).meta, :review_park_reason)
    end
  end

  test ":review_parked is a valid run status" do
    assert :review_parked in Run.statuses()
  end
end
