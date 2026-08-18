defmodule Arbiter.Worker.DivergedPushEscalationTest do
  @moduledoc """
  Regression test for bd-3doy0y finding 4: nothing exercised
  `merge_failure_subject/2` / `merge_failure_body/3` for the `:diverged`
  reason end-to-end, which is how finding 1 (the double-wrapped
  `{:push_failed, {:push_failed, {:diverged, _}}}` term never matching
  `diverged_push_error?/1`) shipped undetected — the mechanics tests in
  `push_before_pr_test.exs` and `worktree_test.exs` cover the reconcile
  itself, but not the escalation the operator actually reads.

  Drives the full two-writer shape through `merge_branch/3 ->
  park_merge_failure/3 -> escalate_merge_failure/3`: a ReviewGate
  implementer round pushes a commit to `origin/<branch>` that edits the same
  file the main worker's own worktree commit also edits, so the
  reconcile-before-push rebase hits a REAL conflict (not just divergence) and
  refuses to push. Asserts the resulting Admiral escalation names divergence
  specifically — not the generic "could not be opened/merged" — and lists
  the conflicting file.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker

  @owner "octo"
  @repo "widget"
  @token "test-token-abc123"

  @ws_github %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => @owner,
        "repo" => @repo,
        "credentials_ref" => @token
      }
    }
  }

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Github.HTTP, fun)

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

  defp new_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "diverged-push-ws-#{System.unique_integer([:positive])}",
        prefix: "dpe",
        config: @ws_github
      })

    ws
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "diverged push escalation",
        workspace_id: ws.id,
        issue_type: :feature
      })

    task
  end

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_repo(tmp, branch) do
    bare = Path.join(tmp, "origin.git")
    work = Path.join(tmp, "repo")
    File.mkdir_p!(work)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", work])
    {_, 0} = git(["config", "user.email", "test@example.com"], work)
    {_, 0} = git(["config", "user.name", "Test"], work)
    {_, 0} = git(["config", "commit.gpgsign", "false"], work)
    File.write!(Path.join(work, "shared.txt"), "base\n")
    {_, 0} = git(["add", "shared.txt"], work)
    {_, 0} = git(["commit", "-q", "-m", "seed"], work)

    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", work, bare])
    {_, 0} = git(["remote", "add", "origin", bare], work)
    {_, 0} = git(["fetch", "-q", "origin"], work)

    wt = Path.join(tmp, "worktrees/wt")
    {_, 0} = git(["worktree", "add", "-b", branch, wt, "HEAD"], work)
    {_, 0} = System.cmd("git", ["-C", wt, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", wt, "config", "user.name", "Test"])
    {_, 0} = System.cmd("git", ["-C", wt, "config", "commit.gpgsign", "false"])

    # Branch exists on origin already, at the same point the worktree's own
    # commit will sit on top of — mirrors a pre-review PR already open.
    {_, 0} = git(["push", "-q", "-u", "origin", branch], wt)

    %{repo: work, bare: bare, worktree: wt}
  end

  test "a real rebase conflict on push escalates as divergence, not a generic merge failure" do
    ws = new_workspace()
    task = new_task(ws)
    branch = "bugfix/#{task.id}-diverged"

    tmp =
      Path.join(
        System.tmp_dir!(),
        "diverged-push-escalation-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    repo = init_repo(tmp, branch)

    # ReviewGate implementer round: a separate clone edits shared.txt and
    # pushes straight to origin/<branch>. This worktree never sees it.
    other = Path.join(tmp, "implementer-clone")
    {_, 0} = System.cmd("git", ["clone", "-q", repo.bare, other])
    {_, 0} = System.cmd("git", ["-C", other, "checkout", "-q", branch])
    {_, 0} = System.cmd("git", ["-C", other, "config", "user.email", "impl@example.com"])
    {_, 0} = System.cmd("git", ["-C", other, "config", "user.name", "Implementer"])
    {_, 0} = System.cmd("git", ["-C", other, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(other, "shared.txt"), "implementer version\n")
    {_, 0} = System.cmd("git", ["-C", other, "add", "shared.txt"])
    {_, 0} = System.cmd("git", ["-C", other, "commit", "-q", "-m", "implementer fix"])
    {_, 0} = System.cmd("git", ["-C", other, "push", "-q", "origin", branch])

    # The main worker's own worktree edits the SAME file differently and
    # never sees the implementer's commit — a real conflict on rebase, not
    # just divergence.
    File.write!(Path.join(repo.worktree, "shared.txt"), "main worker version\n")
    {_, 0} = System.cmd("git", ["-C", repo.worktree, "add", "shared.txt"])
    {_, 0} = System.cmd("git", ["-C", repo.worktree, "commit", "-q", "-m", "main worker fix"])

    meta = %{
      branch: branch,
      target_branch: "main",
      merge_title: "Merge #{task.id}",
      worktree_path: repo.worktree
    }

    {:ok, pid} = Worker.start(task_id: task.id, repo: "widget", workspace_id: ws.id, meta: meta)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)

    stub(fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)
    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)

    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> Worker.state(pid).status == :failed end)

    escalations = Message.inbox("admiral", workspace_id: ws.id)
    escalation = Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == task.id))

    assert escalation
    assert escalation.subject =~ "branch diverged from origin"
    refute escalation.subject =~ "could not be opened/merged"
    assert escalation.body =~ "genuinely diverged"
    assert escalation.body =~ "shared.txt"
  end
end
