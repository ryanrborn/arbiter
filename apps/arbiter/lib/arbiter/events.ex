defmodule Arbiter.Events do
  @moduledoc """
  PubSub broadcast hooks for the server-push event stream (`GET /events`),
  plus the durable log backing `?since=` replay.

  Fires workspace-scoped `{:event, map}` messages on the `"events:<ws_id>"`
  topic. `ArbiterWeb.Api.EventController` subscribes to this topic and streams
  matching events as newline-delimited JSON to connected coordinators.

  ## Durability

  Every broadcast is first written to `Arbiter.Events.Record` (table
  `events`), then fanned out over PubSub. The inserted row's `seq` — an
  autoincrementing integer — is merged into the broadcast payload as
  `:cursor` before either PubSub send, so live subscribers and replay
  readers agree on the same cursor space. A reconnecting coordinator passes
  the last cursor it saw as `GET /events?since=<cursor>`; the controller
  calls `replay/3` to fill the gap before resuming the live stream — see
  that module for how the two are stitched together without dropping or
  duplicating events.

  Persistence failures are logged at `:error` (not swallowed) so an
  operator notices, but do not raise — every existing caller of
  `broadcast/3` treats it as infallible. The live *broadcast* keeps its
  original swallow-on-failure behavior.

  Retention is enforced by `Arbiter.Events.Retention`.

  ## Topic registry

  | Topic           | Fires when                                             |
  |-----------------|--------------------------------------------------------|
  | `inbox`         | A message arrives in the coordinator's mailbox          |
  | `review_gate`      | A review_gate escalation requires coordinator ruling           |
  | `worker_failed`| A worker stops unexpectedly (status → failed)         |
  | `worker_done`  | A worker completes (status → completed)               |
  | `task_state`    | Any task FSM transition (noisier — opt-in only)         |
  | `external_review` | An ExternalReview lifecycle transition (running/completed/failed) |
  | `loop_proposal`  | A loop-engineering proposal is recorded / reinforced / promoted / applied / rejected (opt-in only) |

  ## Broadcast hooks

  Called from:
    * `Arbiter.Worker.fail_now/2` and `fail_stopped/2` → `:worker_failed`
    * `Arbiter.Worker.broadcast_done/1` → `:worker_done`
    * `Arbiter.Worker.escalate_review_gate/3` → `:review_gate`
    * `Arbiter.Messages.Message.broadcast_new/1` → `:inbox` (coordinator-addressed only)
    * `Arbiter.Tasks.Issue.broadcast_lifecycle/2` → `:task_state`
    * `Arbiter.Reviews.ExternalReview.create_review_record/2` and
      `complete_review_record/3` → `:external_review`
    * `Arbiter.Loop.record/2`, `apply_pending/2` and `reject_pending/2` →
      `:loop_proposal`

  All broadcasts are best-effort: PubSub failures are logged at debug and swallowed.
  """

  use Ash.Domain

  require Ash.Query
  require Logger

  alias Arbiter.Events.Record

  resources do
    resource Record
  end

  @valid_topics ~w(inbox review_gate worker_failed worker_done task_state external_review loop_proposal)

  @doc "All valid topic name strings accepted by the `subscribe=` query parameter."
  def valid_topics, do: @valid_topics

  @global_topic "events"

  @doc """
  The PubSub topic for a workspace's event stream.
  `nil` returns the global topic, which receives a copy of every broadcast.
  """
  def pubsub_topic(nil), do: @global_topic
  def pubsub_topic(workspace_id) when is_binary(workspace_id), do: "events:" <> workspace_id

  @doc """
  Broadcast an event on the workspace's event stream PubSub topic.

  `event_topic` is one of the valid topic strings (e.g. `"worker_failed"`).
  `payload` is merged with `topic` and `at` (ISO-8601 timestamp) before broadcasting.
  Also fans out to the global topic so workspace-agnostic coordinator connections
  receive all events.

  Before broadcasting, the event is persisted as an `Arbiter.Events.Record`
  and the row's `seq` merged in as `:cursor` — this is what `replay/3` uses
  to fill a reconnect gap. A persist failure is logged at `:error` (visible,
  unlike the debug-and-swallow below) but does not stop the broadcast — the
  event just isn't replayable. The live broadcast itself stays best-effort:
  PubSub failures are logged at debug and swallowed.
  """
  def broadcast(workspace_id, event_topic, payload)
      when is_binary(workspace_id) and is_binary(event_topic) and is_map(payload) do
    now = DateTime.utc_now()

    event =
      payload
      |> Map.put(:topic, event_topic)
      |> Map.put(:at, DateTime.to_iso8601(now))

    event =
      case persist(workspace_id, event, now) do
        nil -> event
        seq -> Map.put(event, :cursor, seq)
      end

    Phoenix.PubSub.broadcast(Arbiter.PubSub, pubsub_topic(workspace_id), {:event, event})
    Phoenix.PubSub.broadcast(Arbiter.PubSub, @global_topic, {:event, event})
    :ok
  rescue
    e ->
      Logger.debug("Arbiter.Events.broadcast/3 swallowed: #{Exception.message(e)}")
      :ok
  end

  def broadcast(_workspace_id, _event_topic, _payload), do: :ok

  # Not swallowed at debug like the PubSub sends above — a lost row silently
  # breaks replay for every future reconnect, so it's worth a log line an
  # operator can actually find.
  defp persist(workspace_id, event, occurred_at) do
    case Record
         |> Ash.Changeset.for_create(:create, %{
           workspace_id: workspace_id,
           topic: Map.fetch!(event, :topic),
           payload: event,
           occurred_at: occurred_at
         })
         |> Ash.create() do
      {:ok, record} ->
        record.seq

      {:error, reason} ->
        Logger.error(
          "Arbiter.Events failed to persist event (topic=#{event.topic}, workspace_id=#{workspace_id}), " <>
            "not replayable: #{inspect(reason)}"
        )

        nil
    end
  rescue
    e ->
      Logger.error(
        "Arbiter.Events failed to persist event (topic=#{event.topic}, workspace_id=#{workspace_id}), " <>
          "not replayable: #{Exception.message(e)}"
      )

      nil
  end

  @typedoc "A replay cursor: an opaque integer `seq`, or a timestamp to replay everything after."
  @type since :: {:cursor, integer()} | {:timestamp, DateTime.t()}

  @doc """
  Replay persisted events after `since`, restricted to `topics`, oldest first.

  `workspace_id` scopes to one workspace's events; `nil` returns events
  across all workspaces (mirrors the workspace-agnostic coordinator token —
  see `pubsub_topic/1`).

  Returns a list of JSON-ready maps (string keys), each carrying `"cursor"`
  — the same cursor space as the `:cursor` key `broadcast/3` stamps onto the
  live event, so a caller can uniformly track "highest cursor delivered so
  far" across replay and live events without double-delivery.
  """
  @spec replay(String.t() | nil, [String.t()], since()) :: [map()]
  def replay(workspace_id, topics, since) when is_list(topics) do
    Record
    |> Ash.Query.filter(topic in ^topics)
    |> since_filter(since)
    |> workspace_filter(workspace_id)
    |> Ash.Query.sort(seq: :asc)
    |> Ash.read!()
    |> Enum.map(&record_to_event/1)
  end

  defp since_filter(query, {:cursor, cursor}), do: Ash.Query.filter(query, seq > ^cursor)

  defp since_filter(query, {:timestamp, %DateTime{} = dt}),
    do: Ash.Query.filter(query, occurred_at > ^dt)

  defp workspace_filter(query, nil), do: query

  defp workspace_filter(query, ws) when is_binary(ws),
    do: Ash.Query.filter(query, workspace_id == ^ws)

  defp record_to_event(%Record{seq: seq, payload: payload}) do
    payload
    |> stringify_keys()
    |> Map.put("cursor", seq)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
