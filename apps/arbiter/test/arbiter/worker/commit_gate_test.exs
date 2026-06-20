defmodule Arbiter.Worker.CommitGateTest do
  @moduledoc """
  Regression test for bd-ofql8k.

  Root cause the gate addresses: the worker EDITS files in its worktree
  correctly but never `git commit`s, so HEAD stays at the base branch with
  the work UNCOMMITTED in the worktree. Before this fix the ReviewGate — which
  runs in the same worktree — diffed `git diff <base>..HEAD` (committed
  history only), saw empty, and reported "no code exists" while literally
  sitting on the uncommitted changes.

  The fix gates `Worker.on_claude_done` on `Worktree.completion_state/2`:
  if the tree is dirty or has no commits ahead of the target, the worker
  either (a) relaunches the worker with a clear "you have uncommitted
  changes — commit + push" nudge, capped at `meta[:commit_nudge_cap]` (default
  1), or (b) fails + escalates with details when the cap is exhausted. The
  ReviewGate is never reached in either case, so it can never falsely report
  "no work" while the work is sitting right there.

  These tests pin the structural gate (cap: 0 → fail immediately) so the
  failure mode cannot regress. The nudge re-spawn itself is exercised
  indirectly via the cap-bookkeeping assertion.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.Worktree

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)

    # Worktree.create/3 fetches from `origin` and branches from `origin/<base>`,
    # so the repo needs an upstream the provisioner can consult — mirrors the
    # bare-origin pattern in dispatch_test.exs.
    remote = Path.join(dir, "repo-remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = git(["remote", "add", "origin", remote], repo)
    {_, 0} = git(["push", "-q", "origin", "main"], repo)

    repo
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
    tmp = Path.join(System.tmp_dir!(), "commit-gate-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    Application.put_env(:arbiter, :repo_paths, %{"gate/repo" => repo})

    on_exit(fn ->
      Application.delete_env(:arbiter, :worktree_root)
      Application.delete_env(:arbiter, :repo_paths)
      File.rm_rf!(tmp)
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "gate-ws-#{System.unique_integer([:positive])}",
        prefix: "gt",
        # Review required: tests must verify the gate trips BEFORE the ReviewGate
        # is spawned. With review:false the merge path also short-circuits, so
        # an absent gate would surface as the wrong assertion (merge attempted
        # instead of ReviewGate entered).
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws}
  end

  # Provision a fresh worktree on a per-task branch using the same helper Dispatch
  # uses in production. Tests want to drive the worker directly (cap: 0 → fail
  # path), but the worktree on disk has to be real so the gate's git inspection
  # is exercised, not stubbed.
  defp provision_worktree(repo, branch) do
    {:ok, path} = Worktree.create(repo, branch, "main")
    {_, 0} = git(["config", "user.email", "wt@example.com"], path)
    {_, 0} = git(["config", "user.name", "WT"], path)
    {_, 0} = git(["config", "commit.gpgsign", "false"], path)
    path
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "commit-gate task",
        workspace_id: ws.id,
        issue_type: :feature
      })

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  defp start_worker(task, repo, worktree_path, extra_meta) do
    meta =
      Map.merge(
        %{
          branch: "bd-gate/#{task.id}",
          repo_path: repo,
          worktree_path: worktree_path,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          # Skip the live ReviewGate subprocess — a tripped gate must NOT route
          # to a ReviewGate at all, so a stubbed-out spawn would prove nothing.
          # If the gate fails, status moves to :failed before this even matters.
          review_spawn: false
        },
        extra_meta
      )

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "gate/repo",
        workspace_id: ws_id(task),
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  defp ws_id(%Issue{workspace_id: ws}), do: ws

  # ---- Worktree.completion_state/2 ----------------------------------------

  describe "Worktree.completion_state/2" do
    test "reports :ready when the tree is clean and has commits ahead", %{repo: repo} do
      path = provision_worktree(repo, "feature/ready")
      File.write!(Path.join(path, "x.txt"), "x\n")
      {_, 0} = git(["add", "x.txt"], path)
      {_, 0} = git(["commit", "-q", "-m", "x"], path)

      assert {:ok, :ready} = Worktree.completion_state(path, "main")
    end

    test "reports :uncommitted when staged/unstaged/untracked changes exist", %{repo: repo} do
      path = provision_worktree(repo, "feature/dirty")
      File.write!(Path.join(path, "untracked.txt"), "u\n")

      assert {:ok, :uncommitted} = Worktree.completion_state(path, "main")
    end

    test "uncommitted wins over no_commits when both apply", %{repo: repo} do
      # No commits ahead AND a dirty tree: the actionable signal is "commit it",
      # so :uncommitted must win.
      path = provision_worktree(repo, "feature/dirty-no-commits")
      File.write!(Path.join(path, "u.txt"), "u\n")

      assert {:ok, :uncommitted} = Worktree.completion_state(path, "main")
    end

    test "reports :no_commits when clean but zero commits ahead of base", %{repo: repo} do
      path = provision_worktree(repo, "feature/empty")

      assert {:ok, :no_commits} = Worktree.completion_state(path, "main")
    end
  end

  # ---- the gate itself ----------------------------------------------------

  describe "the commit gate (bd-ofql8k)" do
    test "an arb-done with UNCOMMITTED changes fails + escalates instead of routing to ReviewGate",
         %{repo: repo, ws: ws} do
      # Reproduce the bd-8ucc29 / #135 root cause: edit a file in the worktree
      # but never `git commit`. Before the gate, the ReviewGate would be spawned
      # against an empty `base..HEAD` and report "no work" while the edit was
      # right there. After the gate, with the nudge cap pinned at 0 (so we
      # assert the structural gate without the retry layer), the worker must
      # park as :failed with a bd-ofql8k-specific failure reason and surface
      # the uncommitted state to the Admiral.
      task = new_task(ws)
      path = provision_worktree(repo, "bd-gate/#{task.id}")
      File.write!(Path.join(path, "forgotten_work.txt"), "edited but not committed\n")

      pid = start_worker(task, repo, path, %{commit_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)

      # The structural pin: NEVER routed to ReviewGate.
      refute snap.status == :awaiting_review_gate
      refute snap.status == :completed
      assert snap.meta.failure_reason == :uncommitted_at_completion
      assert snap.meta.commit_gate_reason == :uncommitted

      # The task is not closed; notes carry the gate diagnostic.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.status == :closed
      assert reloaded.notes =~ "Commit gate tripped"
      assert reloaded.notes =~ "forgotten_work.txt"

      # The Admiral got an escalation that explicitly names the failure mode.
      escalations = Message.inbox("admiral", workspace_id: ws.id)

      escalation =
        Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == task.id))

      assert escalation
      assert escalation.subject =~ "uncommitted"
      assert escalation.body =~ "forgotten_work.txt"

      # The work is still on disk — we did NOT auto-commit (per bd-ofql8k:
      # "Prefer send-back/retry over a blind auto-commit").
      assert File.read!(Path.join(path, "forgotten_work.txt")) =~ "edited but not committed"
      # And the local repo's main is untouched — no merge attempted.
      {merges, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
      assert String.trim(merges) == "0"
    end

    test "an arb-done with ZERO commits ahead of base fails + escalates",
         %{repo: repo, ws: ws} do
      # The other half of the gate: a clean worktree but no commits on the
      # per-task branch is also unreviewable — there is literally nothing on
      # `base..HEAD` to diff. Distinct failure reason so the operator can
      # tell the two cases apart in the run log.
      task = new_task(ws)
      path = provision_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{commit_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      refute snap.status == :awaiting_review_gate
      assert snap.meta.failure_reason == :no_commits_at_completion
      assert snap.meta.commit_gate_reason == :no_commits

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.notes =~ "Commit gate tripped"
      assert reloaded.notes =~ "zero commits ahead"
    end

    test "an arb-done with a CLEAN tree + ≥1 commit ahead proceeds to the ReviewGate",
         %{repo: repo, ws: ws} do
      # The happy-path counterpart: the gate must let real work through to
      # the review gate. Without this assertion, a too-strict gate would
      # silently regress every task.
      task = new_task(ws)
      path = provision_worktree(repo, "bd-gate/#{task.id}")
      File.write!(Path.join(path, "real_work.txt"), "real\n")
      {_, 0} = git(["add", "real_work.txt"], path)
      {_, 0} = git(["commit", "-q", "-m", "real work"], path)

      pid = start_worker(task, repo, path, %{commit_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      # The gate passes → review_spawn: false leaves the worker parked at
      # :awaiting_review_gate waiting for a directly-delivered verdict.
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      refute snap.status == :failed
      # The gate did NOT record a trip when the worktree was ready.
      refute Map.has_key?(snap.meta, :commit_gate_reason)
    end

    test "a review-only worker (reviewer) completes despite zero commits (bd-40j98i)",
         %{repo: repo, ws: ws} do
      # Reviewers operate in review-only mode (meta[:review_only] = true) and
      # analyze diffs without authoring code. They make NO commits by design.
      # Before this fix, they would be marked :failed with :no_commits_at_completion
      # because the commit gate checked all workers. The fix skips the gate for
      # reviewers so they complete successfully.
      task = new_task(ws)
      path = provision_worktree(repo, "bd-gate/#{task.id}")

      pid =
        start_worker(task, repo, path, %{
          commit_nudge_cap: 0,
          review_only: true
        })

      send(pid, {:__claude_session_done__, "arb done"})

      # Reviewer completes despite zero commits (the worktree was just created,
      # no work was done). Before bd-40j98i, this would fail with
      # :no_commits_at_completion. After the fix, review_only workers bypass
      # the gate and proceed directly.
      wait_until(fn ->
        snap = Worker.state(pid)
        snap.status in [:completed, :awaiting_review, :awaiting_review_gate]
      end)

      snap = Worker.state(pid)
      # The gate was SKIPPED because review_only=true, so the worker must NOT
      # be :failed with a commit_gate_reason.
      refute snap.status == :failed
      refute Map.has_key?(snap.meta, :commit_gate_reason)
      refute snap.meta[:failure_reason] == :no_commits_at_completion
    end
  end
end
