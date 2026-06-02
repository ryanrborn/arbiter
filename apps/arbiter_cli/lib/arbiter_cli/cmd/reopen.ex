defmodule ArbiterCli.Cmd.Reopen do
  @moduledoc """
  `arb reopen <id>` — reopen a closed issue.

  Wraps `POST /api/issues/:id/reopen`, which runs the `:reopen` action: it
  clears `closed_at` and returns the bead to `:open` (and the ready queue).
  `--status open` won't work for this — the GuardStatus FSM rejects moving out
  of `:closed` via `:update`, so a dedicated verb is the supported path.
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean]

  def run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text

    id =
      case rest do
        [id] -> id
        [] -> Output.die("reopen requires an issue id")
        _ -> Output.die("reopen takes exactly one positional argument: the issue id")
      end

    case Client.post("/api/issues/" <> id <> "/reopen", %{}) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(friendly_error(id, err))
    end
  end

  # The FSM guard returns a 422 whose top-level message is the generic
  # "validation failed"; the useful reason ("…must be :closed") lives in the
  # per-field details. Surface that reason so the user understands the bead
  # simply isn't closed, rather than seeing an opaque validation failure.
  defp friendly_error(id, %Client.Error{status: 422} = err) do
    case status_error_message(err) do
      nil -> err
      msg -> "#{id} could not be reopened: #{msg}"
    end
  end

  defp friendly_error(_id, err), do: err

  defp status_error_message(%Client.Error{body: %{"details" => %{"errors" => errors}}})
       when is_list(errors) do
    Enum.find_value(errors, fn
      %{"field" => "status", "message" => msg} when is_binary(msg) -> msg
      _ -> nil
    end)
  end

  defp status_error_message(_), do: nil
end
