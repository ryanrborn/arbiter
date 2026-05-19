defmodule GtElixirCli.Cmd.Ready do
  @moduledoc """
  `bd2 ready` — list issues that are ready to work on (`GET /api/issues/ready`).

  The server-side `Issue.ready/0` query is what "ready" means; this command
  is a thin shell over it.
  """

  alias GtElixirCli.{Client, Output}

  def run(argv) do
    mode = Output.mode(argv)

    case Client.get("/api/issues/ready") do
      {:ok, %{"data" => issues}} -> Output.emit_issue_list(issues, mode)
      {:ok, other} -> Output.emit_issue_list(List.wrap(other), mode)
      {:error, err} -> Output.die(err)
    end
  end
end
