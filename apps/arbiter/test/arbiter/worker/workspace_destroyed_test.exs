defmodule Arbiter.Worker.WorkspaceDestroyedTest do
  @moduledoc """
  Regression tests for bd-b6noq9 / #1930: a worker whose **provisioned**
  workspace is deleted out from under it mid-run must fail with a distinct,
  machine-readable `:workspace_destroyed` stop reason.

  The four escalations that produced this issue (`fp-7zn1p7`, `fp-6u0wu1`,
  `cr-ag13cz`, `fp-ry8klj`) each reached the coordinator as a differently
  worded free-text "needs human review" note, because Arbiter itself had no
  concept of the condition:

    * `commit_gate/1` gates on `File.dir?(worktree)` and **fails open** when
      the directory is gone, so a destroyed workspace routed to the review
      gate / merger exactly like a healthy completion — on a branch that no
      longer exists anywhere.
    * `:exited_without_done` is a *resumable* category, so a subprocess that
      died because its cwd vanished was auto-resumed into a directory that is
      not there.

  Both paths must now terminate at `:workspace_destroyed`, and the condition
  must stay distinct from `:missing_worktree` (bd-7pe74i), which means the
  opposite thing: a workspace that was never provisioned at all.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

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

  # A provisioned worktree: a real git repo checked out on the per-task branch,
  # exactly the shape `Worktree.create/3` leaves behind.
  defp provision_worktree!(branch) do
    dir =
      Path.join(
        Arbiter.Config.Paths.scratch_root(),
        "workspace-destroyed-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", dir])
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.name", "T"])
    {_, 0} = System.cmd("git", ["-C", dir, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(dir, "README.md"), "seed\n")
    {_, 0} = System.cmd("git", ["-C", dir, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", dir, "commit", "-q", "-m", "seed"])
    {_, 0} = System.cmd("git", ["-C", dir, "checkout", "-q", "-b", branch])
    File.write!(Path.join(dir, "feature.txt"), "work\n")
    {_, 0} = System.cmd("git", ["-C", dir, "add", "feature.txt"])
    {_, 0} = System.cmd("git", ["-C", dir, "commit", "-q", "-m", "feature"])

    dir
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "workspace-destroyed-ws-#{System.unique_integer([:positive])}",
        prefix: "wd",
        config: %{}
      })

    {:ok, task} =
      Ash.create(Issue, %{
        title: "code directive",
        workspace_id: ws.id,
        issue_type: :feature
      })

    {:ok, task} = Ash.update(task, %{status: :in_progress})

    branch = "feature/workspace-destroyed-#{System.unique_integer([:positive])}"
    worktree = provision_worktree!(branch)

    %{ws: ws, task: task, branch: branch, worktree: worktree}
  end

  defp start_worker!(ws, task, branch, worktree) do
    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "arbiter",
        workspace_id: ws.id,
        meta: %{
          issue_type: :feature,
          branch: branch,
          target_branch: "main",
          worktree_path: worktree
        }
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  describe "arb done with a destroyed workspace" do
    test "fails with :workspace_destroyed instead of routing to review/merge",
         %{ws: ws, task: task, branch: branch, worktree: worktree} do
      pid = start_worker!(ws, task, branch, worktree)

      # The whole sandbox root goes away mid-session — worktree, repo and the
      # only copy of the branch with it.
      File.rm_rf!(worktree)
      refute File.dir?(worktree)

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)

      refute snap.status == :completed
      refute snap.status == :awaiting_review_gate
      refute snap.status == :awaiting_review

      assert snap.meta.stop_reason.category == :workspace_destroyed
      # Distinct from the "never provisioned" condition (bd-7pe74i).
      refute snap.meta.stop_reason.category == :missing_worktree
      assert snap.meta.failure_reason =~ worktree

      # The task stays open — nothing was integrated and nothing may close it.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.status == :closed
    end

    test "escalates to the coordinator naming the destroyed workspace",
         %{ws: ws, task: task, branch: branch, worktree: worktree} do
      pid = start_worker!(ws, task, branch, worktree)
      File.rm_rf!(worktree)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      wait_until(fn ->
        Message.coordinator_ref()
        |> Message.inbox(workspace_id: ws.id)
        |> Enum.any?(&(&1.kind == :escalation and &1.directive_ref == task.id))
      end)

      escalation =
        Message.coordinator_ref()
        |> Message.inbox(workspace_id: ws.id)
        |> Enum.find(&(&1.kind == :escalation and &1.directive_ref == task.id))

      assert escalation
      assert escalation.body =~ "workspace"
      assert escalation.body =~ worktree
      assert escalation.subject =~ "workspace destroyed mid-run"

      # The generic stopped-worker page offers "resume … from the preserved
      # worktree". There is no preserved worktree here — that hint would send
      # the operator (or an auto-resume) into a directory that is gone.
      refute escalation.body =~ "preserved worktree"
      refute escalation.body =~ "arb worker resume"
      assert escalation.body =~ "unrecoverable"
    end

    test "an intact workspace is not reported as destroyed",
         %{ws: ws, task: task, branch: branch, worktree: worktree} do
      pid = start_worker!(ws, task, branch, worktree)

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> Worker.state(pid).status != :claude end)

      snap = Worker.state(pid)
      refute match?(%{stop_reason: %{category: :workspace_destroyed}}, snap.meta)
    end
  end

  describe "a destroyed origin repo, worktree intact" do
    test "is reported as the repo checkout, not the worktree",
         %{ws: ws, task: task, branch: branch, worktree: worktree} do
      repo =
        Path.join(
          Arbiter.Config.Paths.scratch_root(),
          "wd-repo-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(repo)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ws.id,
          meta: %{
            issue_type: :feature,
            branch: branch,
            target_branch: "main",
            worktree_path: worktree,
            repo_path: repo
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)

      # Only the repo/origin side goes — cr-ag13cz's shape, where the bare
      # origin was co-located with the worktree and both were lost. The
      # worktree is still there, so the failure must name the repo.
      File.rm_rf!(repo)

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      assert snap.meta.stop_reason.category == :workspace_destroyed
      assert snap.meta.failure_reason =~ "repo checkout"
      assert snap.meta.failure_reason =~ repo
      assert File.dir?(worktree)
    end
  end

  describe "subprocess stop with a destroyed workspace" do
    test "is classified :workspace_destroyed rather than resumed or :crashed",
         %{ws: ws, task: task, branch: branch, worktree: worktree} do
      pid = start_worker!(ws, task, branch, worktree)

      # A REAL session port whose cwd is the provisioned worktree. The tree is
      # deleted while the subprocess is still alive, so the exit arrives with
      # the workspace already gone — the live shape of the incident.
      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: worktree,
          command: ["sh", "-c", "sleep 0.4; exit 0"]
        )

      File.rm_rf!(worktree)
      refute File.dir?(worktree)

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      assert snap.meta.stop_reason.category == :workspace_destroyed
      refute snap.status == :resuming
    end
  end
end
