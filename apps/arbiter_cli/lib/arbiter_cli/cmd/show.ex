defmodule ArbiterCli.Cmd.Show do
  @moduledoc """
  `arb show <id>` — display a single issue's details.

  Flags:
    --json    emit JSON instead of human-readable text
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    mode = Output.mode(argv)
    rest = Output.drop_json(argv)

    case rest do
      [id] -> show(id, mode)
      [] -> Output.die("show requires an issue id (e.g. `arb show gte-006`)")
      _ -> Output.die("show takes exactly one argument: the issue id")
    end
  end

  defp show(id, mode) do
    case Client.get("/api/issues/" <> id) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end
end
