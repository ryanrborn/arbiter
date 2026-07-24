defmodule Arbiter.Quota.Gate.Throttle do
  @moduledoc """
  Default `Arbiter.Quota.Gate` (bd-7cd38f): HOLD new dispatches near the cap.

  Returns `{:hold, reason}` when the latest quota snapshot for the dispatch's
  provider is at/over the cap (past-plan status OR `utilization >= threshold`),
  so the dispatcher queues the intent in the per-workspace
  `Arbiter.Workflows.DispatchQueue` instead of spawning a worker. Otherwise
  `:allow`.

  Provider-neutral (bd-2mpo3f): the snapshot may be an `AnthropicQuota`,
  `CodexQuota` or `GoogleQuota` row — `Arbiter.Quota.Gate.Snapshot` normalizes
  it, so a blown Codex or Gemini account holds exactly like a blown Anthropic
  one.

  Fails open — a `nil` (or unrecognized) snapshot always returns `:allow`, so
  dispatch never deadlocks on missing quota data.
  """

  @behaviour Arbiter.Quota.Gate

  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot

  @impl true
  def check(_task, quota, workspace, _opts) do
    case Snapshot.normalize(quota) do
      nil ->
        :allow

      %Snapshot{} = snapshot ->
        if Gate.over_cap?(snapshot, workspace) do
          {:hold, hold_reason(snapshot, workspace)}
        else
          :allow
        end
    end
  end

  # A compact, inspectable reason for why the dispatch was held — surfaced in the
  # queue state and logs. Captures the binding signal (status vs utilization) plus
  # the provider it applies to, since the fleet gates each provider separately.
  defp hold_reason(%Snapshot{} = snapshot, workspace) do
    %{
      provider: snapshot.provider,
      window: snapshot.window_label,
      status: snapshot.status,
      utilization: snapshot.utilization,
      threshold: Gate.threshold(workspace)
    }
  end
end
