defmodule ArbiterWeb.Api.MessageController do
  @moduledoc """
  REST endpoints for `Arbiter.Messages.Message` — the inter-agent queue.

  Routes:

    * `GET  /api/messages`           — :index (filters: kind, to_ref, from_ref,
                                       unread=true [pending: read_at & cleared_at
                                       both nil], outstanding=true [read, not
                                       cleared], limit [default 50])
    * `POST /api/messages`           — :create (body: kind, from_ref, to_ref,
                                       subject, body, task_ref (or the
                                       deprecated directive_ref alias),
                                       workspace_id)
    * `POST /api/messages/:id/read`  — :read (stamp read_at = now)
    * `DELETE /api/messages`         — :clear (soft-clear by stamping cleared_at;
                                       rows are retained, not destroyed). Three
                                       forms: `ids=<comma-separated>` clears
                                       exactly those messages, resolved
                                       regardless of workspace; `task_id=<ref>`
                                       (+ optional `workspace_id`) clears every
                                       coordinator message concerning that
                                       task; `to_ref=<ref>` (+ optional `all`)
                                       is the bulk mailbox clear — `all=true`
                                       clears read+unread, absent/false clears
                                       the outstanding (read) tail only.

  Newest first. `arb inbox` / `arb notify` / `arb msg` / `arb message` drive
  these.

  ## Reader identity (bd-8akewg)

  The coordinator mailbox is shared, but read/cleared state is per reader. These
  endpoints act as the **sessionless coordinator** reader by default — the
  identity the CLI, the dashboard drawer and any plain minted token share — so
  every existing caller behaves exactly as it did. Pass `session=<session_id>`
  on :index, :read or any :clear form (bulk, `ids`, `task_id`) to act as that
  browser session's reader instead;
  its reads and clears then leave the shared row, and therefore every other
  reader, untouched.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Messages.Message
  require Ash.Query

  action_fallback(ArbiterWeb.Api.FallbackController)

  @default_limit 50

  def index(conn, params) do
    reader = reader_ref(params)

    with {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, kind} <- parse_kind(params["kind"]) do
      messages =
        Message
        |> filter_eq(:kind, kind)
        |> filter_eq(:to_ref, params["to_ref"])
        |> filter_eq(:from_ref, params["from_ref"])
        |> maybe_unread(params["unread"], reader)
        |> maybe_outstanding(params["outstanding"], reader)
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      render(conn, :index, messages: messages)
    end
  end

  def create(conn, params) do
    attrs =
      coerce_kind(
        Map.take(
          params,
          ~w(kind from_ref to_ref subject body task_ref directive_ref workspace_id)
        )
      )

    case Ash.create(Message, attrs) do
      {:ok, message} ->
        conn
        |> put_status(:created)
        |> render(:show, message: message)

      {:error, _} = err ->
        err
    end
  end

  def read(conn, %{"id" => id} = params) do
    with {:ok, message} <- Ash.get(Message, id),
         {:ok, updated} <- Message.mark_read(message, reader: reader_ref(params)) do
      render(conn, :show, message: updated)
    end
  end

  # Soft-clear specific messages by id (comma-separated). Resolved directly by
  # id — no workspace scoping, since an id is already unambiguous (bd-95pse9:
  # a workspace-scoped lookup here is exactly the trap that made
  # `coordinator_inbox` silently return `count: 0` when the caller omitted
  # `workspace`).
  def clear(conn, %{"ids" => ids_param} = params) when is_binary(ids_param) and ids_param != "" do
    ids =
      ids_param
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, cleared, not_found} = Message.clear_ids(ids, reader: reader_ref(params))

    json(conn, %{
      data: %{
        cleared: Enum.map(cleared, & &1.id),
        not_found: not_found
      }
    })
  end

  # Soft-clear every coordinator message concerning `task_id`. Pass
  # `workspace_id` to scope to one workspace.
  def clear(conn, %{"task_id" => task_id} = params) when is_binary(task_id) and task_id != "" do
    opts =
      case params["workspace_id"] do
        ws when is_binary(ws) and ws != "" -> [workspace_id: ws]
        _ -> []
      end

    {:ok, cleared} = Message.clear_by_task(task_id, [reader: reader_ref(params)] ++ opts)

    json(conn, %{
      data: %{
        cleared: Enum.map(cleared, & &1.id),
        cleared_count: length(cleared)
      }
    })
  end

  # Soft-clear a mailbox: stamp `cleared_at` on the outstanding (read, uncleared)
  # tail addressed to `to_ref`. Pending mail is left untouched — you read it
  # first, then clear. Pass `all=true` to clear both read and unread. Rows are
  # retained (soft), never destroyed; the durable escalation record survives.
  # `to_ref` is required so a stray call can't sweep the table.
  def clear(conn, %{"to_ref" => to_ref} = params) when is_binary(to_ref) and to_ref != "" do
    opts = [reader: reader_ref(params)]

    {:ok, deleted_read, deleted_unread, remaining_unread} =
      if params["all"] in ["true", true] do
        Message.clear_all(to_ref, opts)
      else
        Message.clear_read(to_ref, opts)
      end

    json(conn, %{
      data: %{
        deleted_read: deleted_read,
        deleted_unread: deleted_unread,
        remaining_unread: remaining_unread
      }
    })
  end

  def clear(_conn, _params), do: {:error, {:invalid_request, "clear requires to_ref"}}

  # ---- query helpers ----

  defp filter_eq(query, _field, value) when value in [nil, ""], do: query
  defp filter_eq(query, :kind, value), do: Ash.Query.filter(query, kind == ^value)
  # `to_ref`/`from_ref` dual-read the coordinator mailbox during the
  # admiral→coordinator compat window: either literal matches both stored
  # variants (`Message.ref_variants/1`); every other ref matches only itself.
  defp filter_eq(query, :to_ref, value),
    do: Ash.Query.filter(query, to_ref in ^Message.ref_variants(value))

  defp filter_eq(query, :from_ref, value),
    do: Ash.Query.filter(query, from_ref in ^Message.ref_variants(value))

  # `unread` = pending: never seen and not cleared. cleared_at must also be nil
  # so a message soft-cleared while still unread does not resurface as pending.
  defp maybe_unread(query, flag, reader) when flag in ["true", true],
    do: Message.for_reader(query, reader, :unread)

  defp maybe_unread(query, _flag, _reader), do: query

  # `outstanding` = the triage queue: seen (read_at set) but not yet cleared.
  defp maybe_outstanding(query, flag, reader) when flag in ["true", true],
    do: Message.for_reader(query, reader, :outstanding)

  defp maybe_outstanding(query, _flag, _reader), do: query

  # The reader these endpoints act as. `session=<session_id>` opts into that
  # browser session's own view; everything else is the shared sessionless
  # coordinator reader, whose state is mirrored onto the row — which is why
  # callers that never pass `session` see no change at all.
  defp reader_ref(%{"session" => session}) when is_binary(session) and session != "",
    do: Message.session_reader(session)

  defp reader_ref(_params), do: Message.coordinator_reader()

  # ---- param coercion ----

  defp parse_limit(nil), do: {:ok, @default_limit}
  defp parse_limit(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_request, "limit must be a positive integer"}}
    end
  end

  defp parse_limit(_), do: {:error, {:invalid_request, "limit must be a positive integer"}}

  defp parse_kind(nil), do: {:ok, nil}
  defp parse_kind(""), do: {:ok, nil}

  defp parse_kind(raw) when is_binary(raw) do
    {:ok, String.to_existing_atom(raw)}
  rescue
    ArgumentError -> {:error, {:invalid_request, "invalid kind: #{inspect(raw)}"}}
  end

  defp coerce_kind(%{"kind" => kind} = attrs) when is_binary(kind) do
    Map.put(attrs, "kind", String.to_existing_atom(kind))
  rescue
    # Leave the bad string in place; Ash returns a clean validation error.
    ArgumentError -> attrs
  end

  defp coerce_kind(attrs), do: attrs
end
