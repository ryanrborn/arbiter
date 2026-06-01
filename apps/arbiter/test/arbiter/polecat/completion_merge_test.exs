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
  alias Arbiter.Polecat
  alias Arbiter.Polecat.Sling

  @fixture Path.expand("../../fixtures/commit_and_done.sh", __DIR__)

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_rig(dir) do
    repo = Path.join(dir, "rig")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "rig@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Rig"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
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

    # The acolyte commits on the branch, prints "gt done"; the polecat opens the
    # MR (Direct merges synchronously) and the Warden completes it.
    wait_until(fn ->
      match?(%{status: :completed}, Polecat.state(result.polecat_pid))
    end)

    # main now carries a real merge commit (two parents) — not a fast-forward.
    {merges, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    assert String.trim(merges) == "1"

    # ...and the acolyte's work landed on main via that merge.
    {tree, 0} = git(["ls-tree", "--name-only", "main"], repo)
    assert tree =~ "acolyte_work.txt"

    # The bead closes only after the merge.
    wait_until(fn ->
      match?({:ok, %Issue{status: :closed}}, Ash.get(Issue, bead.id))
    end)
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

    send(pid, {:__claude_session_done__, "gt done"})

    wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end)

    snap = Polecat.state(pid)
    assert {:merge_failed, _reason} = snap.meta.failure_reason
    # Critically: not silently :completed.
    refute snap.status == :completed
  end
end
