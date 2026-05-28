defmodule ArbiterCli.Cmd.Message do
  @moduledoc """
  `arb message <bead-id> <text>` — send a direction to a running acolyte.

  Writes a `:direction` mailbox message from "admiral" to the bead. The
  acolyte picks it up next time it runs `arb inbox <bead-id>`.

  The text can be multiple words (no quoting required):

      arb message bd-xyz check the API contract before you refactor

  Flags:
    --json    emit the created message as JSON
  """

  alias ArbiterCli.{Client, Output, Workspace}

  def run(argv) do
    mode = Output.mode(argv)
    rest = Output.drop_json(argv)

    case rest do
      [bead_id | [_ | _] = words] ->
        send_message(bead_id, Enum.join(words, " "), mode)

      [_bead_id] ->
        Output.die("message requires text: `arb message <bead-id> <text>`")

      _ ->
        Output.die("message requires: <bead-id> <text>")
    end
  end

  defp send_message(bead_id, text, mode) do
    workspace_id = Workspace.id_or_halt()

    body = %{
      kind: "direction",
      from_ref: "admiral",
      to_ref: bead_id,
      body: text,
      workspace_id: workspace_id
    }

    case Client.post("/api/messages", body) do
      {:ok, message} -> emit(message, bead_id, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit(message, _bead_id, :json), do: IO.puts(Jason.encode!(message))

  defp emit(_message, bead_id, :text) do
    IO.puts("Direction sent to #{bead_id}.")
  end
end
