defmodule ArbiterCli.Cmd.Promote do
  @moduledoc """
  `arb promote <id>` — promote a task from Backlog to Ready.

  Wraps `POST /api/issues/:id/promote`, which runs the `:promote_to_ready` action:
  it sets `refined: true`, moving the task from Backlog to Ready. Idempotent —
  promoting an already-refined task is a no-op success, not an error.
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      id =
        case rest do
          [id] -> id
          [] -> Output.die("promote requires an issue id")
          _ -> Output.die("promote takes exactly one positional argument: the issue id")
        end

      case Client.post("/api/issues/" <> id <> "/promote", %{}) do
        {:ok, issue} -> Output.emit_issue(issue, mode)
        {:error, err} -> Output.die(friendly_error(id, err))
      end
    end
  end

  defp friendly_error(_id, err), do: err
end
