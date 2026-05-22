defmodule ArbiterCli.Cmd.Sling do
  @moduledoc """
  `arb sling <bead-id> [<rig>] [--with-claude]` — spawn a polecat to work
  on a bead.

  POSTs to `/api/polecats/sling`. The server transitions the bead to
  `:in_progress`, starts a polecat GenServer under
  `Arbiter.Polecat.Supervisor`, attaches `Arbiter.Workflows.Work` via
  the WorkflowMachine, and (with `--with-claude`) spawns a Claude
  subprocess in the polecat's worktree.

  Flags:
    --with-claude  spawn a real Claude subprocess in the worktree.
                   Requires a worktree (rig must be in
                   `:arbiter, :rig_paths`) and the `claude` CLI on PATH.
                   **This consumes Anthropic API credits.** Off by default.
    --json         emit JSON instead of human-readable text
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean, with_claude: :boolean]

  def run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text
    with_claude = opts[:with_claude] || false

    {bead_id, rig} =
      case rest do
        [id] -> {id, nil}
        [id, rig] -> {id, rig}
        [] -> Output.die("sling requires an issue id (e.g. `arb sling gte-006`)")
        _ -> Output.die("sling takes at most two positional arguments: <bead-id> [<rig>]")
      end

    body =
      %{"bead_id" => bead_id}
      |> maybe_put("rig", rig)
      |> maybe_put("with_claude", if(with_claude, do: true, else: nil))

    case Client.post("/api/polecats/sling", body) do
      {:ok, payload} -> emit(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit(payload, :text) do
    bead = payload["bead"] || %{}
    polecat = payload["polecat"] || %{}
    machine = payload["machine"] || %{}

    IO.puts("Slung:")
    IO.puts("  Bead:     #{bead["id"]} — #{bead["title"]}")
    IO.puts("  Status:   #{bead["status"]}")
    IO.puts("  Polecat:  #{polecat["pid"]}")
    IO.puts("  Machine:  #{machine["id"]} #{machine["pid"]}")

    case payload["worktree_path"] do
      nil -> :ok
      path -> IO.puts("  Worktree: #{path}")
    end

    case payload["claude_started"] do
      true -> IO.puts("  Claude:   started")
      _ -> :ok
    end
  end
end
