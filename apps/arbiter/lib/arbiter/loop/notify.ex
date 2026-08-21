defmodule Arbiter.Loop.Notify do
  @moduledoc """
  The queue's **notification step**: one place that turns a `PendingWrite`
  state change into fan-out.

  Split out of `Arbiter.Loop` (bd-3b7svv) because every write path in the queue
  ends here — `record/1`, reinforcement, promotion, `apply_pending/2`,
  `reject_pending/2` — and because "did applying announce it?" is worth
  asserting on its own rather than only as a side effect of the apply pipeline.

  Announcing is best-effort by design: a queue write must never fail because a
  subscriber, PubSub, or the events stream did.
  """

  alias Arbiter.Loop.PendingWrite

  require Logger

  # Internal fan-out for every queue state change. See `topic/0`.
  @topic "loop_proposals"

  @doc """
  PubSub topic the queue publishes every state change on, for in-process
  subscribers (the `/loop` dashboard).

  Distinct from the `/events` `loop_proposal` topic on purpose: `/events` is
  keyed by workspace and can only carry a workspace-scoped row, while most
  proposals are fleet-wide with no workspace at all.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Broadcast `event` for `row` on both the in-process topic and `/events`.

  Always returns `:ok`-ish: any failure downstream is logged and swallowed.
  """
  @spec announce(PendingWrite.t(), atom()) :: any()
  def announce(%PendingWrite{} = row, event) do
    payload = %{
      event: event,
      id: row.id,
      kind: row.kind,
      state: row.state,
      scope: row.scope,
      gist: row.gist,
      evidence_count: row.evidence_count,
      distinct_tasks: row.distinct_tasks
    }

    Phoenix.PubSub.broadcast(Arbiter.PubSub, @topic, {:loop_proposal, event, row.id})

    # `Arbiter.Events.broadcast/3` is workspace-keyed and no-ops on a nil id, and
    # a fleet-wide proposal carries no workspace of its own — so it is published
    # onto the installation default workspace's stream, the same fallback the
    # escalation uses. Ambiguous installs resolve to nil and simply don't reach
    # `/events`.
    Arbiter.Events.broadcast(workspace_id(row), "loop_proposal", payload)
  rescue
    e ->
      Logger.debug("Arbiter.Loop announce swallowed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  The workspace a notification about `row` should be keyed to.

  A fleet-wide proposal has no workspace of its own, but the coordinator
  mailbox and the `/events` stream are both workspace-keyed. `arb loop analyze
  --propose` without `--workspace` is the primary path, so falling back to the
  installation default workspace is what makes the escalation fire at all.
  `default_workspace_id/0` deliberately errors when the install is ambiguous
  (several workspaces, none named "default"), and there we stay silent rather
  than pick one.
  """
  @spec workspace_id(PendingWrite.t()) :: String.t() | nil
  def workspace_id(%PendingWrite{workspace_id: ws_id}) when is_binary(ws_id), do: ws_id

  def workspace_id(_row) do
    case Arbiter.Quota.default_workspace_id() do
      {:ok, ws_id} -> ws_id
      _ -> nil
    end
  end
end
