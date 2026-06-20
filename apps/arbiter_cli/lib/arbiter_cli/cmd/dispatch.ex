defmodule ArbiterCli.Cmd.Dispatch do
  @moduledoc """
  `arb dispatch <task-id> [<repo>] [--provider claude|gemini | --no-agent] [--model <name>]`
  — spawn a worker to work on a task.

  POSTs to `/api/workers/dispatch`. The server transitions the task to
  `:in_progress`, starts a worker GenServer under
  `Arbiter.Worker.Supervisor`, attaches `Arbiter.Workflows.Work` via
  the WorkflowMachine, and spawns an agent subprocess in the worktree.

  By default (no worker flag) the server reads the workspace's `agent.type`
  config and spawns that agent. Use `--provider` to force a specific provider,
  or `--no-agent` to park the task for a manual attach instead.

  Flags:
    --provider <p>   force the worker provider regardless of the workspace's
                     `agent.type`. One of `claude` | `gemini`. `claude`
                     requires the `claude` CLI on PATH (consumes Anthropic
                     credits); `gemini` requires the `agy`/`gemini` CLI on PATH
                     (consumes Google credits).
    --with-claude    DEPRECATED alias for `--provider claude`.
    --with-gemini    DEPRECATED alias for `--provider gemini`.
    --no-agent       dry dispatch — park the task in `:in_progress` for a hand
                     to attach, with no agent spawned. Preserves the old
                     manual-attach path.
    --model <name>   one-shot override of the model the worker session runs
                     on (`haiku|sonnet|opus`). Takes precedence over the
                     workspace's `agent.config.model` and any routing rule
                     for the task.
    --json           emit JSON instead of human-readable text
  """

  alias ArbiterCli.{Client, Output}

  @switches [
    json: :boolean,
    provider: :string,
    with_claude: :boolean,
    with_gemini: :boolean,
    no_agent: :boolean,
    model: :string
  ]

  @providers ~w(claude gemini)

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text
      model = opts[:model]

      {task_id, repo} =
        case rest do
          [id] -> {id, nil}
          [id, repo] -> {id, repo}
          [] -> Output.die("dispatch requires an issue id (e.g. `arb dispatch gte-006`)")
          _ -> Output.die("dispatch takes at most two positional arguments: <task-id> [<repo>]")
        end

      worker =
        cond do
          opts[:provider] -> %{"provider" => validate_provider(opts[:provider])}
          # Deprecated aliases — map to the same `provider` wire field the server
          # now understands so old scripts keep working unchanged.
          opts[:with_claude] -> %{"with_claude" => true}
          opts[:with_gemini] -> %{"with_gemini" => true}
          opts[:no_agent] -> %{"no_agent" => true}
          true -> %{}
        end

      body =
        %{"task_id" => task_id}
        |> Map.merge(worker)
        |> maybe_put("repo", repo)
        |> maybe_put("model", model)

      case Client.post("/api/workers/dispatch", body) do
        {:ok, payload} -> emit(payload, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp validate_provider(p) when p in @providers, do: p

  defp validate_provider(p) do
    Output.die("--provider must be one of #{Enum.join(@providers, " | ")} (got #{inspect(p)})")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit(payload, :text) do
    task = payload["task"] || %{}
    worker = payload["worker"] || %{}
    machine = payload["machine"] || %{}

    IO.puts("Dispatch:")
    IO.puts("  Issue:     #{task["id"]} — #{task["title"]}")
    IO.puts("  Status:   #{task["status"]}")
    IO.puts("  Worker:  #{worker["pid"]}")
    IO.puts("  Machine:  #{machine["id"]} #{machine["pid"]}")

    case payload["worktree_path"] do
      nil -> :ok
      path -> IO.puts("  Worktree: #{path}")
    end

    case payload["claude_started"] do
      true -> IO.puts("  Worker: started")
      _ -> :ok
    end
  end
end
