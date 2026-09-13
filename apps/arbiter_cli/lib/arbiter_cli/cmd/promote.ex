defmodule ArbiterCli.Cmd.Promote do
  @moduledoc """
  `arb issue promote <id> [--waive REASON]` — promote a task from Backlog to Ready.

  Wraps `POST /api/issues/:id/promote`, which runs the `:promote_to_ready` action:
  it sets `refined: true`, moving the task from Backlog to Ready. Idempotent —
  promoting an already-refined task is a no-op success, not an error.

  bd-7mbrlg: a `bug`/`feature`/`chore` with blank `acceptance` is refused
  unless `--waive REASON` is given (`task`/`decision`/`epic` are exempt; D0
  work is auto-waived). The reason is persisted onto the task as
  `acceptance_waived` and shown in `task show`.
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean, waive: :string]

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
    body = waive_body(opts[:waive])

    case Client.post("/api/issues/" <> id <> "/promote", body) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(friendly_error(id, err))
    end
  end

  defp parse_id(rest) do
    case rest do
      [id] -> id
      [] -> Output.die("promote requires an issue id")
      _ -> Output.die("promote takes exactly one positional argument: the issue id")
    end
  end

  defp waive_body(reason) when is_binary(reason) and reason != "",
    do: %{"acceptance_waived" => reason}

  defp waive_body(_), do: %{}

  defp friendly_error(_id, err), do: err
end
