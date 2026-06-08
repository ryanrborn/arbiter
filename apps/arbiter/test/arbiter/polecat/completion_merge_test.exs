defmodule Arbiter.Polecat.CompletionMergeTest do
  @moduledoc """
  End-to-end proof for bd-7qq81g: a `--with-claude` sling on the default
  (Direct) domain must integrate the branch into the target line when the
  acolyte finishes — a real `git merge --no-ff` commit on `main` — rather than
  closing the bead without merging.
  """

  # DataCase (async: false → shared sandbox) so the polecat/driver/warden
  # processes under the DynamicSupervisor reach the same DB connection.
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat
  alias Arbiter.Polecat.Sling

  @fixture Path.expand("../../fixtures/commit_and_done.sh", __DIR__)

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_rig(dir) do
    repo = Path.join(dir, "rig")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "rig@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Rig"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
    # Clone into a bare repo so the worktree code can fetch origin/main.
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    {_, 0} = git(["remote", "add", "origin", bare], repo)
    {_, 0} = git(["fetch", "-q", "origin"], repo)
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
    tmp = Path.join(System.tmp_dir!(), "completion-merge-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_rig(tmp)

    Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    Application.put_env(:arbiter, :rig_paths, %{"merge/rig" => repo})

    on_exit(fn ->
      Application.delete_env(:arbiter, :worktree_root)
      Application.delete_env(:arbiter, :rig_paths)
      File.rm_rf!(tmp)
    end)

    # Plain workspace → merger_strategy/1 falls back to :direct.
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "merge-ws-#{System.unique_integer([:positive])}",
        prefix: "mg"
      })

    %{repo: repo, ws: ws}
  end

  test "a --with-claude completion merges the branch into main with a --no-ff commit",
       %{repo: repo, ws: ws} do
    {:ok, bead} =
      Ash.create(Issue, %{title: "integrate me", workspace_id: ws.id, issue_type: :feature})

    {:ok, result} =
      Sling.sling(bead.id,
        rig: "merge/rig",
        start_claude: true,
        claude_command: [@fixture],
        interval_ms: 10,
        max_ticks: 200
      )

    on_exit(fn ->
      if Process.alive?(result.polecat_pid), do: GenServer.stop(result.polecat_pid, :normal)
    end)

    # Wait for the whole path: acolyte done → Direct merge → bead closes.
    # We use the bead's DB status (not polecat in-memory state) because the
    # StopPolecat after-action kills the polecat process right after close_bead
    # returns — checking Polecat.state/1 would raise if we arrive slightly late.
    wait_until(fn ->
      match?({:ok, %Issue{status: :closed}}, Ash.get(Issue, bead.id))
    end)

    # main now carries a real merge commit (two parents) — not a fast-forward.
    {merges, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    assert String.trim(merges) == "1"

    # ...and the acolyte's work landed on main via that merge.
    {tree, 0} = git(["ls-tree", "--name-only", "main"], repo)
    assert tree =~ "acolyte_work.txt"
  end

  test "a merge failure surfaces as a failure_reason and does NOT complete the polecat",
       %{repo: repo, ws: ws} do
    {:ok, bead} =
      Ash.create(Issue, %{title: "conflict me", workspace_id: ws.id, issue_type: :feature})

    # Create the source branch so it exists, but point target_branch at a branch
    # that does not — the Direct adapter's `git checkout <target>` then fails
    # deterministically (no race with the fixture). Drive the polecat directly
    # so we control its meta.
    {_, 0} = git(["branch", "feature/x"], repo)

    meta = %{
      branch: "feature/x",
      repo_path: repo,
      target_branch: "no-such-target",
      merge_title: "Merge #{bead.id}"
    }

    {:ok, pid} =
      Polecat.start(bead_id: bead.id, rig: "merge/rig", workspace_id: ws.id, meta: meta)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Polecat.advance(pid, :claude)

    send(pid, {:__claude_session_done__, "arb done"})

    wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end)

    snap = Polecat.state(pid)
    assert {:merge_failed, _reason} = snap.meta.failure_reason
    # Critically: not silently :completed.
    refute snap.status == :completed
  end

  test "a conflicting auto-merge aborts, keeps main clean, escalates, and does NOT close the bead",
       %{repo: repo, ws: ws} do
    # bd-1rhyla: a conflicted auto-merge once left main half-merged + uncompilable
    # and took the live server down. Prove the full recovery contract end-to-end.
    {:ok, bead} =
      Ash.create(Issue, %{
        title: "conflict me for real",
        workspace_id: ws.id,
        issue_type: :feature
      })

    # Diverging edits to the same file on both branches → a genuine merge conflict.
    {_, 0} = git(["checkout", "-q", "-b", "feature/conflict"], repo)
    File.write!(Path.join(repo, "README.md"), "from feature\n")
    {_, 0} = git(["commit", "-q", "-am", "feature edit"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)
    File.write!(Path.join(repo, "README.md"), "from main\n")
    {_, 0} = git(["commit", "-q", "-am", "main edit"], repo)

    {head_before, 0} = git(["rev-parse", "HEAD"], repo)

    meta = %{
      branch: "feature/conflict",
      repo_path: repo,
      target_branch: "main",
      merge_title: "Merge #{bead.id}"
    }

    {:ok, pid} =
      Polecat.start(bead_id: bead.id, rig: "merge/rig", workspace_id: ws.id, meta: meta)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Polecat.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})

    wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end)

    # 1. main is unchanged + compilable: HEAD didn't move, no merge commit, tree clean.
    {head_after, 0} = git(["rev-parse", "HEAD"], repo)
    assert head_after == head_before
    {merges, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    assert String.trim(merges) == "0"
    assert {"", 0} = git(["status", "--porcelain"], repo)
    refute File.read!(Path.join(repo, "README.md")) =~ "<<<<<<<"

    # 2. the bead is NOT closed (parked for rebase) — and the polecat failed, not completed.
    snap = Polecat.state(pid)
    assert snap.status == :failed
    assert snap.meta.failure_reason == :merge_conflict
    {:ok, reloaded} = Ash.get(Issue, bead.id)
    refute reloaded.status == :closed
    assert reloaded.notes =~ "Merge conflict"
    assert reloaded.notes =~ "README.md"

    # 3. the Admiral inbox got an escalation naming the conflicting files.
    escalations = Message.inbox("admiral", workspace_id: ws.id)
    escalation = Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == bead.id))
    assert escalation
    assert escalation.body =~ "README.md"
    assert escalation.body =~ "feature/conflict"
  end
end
