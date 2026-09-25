defmodule Arbiter.Worker.ReviewGateFabricatedEvidenceTest do
  @moduledoc """
  bd-80talz: when a ReviewGate reviewer says the work fabricated or falsified
  its evidence, the task goes to the coordinator. No further fix round is
  started on the same provider, either inside the gate's revise loop or by the
  author's automatic fix round (`Arbiter.Worker.maybe_dispatch_fix_round/3`).

  On bd-aro53b the gate did the opposite. Round 1 said the artwork citation
  was false and a fix round ran; the agy implementer replaced a TRUE citation
  with an unverified one and uploaded mockup "screenshots" to catbox.moe.
  Round 2 flagged both, and the author's fix round would have gone to the same
  provider again. The reviewer fixture here prints that round-2 text verbatim.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.StubFixRoundDispatcher
  alias Arbiter.Worker
  alias Arbiter.Worker.EvidenceIntegrity
  alias Arbiter.Worker.ReviewGate

  @fabricated Path.expand("../../fixtures/review_fabricated_evidence.sh", __DIR__)
  @reject_once Path.expand("../../fixtures/review_reject_twice.sh", __DIR__)
  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)
  @aro53b_round2 File.read!(
                   Path.expand("../../fixtures/review_findings_bd_aro53b_round2.md", __DIR__)
                 )

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

    tmp = Path.join(System.tmp_dir!(), "rg_fabricated-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "fabricated-ws-#{System.unique_integer([:positive])}",
        prefix: "fe",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws}
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "evidence task", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  # A live gate: the author signals done, the gate spawns the fixture reviewer
  # and (if it gets that far) the committing implementer.
  defp run_gate(task, repo, review_command) do
    branch = "feature/evidence"
    :ok = seed_feature_branch(repo, branch)

    meta = %{
      branch: branch,
      repo_path: repo,
      target_branch: "main",
      merge_title: "Merge #{task.id}",
      review_required: true,
      review_rounds: 2,
      worktree_path: repo,
      review_command: [review_command],
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
    pid
  end

  defp counter(repo, name) do
    case File.read(Path.join([repo, ".git", name])) do
      {:ok, n} -> String.trim(n)
      {:error, :enoent} -> nil
    end
  end

  describe "a round-1 reviewer that flags fabricated evidence" do
    test "stops the gate's revise loop and escalates instead of a fix round",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = run_gate(task, repo, @fabricated)

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 8_000)

      # One reviewing pass, and the implementer never ran — the gate had a
      # second round in hand and did not spend it.
      assert counter(repo, "review_fabricated_evidence_pass") == "1"
      assert counter(repo, "revise_commit_pass") == nil

      meta = Worker.state(pid).meta
      assert meta.failure_reason == :review_gate_rejected
      assert String.starts_with?(meta.review_gate_findings, EvidenceIntegrity.marker())
      assert meta.review_gate_findings =~ "fabricated static mockup"

      # ...and the author's automatic fix round is not dispatched either: the
      # coordinator gets the one fabricated-evidence page instead.
      wait_until(fn -> StubFixRoundDispatcher.escalations() != [] end)
      assert StubFixRoundDispatcher.dispatch_count() == 0

      assert [{task_id, ws_id, 0, :fabricated_evidence}] = StubFixRoundDispatcher.escalations()
      assert task_id == task.id
      assert ws_id == ws.id

      assert Enum.any?(
               Message.inbox("admiral", workspace_id: ws.id),
               &(&1.task_ref == task.id and &1.body =~ EvidenceIntegrity.marker())
             )
    end

    test "an ordinary rejection still gets the gate's revise round (control)",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = run_gate(task, repo, @reject_once)

      wait_until(fn -> counter(repo, "revise_commit_pass") == "1" end, 8_000)

      wait_until(
        fn -> Worker.state(pid).status in [:failed, :awaiting_review, :completed] end,
        8_000
      )

      refute String.starts_with?(
               Map.get(Worker.state(pid).meta, :review_gate_findings) || "",
               EvidenceIntegrity.marker()
             )
    end
  end

  # The author parks on a verdict the test hands it directly, the way the
  # gate delivers one (`review_spawn: false` skips starting a real gate).
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
    test "is not dispatched when the gate stopped on fabricated evidence",
         %{repo: repo, ws: ws} do
      findings = EvidenceIntegrity.escalation_findings(@aro53b_round2, "FULL TRANSCRIPT")
      task = park_on(ws, repo, "feature/evidence-marker", {:request_changes, findings})
      wait_until(fn -> StubFixRoundDispatcher.escalations() != [] end)

      assert StubFixRoundDispatcher.dispatch_count() == 0
      assert [{task_id, _ws_id, 0, :fabricated_evidence}] = StubFixRoundDispatcher.escalations()
      assert task_id == task.id
    end

    # Round-1 review finding: at the round cap the gate reports its escalation
    # payload — the whole thread, the implementer's replies and the full diff.
    # A diff that touches this very prompt text, or a rebuttal quoting the
    # accusation, must not read as a reviewer flagging fabricated evidence.
    test "is still dispatched for a cap payload whose diff and thread quote the rule's terms",
         %{repo: repo, ws: ws} do
      payload = """
      ReviewGate escalation — not converged after 2 round(s) of review
      (cap 2). The implementer and reviewer did not reach agreement.

      ## Full implementer↔reviewer transcript

      ### Round 1 — Reviewer → Implementer: REQUEST_CHANGES
      - [high] a.ex:1 nil guard missing

      ### Round 1 — Implementer → Reviewer: REBUTTED
      I disagree the icon source is fabricated; the nil guard is fixed.

      ## Current diff (feature/evidence-cap since main)

      ```
      +    honest "not met" is always acceptable. A mockup passed off as a screenshot is not.
      +  # A test helper that fabricates a source map for the icon fixture
      ```
      """

      # The text rule alone would flag it; only the marker decides here.
      assert EvidenceIntegrity.flagged?(payload)

      _task = park_on(ws, repo, "feature/evidence-cap", {:request_changes, payload})
      wait_until(fn -> StubFixRoundDispatcher.dispatch_count() == 1 end)

      assert StubFixRoundDispatcher.escalations() == []
    end
  end

  describe "the gate's own prompts" do
    test "the revise prompt carries the worker rules, including not bowing to a wrong finding",
         %{ws: ws} do
      task = new_task(ws)

      state = %{
        task_id: task.id,
        branch: "feature/evidence",
        target_branch: "main",
        worktree_path: nil,
        round: 1
      }

      prompt = ReviewGate.revise_prompt(state, "VERDICT: REQUEST_CHANGES\n1. cite the source")

      assert prompt =~ EvidenceIntegrity.worker_block()
      assert prompt =~ "Never change a true statement to"
    end

    test "the review prompt says how to report fabricated evidence", %{ws: ws} do
      task = new_task(ws)

      state = %{
        task_id: task.id,
        branch: "feature/evidence",
        target_branch: "main",
        worktree_path: nil,
        round: 1,
        head_sha: nil,
        base_sha: "abc1234"
      }

      assert ReviewGate.review_prompt(state) =~ EvidenceIntegrity.reviewer_block()
    end
  end
end
