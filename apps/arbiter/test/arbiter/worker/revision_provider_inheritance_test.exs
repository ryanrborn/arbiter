defmodule Arbiter.Worker.RevisionProviderInheritanceTest do
  @moduledoc """
  Tests for bd-2exkl0 / #1922:
  ReviewGate impl/fix passes, CI fix passes, conflict resolvers, and resumes
  must inherit the provider of the run they are revising.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Agents
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  require Ash.Query

  defp runs_for_task(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  defp runs_for_worker_type(base_task_id, worker_type) do
    Run
    |> Ash.Query.filter(base_task_id == ^base_task_id and worker_type == ^worker_type)
    |> Ash.read!()
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

  defp wait_until(fun, timeout \\ 5_000) do
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
    tmp = Path.join(System.tmp_dir!(), "rev-provider-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"test/repo" => repo})

    stub_dir = Path.join(tmp, "bin")
    File.mkdir_p!(stub_dir)
    log = Path.join(tmp, "cli-calls.log")

    prepend_path(stub_dir)

    CredentialWatchdog.mark_recovered(Agents.Gemini)
    CredentialWatchdog.mark_recovered(Agents.Claude)
    _ = :sys.get_state(CredentialWatchdog)

    on_exit(fn ->
      CredentialWatchdog.mark_recovered(Agents.Gemini)
      CredentialWatchdog.mark_recovered(Agents.Claude)
      _ = :sys.get_state(CredentialWatchdog)
      File.rm_rf!(tmp)
    end)

    %{repo: repo, tmp: tmp, stub_dir: stub_dir, log: log}
  end

  describe "ReviewGate implementer provider inheritance (AC1, AC2, AC3)" do
    test "implementer fix round inherits gemini from the main run even when workspace defaults to claude",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      # Reviewer stub: requests changes
      write_stub(stub_dir, "claude", """
      echo "claude $@" >> #{log}
      echo "VERDICT: REQUEST_CHANGES"
      echo "- [high] feature.txt:1 needs fix"
      echo "arb done"
      exit 0
      """)

      # Agy stub: can be reviewer or implementer
      write_stub(stub_dir, "agy", """
      echo "agy $@" >> #{log}
      # If implementer, make a commit to satisfy commit gate
      if [ -f feature.txt ]; then
        echo "fixed" >> feature.txt
        git add feature.txt
        git commit -m "implementer fix"
      fi
      echo "arb done"
      exit 0
      """)

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ws-rev-inherit-#{System.unique_integer([:positive])}",
          prefix: "ri",
          config: %{
            "agent" => %{"type" => "claude"},
            "review_agent" => %{"type" => "claude"},
            "review" => %{"required" => true, "rounds" => 2}
          }
        })

      {:ok, task} =
        Ash.create(Issue, %{
          title: "implementer inheritance task",
          workspace_id: ws.id,
          issue_type: :feature
        })

      {:ok, task} = Ash.update(task, %{status: :in_progress})

      branch = "task-#{task.id}"
      :ok = seed_feature_branch(repo, branch)

      # Create author's main run record with provider: "gemini"
      {:ok, _author_run} =
        Ash.create(Run, %{
          task_id: task.id,
          base_task_id: task.id,
          repo: "test/repo",
          workspace_id: ws.id,
          worker_type: :main,
          role: "base",
          provider: "gemini",
          model: "gemini-3.8-flash-medium",
          status: :completed,
          started_at: DateTime.utc_now()
        })

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        review_rounds: 2,
        worktree_path: repo,
        review_verdict_retries: 0,
        review_timeout_ms: 30_000
      }

      {:ok, worker_pid} =
        Worker.start(
          task_id: task.id,
          repo: "test/repo",
          workspace_id: ws.id,
          meta: meta
        )

      on_exit(fn -> if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal) end)
      :ok = Worker.advance(worker_pid, :claude)
      send(worker_pid, {:__claude_session_done__, "arb done"})

      # Wait for review gate to start, reviewer to request changes, and implementer to be spawned
      impl_task_id = "#{task.id}#review#impl1"

      wait_until(fn ->
        calls(log) |> Enum.any?(&String.starts_with?(&1, "agy"))
      end)

      # Verify that agy was invoked for the implementer pass
      call_lines = calls(log)
      assert Enum.any?(call_lines, &String.starts_with?(&1, "claude")), "reviewer should have run on claude"
      assert Enum.any?(call_lines, &String.starts_with?(&1, "agy")), "implementer should have run on agy"

      # Verify run records
      wait_until(fn ->
        case runs_for_task(impl_task_id) do
          [%Run{provider: p}] when not is_nil(p) -> true
          _ -> false
        end
      end)

      [impl_run] = runs_for_task(impl_task_id)
      assert impl_run.provider == "gemini", "implementer pass must record provider as gemini"
      assert impl_run.worker_type == :impl
    end
  end

  describe "Reviewer independence (AC5)" do
    test "review_agent.type continues to govern the reviewer independently of worker's provider",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      write_stub(stub_dir, "claude", """
      echo "claude $@" >> #{log}
      echo "VERDICT: APPROVE"
      echo "arb done"
      exit 0
      """)

      write_stub(stub_dir, "agy", """
      echo "agy $@" >> #{log}
      echo "arb done"
      exit 0
      """)

      # Workspace configures worker agent: gemini, reviewer: claude
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ws-rev-indep-#{System.unique_integer([:positive])}",
          prefix: "ri",
          config: %{
            "agent" => %{"type" => "gemini"},
            "review_agent" => %{"type" => "claude"},
            "review" => %{"required" => true, "rounds" => 1}
          }
        })

      {:ok, task} =
        Ash.create(Issue, %{
          title: "reviewer independence task",
          workspace_id: ws.id,
          issue_type: :feature
        })

      {:ok, task} = Ash.update(task, %{status: :in_progress})

      branch = "task-#{task.id}"
      :ok = seed_feature_branch(repo, branch)

      # Main author run ran on gemini
      {:ok, _author_run} =
        Ash.create(Run, %{
          task_id: task.id,
          base_task_id: task.id,
          repo: "test/repo",
          workspace_id: ws.id,
          worker_type: :main,
          role: "base",
          provider: "gemini",
          status: :completed,
          started_at: DateTime.utc_now()
        })

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

      {:ok, worker_pid} =
        Worker.start(
          task_id: task.id,
          repo: "test/repo",
          workspace_id: ws.id,
          meta: meta
        )

      on_exit(fn -> if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal) end)
      :ok = Worker.advance(worker_pid, :claude)
      send(worker_pid, {:__claude_session_done__, "arb done"})

      rev_task_id = "#{task.id}#review"

      wait_until(fn ->
        calls(log) |> Enum.any?(&String.starts_with?(&1, "claude"))
      end)

      # Reviewer ran on Claude
      call_lines = calls(log)
      assert Enum.any?(call_lines, &String.starts_with?(&1, "claude")), "reviewer must run on claude"
      refute Enum.any?(call_lines, &String.starts_with?(&1, "agy")), "agy should not have run for reviewer"

      # Reviewer run record shows claude
      wait_until(fn ->
        case runs_for_task(rev_task_id) do
          [%Run{provider: p}] when not is_nil(p) -> true
          _ -> false
        end
      end)

      [rev_run] = runs_for_task(rev_task_id)
      assert rev_run.provider == "claude"
      assert rev_run.worker_type == :review
    end
  end

  describe "Unavailable provider fallback (AC4)" do
    test "when original provider credentials are flagged expired, falls back to available provider with coordinator visibility",
         %{repo: _repo, stub_dir: stub_dir, log: log} do
      write_stub(stub_dir, "claude", """
      echo "claude $@" >> #{log}
      if [ -f feature.txt ]; then
        echo "fixed by claude" >> feature.txt
        git add feature.txt
        git commit -m "claude fix"
      fi
      echo "arb done"
      exit 0
      """)

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ws-rev-fallback-#{System.unique_integer([:positive])}",
          prefix: "rf",
          config: %{
            "agent" => %{"type" => ["gemini", "claude"]},
            "review" => %{"required" => true}
          }
        })

      {:ok, task} =
        Ash.create(Issue, %{
          title: "fallback task",
          workspace_id: ws.id,
          issue_type: :feature
        })

      # Main author run ran on gemini
      {:ok, _author_run} =
        Ash.create(Run, %{
          task_id: task.id,
          base_task_id: task.id,
          repo: "test/repo",
          workspace_id: ws.id,
          worker_type: :main,
          role: "base",
          provider: "gemini",
          status: :completed,
          started_at: DateTime.utc_now()
        })

      # Flag Gemini credentials as expired
      stop_reason = %Arbiter.Worker.StopReason{
        category: :auth_expired,
        summary: "credentials expired"
      }
      CredentialWatchdog.mark_expired(Agents.Gemini, stop_reason)
      _ = :sys.get_state(CredentialWatchdog)

      # Attempt resolution for revision
      {provider, fallback_reason} = Agents.resolve_revision_provider(task.id, ws)

      assert provider == :claude
      assert fallback_reason =~ "fell back from gemini"
      assert fallback_reason =~ "credentials flagged expired"
    end
  end

  describe "CI fix pass provider inheritance (AC2)" do
    test "FixPassDispatcher inherits gemini from main run",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      write_stub(stub_dir, "agy", """
      echo "agy $@" >> #{log}
      echo "arb done"
      exit 0
      """)

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ws-fixpass-#{System.unique_integer([:positive])}",
          prefix: "fp",
          config: %{
            "agent" => %{"type" => "claude"},
            "repo_paths" => %{"test/repo" => repo}
          }
        })

      {:ok, task} =
        Ash.create(Issue, %{
          title: "fixpass task",
          workspace_id: ws.id,
          issue_type: :feature
        })

      branch = "task-#{task.id}"
      :ok = seed_feature_branch(repo, branch)

      # Author run used gemini
      {:ok, _author_run} =
        Ash.create(Run, %{
          task_id: task.id,
          base_task_id: task.id,
          repo: "test/repo",
          workspace_id: ws.id,
          worker_type: :main,
          role: "base",
          provider: "gemini",
          status: :completed,
          started_at: DateTime.utc_now()
        })

      context = %{
        task: task,
        repo: "test/repo",
        repo_path: repo,
        branch: branch,
        target_branch: "main",
        workspace: ws
      }

      {:ok, %{worker_pid: pid}} = Arbiter.Workflows.MergeQueue.FixPassDispatcher.dispatch(context)

      wait_until(fn ->
        calls(log) |> Enum.any?(&String.starts_with?(&1, "agy"))
      end)

      # Ensure fix_pass run record has provider: "gemini"
      wait_until(fn ->
        case runs_for_worker_type(task.id, :fix_pass) do
          [%Run{provider: p}] when not is_nil(p) -> true
          _ -> false
        end
      end)

      [fix_run] = runs_for_worker_type(task.id, :fix_pass)
      assert fix_run.provider == "gemini"
      assert fix_run.worker_type == :fix_pass

      Worker.stop(pid, :normal)
    end
  end

  describe "ConflictResolver provider inheritance (AC2)" do
    test "ConflictResolver inherits gemini from main run",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      write_stub(stub_dir, "agy", """
      echo "agy $@" >> #{log}
      echo "arb done"
      exit 0
      """)

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ws-conflict-#{System.unique_integer([:positive])}",
          prefix: "cr",
          config: %{
            "agent" => %{"type" => "claude"},
            "repo_paths" => %{"test/repo" => repo}
          }
        })

      {:ok, task} =
        Ash.create(Issue, %{
          title: "conflict task",
          workspace_id: ws.id,
          issue_type: :feature
        })

      branch = "task-#{task.id}"
      :ok = seed_feature_branch(repo, branch)

      File.write!(Path.join(repo, "other.txt"), "other\n")
      {_, 0} = git(["add", "other.txt"], repo)
      {_, 0} = git(["commit", "-q", "-m", "other work"], repo)
      {_, 0} = git(["push", "-q", "origin", "main"], repo)

      # Author run used gemini
      {:ok, _author_run} =
        Ash.create(Run, %{
          task_id: task.id,
          base_task_id: task.id,
          repo: "test/repo",
          workspace_id: ws.id,
          worker_type: :main,
          role: "base",
          provider: "gemini",
          status: :completed,
          started_at: DateTime.utc_now()
        })

      context = %{
        task: task,
        repo: "test/repo",
        repo_path: repo,
        branch: branch,
        target_branch: "main",
        workspace: ws
      }

      {:ok, %{worker_pid: pid}} = Arbiter.Workflows.MergeQueue.ConflictResolver.dispatch(context)

      wait_until(fn ->
        calls(log) |> Enum.any?(&String.starts_with?(&1, "agy"))
      end)

      wait_until(fn ->
        case runs_for_worker_type(task.id, :conflict) do
          [%Run{provider: p}] when not is_nil(p) -> true
          _ -> false
        end
      end)

      [conflict_run] = runs_for_worker_type(task.id, :conflict)
      assert conflict_run.provider == "gemini"
      assert conflict_run.worker_type == :conflict

      Worker.stop(pid, :normal)
    end
  end
end
