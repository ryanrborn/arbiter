defmodule Arbiter.Worker.ReviewGateReconcileTest do
  @moduledoc """
  bd-3wumco: a ReviewGate round that converges to APPROVE *after* an earlier
  round's REQUEST_CHANGES already parked the author at `:failed`.

  Observed on vstim `vs-33ulbf`: round 1 came back "changes requested", the
  worker's run went terminal (`failure_reason: :review_gate_rejected`), and the
  revise loop then kept going on its own — round-2 and round-3 reviews both
  APPROVEd. The approval was reported back to an author already sitting at
  `:failed`, where `review_gate_verdict/2` answered
  `{:invalid_transition, :failed, :review_gate_verdict}` — an error
  `ReviewGate.report/2` discards inside `safe/1`. Net effect: the MR sat open
  with green CI and an approving review, the task stayed `failed` forever, and
  the merge handoff never happened.

  The fix reconciles forward: an APPROVE arriving at a worker whose *only*
  reason for being `:failed` is a ReviewGate rejection overturns that rejection
  and runs the normal approve path (merge / Watchdog handoff). Failures for any
  other reason are untouched, and a late REQUEST_CHANGES / no-verdict is still
  refused — reconciliation only ever moves a task forward.
  """

  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate

  @reviewer Path.expand("../../fixtures/review_verdict.sh", __DIR__)

  # Mirrors Arbiter.Worker.ReviewGateTest's fixture: a working repo with a bare
  # `origin` behind it, so the Direct merger's push has somewhere to land.
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

  defp merge_commit_count(repo) do
    {out, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    out |> String.trim() |> String.to_integer()
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
    tmp = Path.join(System.tmp_dir!(), "rg_reconcile-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "reconcile-ws-#{System.unique_integer([:positive])}",
        prefix: "rc",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws}
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "reconcile task",
        workspace_id: ws.id,
        issue_type: :feature
      })

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  # An author parked at :awaiting_review_gate with `review_spawn: false`, so the
  # rounds' verdicts can be delivered directly (exactly as the gate would).
  defp start_parked_author(task, repo) do
    branch = "feature/rev"
    :ok = seed_feature_branch(repo, branch)

    meta = %{
      branch: branch,
      repo_path: repo,
      target_branch: "main",
      merge_title: "Merge #{task.id}",
      review_required: true,
      review_spawn: false
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
    wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)
    {pid, branch}
  end

  # Drive round 1: REQUEST_CHANGES → the author parks terminal, exactly as
  # production recorded it before the later rounds converged.
  defp reject_round_one(pid) do
    findings = "VERDICT: REQUEST_CHANGES\n- [high] feature.txt:1 Enum.max_by/2 uses term order"
    :ok = Worker.review_gate_verdict(pid, {:request_changes, findings})
    wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)
    assert Worker.state(pid).meta.failure_reason == :review_gate_rejected
    :ok
  end

  defp run_for(task_id) do
    Arbiter.Workers.Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
    |> List.first()
  end

  describe "a later round's APPROVE overturning an earlier rejection" do
    test "reconciles the parked worker forward and merges", %{repo: repo, ws: ws} do
      task = new_task(ws)
      {pid, _branch} = start_parked_author(task, repo)
      :ok = reject_round_one(pid)
      assert merge_commit_count(repo) == 0

      # Round 3 converges. The gate reports it to an author already at :failed.
      :ok =
        Worker.review_gate_verdict(
          pid,
          {:approve, "VERDICT: APPROVE\nAll findings addressed."}
        )

      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end)

      # The merge handoff actually happened — the whole point of the ticket.
      assert merge_commit_count(repo) == 1

      snap = Worker.state(pid)
      assert snap.meta.review_gate_verdict == :approve
      refute Map.has_key?(snap.meta, :failure_reason)
      refute Map.has_key?(snap.meta, :failure_summary)

      # The reversal is recorded, not silent.
      assert snap.meta.review_gate_reconciled_from == :review_gate_rejected

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.notes =~ "ReviewGate verdict: APPROVE"
    end

    test "clears the stale rejection off the durable run row", %{repo: repo, ws: ws} do
      task = new_task(ws)
      {pid, _branch} = start_parked_author(task, repo)
      :ok = reject_round_one(pid)

      failed_run = run_for(task.id)
      assert failed_run.status == :failed
      assert failed_run.failure_reason == ":review_gate_rejected"
      assert is_binary(failed_run.failure_summary)

      :ok = Worker.review_gate_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end)

      reconciled = run_for(task.id)
      assert reconciled.id == failed_run.id
      assert reconciled.status == :completed
      assert is_nil(reconciled.failure_reason)
      assert is_nil(reconciled.failure_summary)
    end

    test "tells the coordinator the earlier rejection was overturned", %{repo: repo, ws: ws} do
      task = new_task(ws)
      {pid, _branch} = start_parked_author(task, repo)
      :ok = reject_round_one(pid)

      :ok = Worker.review_gate_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end)

      mail = Message.inbox("admiral", workspace_id: ws.id)

      assert Enum.any?(mail, fn m ->
               m.directive_ref == task.id and m.subject =~ "reconciled" and
                 m.subject =~ task.id
             end),
             "expected a reconciliation notice for #{task.id}, got: " <>
               inspect(Enum.map(mail, & &1.subject))
    end

    test "an inconclusive review is reconciled the same way", %{repo: repo, ws: ws} do
      task = new_task(ws)
      {pid, _branch} = start_parked_author(task, repo)

      :ok = Worker.review_gate_verdict(pid, {:no_verdict, "reviewer crashed"})
      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)
      assert Worker.state(pid).meta.failure_reason == :review_gate_inconclusive

      :ok = Worker.review_gate_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end)
      assert merge_commit_count(repo) == 1
    end
  end

  describe "reconciliation only ever moves a task forward" do
    test "a late REQUEST_CHANGES on an already-rejected worker is refused",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      {pid, _branch} = start_parked_author(task, repo)
      :ok = reject_round_one(pid)

      assert {:error, {:invalid_transition, :failed, :review_gate_verdict}} =
               Worker.review_gate_verdict(pid, {:request_changes, "VERDICT: REQUEST_CHANGES\nx"})

      assert Worker.state(pid).meta.failure_reason == :review_gate_rejected
      assert merge_commit_count(repo) == 0
    end

    test "an APPROVE does NOT resurrect a worker that failed for a non-review reason",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: %{branch: branch, repo_path: repo, target_branch: "main"}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      :ok = Worker.fail(pid, :merge_conflict)
      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      assert {:error, {:invalid_transition, :failed, :review_gate_verdict}} =
               Worker.review_gate_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})

      assert Worker.state(pid).meta.failure_reason == :merge_conflict
      assert merge_commit_count(repo) == 0
    end
  end

  describe "end-to-end: a live gate reporting into an already-rejected author" do
    # The closest reachable analogue of the production shape (vs-33ulbf): the
    # author is terminal on an earlier round's REQUEST_CHANGES, then a REAL
    # ReviewGate — a real reviewer subprocess, a real verdict parse, a real
    # `report/2` — approves the same branch. Everything between the reviewer's
    # stdout and the merge commit is exercised, not stubbed.
    test "the approval unsticks the task and the branch merges", %{repo: repo, ws: ws} do
      task = new_task(ws)
      {author, branch} = start_parked_author(task, repo)
      :ok = reject_round_one(author)
      assert merge_commit_count(repo) == 0

      {:ok, gate} =
        ReviewGate.start(
          author: author,
          task_id: task.id,
          workspace_id: ws.id,
          repo: "trib/repo",
          worktree_path: repo,
          branch: branch,
          target_branch: "main",
          rounds: 1,
          timeout_ms: 5_000,
          command: [@reviewer, "APPROVE"]
        )

      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, 8_000

      wait_until(fn -> match?(%{status: :completed}, Worker.state(author)) end, 8_000)
      assert merge_commit_count(repo) == 1
      assert Worker.state(author).meta.review_gate_reconciled_from == :review_gate_rejected
    end
  end

  describe "an undeliverable verdict" do
    # The orphan was invisible: `report/2` wrapped the author call in `safe/1`,
    # which passes an `{:error, _}` return straight through unexamined. A gate
    # whose verdict lands nowhere must say so, or the only trace of a converged
    # review that never merged is the absence of a merge.
    test "is logged by the gate rather than silently dropped", %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      # An author that is NOT parked at the gate — it refuses any verdict, the
      # same way a worker already parked terminal for a non-review reason does.
      {:ok, author} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: %{branch: branch, repo_path: repo, target_branch: "main"}
        )

      on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
      :ok = Worker.advance(author, :claude)

      log =
        capture_log(fn ->
          {:ok, gate} =
            ReviewGate.start(
              author: author,
              task_id: task.id,
              workspace_id: ws.id,
              repo: "trib/repo",
              worktree_path: repo,
              branch: branch,
              target_branch: "main",
              rounds: 1,
              timeout_ms: 5_000,
              command: [@reviewer, "APPROVE"]
            )

          ref = Process.monitor(gate)
          assert_receive {:DOWN, ^ref, :process, ^gate, _}, 8_000
        end)

      assert log =~ "could not deliver"
      assert log =~ task.id
      assert log =~ "invalid_transition"
    end
  end
end
