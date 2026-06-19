defmodule Arbiter.Events do
  @moduledoc """
  PubSub broadcast hooks for the server-push event stream (`GET /events`).

  Fires workspace-scoped `{:event, map}` messages on the `"events:<ws_id>"`
  topic. `ArbiterWeb.Api.EventController` subscribes to this topic and streams
  matching events as newline-delimited JSON to connected coordinators.

  ## Topic registry

  | Topic           | Fires when                                             |
  |-----------------|--------------------------------------------------------|
  | `inbox`         | A message arrives in the coordinator's mailbox          |
  | `review_gate`      | A review_gate escalation requires Admiral ruling           |
  | `worker_failed`| An worker stops unexpectedly (status → failed)         |
  | `worker_done`  | An worker completes (status → completed)               |
  | `bead_state`    | Any bead FSM transition (noisier — opt-in only)         |

  ## Broadcast hooks

  Called from:
    * `Arbiter.Worker.fail_now/2` and `fail_stopped/2` → `:worker_failed`
    * `Arbiter.Worker.broadcast_done/1` → `:worker_done`
    * `Arbiter.Worker.escalate_review_gate/3` → `:review_gate`
    * `Arbiter.Messages.Message.broadcast_new/1` → `:inbox` (admiral-addressed only)
    * `Arbiter.Beads.Issue.broadcast_lifecycle/2` → `:bead_state`

  All broadcasts are best-effort: PubSub failures are logged at debug and swallowed.
  """

  require Logger

  @valid_topics ~w(inbox review_gate worker_failed worker_done bead_state)

  @doc "All valid topic name strings accepted by the `subscribe=` query parameter."
  def valid_topics, do: @valid_topics

  @doc "The PubSub topic for a workspace's event stream."
  def pubsub_topic(workspace_id) when is_binary(workspace_id), do: "events:" <> workspace_id

  @doc """
  Broadcast an event on the workspace's event stream PubSub topic.

  `event_topic` is one of the valid topic strings (e.g. `"worker_failed"`).
  `payload` is merged with `topic` and `at` (ISO-8601 timestamp) before broadcasting.
  Best-effort: PubSub failures are swallowed.
  """
  def broadcast(workspace_id, event_topic, payload)
      when is_binary(workspace_id) and is_binary(event_topic) and is_map(payload) do
    event =
      payload
      |> Map.put(:topic, event_topic)
      |> Map.put(:at, DateTime.utc_now() |> DateTime.to_iso8601())

    Phoenix.PubSub.broadcast(Arbiter.PubSub, pubsub_topic(workspace_id), {:event, event})
    :ok
  rescue
    e ->
      Logger.debug("Arbiter.Events.broadcast/3 swallowed: #{Exception.message(e)}")
      :ok
  end

  def broadcast(_workspace_id, _event_topic, _payload), do: :ok
end
