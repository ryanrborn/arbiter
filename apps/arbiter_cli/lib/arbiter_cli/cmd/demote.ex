defmodule ArbiterCli.Cmd.Demote do
  @moduledoc """
  `arb issue demote <id>` — demote a task from Ready to Backlog.

  Wraps `POST /api/issues/:id/demote`, which runs the `:return_to_backlog` action:
  it sets `refined: false`, moving the task from Ready back to Backlog.
  Idempotent — demoting an already-backlog task is a no-op success, not an error.

  Refused if the task has a live worker or is in an unsafe state
  (in_progress, awaiting_verification, or closed).
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      do_run(argv)
    end
  end

  defp do_run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text
    id = parse_id(rest)

    case Client.post("/api/issues/" <> id <> "/demote", %{}) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(friendly_error(id, err))
    end
  end

  defp parse_id(rest) do
    case rest do
      [id] -> id
      [] -> Output.die("demote requires an issue id")
      _ -> Output.die("demote takes exactly one positional argument: the issue id")
    end
  end

  defp friendly_error(_id, err), do: err
end
