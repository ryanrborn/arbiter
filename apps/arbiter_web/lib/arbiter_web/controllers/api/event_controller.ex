defmodule ArbiterWeb.Api.EventController do
  @moduledoc """
  Server-push event stream over a long-lived chunked HTTP connection.

  Route: GET /events?token=<coord_token>&subscribe=<comma-separated topics>

  Auth: coordinator-tier MCP token in the `token=` query parameter.

  Topics (default: inbox,review_gate,polecat_failed):
    * inbox          — a message arrived in the coordinator's mailbox
    * review_gate       — a review_gate escalation requires Admiral ruling
    * polecat_failed — a worker stopped unexpectedly (status → failed)
    * polecat_done   — a worker completed (status → completed)
    * bead_state     — any bead FSM transition (noisier — opt-in only)

  Wire format: one newline-terminated JSON object per event. A bare newline
  is sent every 30 seconds on idle connections as a keepalive.

  Client usage:
      curl -N "http://127.0.0.1:4848/events?token=...&subscribe=inbox,review_gate"
  """

  use ArbiterWeb, :controller

  alias Arbiter.Events
  alias Arbiter.MCP.Scope

  @default_topics ~w(inbox review_gate polecat_failed)
  @keepalive_ms 30_000

  @doc """
  Subscribe and stream events. Returns 401 for missing/invalid tokens,
  400 for unknown topic names, 200 + chunked body for valid requests.
  """
  def stream(conn, params) do
    with {:ok, scope} <- authenticate(params),
         {:ok, topics} <- parse_topics(params) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Events.pubsub_topic(scope.workspace_id))

      conn =
        conn
        |> put_resp_content_type("application/x-ndjson")
        |> send_chunked(200)

      event_loop(conn, MapSet.new(topics))
    else
      {:error, :unauthorized} ->
        conn
        |> put_status(401)
        |> json(%{"error" => "unauthorized"})

      {:error, :invalid_topics, invalid} ->
        conn
        |> put_status(400)
        |> json(%{"error" => "unknown topics: #{Enum.join(invalid, ", ")}"})
    end
  end

  # ---- auth ---------------------------------------------------------------

  defp authenticate(%{"token" => token}) when is_binary(token) and token != "" do
    case Scope.from_token(token) do
      {:ok, %Scope{tier: :coordinator} = scope} -> {:ok, scope}
      {:ok, _polecat_tier} -> {:error, :unauthorized}
      {:error, _} -> {:error, :unauthorized}
    end
  end

  defp authenticate(_), do: {:error, :unauthorized}

  # ---- topic parsing ------------------------------------------------------

  defp parse_topics(%{"subscribe" => s}) when is_binary(s) and s != "" do
    requested =
      s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    valid = Events.valid_topics()
    invalid = Enum.reject(requested, &(&1 in valid))

    if invalid == [] do
      {:ok, requested}
    else
      {:error, :invalid_topics, invalid}
    end
  end

  defp parse_topics(_), do: {:ok, @default_topics}

  # ---- event loop ---------------------------------------------------------

  # Tail-recursive receive loop. Waits up to @keepalive_ms for an event; on
  # timeout sends a bare newline keepalive to prevent proxy timeouts.
  defp event_loop(conn, topics) do
    receive do
      {:event, %{topic: event_topic} = event} ->
        if MapSet.member?(topics, event_topic) do
          json_line = Jason.encode!(stringify_keys(event)) <> "\n"

          case Plug.Conn.chunk(conn, json_line) do
            {:ok, conn} -> event_loop(conn, topics)
            {:error, _} -> conn
          end
        else
          event_loop(conn, topics)
        end
    after
      @keepalive_ms ->
        case Plug.Conn.chunk(conn, "\n") do
          {:ok, conn} -> event_loop(conn, topics)
          {:error, _} -> conn
        end
    end
  end

  # The event map uses atom keys internally; JSON encoding expects string keys
  # or structs — Jason handles atom keys fine, but to be explicit and safe we
  # convert atoms so the wire format is consistent regardless of how the map
  # was constructed.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
