defmodule Arbiter.Worker.ReviewGateEmptyNetDiffTest do
  @moduledoc """
  bd-aq81qz: a PR/branch with commits ahead of its base but a **zero net diff**
  against it must not get a clean ReviewGate APPROVE that proceeds to merge.

  The exact incident shape (bd-96mn8i / PR #1957): a task was redispatched onto
  its OLD branch, whose commits had already been squashed onto main. The worker
  added no new commits and merged main in. `base_sha != head_sha` (there is a
  merge commit), so G2's `empty_diff_guard/1` (SHA equality) never fires — but
  `git diff base_sha..HEAD` is empty because the trees are identical. The
  reviewer saw nothing wrong and APPROVEd; only a `review-coverage write
  failed: :no_net_diff` warning marked the miss.

  This reproduces that git shape for real (a genuine merge commit, not a SHA
  collision) and asserts the gate parks `:empty_net_diff` instead of merging.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Reviews.Coverage.Entry
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  @reviewer Path.expand("../../fixtures/review_verdict.sh", __DIR__)

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

  # The bd-96mn8i shape: a feature branch whose content is later (independently)
  # squashed onto main, then merged back into the feature branch. HEAD moves
  # (a real merge commit) but contributes nothing against the new main.
  defp seed_already_squashed_branch(repo, branch) do
    {_, 0} = git(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "squashed content\n")
    {_, 0} = git(["add", "feature.txt"], repo)
    {_, 0} = git(["commit", "-q", "-m", "old feature work"], repo)

    {_, 0} = git(["checkout", "-q", "main"], repo)
    File.write!(Path.join(repo, "feature.txt"), "squashed content\n")
    {_, 0} = git(["add", "feature.txt"], repo)
    {_, 0} = git(["commit", "-q", "-m", "already squashed onto main"], repo)
    {_, 0} = git(["push", "-q", "origin", "main"], repo)

    {_, 0} = git(["checkout", "-q", branch], repo)
    {_, 0} = git(["merge", "main", "-q", "-m", "merge main into #{branch}"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)
    :ok
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

  defp merge_commit_count_on_main(repo) do
    {out, 0} = git(["log", "--oneline", "--merges", "main"], repo)
    out |> String.split("\n", trim: true) |> length()
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "empty net diff task", workspace_id: ws.id, issue_type: :bug})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  defp coverage_rows(task_id) do
    Entry
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
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
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "rg-empty-net-diff-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-empty-net-diff-#{System.unique_integer([:positive])}",
        prefix: "en",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws, tmp: tmp}
  end

  test "commits ahead of base but zero net diff: parks :empty_net_diff instead of approving",
       %{repo: repo, ws: ws, tmp: tmp} do
    branch = "bugfix/already-squashed"
    :ok = seed_already_squashed_branch(repo, branch)
    wt = branch_worktree(repo, tmp, branch)

    task = new_task(ws)

    {base_out, 0} = git(["rev-parse", "main"], repo)
    {head_out, 0} = git(["rev-parse", branch], repo)
    base_sha = String.trim(base_out)
    head_sha = String.trim(head_out)
    assert base_sha != head_sha, "the branch must carry a real commit ahead of base"

    {out, 0} = git(["diff", "#{base_sha}..#{head_sha}"], repo)
    assert String.trim(out) == "", "test setup sanity: the net diff must be empty"

    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta: %{
          branch: branch,
          repo_path: repo,
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

    {:ok, _gate} =
      Worker.ReviewGate.start(
        author: author,
        task_id: task.id,
        workspace_id: ws.id,
        repo: "trib/repo",
        worktree_path: wt,
        branch: branch,
        target_branch: "main",
        command: [@reviewer, "APPROVE"],
        timeout_ms: 10_000
      )

    wait_until(fn -> match?(%{status: :failed}, Worker.state(author)) end, 15_000)

    parked = Ash.get!(Issue, task.id)
    assert parked.review_park_reason == "empty_net_diff"

    # Content stays fail-closed: no coverage row, no stamp, no merge.
    assert coverage_rows(task.id) == []
    assert is_nil(parked.last_reviewed_sha)
    assert merge_commit_count_on_main(repo) == 0
  end
end
