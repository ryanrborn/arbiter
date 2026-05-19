defmodule GtElixirCli.Cmd.Close do
  @moduledoc """
  `bd2 close <id> [--reason ...]` — close an issue.
  """

  alias GtElixirCli.{Client, Output}

  @switches [reason: :string, json: :boolean]

  def run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text

    id =
      case rest do
        [id] -> id
        [] -> Output.die("close requires an issue id")
        _ -> Output.die("close takes exactly one positional argument: the issue id")
      end

    body = if opts[:reason], do: %{"reason" => opts[:reason]}, else: %{}

    case Client.post("/api/issues/" <> id <> "/close", body) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end
end
