defmodule Arbiter.Worker.MCPConfigSpawnTest do
  @moduledoc """
  bd-7e8ezw / #2045: every Claude spawn path that gets an isolated worktree
  must hand the agent a working Arbiter MCP config — a `.mcp.json` carrying a
  freshly minted worker token, passed **explicitly** via `--mcp-config`.

  Two separate failures made fix-pass workers report the `arbiter` server as
  not connected:

    * `FixPassDispatcher` never minted a token or wrote `.mcp.json` at all, so
      a fix pass ran with no config, or with the original run's stale file
      (its 4h worker lease long expired).
    * Claude Code applies the *main checkout's* `.claude/settings.local.json`
      to every git worktree of the repo. A `disabledMcpjsonServers:
      ["arbiter"]` there drops the worktree's auto-loaded `.mcp.json` without
      a word, which hit every worker in that workspace. Servers passed with
      `--mcp-config` are not subject to that list.

  Both paths run against `Arbiter.TestSandbox`'s stubbed agent binaries, which
  log their argv, so no real CLI is ever spawned.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Agents
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workflows.MergeQueue.ConflictResolver
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  setup do
    sandbox = TestSandbox.provision!("mcp-config-spawn")

    put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
    put_app_env(:arbiter, :repo_paths, %{"test/repo" => sandbox.repo})

    # config/test.exs turns per-spawn `.mcp.json` injection off.
    prior = Application.get_env(:arbiter, Arbiter.MCP)
    Application.put_env(:arbiter, Arbiter.MCP, Keyword.put(prior || [], :inject_config, true))

    CredentialWatchdog.mark_recovered(Agents.Claude)
    _ = :sys.get_state(CredentialWatchdog)

    # Registered after `provision!/1`, so it runs first (on_exit is LIFO):
    # adopt and stop every worker before the sandbox is deleted.
    on_exit(fn ->
      Application.put_env(:arbiter, Arbiter.MCP, prior)
      TestSandbox.own_live_workers!(sandbox)
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ws-mcp-spawn-#{System.unique_integer([:positive])}",
        prefix: "mcs",
        config: %{
          "agent" => %{"type" => "claude"},
          "repo_paths" => %{"test/repo" => sandbox.repo}
        }
      })

    %{sandbox: sandbox, ws: ws}
  end

  test "a CI fix pass writes a fresh worker token and passes it via --mcp-config",
       %{sandbox: sandbox, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "fix ci", workspace_id: ws.id})
    branch = "task-#{task.id}"
    :ok = TestSandbox.seed_branch!(sandbox, branch)

    {:ok, %{worker_pid: pid, worktree_path: wt}} =
      FixPassDispatcher.dispatch(%{
        task: task,
        repo: "test/repo",
        repo_path: sandbox.repo,
        branch: branch,
        target_branch: "main",
        workspace: ws
      })

    TestSandbox.own!(sandbox, pid)

    config_path = Path.join(wt, ".mcp.json")
    wait_until(fn -> claude_called?(sandbox) end)

    assert File.read!(sandbox.log) =~ "--mcp-config #{config_path}"
    assert_valid_worker_token!(config_path, task.id)
  end

  test "a merge-conflict resolver writes a fresh worker token and passes it via --mcp-config",
       %{sandbox: sandbox, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "resolve conflict", workspace_id: ws.id})
    branch = "task-#{task.id}"
    :ok = TestSandbox.seed_branch!(sandbox, branch)

    # Move main past the branch, or the resolver has nothing to do (:no_op).
    File.write!(Path.join(sandbox.repo, "other.txt"), "other\n")

    for args <- [
          ["add", "other.txt"],
          ["commit", "-q", "-m", "other"],
          ["push", "-q", "origin", "main"]
        ] do
      {_, 0} = System.cmd("git", ["-C", sandbox.repo | args], stderr_to_stdout: true)
    end

    {:ok, %{worker_pid: pid, worktree_path: wt}} =
      ConflictResolver.dispatch(%{
        task: task,
        repo: "test/repo",
        repo_path: sandbox.repo,
        branch: branch,
        target_branch: "main",
        workspace: ws
      })

    TestSandbox.own!(sandbox, pid)

    config_path = Path.join(wt, ".mcp.json")
    wait_until(fn -> claude_called?(sandbox) end)

    assert File.read!(sandbox.log) =~ "--mcp-config #{config_path}"
    assert_valid_worker_token!(config_path, task.id)
  end

  test "a fresh work dispatch passes its injected config via --mcp-config",
       %{sandbox: sandbox, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "do work", workspace_id: ws.id})

    {:ok, result} =
      Dispatch.dispatch(task.id, repo: "test/repo", start_driver: false, start_claude: true)

    TestSandbox.own!(sandbox, result.worker_pid)

    config_path = Path.join(result.worktree_path, ".mcp.json")
    wait_until(fn -> claude_called?(sandbox) end)

    assert File.read!(sandbox.log) =~ "--mcp-config #{config_path}"
    assert_valid_worker_token!(config_path, task.id)
  end

  defp assert_valid_worker_token!(config_path, task_id) do
    %{"mcpServers" => %{"arbiter" => %{"headers" => %{"Authorization" => "Bearer " <> token}}}} =
      config_path |> File.read!() |> Jason.decode!()

    assert {:ok, %Scope{tier: :worker, task_id: ^task_id}} = Scope.from_token(token)
  end

  defp claude_called?(sandbox),
    do: Enum.any?(TestSandbox.calls(sandbox), &String.starts_with?(&1, "claude "))

  defp wait_until(fun, timeout \\ 10_000) do
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
end
