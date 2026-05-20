defmodule GtElixirCli.Cmd.Polecat do
  @moduledoc """
  Polecat subcommand router:

      bd2 polecat list             — list active polecats with status + step
      bd2 polecat show <bead-id>   — full snapshot incl. recent Claude output
      bd2 polecat stop <bead-id>   — terminate a running polecat cleanly

  Use `bd2 sling` to start a polecat in the first place.
  """

  alias GtElixirCli.{Client, Output}

  def run(argv) do
    mode = Output.mode(argv)
    rest = Output.drop_json(argv)

    case rest do
      ["list" | _] -> list(mode)
      ["ls" | _] -> list(mode)
      ["show", bead_id | _] -> show(bead_id, mode)
      ["show" | _] -> Output.die("polecat show requires: <bead-id>")
      ["stop", bead_id | _] -> stop(bead_id, mode)
      ["stop" | _] -> Output.die("polecat stop requires: <bead-id>")
      [] -> Output.die("polecat requires a subcommand: `list`, `show`, or `stop`")
      [unknown | _] -> Output.die("unknown polecat subcommand: #{unknown}")
    end
  end

  defp list(mode) do
    case Client.get("/api/polecats") do
      {:ok, %{"data" => list}} -> emit_list(list, mode)
      {:ok, _} -> emit_list([], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp show(bead_id, mode) do
    case Client.get("/api/polecats/#{bead_id}") do
      {:ok, snap} -> emit_show(snap, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp stop(bead_id, mode) do
    case Client.post("/api/polecats/#{bead_id}/stop", %{}) do
      {:ok, payload} -> emit_stop(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ---- render ---------------------------------------------------------

  defp emit_show(snap, :json), do: IO.puts(Jason.encode!(snap))

  defp emit_show(snap, :text) do
    IO.puts("Bead:       #{snap["bead_id"]}")
    IO.puts("Status:     #{snap["status"]}")
    IO.puts("Step:       #{snap["current_step"]}")
    IO.puts("Rig:        #{snap["rig"]}")
    IO.puts("Started:    #{snap["started_at"]}")
    if snap["exit_status"], do: IO.puts("Exit:       #{snap["exit_status"]}")
    if snap["result"], do: IO.puts("Result:     #{snap["result"]}")
    if snap["failure_reason"], do: IO.puts("Failure:    #{snap["failure_reason"]}")

    case snap["output_lines"] || [] do
      [] ->
        IO.puts("\n(no output lines captured)")

      lines ->
        IO.puts("\nOutput (#{length(lines)} lines, oldest first):")
        Enum.each(lines, fn line -> IO.puts("  | #{line}") end)
    end
  end

  defp emit_stop(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_stop(payload, :text) do
    IO.puts("Stopped polecat for bead #{payload["bead_id"]}.")
  end

  defp emit_list(list, :json), do: IO.puts(Jason.encode!(%{"data" => list}))

  defp emit_list([], :text), do: IO.puts("(no active polecats)")

  defp emit_list(list, :text) do
    IO.puts("Active polecats (#{length(list)}):")

    Enum.each(list, fn p ->
      IO.puts(
        "  #{p["bead_id"]}  status=#{p["status"]}  step=#{p["current_step"]}  rig=#{p["rig"]}  started=#{p["started_at"]}"
      )
    end)
  end
end
