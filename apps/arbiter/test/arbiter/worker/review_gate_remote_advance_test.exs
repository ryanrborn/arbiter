defmodule Arbiter.Worker.ReviewGateRemoteAdvanceTest do
  @moduledoc """
  bd-bq8c8a / #1860 — a ReviewGate fix round must not commit on top of a head
  the remote has already moved past.

  leotech `lt-20r7zu`, `admin_server` PR #424, 2026-09-17. Round 1 said
  REQUEST_CHANGES at 16:29:52 and dispatched an implementer. At 16:30:10
  PRPatrol's fix worker pushed `aed4457` to `origin/<branch>`. At ~16:30:30 the
  gate's implementer committed `19665a3` on the worktree — a child of the same
  parent, containing none of the patrol's work. The push at 16:30:38 was
  rejected `:diverged`, the run recorded `review_parked` and the task parked
  `head_not_pushed`. Recovery was manual.

  The gate never fetched between the reviewer's verdict and the implementer's
  commit, so it could not see the remote move and its push could only fail.

  What is pinned here, against real git repos with a real bare origin:

    * the fix round fetches and compares before the implementer is launched;
    * when the remote advanced, the implementer never runs — so there is no
      orphan commit and no `:impl` round row;
    * the gate fast-forwards onto the new remote head and opens a FRESH review
      round on it, instead of parking `head_not_pushed`;
    * that fresh round's prompt says what actually happened — nobody addressed
      the findings — instead of the default "the implementer has addressed your
      prior findings", which would push the reviewer to disposition its own
      open findings `[ADDRESSED]` against a diff that never targeted them
      (the bd-6r8caj property);
    * the branch is otherwise untouched: `origin/<branch>` still carries the
      other actor's commit.

  The reviewer fixture (`review_remote_advance.sh`) encodes the push state it
  read into its own verdict, so a regression shows up as a REQUEST_CHANGES
  rather than as a test that passes for the wrong reason.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.CircuitBreaker
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.PromptLog
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Workers.Run

  @remote_advance Path.expand("../../fixtures/review_remote_advance.sh", __DIR__)
  @push_check Path.expand("../../fixtures/review_push_check.sh", __DIR__)
  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "rg-adv-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-adv-#{System.unique_integer([:positive])}",
        prefix: "ra",
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

  # A second clone standing in for PRPatrol's fix worker: it commits a superset
  # of the gate's finding but does NOT push. `review_remote_advance.sh` pushes
  # it mid-round.
  defp patrol_clone(tmp, branch) do
    other = Path.join(tmp, "patrol-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", "-q", Path.join(tmp, "origin.git"), other])
    git!(["config", "user.email", "patrol@example.com"], other)
    git!(["config", "user.name", "Patrol"], other)
    git!(["config", "commit.gpgsign", "false"], other)
    git!(["checkout", "-q", branch], other)
    File.write!(Path.join(other, "guard.txt"), "anchored guard (patrol)\n")
    git!(["add", "guard.txt"], other)
    git!(["commit", "-q", "-m", "address review follow-ups"], other)
    on_exit(fn -> File.rm_rf!(other) end)
    {other, sha(other, "HEAD")}
  end

  defp sha(repo, ref) do
    case git(["rev-parse", ref], repo) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  # ---- app rig -------------------------------------------------------------

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "remote-advance", workspace_id: ws.id, issue_type: :feature})

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

  # The prompt the round-`n` reviewer pass was actually launched with, read back
  # off its own run row (`Worker.persist_composed_prompt/2` writes it).
  defp round_prompt(task_id, round) do
    id = ReviewGate.reviewer_task_id(task_id) <> "#r#{round}"

    run =
      Run
      |> Ash.Query.filter(task_id == ^id)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!()
      |> List.first()

    refute is_nil(run), "no run row for reviewer pass #{id}"
    assert {:ok, prompt} = PromptLog.read(run.id)
    prompt
  end

  defp rounds(task_id) do
    Round |> Ash.Query.filter(task_id == ^task_id) |> Ash.Query.sort(:inserted_at) |> Ash.read!()
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

  describe "a remote that advances mid-round" do
    test "the fix round aborts, no orphan commit is made, and a fresh round reviews the new head",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      branch = "feature/adv-1"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      round1_head = sha(wt, "HEAD")

      {patrol_clone_path, patrol_sha} = patrol_clone(tmp, branch)
      refute patrol_sha == round1_head

      author = start_author(task, ws, repo, branch, wt)

      start_gate(author, task, ws, branch, wt,
        command: [@remote_advance, patrol_clone_path, branch],
        revise_command: [@revise_commit]
      )

      wait_until(fn -> Ash.get!(Issue, task.id).last_reviewed_sha == patrol_sha end, 30_000)

      # The gate approved the head the REMOTE carries, not a local orphan.
      assert Ash.get!(Issue, task.id).review_park_reason == nil
      assert sha(wt, "HEAD") == patrol_sha

      git!(["fetch", "-q", "origin"], repo)
      assert sha(repo, "origin/" <> branch) == patrol_sha

      # The implementer never ran: no orphan commit, and no `:impl` round row.
      {git_dir, 0} = git(["rev-parse", "--absolute-git-dir"], wt)
      refute File.exists?(Path.join(String.trim(git_dir), "revise_commit_pass"))
      assert Enum.filter(rounds(task.id), &(&1.role == :impl)) == []

      # The fresh round is honest about WHY there is a new diff: no implementer
      # ran, so the reviewer must re-check each open finding against a commit
      # that was never aimed at it.
      prompt = round_prompt(task.id, 2)
      refute prompt =~ "The implementer has addressed your prior findings"
      assert prompt =~ "NO implementer ran for your prior findings"
      assert prompt =~ "the branch moved on"
      assert prompt =~ String.slice(patrol_sha, 0, 12)
      # The carried findings and their DISPOSITIONS instruction are still there.
      assert prompt =~ "OPEN FINDINGS CARRIED FORWARD"
      assert prompt =~ "DISPOSITIONS:"
    end
  end

  describe "the ordinary fix round (unchanged)" do
    test "a remote that does NOT move still runs the implementer and pushes its commit",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      branch = "feature/adv-2"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      round1_head = sha(wt, "HEAD")

      author = start_author(task, ws, repo, branch, wt)

      start_gate(author, task, ws, branch, wt,
        command: [@push_check, branch, "ROUND2"],
        revise_command: [@revise_commit]
      )

      wait_until(
        fn ->
          case Ash.get!(Issue, task.id).last_reviewed_sha do
            nil -> false
            sha -> sha != round1_head
          end
        end,
        30_000
      )

      assert Ash.get!(Issue, task.id).review_park_reason == nil
      fix_head = sha(wt, "HEAD")
      refute fix_head == round1_head

      git!(["fetch", "-q", "origin"], repo)
      assert sha(repo, "origin/" <> branch) == fix_head
      assert Enum.any?(rounds(task.id), &(&1.role == :impl))

      # An ordinary fix round keeps the ordinary framing: an implementer really
      # did address the findings on this path.
      prompt = round_prompt(task.id, 2)
      assert prompt =~ "The implementer has addressed your prior findings"
      refute prompt =~ "NO implementer ran for your prior findings"
    end
  end
end
