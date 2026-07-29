defmodule Arbiter.Worker.PromptPersistenceTest do
  @moduledoc """
  End-to-end coverage for bd-9rdwe4 (#1017 gap G5): every agent run persists
  its composed prompt, redacted, retrievable by `run_id`, with a SHA-256
  anchored on the Run row.

  Mirrors `Arbiter.Worker.WorkerEnvE2ETest`'s shape (a real `Workspace` with a
  secret-flagged worker env var, a real `Worker` + `Port`) to prove the
  redaction choke-point actually reaches the persisted prompt file, not just
  the transcript.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.PromptLog
  alias Arbiter.Workers.Run

  require Ash.Query

  @scope_token "mcp_scope_tok_supersecret"

  defp new_workspace_with_secret(secret) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "prompt-persist-ws-#{System.unique_integer([:positive])}",
        worker_env: %{
          "MCP_SCOPE_TOKEN" => %{"value" => secret, "secret" => true}
        }
      })

    ws
  end

  defp latest_run!(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  test "the composed prompt is persisted, redacted, and hashed onto the Run row" do
    ws = new_workspace_with_secret(@scope_token)
    {:ok, task} = Ash.create(Issue, %{title: "prompt persistence", workspace_id: ws.id})

    {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    prompt = "You are a worker. MCP token: #{@scope_token}\n\nDo the thing."

    # Mirrors how Dispatch/ReviewGate call this: a caller-built argv via
    # `:command` (so no real `claude` spawns in the test), plus the raw
    # `:prompt` the worker should persist alongside it.
    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: System.tmp_dir!(),
        command: ["true"],
        prompt: prompt
      )

    run = latest_run!(task.id)
    assert %Run{} = run

    assert {:ok, persisted} = PromptLog.read(run.id)
    refute persisted =~ @scope_token
    assert persisted =~ "[REDACTED]"
    assert persisted == "You are a worker. MCP token: [REDACTED]\n\nDo the thing."

    assert run.prompt_sha256 == PromptLog.sha256(persisted)
    assert String.length(run.prompt_sha256) == 64
  end

  test "no prompt is persisted when the spawn carried none (command-only fixture)" do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "no-prompt-ws-#{System.unique_integer([:positive])}"})

    {:ok, task} = Ash.create(Issue, %{title: "no prompt", workspace_id: ws.id})
    {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    {:ok, _port} =
      ClaudeSession.start(owner: pid, worktree_path: System.tmp_dir!(), command: ["true"])

    run = latest_run!(task.id)
    assert {:error, :enoent} = PromptLog.read(run.id)
    assert run.prompt_sha256 == nil
  end
end
