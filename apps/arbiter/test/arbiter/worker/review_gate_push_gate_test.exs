defmodule Arbiter.Worker.ReviewGatePushGateTest do
  @moduledoc """
  bd-2jkrqu / #1701 — the ReviewGate reviewed the worker's LOCAL head, not the
  pushed PR head.

  vs-5l45oz (vstim MR !228), 2026-09-15: round 1 said REQUEST_CHANGES; the fix
  round committed `edadf22c` in the worktree and never pushed; origin and the
  MR's pipeline stayed on the unfixed `8deed4e5`. Round 2 read the **local**
  worktree, marked every finding `[ADDRESSED]` citing lines that only existed
  locally, and APPROVED. The park escalation then said "the work is committed
  and the branch is pushed … merge it by hand, if the diff is fine" — a human
  following it would have merged the unfixed commit. Two days earlier
  (vs-bdrbp0) a timed-out fix round left sixteen commits unpushed.

  What is pinned here, against real git repos with a real bare origin:

    * **AC1** — no review round runs against a head that is not on the remote
      branch. Round 1 and the fix round's re-review both push first; a head
      that *cannot* be pushed (diverged) parks `:head_not_pushed` and the
      reviewer is never paid for.
    * **AC2** — the reviewed-SHA stamp and the `review_coverage` row only ever
      name a head the remote carries.
    * **AC3** — the park escalation states the push state it *checked*, and
      withholds "merge it by hand" when the PR head is not the reviewed head.

  The reviewer fixture (`review_push_check.sh`) encodes the push state it saw
  in its own verdict, so a regression shows up as a REQUEST_CHANGES rather
  than as a test that passes for the wrong reason.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.CircuitBreaker
  alias Arbiter.Messages.Message
  alias Arbiter.Reviews.Coverage.Entry
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate

  @push_check Path.expand("../../fixtures/review_push_check.sh", __DIR__)
  @commit_then_approve Path.expand("../../fixtures/review_commit_then_approve.sh", __DIR__)
  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "rg-push-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-push-#{System.unique_integer([:positive])}",
        prefix: "rp",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws, tmp: tmp}
  end

  # ---- git rig -------------------------------------------------------------

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  defp git!(args, repo), do: {_, 0} = git(args, repo)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    git!(["config", "user.email", "repo@example.com"], repo)
    git!(["config", "user.name", "Repo"], repo)
    git!(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    git!(["add", "README.md"], repo)
    git!(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    git!(["remote", "add", "origin", bare], repo)
    git!(["fetch", "-q", "origin"], repo)
    repo
  end

  defp seed_feature_branch(repo, branch) do
    git!(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "worker work\n")
    git!(["add", "feature.txt"], repo)
    git!(["commit", "-q", "-m", "feature work"], repo)
    git!(["checkout", "-q", "main"], repo)
    :ok
  end

  defp branch_worktree(repo, tmp, branch) do
    wt = Path.join(tmp, "wt-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", wt, branch], cd: repo)
    git!(["config", "user.email", "wt@example.com"], wt)
    git!(["config", "user.name", "WT"], wt)
    git!(["config", "commit.gpgsign", "false"], wt)

    on_exit(fn ->
      _ = System.cmd("git", ["-C", repo, "worktree", "remove", "--force", wt])
      File.rm_rf!(wt)
    end)

    wt
  end

  defp sha(repo, ref) do
    case git(["rev-parse", ref], repo) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp commit_in(wt, name, body) do
    File.write!(Path.join(wt, name), body)
    git!(["add", name], wt)
    git!(["commit", "-q", "-m", "local #{name}"], wt)
    sha(wt, "HEAD")
  end

  # ---- app rig -------------------------------------------------------------

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "push-gate task", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  defp start_author(task, ws, repo, branch, wt) do
    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta: %{
          branch: branch,
          repo_path: repo,
          worktree_path: wt,
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
    author
  end

  defp start_gate(author, task, ws, branch, wt, opts) do
    {:ok, gate} =
      ReviewGate.start(
        [
          author: author,
          task_id: task.id,
          workspace_id: ws.id,
          repo: "trib/repo",
          worktree_path: wt,
          branch: branch,
          target_branch: "main",
          timeout_ms: 15_000
        ] ++ opts
      )

    gate
  end

  defp coverage_rows(task_id) do
    Entry |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
  end

  defp escalations(ws, task) do
    Message
    |> Ash.Query.filter(workspace_id == ^ws.id and kind == :escalation)
    |> Ash.read!()
    |> Enum.filter(&(&1.task_ref == task.id))
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
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end

  # ---- AC1: no round reviews an unpushed head ------------------------------

  describe "round start (AC1)" do
    test "a branch origin has never seen is pushed before the reviewer reads it",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      branch = "feature/push-1"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      head = sha(wt, "HEAD")

      assert sha(repo, "origin/" <> branch) == nil

      author = start_author(task, ws, repo, branch, wt)
      start_gate(author, task, ws, branch, wt, command: [@push_check, branch, "ROUND1"])

      # The fixture only APPROVEs when the head it read is on origin/<branch>,
      # and only an APPROVE stamps the reviewed SHA.
      wait_until(fn -> Ash.get!(Issue, task.id).last_reviewed_sha == head end, 20_000)

      git!(["fetch", "-q", "origin"], repo)
      assert sha(repo, "origin/" <> branch) == head
    end

    test "a local commit ahead of origin (the vs-5l45oz shape) is pushed before review",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      branch = "feature/push-2"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      stale = sha(wt, "HEAD")

      # The unpushed fix-round commit.
      local = commit_in(wt, "fix.txt", "the fix the MR never got\n")
      refute local == stale

      author = start_author(task, ws, repo, branch, wt)
      start_gate(author, task, ws, branch, wt, command: [@push_check, branch, "ROUND1"])

      wait_until(fn -> Ash.get!(Issue, task.id).last_reviewed_sha == local end, 20_000)

      git!(["fetch", "-q", "origin"], repo)
      assert sha(repo, "origin/" <> branch) == local
    end

    test "a head that cannot be pushed parks :head_not_pushed and never pays for a reviewer",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      branch = "feature/push-3"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      base = sha(wt, "HEAD")

      # Someone else advances origin/<branch>; this worktree rewrites its own
      # tip. The branches have genuinely diverged, so a push would clobber.
      other = Path.join(tmp, "other")
      {_, 0} = System.cmd("git", ["clone", "-q", Path.join(tmp, "origin.git"), other])
      git!(["config", "user.email", "o@example.com"], other)
      git!(["config", "user.name", "O"], other)
      git!(["config", "commit.gpgsign", "false"], other)
      git!(["checkout", "-q", branch], other)
      File.write!(Path.join(other, "theirs.txt"), "theirs\n")
      git!(["add", "theirs.txt"], other)
      git!(["commit", "-q", "-m", "theirs"], other)
      git!(["push", "-q", "origin", branch], other)
      theirs = sha(other, "HEAD")

      git!(["reset", "-q", "--hard", base], wt)
      mine = commit_in(wt, "mine.txt", "mine\n")

      author = start_author(task, ws, repo, branch, wt)
      start_gate(author, task, ws, branch, wt, command: [@push_check, branch, "ROUND1"])

      wait_until(fn -> Ash.get!(Issue, task.id).review_park_reason != nil end, 20_000)

      assert Ash.get!(Issue, task.id).review_park_reason == "head_not_pushed"

      # The reviewer was never launched: no sentinel, no verdict, no coverage.
      {git_dir, 0} = git(["rev-parse", "--absolute-git-dir"], wt)
      refute File.exists?(Path.join(String.trim(git_dir), "review_gate_push_check_ran"))
      refute Worker.state(author).meta[:review_gate_verdict] == :approve
      assert coverage_rows(task.id) == []
      assert Ash.get!(Issue, task.id).last_reviewed_sha == nil

      # And the remote was not clobbered.
      git!(["fetch", "-q", "origin"], repo)
      assert sha(repo, "origin/" <> branch) == theirs
      assert sha(wt, "HEAD") == mine
    end
  end

  describe "the worktree-on-another-branch shape (AC1)" do
    # bd-2jkrqu review round 1, finding 1: `push_gate/1` runs
    # before anything else in a round, and `PushState.ensure_pushed/3` pushes
    # `HEAD:refs/heads/<branch>`. Some ad-hoc runs and test rigs reuse the repo
    # itself as the worktree with HEAD on `main` and `branch:` checked out
    # elsewhere — the shape `prepare_branch_for_review/1` and
    # `reviewer_commit_check/1` already guard for. Unguarded, the gate would
    # publish `main`'s tip AS the PR branch: a merge-safety guard writing the
    # wrong commit to the branch it protects.
    test "never publishes the checked-out branch's HEAD as the PR branch",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/push-9"
      :ok = seed_feature_branch(repo, branch)

      # The repo IS the worktree: HEAD on `main`, `branch` checked out nowhere
      # and one commit ahead.
      assert String.trim(elem(git(["rev-parse", "--abbrev-ref", "HEAD"], repo), 0)) == "main"
      main_head = sha(repo, "HEAD")
      refute sha(repo, branch) == main_head
      assert sha(repo, "origin/" <> branch) == nil

      author = start_author(task, ws, repo, branch, repo)
      start_gate(author, task, ws, branch, repo, command: [@push_check, branch, "ROUND1"])

      # The round terminates (on this shape the diff range is empty, since the
      # worktree's HEAD *is* the target tip) — well after `push_gate/1` ran.
      wait_until(fn -> Ash.get!(Issue, task.id).review_park_reason != nil end, 20_000)

      {out, 0} = System.cmd("git", ["-C", repo, "ls-remote", "--heads", "origin", branch])

      assert String.trim(out) == "",
             "push_gate published a commit from the wrong branch to origin/#{branch}: #{out}"

      assert sha(repo, "origin/main") == main_head, "origin/main was moved"
    end

    test "pushed_head/1 falls back to the local head instead of accusing a branch it is not on",
         %{repo: repo} do
      branch = "feature/push-10"
      :ok = seed_feature_branch(repo, branch)
      main_head = sha(repo, "HEAD")

      # Not `{:error, {:head_not_pushed, _}}`: the worktree's HEAD is another
      # branch's commit, so it is neither accused nor blessed — the exact
      # pre-guard behaviour.
      assert {:ok, ^main_head} =
               ReviewGate.pushed_head(%{worktree_path: repo, branch: branch})
    end
  end

  describe "the fix round's re-review (AC1)" do
    test "a fix-round commit is pushed before round 2 reads it",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      branch = "feature/push-4"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      round1_head = sha(wt, "HEAD")

      author = start_author(task, ws, repo, branch, wt)

      start_gate(author, task, ws, branch, wt,
        command: [@push_check, branch, "ROUND2"],
        revise_command: [@revise_commit],
        rounds: 2
      )

      wait_until(fn -> Ash.get!(Issue, task.id).last_reviewed_sha != nil end, 60_000)

      fix_head = sha(wt, "HEAD")
      refute fix_head == round1_head, "the revise round should have committed"

      assert Ash.get!(Issue, task.id).last_reviewed_sha == fix_head

      git!(["fetch", "-q", "origin"], repo)

      assert sha(repo, "origin/" <> branch) == fix_head,
             "round 2 approved a head the remote does not carry"
    end
  end

  # ---- AC2: stamps and coverage name the pushed head -----------------------

  describe "reviewed-SHA stamp and coverage (AC2)" do
    test "an approval of an unpushed local head produces no coverage row for the PR",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      branch = "feature/push-5"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      pushed_head = sha(wt, "HEAD")

      author = start_author(task, ws, repo, branch, wt)

      start_gate(author, task, ws, branch, wt,
        command: [@commit_then_approve],
        pr_ref: "owner/repo#228"
      )

      wait_until(
        fn ->
          Enum.any?(escalations(ws, task), &(&1.subject =~ "review coverage write failed"))
        end,
        20_000
      )

      # The reviewer's own drive-by commit left HEAD off the remote branch.
      refute sha(wt, "HEAD") == pushed_head

      assert coverage_rows(task.id) == [],
             "a coverage row was written for a head the PR does not carry"

      assert Ash.get!(Issue, task.id).last_reviewed_sha == nil,
             "the reviewed-SHA stamp named an unpushed head"

      page = Enum.find(escalations(ws, task), &(&1.subject =~ "review coverage write failed"))
      assert page.body =~ "head_not_pushed"
    end

    test "pushed_head/1 refuses an unpushed local head and passes a pushed one",
         %{repo: repo, tmp: tmp} do
      branch = "feature/push-6"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      pushed = sha(wt, "HEAD")

      assert {:ok, ^pushed} = ReviewGate.pushed_head(%{worktree_path: wt, branch: branch})

      commit_in(wt, "local.txt", "unpushed\n")

      assert {:error, {:head_not_pushed, state}} =
               ReviewGate.pushed_head(%{worktree_path: wt, branch: branch})

      assert state.status == :ahead
    end
  end

  # ---- AC3: the park escalation tells the truth ----------------------------

  describe "park escalation text (AC3)" do
    test "an unpushed branch is named as such and merge-by-hand is withheld",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      branch = "feature/push-7"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      commit_in(wt, "fix.txt", "the unpushed fix\n")

      author = start_author(task, ws, repo, branch, wt)

      :ok =
        Worker.review_gate_verdict(
          author,
          {:parked, :verdict_guard_exhausted, "VERDICT: APPROVE\nbut F1.4 is open"}
        )

      wait_until(fn -> escalations(ws, task) != [] end)

      body = hd(escalations(ws, task)).body

      refute body =~ "the branch is pushed",
             "the escalation asserted a push state it never checked"

      assert body =~ "NOT pushed"
      assert body =~ "Do NOT merge by hand"
      refute body =~ "merge it by hand, if the diff is fine"
    end

    # bd-2jkrqu review round 1, finding 2: `:diverged` is the state that
    # PRODUCES the `:head_not_pushed` park (a diverged branch is never
    # force-pushed), so it is the likeliest reader of this bullet — and
    # "push it first" is precisely what git will reject. The ReviewGate's own
    # findings body says "reconcile … never force-push"; the two texts in one
    # escalation must not contradict each other.
    test "a diverged branch is told to reconcile, not to push",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      branch = "feature/push-11"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      base = sha(wt, "HEAD")

      other = Path.join(tmp, "other-#{System.unique_integer([:positive])}")
      {_, 0} = System.cmd("git", ["clone", "-q", Path.join(tmp, "origin.git"), other])
      git!(["config", "user.email", "o@example.com"], other)
      git!(["config", "user.name", "O"], other)
      git!(["config", "commit.gpgsign", "false"], other)
      git!(["checkout", "-q", branch], other)
      File.write!(Path.join(other, "theirs.txt"), "theirs\n")
      git!(["add", "theirs.txt"], other)
      git!(["commit", "-q", "-m", "theirs"], other)
      git!(["push", "-q", "origin", branch], other)

      git!(["reset", "-q", "--hard", base], wt)
      commit_in(wt, "mine.txt", "mine\n")

      author = start_author(task, ws, repo, branch, wt)

      :ok =
        Worker.review_gate_verdict(
          author,
          {:parked, :head_not_pushed, "ReviewGate refused to review an unpushed head"}
        )

      wait_until(fn -> escalations(ws, task) != [] end)

      body = hd(escalations(ws, task)).body

      assert body =~ "DIVERGED"
      assert body =~ "Do NOT merge by hand"
      assert body =~ "Reconcile `#{branch}`"
      assert body =~ "never force-push"

      refute body =~ "Push `#{branch}` first",
             "a diverged branch was told to do the one thing git will reject"
    end

    test "a genuinely pushed branch still offers the merge-by-hand option",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      branch = "feature/push-8"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)

      author = start_author(task, ws, repo, branch, wt)

      :ok =
        Worker.review_gate_verdict(
          author,
          {:parked, :reviewer_timeout, "ReviewGate reviewing pass timed out"}
        )

      wait_until(fn -> escalations(ws, task) != [] end)

      body = hd(escalations(ws, task)).body

      assert body =~ "is pushed"
      assert body =~ "merge it by hand"
      refute body =~ "Do NOT merge by hand"
    end
  end
end
