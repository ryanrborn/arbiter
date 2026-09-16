defmodule ArbiterCli.Cmd.Dep do
  @moduledoc """
  Dependency subcommand router:

      arb dep add <from> <type> <to>
      arb dep rm  <from> <to> [--type T]

  Edge types:

      depends_on       <from> waits until <to> is closed. Gates dispatch.
      blocks           the mirror image: <to> waits until <from> is closed.
      conflicts_with   symmetric mutex — never run the two at the same time.
                       Honoured by BOTH schedulers: the board's Autopilot and
                       the graph Conductor. A card held by it says
                       `blocked — conflicts with bd-1c4pg3 (running)`, and
                       dispatches once the counterpart merges, closes or is
                       parked.
      parent_of        <from> is the parent (epic) of <to>. Rolls up child
                       progress; does not gate.
      relates_to       informational cross-reference; does not gate.
      discovered_from  <from> was found while working <to>; does not gate.

  A `depends_on` / `blocks` edge that would close a cycle is refused, with the
  cycle named.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
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
