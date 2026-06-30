defmodule Arbiter.Worker.PushBeforePRTest do
  @moduledoc """
  Regression tests for bd-13thk9: the worker must push the worktree branch to
  origin before asking a hosted forge (GitHub/GitLab) to open a PR. Without the
  push, GitHub returns 422 "field head invalid" and the task is stranded.

  We use a real git repo so we can verify whether the push actually happened,
  paired with a StubMerger whose `open/4` captures args so we can confirm the
  sequence (push → open) is correct. For the Direct strategy we confirm push is
  NOT attempted — no remote branch required for a local git merge.
  """

  use ExUnit.Case, async: false

  alias Arbiter.Worker
  alias Arbiter.Test.StubMerger

  defp git(args, repo),
    do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_rig(tmp) do
    bare = Path.join(tmp, "origin.git")
    work = Path.join(tmp, "repo")
    File.mkdir_p!(work)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", work])
    {_, 0} = git(["config", "user.email", "test@example.com"], work)
    {_, 0} = git(["config", "user.name", "Test"], work)
    {_, 0} = git(["config", "commit.gpgsign", "false"], work)
    File.write!(Path.join(work, "seed.txt"), "seed\n")
    {_, 0} = git(["add", "seed.txt"], work)
    {_, 0} = git(["commit", "-q", "-m", "seed"], work)

    # bare clone acts as origin
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", work, bare])
    {_, 0} = git(["remote", "add", "origin", bare], work)
    {_, 0} = git(["fetch", "-q", "origin"], work)

    # Provision a worktree on a feature branch with a commit
    wt = Path.join(tmp, "worktrees/feature-abc")
    {_, 0} = git(["worktree", "add", "-b", "feature/abc", wt, "HEAD"], work)

    {_, 0} =
      System.cmd("git", ["-C", wt, "config", "user.email", "test@example.com"],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd("git", ["-C", wt, "config", "user.name", "Test"], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", wt, "config", "commit.gpgsign", "false"], stderr_to_stdout: true)

    File.write!(Path.join(wt, "work.txt"), "done\n")
    {_, 0} = System.cmd("git", ["-C", wt, "add", "work.txt"], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", wt, "commit", "-q", "-m", "work"], stderr_to_stdout: true)

    %{repo: work, bare: bare, worktree: wt}
  end

  setup do
    StubMerger.reset()

    tmp =
      Path.join(System.tmp_dir!(), "push-before-pr-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    rig = init_rig(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    task_id = "test-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(
        task_id: task_id,
        repo: "stub/repo",
        meta: %{worktree_path: rig.worktree}
      )

    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    %{pid: pid, task_id: task_id, rig: rig}
  end

  defp branch_on_origin(bare, branch) do
    {out, _} = System.cmd("git", ["-C", bare, "branch", "--list", branch], stderr_to_stdout: true)
    String.trim(out) != ""
  end

  describe "hosted forge (StubMerger with GitHub strategy key)" do
    # We signal a hosted-forge workspace by setting the strategy via opts.
    # `hosted_forge_merger?/2` in worker.ex checks for strategy: :github/:gitlab
    # when the workspace struct is nil (adapter test path).
    # In these tests we pass adapter: StubMerger (not a real forge) but set
    # strategy: :github so the push gate fires — the push is real, but the
    # open/4 is stubbed.

    test "branch is pushed to origin before open/4 is called", %{pid: pid, rig: rig} do
      # Feature branch NOT on origin yet
      refute branch_on_origin(rig.bare, "feature/abc")

      assert {:ok, _ref} =
               Worker.open_mr(pid, "feature/abc", "Add abc", "body", %{
                 adapter: StubMerger,
                 workspace: nil,
                 strategy: :github,
                 interval_ms: 1_000_000,
                 initial_delay_ms: 1_000_000
               })

      # open/4 succeeded → branch must now be on origin
      assert branch_on_origin(rig.bare, "feature/abc")

      # And the StubMerger did receive the open call
      assert StubMerger.last_open() != nil
    end

    test "push failure aborts with {:error, {:push_failed, _}} and does NOT call open/4",
         %{pid: pid, rig: rig} do
      # Remove the origin remote from the worktree so push fails
      {_, 0} =
        System.cmd("git", ["-C", rig.worktree, "remote", "remove", "origin"],
          stderr_to_stdout: true
        )

      result =
        Worker.open_mr(pid, "feature/abc", "Add abc", "body", %{
          adapter: StubMerger,
          workspace: nil,
          strategy: :github,
          interval_ms: 1_000_000,
          initial_delay_ms: 1_000_000
        })

      assert {:error, {:push_failed, _reason}} = result

      # No PR was opened
      assert StubMerger.last_open() == nil

      # Worker stays :running after a push failure
      assert Worker.state(pid).status == :running
    end
  end

  # Note: the Direct-strategy push-skip path is tested by the full-integration
  # test in completion_merge_test.exs (real Direct workspace, real git merge).
  # `hosted_forge_merger?/2` skips push when the workspace strategy is :direct,
  # but the test-shortcut `adapter: StubMerger` always evaluates as hosted-forge,
  # so unit-testing the direct skip here would require a real DataCase workspace.

  describe "no worktree on disk (coordinator / ad-hoc path)" do
    test "worker proceeds without push when worktree_path is absent", %{} do
      task_id = "test-#{System.unique_integer([:positive])}"

      # Worker with no worktree in meta
      {:ok, pid} = Worker.start(task_id: task_id, repo: "stub/repo", meta: %{})
      :ok = Worker.advance(pid, :implement)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      assert {:ok, _ref} =
               Worker.open_mr(pid, "feature/x", "X", "body", %{
                 adapter: StubMerger,
                 workspace: nil,
                 strategy: :github,
                 interval_ms: 1_000_000,
                 initial_delay_ms: 1_000_000
               })

      # No crash — open/4 was still called
      assert StubMerger.last_open() != nil
    end
  end
end
