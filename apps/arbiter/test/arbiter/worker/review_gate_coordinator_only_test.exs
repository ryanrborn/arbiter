defmodule Arbiter.Worker.ReviewGateCoordinatorOnlyTest do
  @moduledoc """
  bd-6d3h8m: when a ReviewGate round's every `[NOT MET]` criterion is one the
  reviewer marked as needing coordinator/operator action (not implementer
  work), the gate escalates straight away — no internal revise round, and no
  automatic fix round either.

  On bd-28t80i (PR #2050, 2026-09-25) every round flagged AC3 — verifiable only
  post-deploy — and the fleet still ran 4 implementer passes and 6 reviews
  chasing it before the fix-round budget forced an escalation. The fixture
  here (`review_findings_bd_28t80i_round3.md`) is a reconstruction of that
  shape (a `[NOT MET]` criterion tagged `[NEEDS-COORDINATOR]` alongside a
  `[MET]` one), not a verbatim transcript.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.StubFixRoundDispatcher
  alias Arbiter.Worker
  alias Arbiter.Worker.CoordinatorOnlyFindings

  @bd_28t80i_round3 File.read!(
                      Path.expand("../../fixtures/review_findings_bd_28t80i_round3.md", __DIR__)
                    )
  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)

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
    StubFixRoundDispatcher.reset()

    tmp = Path.join(System.tmp_dir!(), "rg_coordonly-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "coordonly-ws-#{System.unique_integer([:positive])}",
        prefix: "co",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws}
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "coordinator-only task",
        workspace_id: ws.id,
        issue_type: :feature
      })

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  # The author parks on a verdict the test hands it directly, the way the
  # gate delivers one (`review_spawn: false` skips starting a real gate) —
  # mirrors `Arbiter.Worker.ReviewGateFabricatedEvidenceTest`'s `park_on/4`.
  defp park_on(ws, repo, branch, verdict) do
    task = new_task(ws)
    :ok = seed_feature_branch(repo, branch)

    {:ok, pid} =
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

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

    :ok = Worker.review_gate_verdict(pid, verdict)
    task
  end

  describe "the author's automatic fix round" do
    test "is not dispatched when every unmet criterion needs coordinator/operator action",
         %{repo: repo, ws: ws} do
      findings =
        CoordinatorOnlyFindings.escalation_findings(@bd_28t80i_round3, "FULL TRANSCRIPT")

      task = park_on(ws, repo, "feature/coord-only", {:request_changes, findings})
      wait_until(fn -> StubFixRoundDispatcher.escalations() != [] end)

      assert StubFixRoundDispatcher.dispatch_count() == 0
      assert [{task_id, _ws_id, 0, :needs_coordinator}] = StubFixRoundDispatcher.escalations()
      assert task_id == task.id

      assert Enum.any?(
               Message.inbox("admiral", workspace_id: ws.id),
               &(&1.task_ref == task.id and &1.body =~ CoordinatorOnlyFindings.marker())
             )
    end

    test "a plain REQUEST_CHANGES with the same criteria shape but no tag still gets a fix round",
         %{repo: repo, ws: ws} do
      findings = """
      VERDICT: REQUEST_CHANGES
      CRITERIA:
      - [NOT MET] AC3: the guard clause is missing entirely — this is a code fix.
      """

      _task = park_on(ws, repo, "feature/coord-control", {:request_changes, findings})
      wait_until(fn -> StubFixRoundDispatcher.dispatch_count() == 1 end)

      assert StubFixRoundDispatcher.escalations() == []
    end
  end

  describe "the gate's own internal revise loop" do
    test "escalates directly instead of dispatching a revise round", %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/coord-gate"
      :ok = seed_feature_branch(repo, branch)

      fixture = coordinator_only_review_fixture(@bd_28t80i_round3)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        review_rounds: 3,
        worktree_path: repo,
        review_command: [fixture],
        revise_command: [@revise_commit],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: task.workspace_id,
          meta: meta
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 8_000)

      meta = Worker.state(pid).meta
      assert meta.failure_reason == :review_gate_rejected
      assert String.starts_with?(meta.review_gate_findings, CoordinatorOnlyFindings.marker())

      # The gate had 2 more internal rounds in its budget and did not spend
      # them — no revise pass ran.
      refute File.exists?(Path.join([repo, ".git", "revise_commit_pass"]))
    end
  end

  # A tiny inline reviewer fixture that always prints the given findings text,
  # exit 0 — same shape as the checked-in `.sh` fixtures but built per-test so
  # it can carry an arbitrary findings body without a new file on disk.
  defp coordinator_only_review_fixture(findings) do
    dir =
      Path.join(System.tmp_dir!(), "rg_coordonly_fixture-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    script = Path.join(dir, "review.sh")
    findings_file = Path.join(dir, "findings.md")
    File.write!(findings_file, findings)

    File.write!(script, """
    #!/bin/sh
    cat "#{findings_file}"
    exit 0
    """)

    File.chmod!(script, 0o755)
    script
  end
end
