defmodule GtElixirCli.Cmd.Sling do
  @moduledoc """
  `bd2 sling <bead-id> [<rig>]` — spawn a polecat to work on a bead.

  POSTs to `/api/polecats/sling`. The server transitions the bead to
  `:in_progress`, starts a polecat GenServer under
  `GtElixir.Polecat.Supervisor`, and attaches `GtElixir.Workflows.Work` via
  the WorkflowMachine.

  Flags:
    --json    emit JSON instead of human-readable text
  """

  alias GtElixirCli.{Client, Output}

  @switches [json: :boolean]

  def run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text

    {bead_id, rig} =
      case rest do
        [id] -> {id, nil}
        [id, rig] -> {id, rig}
        [] -> Output.die("sling requires an issue id (e.g. `bd2 sling gte-006`)")
        _ -> Output.die("sling takes at most two positional arguments: <bead-id> [<rig>]")
      end

    body =
      %{"bead_id" => bead_id}
      |> maybe_put("rig", rig)

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
  end
end
