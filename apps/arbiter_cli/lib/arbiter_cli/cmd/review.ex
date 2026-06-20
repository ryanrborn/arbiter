defmodule ArbiterCli.Cmd.Review do
  @moduledoc """
  `arb review <task-id> [--repo <repo>] [--model <name>] [--json]` — dispatch a
  review-only worker against the PR/MR linked to a task.

  POSTs to `/api/workers/review`. The server transitions the task to
  `:in_progress`, attaches the `Arbiter.Workflows.CodeReview` workflow,
  **skips** worktree provisioning and per-task branch creation, and spawns a
  Claude subprocess with a review prompt. The reviewer reads the PR/MR diff,
  posts findings + a verdict via the configured tracker, and prints `arb
  done` — completion runs through the no-branch path
  (`Worker.complete_now(:claude_done)`), bypassing the merge queue/merger.

  ## Flags

    --repo <repo>    Local checkout the reviewer runs in. Required when the
                     reviewer needs `gh` / `glab` / `git` against a real repo
                     (i.e. almost always — without it the reviewer has
                     nowhere to `cd` to).
    --model <name>   one-shot override of the model the reviewer session runs
                     on (`haiku|sonnet|opus`). Takes precedence over the
                     workspace's `agent.config.model` and any routing rule.
    --json           emit JSON instead of human-readable text

  ## What this does NOT do

  Reviews never push, merge, or modify a branch. Adding a `--push` flag
  would defeat the purpose — to dispatch authored work, use `arb dispatch`.
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean, repo: :string, model: :string]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      task_id =
        case rest do
          [id] ->
            id

          [] ->
            Output.die("review requires a task id (e.g. `arb review bd-4b39bf`)")

          _ ->
            Output.die("review takes a single positional argument: <task-id>")
        end

      body =
        %{"task_id" => task_id}
        |> maybe_put("repo", opts[:repo])
        |> maybe_put("model", opts[:model])

      case Client.post("/api/workers/review", body) do
        {:ok, payload} -> emit(payload, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit(payload, :text) do
    task = payload["task"] || %{}
    worker = payload["worker"] || %{}
    machine = payload["machine"] || %{}

    IO.puts("Review dispatched:")
    IO.puts("  Issue:     #{task["id"]} — #{task["title"]}")
    IO.puts("  Status:   #{task["status"]}")
    IO.puts("  Worker:  #{worker["pid"]}")
    IO.puts("  Machine:  #{machine["id"]} #{machine["pid"]}")

    case payload["claude_started"] do
      true -> IO.puts("  Claude:   started")
      _ -> :ok
    end
  end
end
