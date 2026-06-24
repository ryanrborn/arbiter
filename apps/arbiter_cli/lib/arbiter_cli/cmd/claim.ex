defmodule ArbiterCli.Cmd.Claim do
  @moduledoc """
  `arb claim <ref> [--force] [--difficulty N] [--repo <repo>] [--json]` — create a task
  linked to a tracker issue assigned to the workspace user.

  POSTs to `/api/workspaces/:workspace_id/claim`. The server dispatches
  through the workspace's configured tracker adapter — GitHub, Jira,
  Shortcut, etc. — so `<ref>` is whatever that tracker uses: a GitHub issue
  number (`arb claim 43`), a Jira key (`arb claim VR-1234`), a Shortcut story
  id, and so on. The adapter fetches the issue, verifies it's assigned to the
  workspace's authenticated user (the adapter-defined claim signal), and
  either creates a new task or returns the existing one if a task already
  references that issue.

  Flags:
    --force        Skip the assignment-as-claim check. Use only when you
                   *know* you want a task for an issue you don't own (e.g.
                   to track someone else's work).
    --difficulty N Task difficulty (0..4): D0 trivial · D1 easy · D2 medium ·
                   D3 hard · D4 very hard. Drives model tier and thinking
                   budget routed to workers. (default: D2 on the server)
    --repo <repo>  Hint for a later `arb dispatch`. Recorded as a tip in the
                   command's text output — not persisted on the task.
    --json         Emit JSON instead of human-readable text.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  @switches [
    force: :boolean,
    difficulty: :integer,
    repo: :string,
    json: :boolean
  ]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      ref =
        case rest do
          [r] ->
            r

          [] ->
            Output.die(
              "claim requires a tracker ref (e.g. `arb claim 43` for GitHub, `arb claim VR-1234` for Jira)"
            )

          _ ->
            Output.die("claim takes a single positional argument: <ref>")
        end

      workspace_id = Workspace.id_or_halt()

      validate_difficulty!(opts[:difficulty])

      body =
        %{"ref" => ref}
        |> maybe_put("force", opts[:force])
        |> maybe_put("difficulty", opts[:difficulty])

      case Client.post("/api/workspaces/#{workspace_id}/claim", body) do
        {:ok, payload} -> emit(payload, opts[:repo], mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp validate_difficulty!(nil), do: :ok
  defp validate_difficulty!(n) when is_integer(n) and n in 0..4, do: :ok

  defp validate_difficulty!(other) do
    Output.die("invalid --difficulty #{inspect(other)} (must be an integer 0..4 / D0..D4)")
  end

  defp emit(payload, _repo, :json), do: IO.puts(Jason.encode!(payload))

  defp emit(payload, repo, :text) do
    task = payload["task"] || %{}

    headline =
      case payload["status"] do
        "created" -> "Claimed #{task["id"]} (new task created)"
        "existing" -> "Already claimed: #{task["id"]}"
        other -> "Claim result: #{other} — #{task["id"]}"
      end

    IO.puts(headline)
    IO.puts("  title:        #{task["title"]}")
    IO.puts("  status:       #{task["status"]}")
    IO.puts("  tracker:      #{task["tracker_type"]}:#{task["tracker_ref"]}")

    if repo do
      IO.puts("")
      IO.puts("Tip: `arb dispatch #{task["id"]} #{repo}` to start work on this task.")
    end
  end
end
