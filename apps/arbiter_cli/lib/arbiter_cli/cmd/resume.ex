defmodule ArbiterCli.Cmd.Resume do
  @moduledoc """
  `arb resume <bead-id> [<rig>] [--model <name>]` — resume a stopped worker
  (bd-auma3z).

  When a worker is stopped mid-work (token exhaustion, crash, kill) its
  worktree — the per-bead git worktree with its committed and uncommitted
  progress — is preserved. `arb resume` re-attaches a **fresh** agent to that
  same worktree, briefed with a git-derived summary of the work so far, so it
  continues from where the stopped run left off instead of restarting from
  scratch.

  POSTs to `/api/polecats/:bead_id/resume`. The server validates the bead has a
  preserved worktree and isn't being actively worked, stops the lingering
  stopped polecat, and slings a fresh claude-driven worker onto the existing
  branch — reusing any already-open PR rather than opening a duplicate.

  The rig is optional: if omitted, it's inherited from the bead's most recent
  run. Pass it explicitly when no prior run is on record.

  Flags:
    --model <name>   one-shot override of the model the resumed worker runs on
                     (`haiku|sonnet|opus`).
    --json           emit JSON instead of human-readable text.
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean, model: :string]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text
      model = opts[:model]

      {bead_id, rig} =
        case rest do
          [id] -> {id, nil}
          [id, rig] -> {id, rig}
          [] -> Output.die("resume requires a bead id (e.g. `arb resume bd-auma3z`)")
          _ -> Output.die("resume takes at most two positional arguments: <bead-id> [<rig>]")
        end

      body =
        %{}
        |> maybe_put("rig", rig)
        |> maybe_put("model", model)

      case Client.post("/api/polecats/#{bead_id}/resume", body) do
        {:ok, payload} -> emit(payload, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit(payload, :text) do
    bead = payload["bead"] || %{}
    polecat = payload["polecat"] || %{}
    machine = payload["machine"] || %{}

    IO.puts("Resume:")
    IO.puts("  Issue:     #{bead["id"]} — #{bead["title"]}")
    IO.puts("  Status:   #{bead["status"]}")
    IO.puts("  Worker:  #{polecat["pid"]}")
    IO.puts("  Machine:  #{machine["id"]} #{machine["pid"]}")

    case payload["worktree_path"] do
      nil -> :ok
      path -> IO.puts("  Worktree: #{path} (reused)")
    end

    case payload["claude_started"] do
      true -> IO.puts("  Claude:   resumed")
      _ -> :ok
    end
  end
end
