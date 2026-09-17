defmodule ArbiterCli.Cmd.Inbox do
  @moduledoc """
  `arb inbox` — the coordinator's mailbox: messages workers (and the system)
  send *up* the chain — completions, failures, escalations, FYIs.

  Usage:

      arb inbox                 unread mail addressed to the coordinator
      arb inbox --all           the 20 most recent (read + unread)
      arb inbox read <id>       show one message in full, mark it read
      arb inbox clear           soft-clear the outstanding (read) tail
      arb inbox clear --all     soft-clear everything (read + unread)
      arb inbox clear <id> ...  soft-clear exactly the given message(s), by id
                                or unique id prefix — read or unread
      arb inbox clear --task <task-id>
                                soft-clear every coordinator message
                                concerning that task
      arb inbox <task-id>       (worker path) a task's unread mail; drained
                                — marked read on fetch

  The coordinator view is read-only triage: listing does NOT mark mail read. You
  drain it deliberately with `read <id>` (one) and `clear` (the read tail) or
  `clear --all` (everything). `clear` is a **soft** state transition — it stamps
  `cleared_at` and the rows are retained (the durable escalation record), not
  destroyed. The task path is the inverse — workers auto-drain their queue on
  fetch, so `arb inbox <task-id>` at the top of each workflow step shows new
  direction exactly once.

  Line format:

      0b9d1f2a  [bd-1qx1nt] completion from worker-019e — GitLab adapter complete (2m ago)

  The leading token is a short message id — pass it (or a unique prefix) to
  `arb inbox read` or `arb inbox clear`. The bracket is the task the message
  concerns.

  Flags:
    --json             emit JSON instead of human-readable text
    --session <id>     act as that browser session's reader instead of the
                       shared sessionless coordinator one (bd-8akewg)

  ## Reader identity (bd-8akewg)

  The coordinator mailbox is a single shared queue, but read/cleared state is
  per reader. With no `--session`, `arb inbox` is the **sessionless
  coordinator** reader — the same identity the dashboard drawer and a plain
  `arb mcp token mint` token share, and the one that carries the operator's
  existing triage state. `--session <id>` reads and clears one browser
  session's view instead, leaving every other reader's untouched. It composes
  with every form, including the targeted `clear <id>` and `clear --task`.
  """

  alias ArbiterCli.{Client, Output}

  @coordinator "coordinator"
  @all_limit 20
  # Kinds the worker (task) path surfaces — addressed, read-acknowledged.
  @mailbox_kinds ~w(mailbox direction flag completion failure escalation info)

  # Pre-existing complexity 10 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)

      {session, rest} = take_session(Output.drop_json(argv))

      case rest do
        [] ->
          coordinator_inbox_view(true, mode, session)

        ["--all"] ->
          coordinator_inbox_view(false, mode, session)

        ["read", id] ->
          read_one(id, mode, session)

        ["read"] ->
          Output.die("inbox read requires a message id: `arb inbox read <id>`")

        ["clear"] ->
          clear(false, mode, session)

        ["clear", "--all"] ->
          clear(true, mode, session)

        ["clear", "--task"] ->
          Output.die("inbox clear --task requires a task id: `arb inbox clear --task <task-id>`")

        ["clear", "--task", task_id] ->
          clear_task(task_id, mode, session)

        ["clear" | ids] when ids != [] ->
          clear_ids(ids, mode, session)

        [task_id] ->
          task_inbox(task_id, mode)

        _ ->
          Output.die("inbox: unrecognized arguments. See `arb help`.")
      end
    end
  end

  # Pull `--session <id>` out of argv wherever it sits, so it composes with the
  # positional subcommands (`clear`, `read <id>`) rather than needing a slot in
  # each of their patterns. Returns `{session_id | nil, remaining_argv}`.
  defp take_session(argv) do
    case Enum.split_while(argv, &(&1 != "--session")) do
      {before, ["--session", id | rest]} -> {id, before ++ rest}
      {_before, ["--session"]} -> Output.die("inbox --session requires a session id")
      {argv, []} -> {nil, argv}
    end
  end

  # The reader query/body param forwarded to the API. Absent means the shared
  # sessionless coordinator reader, which is what every existing caller wants.
  defp reader_params(nil), do: []
  defp reader_params(session) when is_binary(session), do: [session: session]

  # ---- coordinator views ----------------------------------------------------

  defp coordinator_inbox_view(unread_only, mode, session) do
    params =
      if unread_only,
        do: [to_ref: @coordinator, unread: "true"],
        else: [to_ref: @coordinator, limit: @all_limit]

    params = params ++ reader_params(session)

    case Client.get("/api/messages", params) do
      {:ok, %{"data" => list}} -> emit_list(list, mode, coordinator_label(unread_only, list))
      {:ok, _} -> emit_list([], mode, coordinator_label(unread_only, []))
      {:error, err} -> Output.die(err)
    end
  end

  defp coordinator_label(true, list),
    do:
      {"Coordinator inbox — #{length(list)} unread:",
       "(coordinator inbox empty — no unread mail)"}

  defp coordinator_label(false, list),
    do: {"Coordinator inbox — #{length(list)} recent:", "(coordinator inbox empty)"}

  # ---- worker (task) path -------------------------------------------------

  defp task_inbox(task_id, mode) do
    case Client.get("/api/messages", to_ref: task_id, unread: "true") do
      {:ok, %{"data" => list}} ->
        mail = Enum.filter(list, &(&1["kind"] in @mailbox_kinds))
        Enum.each(mail, &mark_read/1)

        emit_list(
          mail,
          mode,
          {"Unread mail for #{task_id} (#{length(mail)}):", "(no unread mail)"}
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

  defp mark_read_as(id, nil), do: Client.post("/api/messages/#{id}/read", %{})

  defp mark_read_as(id, session) when is_binary(session),
    do: Client.post("/api/messages/#{id}/read", %{session: session})

  # ---- read one ------------------------------------------------------------

  defp read_one(token, mode, session) do
    case resolve_id(token) do
      {:ok, id} ->
        case mark_read_as(id, session) do
          {:ok, message} -> emit_full(message, mode)
          {:error, err} -> Output.die(err)
        end

      {:error, msg} ->
        Output.die(msg)
    end
  end

  # A full uuid passes straight through; a short prefix is resolved against the
  # coordinator's mail (the list the operator just read these ids from).
  defp resolve_id(token) do
    if full_uuid?(token) do
      {:ok, token}
    else
      case Client.get("/api/messages", to_ref: @coordinator, limit: 50) do
        {:ok, %{"data" => list}} -> match_prefix(list, token)
        {:ok, _} -> {:error, "no coordinator message matches id #{inspect(token)}"}
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp match_prefix(list, token) do
    case Enum.filter(list, &String.starts_with?(to_string(&1["id"]), token)) do
      [%{"id" => id}] ->
        {:ok, id}

      [] ->
        {:error, "no coordinator message matches id #{inspect(token)}"}

      matches ->
        candidates = Enum.map_join(matches, ", ", &to_string(&1["id"]))

        {:error,
         "ambiguous id prefix #{inspect(token)} — give more characters. Candidates: #{candidates}"}
    end
  end

  defp full_uuid?(token), do: String.length(token) == 36 and String.contains?(token, "-")

  # ---- clear ---------------------------------------------------------------

  defp clear(clear_all, mode, session) do
    params = [to_ref: @coordinator] ++ reader_params(session)
    params = if clear_all, do: params ++ [all: "true"], else: params

    case Client.delete("/api/messages", params) do
      {:ok, %{"data" => data}} ->
        deleted_read = data["deleted_read"] || 0
        deleted_unread = data["deleted_unread"] || 0
        remaining_unread = data["remaining_unread"] || 0
        emit_cleared(deleted_read, deleted_unread, remaining_unread, clear_all, mode)

      {:ok, _} ->
        emit_cleared(0, 0, 0, clear_all, mode)

      {:error, err} ->
        Output.die(err)
    end
  end

  defp emit_cleared(read, unread, remaining, _clear_all, :json) do
    IO.puts(
      Jason.encode!(%{
        data: %{
          deleted_read: read,
          deleted_unread: unread,
          remaining_unread: remaining
        }
      })
    )
  end

  defp emit_cleared(0, 0, 0, _clear_all, :text) do
    IO.puts("Nothing to clear (inbox is empty).")
  end

  defp emit_cleared(read, 0, 0, false, :text) do
    IO.puts("Cleared #{read} read message#{plural(read)}.")
  end

  defp emit_cleared(read, 0, unread, false, :text) when unread > 0 do
    IO.puts(
      "Cleared #{read} read message#{plural(read)}; #{unread} unread message#{plural(unread)} remain — use `clear --all` to remove them."
    )
  end

  defp emit_cleared(read, unread, 0, true, :text) do
    total = read + unread

    IO.puts(
      "Cleared #{read} read + #{unread} unread message#{if total == 1, do: "", else: "s"} (#{total} total)."
    )
  end

  # ---- clear specific ids ----------------------------------------------------

  defp clear_ids(tokens, mode, session) do
    case resolve_ids(tokens) do
      {:ok, ids} ->
        case Client.delete("/api/messages", [ids: Enum.join(ids, ",")] ++ reader_params(session)) do
          {:ok, %{"data" => data}} ->
            cleared = data["cleared"] || []
            not_found = data["not_found"] || []
            emit_cleared_ids(cleared, not_found, mode)

          {:error, err} ->
            Output.die(err)
        end

      {:error, msg} ->
        Output.die(msg)
    end
  end

  defp resolve_ids(tokens) do
    Enum.reduce_while(tokens, {:ok, []}, fn token, {:ok, acc} ->
      case resolve_id(token) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      other -> other
    end
  end

  defp emit_cleared_ids(cleared, not_found, :json) do
    IO.puts(Jason.encode!(%{data: %{cleared: cleared, not_found: not_found}}))
  end

  defp emit_cleared_ids(cleared, [], :text) do
    n = length(cleared)
    IO.puts("Cleared #{n} message#{plural(n)}.")
  end

  defp emit_cleared_ids(cleared, not_found, :text) do
    n = length(cleared)
    m = length(not_found)

    IO.puts(
      "Cleared #{n} message#{plural(n)}; #{m} id#{plural(m)} not found: #{Enum.join(not_found, ", ")}"
    )
  end

  # ---- clear by task ---------------------------------------------------------

  defp clear_task(task_id, mode, session) do
    case Client.delete("/api/messages", [task_id: task_id] ++ reader_params(session)) do
      {:ok, %{"data" => data}} ->
        cleared = data["cleared"] || []
        emit_cleared_task(length(cleared), task_id, mode)

      {:error, err} ->
        Output.die(err)
    end
  end

  defp emit_cleared_task(n, _task_id, :json) do
    IO.puts(Jason.encode!(%{data: %{cleared_count: n}}))
  end

  defp emit_cleared_task(0, task_id, :text), do: IO.puts("Nothing to clear for #{task_id}.")

  defp emit_cleared_task(n, task_id, :text),
    do: IO.puts("Cleared #{n} message#{plural(n)} for #{task_id}.")

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
    task_ref = m["task_ref"] || m["directive_ref"]

    fields =
      [
        {"From", m["from_ref"]},
        {"To", m["to_ref"]},
        {"Kind", m["kind"]},
        {"Issue", task_ref},
        {"Subject", m["subject"]},
        {"Sent", m["inserted_at"]}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.map(fn {k, v} -> "#{String.pad_trailing(k <> ":", 11)}#{v}" end)

    IO.puts(Enum.join(fields, "\n"))
    IO.puts("")
    IO.puts(m["body"] || "")
  end

  # `0b9d1f2a  [bd-1qx1nt] completion from worker-019e — gist (2m ago)`
  defp format_line(m) do
    short = m["id"] |> to_string() |> String.slice(0, 8)
    task_ref = m["task_ref"] || m["directive_ref"] || "-"
    kind = m["kind"] |> to_string() |> String.pad_trailing(10)
    from = truncate(m["from_ref"] || "?", 16)
    gist = gist(m)
    age = age_suffix(m["inserted_at"])
    "#{short}  [#{task_ref}] #{kind} from #{from} — #{gist}#{age}"
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
