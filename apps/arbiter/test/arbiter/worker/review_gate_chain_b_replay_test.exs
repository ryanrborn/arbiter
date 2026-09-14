defmodule Arbiter.Worker.ReviewGateChainBReplayTest do
  @moduledoc """
  Chain B, replayed (bd-9zuvbh / P9, design #1635 §4.6).

  Four incidents — bd-6dxit2, bd-869mmg, bd-1xss5z, bd-c6tdbu — and four
  different defects, all ending in the same place: **a failed run on work that
  was fine.** §4.6's whole point is that the ending is a policy choice, not a
  parsing problem, and class C removes it without touching the parser (which
  stays bd-3hb4ih's ticket).

  One test per shape, each driving the real gate with a real reviewer fixture
  and asserting the same four things:

    1. the run row says `:review_parked`, not `:failed`;
    2. the task carries the park reason a human can act on;
    3. **exactly one** coordinator escalation (invariant I3);
    4. nothing merged — the content half of the guard is still closed.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  @print_timeout Path.expand("../../fixtures/review_print_timeout.sh", __DIR__)
  @no_verdict_auth_prose Path.expand("../../fixtures/review_no_verdict_auth_prose.sh", __DIR__)
  @unaddressed Path.expand("../../fixtures/review_unaddressed_finding.sh", __DIR__)
  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)
  @revise_commit_once Path.expand("../../fixtures/revise_commit_once.sh", __DIR__)

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

  defp wait_until(fun, timeout) do
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
    tmp = Path.join(System.tmp_dir!(), "chain_b-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "chainb-ws-#{System.unique_integer([:positive])}",
        prefix: "cb",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws}
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "chain-b task", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  # Start a real author + a real gate over `repo`, and wait for the gate to
  # reach its terminal state.
  defp run_gate(task, repo, extra_meta) do
    branch = "feature/chain-b"
    :ok = seed_feature_branch(repo, branch)

    meta =
      Map.merge(
        %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          worktree_path: repo,
          review_timeout_ms: 5_000
        },
        extra_meta
      )

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
    wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 10_000)
    pid
  end

  # The run row for the AUTHORING worker (the reviewer's own passes run under
  # their own `<task>#review…` ids and are irrelevant here).
  defp author_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
    |> List.first()
  end

  defp escalations(ws, task) do
    "admiral"
    |> Message.inbox(workspace_id: ws.id)
    |> Enum.filter(&(&1.directive_ref == task.id and &1.kind == :escalation))
  end

  # The four assertions every chain-B shape must now satisfy.
  defp assert_parked(task, ws, repo, reason) do
    parked = Ash.get!(Issue, task.id)

    assert parked.review_park_reason == Atom.to_string(reason)
    assert %DateTime{} = parked.review_parked_at

    run = author_run(task.id)
    assert run.status == :review_parked, "run was #{run.status}, expected :review_parked"

    assert [escalation] = escalations(ws, task)
    assert escalation.subject =~ "parked"
    assert escalation.body =~ "was NOT failed"

    assert merge_commit_count(repo) == 0
  end

  # bd-6dxit2 / bd-869mmg: the reviewer said something the scan could not parse
  # as a verdict. Today: `:review_gate_inconclusive`, run failed, 52 runs /
  # $226.97. Under class C: one page, parked, run intact.
  test "shape 1 — a verdict the gate cannot parse parks instead of failing the run",
       %{repo: repo, ws: ws} do
    task = new_task(ws)
    run_gate(task, repo, %{review_command: [@no_verdict_auth_prose]})

    assert_parked(task, ws, repo, :inconclusive)
  end

  # bd-1xss5z: the reviewer's own print timeout truncates the review and the CLI
  # still exits 0 with a terminal SUCCESS event. The truncation is still a bug;
  # it stops costing a run.
  test "shape 2 — a reviewer print timeout parks instead of failing the run",
       %{repo: repo, ws: ws} do
    task = new_task(ws)
    run_gate(task, repo, %{review_command: [@print_timeout]})

    assert_parked(task, ws, repo, :reviewer_timeout)

    assert [escalation] = escalations(ws, task)
    assert escalation.body =~ "timed out"
  end

  # bd-c6tdbu, first half: the `:unaddressed_findings` guard (G10) refuses an
  # honest APPROVE over an observation it read as an open finding, the re-prompt
  # budget goes, and the round cap arrives. The APPROVE is still NOT accepted —
  # content stays fail-closed — but the run no longer dies for it.
  test "shape 3 — a verdict guard that exhausts its budget at the round cap parks",
       %{repo: repo, ws: ws} do
    task = new_task(ws)

    run_gate(task, repo, %{
      review_rounds: 2,
      review_command: [@unaddressed, "NOT_ADDRESSED"],
      revise_command: [@revise_commit]
    })

    assert_parked(task, ws, repo, :verdict_guard_exhausted)

    # AC3 — content stays fail-closed. The reviewer's APPROVE was refused, not
    # quietly honoured because the run no longer fails: nothing merged (asserted
    # above), the task never got a reviewed-SHA stamp, and no `:reviewed`
    # coverage row was written for the head.
    parked = Ash.get!(Issue, task.id)
    assert parked.status == :in_progress
    assert parked.last_reviewed_sha == nil
    assert Ash.read!(Arbiter.Reviews.Coverage.Entry) == []
  end

  # bd-c6tdbu, second half: the fix round the gap-rejected APPROVE forced had
  # nothing to fix, so HEAD did not move. The escalation still names the open
  # finding (bd-c6tdbu's own AC4) — it just parks now instead of failing.
  test "shape 4 — a no-op fix round after an approval-gap rejection parks",
       %{repo: repo, ws: ws} do
    task = new_task(ws)

    run_gate(task, repo, %{
      review_rounds: 3,
      review_command: [@unaddressed, "NOT_ADDRESSED"],
      revise_command: [@revise_commit_once]
    })

    assert_parked(task, ws, repo, :no_changes_after_approval_gap)

    assert [escalation] = escalations(ws, task)
    assert escalation.body =~ "APPROVE was rejected ONLY because"
    assert escalation.body =~ "NOT auto-accepted"
  end

  # AC4's other half: re-running the review is one of the two human actions that
  # resolve a park, and it has to clear it *when the gate starts* — not when the
  # next verdict lands — or `arb prime` keeps showing a park somebody is already
  # working on.
  test "re-running the review clears an existing park", %{repo: repo, ws: ws} do
    task = new_task(ws)
    {:ok, :claimed, _} = Arbiter.Tasks.ReviewPark.park(task.id, :inconclusive)

    run_gate(task, repo, %{review_command: [@no_verdict_auth_prose]})

    # The re-run cleared the old park; this run reached its own terminal and
    # parked again, which is a fresh episode with its own page.
    assert [_one] = escalations(ws, task)
    assert Ash.get!(Issue, task.id).review_park_reason == "inconclusive"
  end
end
