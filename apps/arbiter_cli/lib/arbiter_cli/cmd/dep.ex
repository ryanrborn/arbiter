defmodule ArbiterCli.Cmd.Dep do
  @moduledoc """
  Dependency subcommand router:

      arb dep add <from> <type> <to>
      arb dep rm  <from> <to> [--type T]
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if "--help" in argv or "-h" in argv do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      case rest do
        ["add", from, type, to | _] -> add(from, type, to, mode)
        ["add" | _] -> Output.die("dep add requires: <from> <type> <to>")
        ["rm" | rest] -> rm(rest, mode)
        ["remove" | rest] -> rm(rest, mode)
        [] -> Output.die("dep requires a subcommand: `add` or `rm`")
        [unknown | _] -> Output.die("unknown dep subcommand: #{unknown}")
      end
    end
  end

  defp add(from, type, to, mode) do
    body = %{"from_issue_id" => from, "to_issue_id" => to, "type" => type}

    case Client.post("/api/dependencies", body) do
      {:ok, dep} -> Output.emit_dependency(dep, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp rm(args, mode) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: [type: :string, json: :boolean])

    case positional do
      [from, to] ->
        params = if opts[:type], do: [type: opts[:type]], else: []

        case Client.delete("/api/dependencies/" <> from <> "/" <> to, params) do
          {:ok, _} ->
            if mode == :json do
              IO.puts(Jason.encode!(%{ok: true}))
            else
              IO.puts("removed dependency edge: #{from} -> #{to}")
            end

          {:error, err} ->
            Output.die(err)
        end

      _ ->
        Output.die("dep rm requires: <from> <to> [--type T]")
    end
  end
end
