defmodule Arbiter.Worker.ReviewGateDeltaScopeTest do
  @moduledoc """
  P7 (bd-60r6wp / #1738) — `docs/review-coverage-and-guard-policy.md` §4.5,
  acceptance 3: when a post-approval push authored content, the review round
  it routes to is scoped to the delta since the last covered commit — the
  `S2..S3` compare — not a full re-review, and the round's APPROVE writes the
  coverage row that lets the new head merge.

  Driven against a real git worktree: the approved commit A and the fix-pass
  commit B each add a distinctive line, so "the reviewer prompt contains only
  the delta" is a literal string check on what the reviewer is handed.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Reviews.Coverage
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate

  @reviewer Path.expand("../../fixtures/review_verdict.sh", __DIR__)

  # Only in the approved commit A.
  @approved_line "approved_work_marker_7f3a"
  # Only in the post-approval fix-pass commit B.
  @delta_line "fixpass_delta_marker_91c2"

  setup do
    tmp = Path.join(System.tmp_dir!(), "rg-delta-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-delta-#{System.unique_integer([:positive])}",
        prefix: "rd",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws, tmp: tmp}
  end

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

  defp commit(repo, file, content, message) do
    File.write!(Path.join(repo, file), content)
    {_, 0} = git(["add", file], repo)
    {_, 0} = git(["commit", "-q", "-m", message], repo)
    sha(repo, "HEAD")
  end

  defp sha(repo, ref) do
    {out, 0} = git(["rev-parse", ref], repo)
    String.trim(out)
  end

  # A on the feature branch (approved), then B on top of it (the fix pass).
  defp seed_branch(repo, branch) do
    {_, 0} = git(["checkout", "-q", "-b", branch], repo)
    approved = commit(repo, "feature.ex", "#{@approved_line}\n", "feature work")
    pushed = commit(repo, "lint.ex", "#{@delta_line}\n", "credo fix after approval")
    {_, 0} = git(["checkout", "-q", "main"], repo)
    {approved, pushed}
  end

  defp branch_worktree(repo, tmp, branch) do
    wt = Path.join(tmp, "wt-#{:erlang.unique_integer([:positive])}")

    {_, 0} =
      System.cmd("git", ["worktree", "add", "-q", wt, branch], cd: repo, stderr_to_stdout: true)

    on_exit(fn ->
      _ = System.cmd("git", ["-C", repo, "worktree", "remove", "--force", wt])
      File.rm_rf!(wt)
    end)

    wt
  end

  defp record_reviewed(task, mr_ref, head) do
    {:ok, _} =
      Coverage.record(%{
        task_id: task.id,
        mr_ref: mr_ref,
        head_sha: head,
        base_ref: "main",
        net_diff_id: "fp-#{head}",
        kind: :reviewed,
        source: :review_gate,
        round: 1
      })
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "delta task", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  # A reviewer that takes a moment before approving, so the pass's prompt can
  # be read off the gate while it is in flight.
  defp slow_reviewer, do: ["sh", "-c", "sleep 1; exec \"$0\" APPROVE", @reviewer]

  defp start_gate(task, ws, wt, branch, pr_ref) do
    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta: %{
          branch: branch,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
    :ok = Worker.advance(author, :claude)
    send(author, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(author)) end)

    {:ok, gate} =
      ReviewGate.start(
        author: author,
        task_id: task.id,
        workspace_id: ws.id,
        repo: "trib/repo",
        worktree_path: wt,
        branch: branch,
        target_branch: "main",
        pr_ref: pr_ref,
        command: slow_reviewer(),
        timeout_ms: 20_000
      )

    gate
  end

  defp prompt_of(gate) do
    wait_until(fn -> is_binary(:sys.get_state(gate).current_prompt) end)
    :sys.get_state(gate).current_prompt
  end

  defp wait_until(fun, timeout \\ 10_000) do
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

  test "a head that descends from a covered commit is reviewed as the delta only, and its APPROVE covers the new head",
       %{repo: repo, ws: ws, tmp: tmp} do
    branch = "feature/delta"
    {approved, pushed} = seed_branch(repo, branch)
    wt = branch_worktree(repo, tmp, branch)
    task = new_task(ws)
    record_reviewed(task, "owner/repo#77", approved)

    gate = start_gate(task, ws, wt, branch, "owner/repo#77")
    prompt = prompt_of(gate)

    # The delta, and only the delta.
    assert prompt =~ @delta_line
    refute prompt =~ @approved_line
    assert prompt =~ "#{approved}..HEAD"
    assert prompt =~ "DELTA REVIEW"
    # None of the whole-branch instructions a full review hands out.
    refute prompt =~ "gh pr diff"
    refute prompt =~ ~r/git diff [0-9a-f]{40}\.\.HEAD/

    # The round's APPROVE is what makes the new head mergeable: a :reviewed
    # row for the fix-pass head.
    wait_until(fn -> Enum.any?(Coverage.for_mr("owner/repo#77"), &(&1.head_sha == pushed)) end)

    assert [%{kind: :reviewed, source: :review_gate}] =
             Enum.filter(Coverage.for_mr("owner/repo#77"), &(&1.head_sha == pushed))
  end

  test "with no coverage on the PR the gate reviews the whole branch, exactly as before",
       %{repo: repo, ws: ws, tmp: tmp} do
    branch = "feature/full"
    {_approved, _pushed} = seed_branch(repo, branch)
    wt = branch_worktree(repo, tmp, branch)
    task = new_task(ws)

    gate = start_gate(task, ws, wt, branch, "owner/repo#78")
    prompt = prompt_of(gate)

    refute prompt =~ "DELTA REVIEW"
    assert prompt =~ "gh pr diff 78"
    assert prompt =~ ~r/git diff [0-9a-f]{40}\.\.HEAD/
  end

  test "a covered commit that is not an ancestor of the head (a rebase) does not scope the review",
       %{repo: repo, ws: ws, tmp: tmp} do
    branch = "feature/rebased"
    {_approved, _pushed} = seed_branch(repo, branch)
    wt = branch_worktree(repo, tmp, branch)
    task = new_task(ws)

    # Coverage names a commit this branch does not contain — the shape a
    # conflict resolver's rebase leaves: the delta is not a range of commits.
    {_, 0} = git(["checkout", "-q", "-b", "elsewhere", "main"], repo)
    orphan = commit(repo, "other.ex", "unrelated\n", "somewhere else")
    {_, 0} = git(["checkout", "-q", "main"], repo)
    record_reviewed(task, "owner/repo#79", orphan)

    gate = start_gate(task, ws, wt, branch, "owner/repo#79")
    prompt = prompt_of(gate)

    refute prompt =~ "DELTA REVIEW"
    assert prompt =~ ~r/git diff [0-9a-f]{40}\.\.HEAD/
  end
end
