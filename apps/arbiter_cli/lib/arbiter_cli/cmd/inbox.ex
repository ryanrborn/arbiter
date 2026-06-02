defmodule ArbiterCli.Cmd.Inbox do
  @moduledoc """
  `arb inbox` — the Admiral's mailbox: messages acolytes (and the system) send
  *up* the chain — completions, failures, escalations, FYIs.

  Usage:

      arb inbox                 unread mail addressed to the Admiral
      arb inbox --all           the 20 most recent (read + unread)
      arb inbox read <id>       show one message in full, mark it read
      arb inbox clear           destroy every already-read Admiral message
      arb inbox <bead-id>       (acolyte path) a bead's unread mail; drained
                                — marked read on fetch

  The Admiral view is read-only triage: listing does NOT mark mail read. You
  drain it deliberately with `read <id>` (one) and `clear` (the read tail).
  The bead path is the inverse — acolytes auto-drain their queue on fetch, so
  `arb inbox <bead-id>` at the top of each workflow step shows new direction
  exactly once.

  Line format:

      0b9d1f2a  [bd-1qx1nt] completion from acolyte-019e — GitLab adapter complete (2m ago)

  The leading token is a short message id — pass it (or a unique prefix) to
  `arb inbox read`. The bracket is the directive the message concerns.

  Flags:
    --json    emit JSON instead of human-readable text
  """

  alias ArbiterCli.{Client, Output}

  @admiral "admiral"
  @all_limit 20
  # Kinds the acolyte (bead) path surfaces — addressed, read-acknowledged.
  @mailbox_kinds ~w(mailbox direction flag completion failure escalation info)

  def run(argv) do
    mode = Output.mode(argv)

    case Output.drop_json(argv) do
      [] -> admiral_inbox(true, mode)
      ["--all"] -> admiral_inbox(false, mode)
      ["read", id] -> read_one(id, mode)
      ["read"] -> Output.die("inbox read requires a message id: `arb inbox read <id>`")
      ["clear"] -> clear(mode)
      [bead_id] -> bead_inbox(bead_id, mode)
      _ -> Output.die("inbox: unrecognized arguments. See `arb help`.")
    end
  end

  # ---- admiral views -------------------------------------------------------

  defp admiral_inbox(unread_only, mode) do
    params =
      if unread_only,
        do: [to_ref: @admiral, unread: "true"],
        else: [to_ref: @admiral, limit: @all_limit]

    case Client.get("/api/messages", params) do
      {:ok, %{"data" => list}} -> emit_list(list, mode, admiral_label(unread_only, list))
      {:ok, _} -> emit_list([], mode, admiral_label(unread_only, []))
      {:error, err} -> Output.die(err)
    end
  end

  defp admiral_label(true, list),
    do: {"Admiral inbox — #{length(list)} unread:", "(admiral inbox empty — no unread mail)"}

  defp admiral_label(false, list),
    do: {"Admiral inbox — #{length(list)} recent:", "(admiral inbox empty)"}

  # ---- acolyte (bead) path -------------------------------------------------

  defp bead_inbox(bead_id, mode) do
    case Client.get("/api/messages", to_ref: bead_id, unread: "true") do
      {:ok, %{"data" => list}} ->
        mail = Enum.filter(list, &(&1["kind"] in @mailbox_kinds))
        Enum.each(mail, &mark_read/1)

        emit_list(
          mail,
          mode,
          {"Unread mail for #{bead_id} (#{length(mail)}):", "(no unread mail)"}
        )

      {:ok, _} ->
        emit_list([], mode, {"", "(no unread mail)"})

      {:error, err} ->
        Output.die(err)
    end
  end

  # Best-effort acknowledgement. A failed read shouldn't abort the listing —
  # the operator still sees the message; it just stays unread.
  defp mark_read(%{"id" => id}), do: Client.post("/api/messages/#{id}/read", %{})

  # ---- read one ------------------------------------------------------------

  defp read_one(token, mode) do
    case resolve_id(token) do
      {:ok, id} ->
        case Client.post("/api/messages/#{id}/read", %{}) do
          {:ok, message} -> emit_full(message, mode)
          {:error, err} -> Output.die(err)
        end

      {:error, msg} ->
        Output.die(msg)
    end
  end

  # A full uuid passes straight through; a short prefix is resolved against the
  # Admiral's mail (the list the operator just read these ids from).
  defp resolve_id(token) do
    if full_uuid?(token) do
      {:ok, token}
    else
      case Client.get("/api/messages", to_ref: @admiral, limit: 50) do
        {:ok, %{"data" => list}} -> match_prefix(list, token)
        {:ok, _} -> {:error, "no admiral message matches id #{inspect(token)}"}
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp match_prefix(list, token) do
    case Enum.filter(list, &String.starts_with?(to_string(&1["id"]), token)) do
      [%{"id" => id}] -> {:ok, id}
      [] -> {:error, "no admiral message matches id #{inspect(token)}"}
      _ -> {:error, "ambiguous id prefix #{inspect(token)} — give more characters"}
    end
  end

  defp full_uuid?(token), do: String.length(token) == 36 and String.contains?(token, "-")

  # ---- clear ---------------------------------------------------------------

  defp clear(mode) do
    case Client.delete("/api/messages", to_ref: @admiral) do
      {:ok, %{"data" => %{"deleted" => n}}} -> emit_cleared(n, mode)
      {:ok, _} -> emit_cleared(0, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_cleared(n, :json), do: IO.puts(Jason.encode!(%{"deleted" => n}))

  defp emit_cleared(0, :text), do: IO.puts("Nothing to clear (no read mail).")
  defp emit_cleared(n, :text), do: IO.puts("Cleared #{n} read message#{plural(n)}.")

  defp plural(1), do: ""
  defp plural(_), do: "s"

  # ---- render --------------------------------------------------------------

  defp emit_list(list, :json, _labels), do: IO.puts(Jason.encode!(%{"data" => list}))

  defp emit_list([], :text, {_present, empty}), do: IO.puts(empty)

  defp emit_list(list, :text, {present, _empty}) do
    IO.puts(present)
    Enum.each(list, fn m -> IO.puts("  " <> format_line(m)) end)
  end

  defp emit_full(message, :json), do: IO.puts(Jason.encode!(message))

  defp emit_full(m, :text) do
    vern = ArbiterCli.Vernacular.fetch()
    directive = m["directive_ref"]

    fields =
      [
        {"From", m["from_ref"]},
        {"To", m["to_ref"]},
        {"Kind", m["kind"]},
        {ArbiterCli.Vernacular.cap(vern, "issue"), directive},
        {"Subject", m["subject"]},
        {"Sent", m["inserted_at"]}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.map(fn {k, v} -> "#{String.pad_trailing(k <> ":", 11)}#{v}" end)

    IO.puts(Enum.join(fields, "\n"))
    IO.puts("")
    IO.puts(m["body"] || "")
  end

  # `0b9d1f2a  [bd-1qx1nt] completion from acolyte-019e — gist (2m ago)`
  defp format_line(m) do
    short = m["id"] |> to_string() |> String.slice(0, 8)
    directive = m["directive_ref"] || "-"
    kind = m["kind"] |> to_string() |> String.pad_trailing(10)
    from = truncate(m["from_ref"] || "?", 16)
    gist = gist(m)
    age = age_suffix(m["inserted_at"])
    "#{short}  [#{directive}] #{kind} from #{from} — #{gist}#{age}"
  end

  defp gist(m) do
    (m["subject"] || m["body"] || "")
    |> to_string()
    |> String.split("\n")
    |> List.first()
    |> truncate(60)
  end

  defp age_suffix(nil), do: ""

  defp age_suffix(iso) when is_binary(iso) do
    case ago(iso) do
      nil -> ""
      a -> " (#{a})"
    end
  end

  defp ago(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> humanize(DateTime.diff(DateTime.utc_now(), dt, :second))
      _ -> nil
    end
  end

  defp humanize(s) when s < 60, do: "#{max(s, 0)}s ago"
  defp humanize(s) when s < 3600, do: "#{div(s, 60)}m ago"
  defp humanize(s) when s < 86_400, do: "#{div(s, 3600)}h ago"
  defp humanize(s), do: "#{div(s, 86_400)}d ago"

  defp truncate(nil, _), do: ""

  defp truncate(s, max) when is_binary(s) do
    if String.length(s) > max, do: String.slice(s, 0, max - 1) <> "…", else: s
  end
end
