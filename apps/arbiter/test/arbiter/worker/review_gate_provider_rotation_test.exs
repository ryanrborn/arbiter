defmodule Arbiter.Worker.ReviewGateProviderRotationTest do
  @moduledoc """
  bd-3hb4ih: on a reviewer `:agent_print_timeout` the ReviewGate must rotate to
  the NEXT provider in the workspace's `review_agent.type` pool rather than
  spending anything on the provider that just hit its own hard print-timeout
  wall (bd-1xss5z) — a re-prompt of the same CLI hits the same wall
  deterministically on a mid-size diff.

  These tests drive the REAL adapter spawn path (no `review_command:` fixture
  escape hatch), with `agy` and `claude` stubbed onto `PATH`, so the provider
  that actually ran each pass is observable from the stub's own invocation log.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Agents
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  # ---- stubs ---------------------------------------------------------------

  # A stub CLI that logs its invocation (one line per call) and then reproduces
  # agy's own print-timeout shape: the fixed timeout warning, a terminal
  # "SUCCESS" result and exit ZERO, with no VERDICT line (the turn was cut off
  # before it could produce one). See test/fixtures/review_print_timeout.sh.
  defp stub_print_timeout(dir, name, log) do
    write_stub(dir, name, """
    echo "#{name}" >> #{log}
    echo "reviewing the diff..."
    echo "[agy] print timeout after 5m0s with turn in progress; returning partial output"
    echo "gemini session SUCCESS · 297s · ~300k tok"
    exit 0
    """)
  end

  # A stub CLI that logs its invocation and returns a clean APPROVE.
  defp stub_approve(dir, name, log) do
    write_stub(dir, name, """
    echo "#{name}" >> #{log}
    echo "reviewing the diff..."
    echo "VERDICT: APPROVE"
    echo "findings: the change looks consistent with the acceptance criteria"
    echo "arb done"
    exit 0
    """)
  end

  # A stub CLI that logs its invocation and dies of expired credentials — an
  # infra failure that is NOT a print-timeout, so it must keep its existing
  # handling (escalate, no rotation). See test/fixtures/review_auth_expired.sh.
  defp stub_auth_expired(dir, name, log) do
    write_stub(dir, name, """
    echo "#{name}" >> #{log}
    echo "reviewing the diff..."
    echo "Error: OAuth token has expired. Please run \\`claude /login\\` to re-authenticate."
    exit 1
    """)
  end

  defp write_stub(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp prepend_path(dir) do
    old = System.get_env("PATH") || ""
    System.put_env("PATH", "#{dir}:#{old}")
    on_exit(fn -> System.put_env("PATH", old) end)
    :ok
  end

  defp calls(log) do
    case File.read(log) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      _ -> []
    end
  end

  # ---- repo / workspace scaffolding ---------------------------------------

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
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "rg-rotate-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    stub_dir = Path.join(tmp, "stub-bin")
    File.mkdir_p!(stub_dir)
    log = Path.join(tmp, "reviewer-calls.txt")

    %{repo: repo, tmp: tmp, stub_dir: stub_dir, log: log}
  end

  defp workspace(type) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "trib-rotate-ws-#{System.unique_integer([:positive])}",
        prefix: "tr",
        config: %{
          "review" => %{"required" => true, "rounds" => 1},
          "review_agent" => %{"type" => type}
        }
      })

    ws
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "review_gate rotation task",
        workspace_id: ws.id,
        issue_type: :feature
      })

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  # Start the author worker parked-ready with a live ReviewGate that routes
  # through the workspace's configured reviewer adapter (no `review_command:`).
  defp run_gate(task, repo, branch) do
    :ok = seed_feature_branch(repo, branch)

    meta = %{
      branch: branch,
      repo_path: repo,
      target_branch: "main",
      merge_title: "Merge #{task.id}",
      review_required: true,
      review_rounds: 1,
      worktree_path: repo,
      review_verdict_retries: 0,
      review_timeout_ms: 30_000
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

  defp review_rounds(task_id) do
    require Ash.Query

    Round
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  defp escalation_for(task_id, ws) do
    "admiral"
    |> Message.inbox(workspace_id: ws.id)
    |> Enum.filter(&(&1.directive_ref == task_id))
  end

  # ---- AC1 / AC6 -----------------------------------------------------------

  describe "reviewer print-timeout rotation (bd-3hb4ih)" do
    test "a gemini print-timeout rotates to claude on the same diff, and the round records the provider that produced the verdict",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_print_timeout(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws)

      run_gate(task, repo, "feature/rot-approve")

      wait_until(fn -> merge_commit_count(repo) == 1 end, 10_000)

      # AC1: the timed-out provider is NOT re-prompted; the next pool entry runs.
      assert calls(log) == ["agy", "claude"]

      rounds = review_rounds(task.id)

      timed_out = Enum.filter(rounds, &(&1.verdict == :timed_out))
      approved = Enum.filter(rounds, &(&1.verdict == :approve))

      # AC6: the rotation itself is in the round history, attributed to gemini…
      assert [%Round{reviewer_provider: "gemini", role: :review}] = timed_out
      # …and the verdict row names the provider that actually produced it.
      assert [%Round{reviewer_provider: "claude", role: :review}] = approved
    end

    # AC2/AC3: the remaining-provider list survives the handoff — the rotated
    # pass knows gemini already timed out, so gemini is never retried in the
    # round; and once EVERY provider has timed out the gate stops rotating and
    # escalates ONCE with each provider's timeout recorded.
    test "when every provider in the pool times out the gate escalates once, naming each provider, and retries none of them",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_print_timeout(stub_dir, "agy", log)
      stub_print_timeout(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws)

      pid = run_gate(task, repo, "feature/rot-exhausted")

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 12_000)

      # AC2: each provider ran exactly once. No provider that timed out was
      # retried inside the round.
      assert calls(log) == ["agy", "claude"]

      assert merge_commit_count(repo) == 0
      assert Worker.state(pid).meta.failure_reason == :review_gate_inconclusive

      # AC3: exactly one escalation, naming both providers' timeouts.
      assert [escalation] = escalation_for(task.id, ws)
      assert escalation.body =~ "gemini"
      assert escalation.body =~ "claude"
      assert escalation.body =~ "every provider"

      refute escalation.body =~ "no parseable VERDICT line",
             "a pool-wide timeout must not be reported as an inconclusive verdict"

      # The park is a reviewer timeout, not a generic reviewer failure.
      task_after = Ash.get!(Issue, task.id)
      assert task_after.review_park_reason == "reviewer_timeout"

      # Both providers' timeouts are recorded structurally, in configured order.
      providers =
        task.id
        |> review_rounds()
        |> Enum.filter(&(&1.verdict == :timed_out))
        |> Enum.map(& &1.reviewer_provider)

      assert "gemini" in providers
      assert "claude" in providers
    end

    # AC4: a single-provider pool keeps today's behaviour — the print-timeout is
    # an infra failure that parks immediately, with no rotation and no pass
    # spent on a second provider.
    test "a single-provider pool does not rotate and parks exactly as today",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_print_timeout(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace("gemini")
      task = new_task(ws)

      pid = run_gate(task, repo, "feature/rot-single")

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 12_000)

      assert calls(log) == ["agy"], "a single-provider pool must not reach another provider"
      assert merge_commit_count(repo) == 0
      assert Worker.state(pid).meta.failure_reason == :review_gate_inconclusive

      assert [escalation] = escalation_for(task.id, ws)
      assert escalation.body =~ "timed out"

      refute escalation.body =~ "every provider",
             "a single-provider pool must not report a pool-wide exhaustion"

      task_after = Ash.get!(Issue, task.id)
      assert task_after.review_park_reason == "reviewer_timeout"
    end

    # AC2 (the identity half): the rotation subtracts the provider that ACTUALLY
    # ran, not the pool head. With gemini inside its circuit-breaker cooldown,
    # ordinary resolution starts the round on claude (the first HEALTHY entry) —
    # so a claude print-timeout has to rotate BACKWARDS to gemini. A rotation
    # that merely counted passes, or that always advanced from the head of the
    # pool, would re-run claude and hit the same wall.
    test "the rotation subtracts the provider that actually ran, not the head of the pool",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_print_timeout(stub_dir, "claude", log)
      stub_approve(stub_dir, "agy", log)
      prepend_path(stub_dir)

      ProviderPool.mark_exhausted(:gemini)
      on_exit(fn -> ProviderPool.record_success(:gemini) end)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws)

      # Precondition: ordinary resolution really does start on claude here.
      assert Agents.reviewer_for_workspace(ws) == Arbiter.Agents.Claude
      assert Agents.reviewer_pool(ws) == [:gemini, :claude]

      run_gate(task, repo, "feature/rot-backwards")

      wait_until(fn -> merge_commit_count(repo) == 1 end, 10_000)

      assert calls(log) == ["claude", "agy"]

      providers =
        task.id
        |> review_rounds()
        |> Enum.map(&{&1.verdict, &1.reviewer_provider})

      assert {:timed_out, "claude"} in providers
      assert {:approve, "gemini"} in providers
    end

    # AC5: only `:agent_print_timeout` rotates. Every other inconclusive cause
    # (no verdict parsed, a crash, a non-timeout infra error) keeps its existing
    # handling even with a multi-provider pool.
    test "a non-timeout infra failure does not rotate, even with a multi-provider pool",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_auth_expired(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws)

      pid = run_gate(task, repo, "feature/rot-auth")

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 12_000)

      assert calls(log) == ["agy"], "an auth failure must not rotate to the next provider"
      assert merge_commit_count(repo) == 0

      assert [escalation] = escalation_for(task.id, ws)
      assert escalation.body =~ "re-authenticate" or escalation.body =~ "expired"

      task_after = Ash.get!(Issue, task.id)
      assert task_after.review_park_reason == "reviewer_failed"
    end
  end
end
