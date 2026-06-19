defmodule ArbiterCli.Cmd.Claim do
  @moduledoc """
  `arb claim <issue#> [--force] [--difficulty N] [--rig <rig>] [--json]` — create a bead
  linked to a GitHub issue assigned to the workspace user.

  POSTs to `/api/workspaces/:workspace_id/claim`. The server fetches the
  issue via the workspace's GitHub tracker, verifies it's assigned to the
  workspace's authenticated user (the claim signal), and either creates a
  new bead or returns the existing one if a bead already references that
  issue.

  Flags:
    --force        Skip the assignment-as-claim check. Use only when you
                   *know* you want a bead for an issue you don't own (e.g.
                   to track someone else's work).
    --difficulty N Task difficulty (0..4): D0 trivial · D1 easy · D2 medium ·
                   D3 hard · D4 very hard. Drives model tier and thinking
                   budget routed to workers. (default: D2 on the server)
    --rig <rig>    Hint for a later `arb sling`. Recorded as a tip in the
                   command's text output — not persisted on the bead.
    --json         Emit JSON instead of human-readable text.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  @switches [
    force: :boolean,
    difficulty: :integer,
    rig: :string,
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
          [r] -> r
          [] -> Output.die("claim requires an issue number (e.g. `arb claim 43`)")
          _ -> Output.die("claim takes a single positional argument: <issue#>")
        end

      workspace_id = Workspace.id_or_halt()

      validate_difficulty!(opts[:difficulty])

      body =
        %{"ref" => ref}
        |> maybe_put("force", opts[:force])
        |> maybe_put("difficulty", opts[:difficulty])

      case Client.post("/api/workspaces/#{workspace_id}/claim", body) do
        {:ok, payload} -> emit(payload, opts[:rig], mode)
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

  defp emit(payload, _rig, :json), do: IO.puts(Jason.encode!(payload))

  defp emit(payload, rig, :text) do
    bead = payload["bead"] || %{}

    headline =
      case payload["status"] do
        "created" -> "Claimed #{bead["id"]} (new bead created)"
        "existing" -> "Already claimed: #{bead["id"]}"
        other -> "Claim result: #{other} — #{bead["id"]}"
      end

    IO.puts(headline)
    IO.puts("  title:        #{bead["title"]}")
    IO.puts("  status:       #{bead["status"]}")
    IO.puts("  tracker:      #{bead["tracker_type"]}:#{bead["tracker_ref"]}")

    if rig do
      IO.puts("")
      IO.puts("Tip: `arb sling #{bead["id"]} #{rig}` to start work on this bead.")
    end
  end
end
