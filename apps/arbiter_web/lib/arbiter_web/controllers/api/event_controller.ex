defmodule ArbiterWeb.Api.EventController do
  @moduledoc """
  Server-push event stream over a long-lived chunked HTTP connection.

  Route: GET /events?token=<coord_token>&subscribe=<comma-separated topics>&since=<cursor|timestamp>

  Auth: coordinator-tier MCP token in the `token=` query parameter.

  Topics (default: inbox,review_gate,worker_failed):
    * inbox          — a message arrived in the coordinator's mailbox
    * review_gate       — a review_gate escalation requires coordinator ruling
    * worker_failed — a worker stopped unexpectedly (status → failed)
    * worker_done   — a worker completed (status → completed)
    * task_state     — any task FSM transition (noisier — opt-in only)
    * external_review — an ExternalReview lifecycle transition: running / completed /
                        failed (opt-in only — pass subscribe=...,external_review)
    * loop_proposal  — a loop-engineering proposal was recorded, reinforced,
                       promoted to `proposed`, applied or rejected (opt-in only —
                       pass subscribe=...,loop_proposal)

  Wire format: one newline-terminated JSON object per event. A bare newline
  is sent every 30 seconds on idle connections as a keepalive. Every event
  carries a `"cursor"` field — an integer that only ever increases — so a
  reconnecting client can pass the highest cursor it saw back as `since=`.

  ## Replay (`since=`)

  `since` accepts either an integer cursor (a value previously seen in an
  event's `"cursor"` field) or an ISO-8601 timestamp. When present, the
  connection first replays every persisted event after that point — scoped
  to the requested topics and workspace, oldest first — before joining the
  live stream, so a client that was disconnected for N minutes and
  reconnects with `since=<last cursor>` sees the gap exactly once, in
  order, with no duplicate delivery from the live tail. See
  `Arbiter.Events.replay/3` for the persistence and ordering guarantees.
  Omitting `since` skips replay entirely (today's behavior: live events only).

  Client usage:
      curl -N "http://127.0.0.1:4848/events?token=...&subscribe=inbox,review_gate"
      curl -N "http://127.0.0.1:4848/events?token=...&since=1042"
  """

  use ArbiterWeb, :controller

  require Logger

  alias Arbiter.Events
  alias Arbiter.MCP.Scope

  @default_topics ~w(inbox review_gate worker_failed)
  @keepalive_ms 30_000

  @doc """
  Subscribe and stream events. Returns 401 for missing/invalid tokens,
  400 for unknown topic names or an unparseable `since=`, 200 + chunked
  body for valid requests.
  """
  def stream(conn, params) do
    with {:ok, scope} <- authenticate(params),
         {:ok, topics} <- parse_topics(params),
         {:ok, since} <- parse_since(params) do
      # Subscribe BEFORE querying replay, so any event that lands in the gap
      # between "replay query ran" and "live loop starts receiving" is
      # caught by the mailbox rather than dropped — see the cursor-watermark
      # dedup in event_loop/3, which is what makes this race-safe rather
      # than just race-reduced.
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Events.pubsub_topic(scope.workspace_id))

      conn =
        conn
        |> put_resp_content_type("application/x-ndjson")
        |> send_chunked(200)

      topic_set = MapSet.new(topics)
      {conn, last_cursor} = replay(conn, scope.workspace_id, topic_set, since)

      event_loop(conn, topic_set, last_cursor)
    else
      {:error, :unauthorized} ->
        conn
        |> put_status(401)
        |> json(%{"error" => "unauthorized"})

      {:error, :invalid_topics, invalid} ->
        conn
        |> put_status(400)
        |> json(%{"error" => "unknown topics: #{Enum.join(invalid, ", ")}"})

      {:error, :invalid_since} ->
        conn
        |> put_status(400)
        |> json(%{"error" => "invalid since: must be an integer cursor or an ISO-8601 timestamp"})
    end
  end

  # ---- auth ---------------------------------------------------------------

  defp authenticate(%{"token" => token}) when is_binary(token) and token != "" do
    case Scope.from_token(token) do
      {:ok, %Scope{tier: :coordinator} = scope} -> {:ok, scope}
      {:ok, _worker_tier} -> {:error, :unauthorized}
      {:error, _} -> {:error, :unauthorized}
    end
  end

  defp authenticate(_), do: {:error, :unauthorized}

  # ---- topic parsing ------------------------------------------------------

  defp parse_topics(%{"subscribe" => s}) when is_binary(s) and s != "" do
    requested =
      s
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    valid = Events.valid_topics()
    invalid = Enum.reject(requested, &(&1 in valid))

    if invalid == [] do
      {:ok, requested}
    else
      {:error, :invalid_topics, invalid}
    end
  end

  defp parse_topics(_), do: {:ok, @default_topics}

  # ---- since parsing --------------------------------------------------------

  # An integer cursor (a value previously seen in an event's "cursor" field)
  # or an ISO-8601 timestamp. Absent `since` skips replay (nil).
  defp parse_since(%{"since" => s}) when is_binary(s) and s != "" do
    case Integer.parse(s) do
      {cursor, ""} ->
        {:ok, {:cursor, cursor}}

      _ ->
        case DateTime.from_iso8601(s) do
          {:ok, dt, _offset} -> {:ok, {:timestamp, dt}}
          {:error, _} -> {:error, :invalid_since}
        end
    end
  end

  defp parse_since(_), do: {:ok, nil}

  # ---- replay ---------------------------------------------------------------

  # Streams every persisted event after `since` (oldest first) before the
  # live loop starts. Returns the last cursor sent — the watermark
  # event_loop/3 uses to skip anything already delivered here. `since ==
  # nil` skips replay entirely, but still gives event_loop/3 a starting
  # watermark of `nil` (deliver everything).
  defp replay(conn, _workspace_id, _topics, nil), do: {conn, nil}

  defp replay(conn, workspace_id, topics, since) do
    %{events: events, truncated?: truncated?} =
      Events.replay(workspace_id, MapSet.to_list(topics), since)

    conn =
      Enum.reduce(events, conn, fn event, conn ->
        case Plug.Conn.chunk(conn, Jason.encode!(event) <> "\n") do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
      end)

    last_cursor =
      case List.last(events) do
        nil -> since_watermark(since)
        %{"cursor" => cursor} -> cursor
      end

    conn =
      if truncated? do
        chunk_truncation_notice(conn, last_cursor)
      else
        conn
      end

    {conn, last_cursor}
  end

  defp chunk_truncation_notice(conn, last_cursor) do
    notice = %{
      "topic" => "_replay_truncated",
      "cursor" => last_cursor,
      "note" =>
        "replay hit Events.replay_limit/0 (#{Events.replay_limit()} rows); " <>
          "reconnect with since=#{last_cursor} to continue"
    }

    case Plug.Conn.chunk(conn, Jason.encode!(notice) <> "\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  # No rows replayed: fall back to the requested cursor, clamped to the
  # log's actual high-water mark. Without the clamp, a client-supplied
  # cursor past the end of the table (e.g. after a DB reset, or a stale/
  # hand-typed value) would make event_loop/3 drop every future live event
  # for the life of the connection — indistinguishable from "fleet quiet".
  # Clamping degrades that to "stream everything live" instead.
  defp since_watermark({:cursor, cursor}) do
    max_seq = Events.max_cursor()

    if cursor > max_seq do
      Logger.error(
        "GET /events since=#{cursor} exceeds the log's high-water mark (#{max_seq}); " <>
          "clamping — client cursor is likely stale or invalid"
      )

      max_seq
    else
      cursor
    end
  end

  defp since_watermark({:timestamp, _}), do: nil

  # ---- event loop ---------------------------------------------------------

  # Tail-recursive receive loop. Waits up to @keepalive_ms for an event; on
  # timeout sends a bare newline keepalive to prevent proxy timeouts.
  #
  # `watermark` is FROZEN at the replay high-water mark for the life of the
  # connection — it is never advanced by live sends. It only exists to
  # suppress events the replay query already returned (cursor <=
  # watermark), which is what makes the subscribe-before-replay race in
  # stream/2 safe: an event that arrives both via the replay query and via a
  # queued PubSub message is only ever sent once. PubSub never redelivers a
  # message, so advancing the watermark on every live send buys nothing —
  # and it actively breaks delivery for concurrent broadcasters, since two
  # events persisted close together can be broadcast out of cursor order
  # (persist and PubSub broadcast aren't atomic across processes): if a
  # higher-cursor event's PubSub message is scheduled first, advancing the
  # watermark to it would cause the lower-cursor event that follows to be
  # wrongly treated as already-delivered and silently dropped. An event with
  # no cursor (persist failed) is always sent — it was never a replay
  # candidate to begin with.
  defp event_loop(conn, topics, watermark) do
    receive do
      {:event, event} ->
        if deliver?(event, topics, watermark) do
          json_line = Jason.encode!(stringify_keys(event)) <> "\n"

          case Plug.Conn.chunk(conn, json_line) do
            {:ok, conn} -> event_loop(conn, topics, watermark)
            {:error, _} -> conn
          end
        else
          event_loop(conn, topics, watermark)
        end
    after
      @keepalive_ms ->
        case Plug.Conn.chunk(conn, "\n") do
          {:ok, conn} -> event_loop(conn, topics, watermark)
          {:error, _} -> conn
        end
    end
  end

  @doc false
  # Exposed for unit testing (finding #3): pure delivery decision, independent
  # of the receive loop and the conn plumbing.
  def deliver?(event, topics, watermark) do
    MapSet.member?(topics, Map.get(event, :topic)) and not already_delivered?(event, watermark)
  end

  defp already_delivered?(%{cursor: cursor}, watermark)
       when is_integer(cursor) and is_integer(watermark),
       do: cursor <= watermark

  defp already_delivered?(_event, _watermark), do: false

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
