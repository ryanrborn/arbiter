defmodule ArbiterWeb.Api.MessageController do
  @moduledoc """
  REST endpoints for `Arbiter.Messages.Message` — the inter-agent queue.

  Routes:

    * `GET  /api/messages`           — :index (filters: kind, to_ref, from_ref,
                                       unread=true, limit [default 50])
    * `POST /api/messages`           — :create (body: kind, from_ref, to_ref,
                                       subject, body, directive_ref, workspace_id)
    * `POST /api/messages/:id/read`  — :read (stamp read_at = now)
    * `DELETE /api/messages`         — :clear (destroy READ messages addressed
                                       to `to_ref`; requires `to_ref`)

  Newest first. `arb inbox` / `arb notify` / `arb msg` / `arb message` drive
  these.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Messages.Message
  require Ash.Query

  action_fallback(ArbiterWeb.Api.FallbackController)

  @default_limit 50

  def index(conn, params) do
    with {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, kind} <- parse_kind(params["kind"]) do
      messages =
        Message
        |> filter_eq(:kind, kind)
        |> filter_eq(:to_ref, params["to_ref"])
        |> filter_eq(:from_ref, params["from_ref"])
        |> maybe_unread(params["unread"])
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      render(conn, :index, messages: messages)
    end
  end

  def create(conn, params) do
    attrs =
      coerce_kind(
        Map.take(params, ~w(kind from_ref to_ref subject body directive_ref workspace_id))
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

  def read(conn, %{"id" => id}) do
    with {:ok, message} <- Ash.get(Message, id),
         {:ok, updated} <- Message.mark_read(message) do
      render(conn, :show, message: updated)
    end
  end

  # Drain the read tail of a mailbox: destroy every *already-read* message
  # addressed to `to_ref`. Unread mail is left untouched — you read it first,
  # then clear. `to_ref` is required so a stray call can't wipe the table.
  def clear(conn, %{"to_ref" => to_ref}) when is_binary(to_ref) and to_ref != "" do
    read_messages =
      Message
      |> Ash.Query.filter(to_ref == ^to_ref and not is_nil(read_at))
      |> Ash.read!()

    Enum.each(read_messages, &Ash.destroy!/1)
    json(conn, %{data: %{deleted: length(read_messages)}})
  end

  def clear(_conn, _params), do: {:error, {:invalid_request, "clear requires to_ref"}}

  # ---- query helpers ----

  defp filter_eq(query, _field, value) when value in [nil, ""], do: query
  defp filter_eq(query, :kind, value), do: Ash.Query.filter(query, kind == ^value)
  defp filter_eq(query, :to_ref, value), do: Ash.Query.filter(query, to_ref == ^value)
  defp filter_eq(query, :from_ref, value), do: Ash.Query.filter(query, from_ref == ^value)

  defp maybe_unread(query, flag) when flag in ["true", true],
    do: Ash.Query.filter(query, is_nil(read_at))

  defp maybe_unread(query, _), do: query

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
    try do
      {:ok, String.to_existing_atom(raw)}
    rescue
      ArgumentError -> {:error, {:invalid_request, "invalid kind: #{inspect(raw)}"}}
    end
  end

  defp coerce_kind(%{"kind" => kind} = attrs) when is_binary(kind) do
    try do
      Map.put(attrs, "kind", String.to_existing_atom(kind))
    rescue
      # Leave the bad string in place; Ash returns a clean validation error.
      ArgumentError -> attrs
    end
  end

  defp coerce_kind(attrs), do: attrs
end
