defmodule Arbiter.Worker.ReviewGateCoverageTest do
  @moduledoc """
  P1 of `docs/review-coverage-and-guard-policy.md` (design #1635) §3.3, the
  **ReviewGate clean approve** row of the stamping table.

  Two obligations, both tested here against a real git worktree and a real
  reviewer fixture:

    1. a clean APPROVE writes exactly ONE `review_coverage` row —
       `kind: :reviewed`, `source: :review_gate`, the gate's round, the full
       approved head SHA, and a non-nil `net_diff_id`;
    2. the write is **not** best-effort: a failing `Coverage.record/1` pages the
       coordinator exactly once through the shared circuit breaker (#1638) and
       does NOT take the gate down — `last_reviewed_sha` still stamps and the
       branch still merges.

  `last_reviewed_sha` stays authoritative: nothing here reads coverage.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.CircuitBreaker
  alias Arbiter.Messages.Message
  alias Arbiter.Reviews.Coverage.Entry
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate

  require Ash.Query

  @reviewer Path.expand("../../fixtures/review_verdict.sh", __DIR__)

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    tmp = Path.join(System.tmp_dir!(), "rg-coverage-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-cov-#{System.unique_integer([:positive])}",
        prefix: "rc",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws, tmp: tmp}
  end

  # ---- helpers -------------------------------------------------------------

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

  # A real second worktree checked out ON the feature branch — the production
  # shape. The gate's `base_sha..HEAD` range is then non-empty, so the net diff
  # really fingerprints (the shared `repo` sits on `main`, where it would not).
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

  defp git_sha(repo, ref) do
    {out, 0} = git(["rev-parse", ref], repo)
    String.trim(out)
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "coverage task", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  defp coverage_rows(task_id) do
    Entry
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  defp escalations(ws) do
    Message
    |> Ash.Query.filter(workspace_id == ^ws.id and kind == :escalation)
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

  # Park an author worker at :awaiting_review_gate, then drive a ReviewGate over
  # a worktree that is really on the feature branch.
  defp run_gate(task, ws, repo, tmp, opts) do
    branch = "feature/cov"
    :ok = seed_feature_branch(repo, branch)
    wt = branch_worktree(repo, tmp, branch)

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
          command: [@reviewer, "APPROVE"],
          timeout_ms: 10_000
        ] ++ opts
      )

    %{author: author, gate: gate, branch: branch, worktree: wt, head: git_sha(repo, branch)}
  end

  # ---- acceptance 1 --------------------------------------------------------

  describe "a clean APPROVE (§3.3 ReviewGate row)" do
    test "writes exactly one :reviewed coverage row for the approved head",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      ctx = run_gate(task, ws, repo, tmp, pr_ref: "owner/repo#42")

      wait_until(fn -> coverage_rows(task.id) != [] end, 15_000)

      assert [entry] = coverage_rows(task.id)
      assert entry.kind == :reviewed
      assert entry.source == :review_gate
      assert entry.round == 1
      assert entry.task_id == task.id
      assert entry.mr_ref == "owner/repo#42"
      assert entry.head_sha == ctx.head
      assert entry.base_ref == "main"
      assert is_binary(entry.net_diff_id) and entry.net_diff_id != ""
      assert entry.derived_from == nil

      # last_reviewed_sha stays authoritative and is written exactly as before.
      wait_until(fn -> Ash.get!(Issue, task.id).last_reviewed_sha == ctx.head end, 10_000)
    end

    test "re-running the same approval does not add a second row (record/1 is idempotent)",
         %{repo: repo, ws: ws, tmp: tmp} do
      task = new_task(ws)
      ctx = run_gate(task, ws, repo, tmp, pr_ref: "owner/repo#43")

      wait_until(fn -> coverage_rows(task.id) != [] end, 15_000)
      [first] = coverage_rows(task.id)

      assert {:ok, again} =
               Arbiter.Reviews.Coverage.record(%{
                 task_id: task.id,
                 mr_ref: "owner/repo#43",
                 head_sha: ctx.head,
                 base_ref: "main",
                 net_diff_id: first.net_diff_id,
                 kind: :reviewed,
                 source: :review_gate,
                 round: 1
               })

      assert again.id == first.id
      assert length(coverage_rows(task.id)) == 1
    end
  end

  # ---- acceptance 2 --------------------------------------------------------

  describe "a failing coverage write (§3.3: the write is not best-effort)" do
    test "pages the coordinator exactly once and leaves the gate running",
         %{repo: repo, ws: ws, tmp: tmp} do
      put_app_env(:arbiter, :review_coverage_writer, fn _attrs -> {:error, :boom} end)

      task = new_task(ws)
      ctx = run_gate(task, ws, repo, tmp, pr_ref: "owner/repo#44")

      # The gate did NOT crash: the reviewed-SHA stamp still lands.
      wait_until(fn -> Ash.get!(Issue, task.id).last_reviewed_sha == ctx.head end, 15_000)

      wait_until(
        fn -> Enum.any?(escalations(ws), &(&1.subject =~ "review coverage write failed")) end,
        10_000
      )

      pages = Enum.filter(escalations(ws), &(&1.subject =~ "review coverage write failed"))
      assert length(pages) == 1
      assert hd(pages).body =~ "owner/repo#44"
      assert hd(pages).body =~ ctx.head

      # No coverage row was written — the failure is honest, not papered over.
      assert coverage_rows(task.id) == []
    end

    test "repeated failures are bounded by the shared circuit breaker", %{ws: ws} do
      prior = Application.get_env(:arbiter, :circuit_breaker, [])

      Application.put_env(
        :arbiter,
        :circuit_breaker,
        Keyword.put(prior, :review_coverage_write_failed, limit: 2, window_ms: 60_000)
      )

      on_exit(fn -> Application.put_env(:arbiter, :circuit_breaker, prior) end)

      snapshot = %{task_id: "bd-cov001", workspace_id: ws.id}

      results =
        for _ <- 1..9,
            do:
              ReviewGate.escalate_coverage_write_failure(
                snapshot,
                "owner/repo#99",
                String.duplicate("a", 40),
                :boom
              )

      assert Enum.count(results, &(&1 == :ok)) == 2
      assert Enum.count(results, &(&1 == :suppressed)) == 7

      trips = Enum.filter(escalations(ws), &(&1.subject =~ "circuit breaker tripped"))
      assert length(trips) == 1
    end
  end
end
