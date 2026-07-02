defmodule Arbiter.Quota.Gate.Throttle do
  @moduledoc """
  Default `Arbiter.Quota.Gate` (bd-7cd38f): HOLD new dispatches near the 5h cap.

  Returns `{:hold, reason}` when the latest quota snapshot is at/over the cap
  (`status_5h != "allowed"` OR `utilization_5h >= threshold`), so the dispatcher
  queues the intent in the per-workspace `Arbiter.Workflows.DispatchQueue`
  instead of spawning a worker. Otherwise `:allow`.

  Fails open — a `nil` snapshot (proxy disabled / nothing captured yet) always
  returns `:allow`, so dispatch never deadlocks on missing quota data.
  """

  @behaviour Arbiter.Quota.Gate

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Gate

  @impl true
  def check(_task, nil, _workspace, _opts), do: :allow

  def check(_task, %AnthropicQuota{} = quota, workspace, _opts) do
    if Gate.over_cap?(quota, workspace) do
      {:hold, hold_reason(quota, workspace)}
    else
      :allow
    end
  end

  # A compact, inspectable reason for why the dispatch was held — surfaced in the
  # queue state and logs. Captures the binding signal (status vs utilization).
  defp hold_reason(%AnthropicQuota{status_5h: status, utilization_5h: util}, workspace) do
    %{
      status_5h: status,
      utilization_5h: util,
      threshold: Gate.threshold(workspace)
    }
  end
end
