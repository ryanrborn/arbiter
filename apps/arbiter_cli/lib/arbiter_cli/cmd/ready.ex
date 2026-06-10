defmodule ArbiterCli.Cmd.Ready do
  @moduledoc """
  `arb ready [--all] [--json]` — list issues ready to work on
  (`GET /api/issues/ready`).

  By default filters to the active workspace (resolved via `ARB_WORKSPACE`
  or the workspace named `default`). Pass `--all` to see ready issues
  across every workspace — useful for cross-workspace coordination but
  noisy when imported data dominates other workspaces.

  The server-side `Issue.ready/1` query is what "ready" means; this
  command is a thin shell over it.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  @switches [json: :boolean, all: :boolean]

  def run(argv) do
    if "--help" in argv or "-h" in argv do
      IO.puts(@moduledoc)
    else
      {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      params = ready_params(opts)

      case Client.get("/api/issues/ready", params) do
        {:ok, %{"data" => issues}} -> Output.emit_issue_list(issues, mode)
        {:ok, other} -> Output.emit_issue_list(List.wrap(other), mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp ready_params(opts) do
    cond do
      opts[:all] == true ->
        []

      true ->
        case Workspace.resolve() do
          {:ok, %{"id" => ws_id}} -> [workspace_id: ws_id]
          {:error, _} -> []
        end
    end
  end
end
