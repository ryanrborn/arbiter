defmodule ArbiterCli.Cmd.Inbox do
  @moduledoc """
  `arb inbox [<bead-id>]` — show unread mailbox messages and mark them read.

  With a bead id, shows that bead's unread mail (direction from the Admiral,
  flags from sibling acolytes). With no argument, shows ALL unread mailbox
  messages across beads.

  Fetching marks the shown messages read — the inbox is a queue you drain.
  Acolytes run `arb inbox <bead-id>` at the start of each workflow step.

  Flags:
    --json    emit JSON instead of human-readable text
  """

  alias ArbiterCli.{Client, Output}

  @mailbox_kinds ~w(mailbox direction flag)

  def run(argv) do
    mode = Output.mode(argv)
    rest = Output.drop_json(argv)

    case rest do
      [] -> inbox(nil, mode)
      [bead_id] -> inbox(bead_id, mode)
      _ -> Output.die("inbox takes at most one argument: the bead id")
    end
  end

  defp inbox(bead_id, mode) do
    params = [unread: "true"] ++ if(bead_id, do: [to_ref: bead_id], else: [])

    case Client.get("/api/messages", params) do
      {:ok, %{"data" => list}} ->
        messages = Enum.filter(list, &(&1["kind"] in @mailbox_kinds))
        Enum.each(messages, &mark_read/1)
        emit(messages, mode)

      {:ok, _} ->
        emit([], mode)

      {:error, err} ->
        Output.die(err)
    end
  end

  # Best-effort acknowledgement. A failed read shouldn't abort the listing —
  # the operator still sees the message; it just stays unread.
  defp mark_read(%{"id" => id}), do: Client.post("/api/messages/#{id}/read", %{})

  # ---- render ----

  defp emit(messages, :json), do: IO.puts(Jason.encode!(%{"data" => messages}))

  defp emit([], :text), do: IO.puts("(no unread mail)")

  defp emit(messages, :text) do
    IO.puts("Unread mail (#{length(messages)}):")

    Enum.each(messages, fn m ->
      from = m["from_ref"] || "?"
      subject = m["subject"]
      header = "  [#{m["kind"]}] from #{from}" <> if(subject, do: " — #{subject}", else: "")
      IO.puts(header)
      IO.puts("    #{m["body"]}")
    end)
  end
end
