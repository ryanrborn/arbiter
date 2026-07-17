defmodule Arbiter.Worker.WorkerEnvE2ETest do
  @moduledoc """
  End-to-end integration for user-defined worker env vars (bd-62d3jh): a real
  `Worker` + real `Port` + a persisted `Workspace`, exercising the whole pipeline
  at once — `WorkerEnv.pairs/1` injection through `ClaudeSession.env_pairs/3`,
  and `Redaction` of secret-flagged values at the `emit_line` choke-point.

  Covers both port-open paths: the initial `ClaudeSession.start/1` spawn, and a
  gate-nudge respawn (`Worker.respawn_with_nudge/3`), which reopens a port on
  the ORIGINAL spawn's secret-bearing `:env` and so must rebuild an equally
  redacting session config.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.Worktree

  @secret "tok-supersecret"

  defp new_workspace(opts \\ []) do
    {:ok, ws} =
      Ash.create(
        Workspace,
        Enum.into(opts, %{
          name: "we-e2e-#{System.unique_integer([:positive])}",
          worker_env: %{
            "MY_PLAIN" => %{"value" => "plain-visible", "secret" => false},
            "MY_SECRET" => %{"value" => @secret, "secret" => true}
          }
        })
      )

    ws
  end

  test "worker child sees injected env vars; secret value is redacted from captured output" do
    ws = new_workspace()
    {:ok, task} = Ash.create(Issue, %{title: "e2e", workspace_id: ws.id})

    {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    cwd = System.tmp_dir!()

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["sh", "-c", "echo PLAIN=$MY_PLAIN; echo SECRET=$MY_SECRET"]
      )

    wait_for_exit(pid)

    lines = Worker.state(pid).meta.output_lines
    plain = Enum.find(lines, &String.starts_with?(&1, "PLAIN="))
    secret = Enum.find(lines, &String.starts_with?(&1, "SECRET="))

    # Injection: both vars reached the child environment.
    assert plain == "PLAIN=plain-visible"
    # Redaction: the secret value never appears; the placeholder does.
    assert secret == "SECRET=[REDACTED]"
    refute Enum.any?(lines, &(&1 =~ @secret))
  end

  describe "gate-nudge respawn" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "we-nudge-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      repo = init_repo(tmp)

      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
      Application.put_env(:arbiter, :repo_paths, %{"we/repo" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :repo_paths)
        File.rm_rf!(tmp)
      end)

      %{repo: repo}
    end

    test "respawned session still redacts the secret from its output", %{repo: repo} do
      # The commit gate relaunches the worker on the SAME port args — including
      # the `:env` carrying MY_SECRET — so the respawned child echoes the secret
      # again. Before the fix the respawn built its session config literally and
      # dropped `:redact_values`, letting the raw value through to the PubSub
      # stream, `worker_runs.output_lines`, and the durable log.
      ws = new_workspace(config: %{"review" => %{"required" => true}})
      {:ok, task} = Ash.create(Issue, %{title: "nudge", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{status: :in_progress})

      branch = "bd-we/#{task.id}"
      path = provision_worktree(repo, branch)
      # Uncommitted change → the commit gate trips on `arb done` and nudges.
      File.write!(Path.join(path, "forgotten.txt"), "edited but not committed\n")

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "we/repo",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            worktree_path: path,
            target_branch: "main",
            commit_nudge_cap: 1,
            review_spawn: false
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)

      # A fixture argv has no prompt slot to splice the nudge into, so the
      # respawn re-runs this same command — which is what we want: it echoes the
      # secret a second time, from the inherited env.
      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: path,
          command: ["sh", "-c", "echo SECRET=$MY_SECRET; echo 'arb done'"]
        )

      # The gate tripped and relaunched, and the respawned session has now
      # exited too (the respawn resets :exit_status to nil).
      wait_until(fn ->
        meta = Worker.state(pid).meta
        Map.get(meta, :commit_nudge_attempts) == 1 and not is_nil(Map.get(meta, :exit_status))
      end)

      # meta.output_lines is synced from the live session, so post-respawn this
      # is the RESPAWNED session's output.
      lines = Worker.state(pid).meta.output_lines

      assert "SECRET=[REDACTED]" in lines
      refute Enum.any?(lines, &(&1 =~ @secret))
    end
  end

  # ---- helpers ------------------------------------------------------------

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)

    # Worktree.create/3 branches from `origin/<base>`, so the repo needs an
    # upstream to consult — mirrors commit_gate_test.exs.
    remote = Path.join(dir, "repo-remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = git(["remote", "add", "origin", remote], repo)
    {_, 0} = git(["push", "-q", "origin", "main"], repo)

    repo
  end

  defp provision_worktree(repo, branch) do
    {:ok, path} = Worktree.create(repo, branch, "main")
    {_, 0} = git(["config", "user.email", "wt@example.com"], path)
    {_, 0} = git(["config", "user.name", "WT"], path)
    {_, 0} = git(["config", "commit.gpgsign", "false"], path)
    path
  end

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met within timeout")
      true -> Process.sleep(25) && do_wait(fun, deadline)
    end
  end

  defp wait_for_exit(pid, tries \\ 100)
  defp wait_for_exit(_pid, 0), do: flunk("worker did not exit")

  defp wait_for_exit(pid, tries) do
    case Worker.state(pid).meta do
      %{exit_status: s} when not is_nil(s) -> :ok
      _ -> Process.sleep(50) && wait_for_exit(pid, tries - 1)
    end
  end
end
