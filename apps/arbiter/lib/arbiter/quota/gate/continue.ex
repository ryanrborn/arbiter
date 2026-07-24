defmodule Arbiter.Quota.Gate.Continue do
  @moduledoc """
  Overage `Arbiter.Quota.Gate` (bd-7cd38f): keep dispatching past the cap.

  For installs that pay the standard API rate once the plan quota is depleted.
  Always returns `:allow` so dispatch proceeds — but when the latest snapshot
  shows past-plan usage (`overage_status == "in_overage"`, or the primary window
  is no longer `"allowed"`) it returns `{:overage, spend_usd}`, where `spend_usd`
  is the windowed overage spend the dispatcher records and alerts on. The
  guardrail is **cap + alert, never stop**: the dispatcher fires one alert per
  `overage_alert_usd` crossing but dispatch is never blocked.

  Provider-neutral (bd-2mpo3f): the snapshot may be an `AnthropicQuota`,
  `CodexQuota` or `GoogleQuota` row. Only Anthropic reports an explicit
  `overage_status`; for Codex / Google the past-plan `status` (Codex's
  `limit_reached`) is the trigger, and `spend_usd` is the same windowed
  workspace spend from the usage ledger.

  Fails open on a `nil` (or unrecognized) snapshot — plain `:allow`, no overage
  tag.
  """

  @behaviour Arbiter.Quota.Gate

  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.Overage

  @impl true
  def check(_task, quota, workspace, _opts) do
    case Snapshot.normalize(quota) do
      nil ->
        :allow

      %Snapshot{} = snapshot ->
        if Gate.in_overage?(snapshot, workspace) do
          {:overage, Overage.windowed_spend(workspace, snapshot)}
        else
          :allow
        end
    end
  end
end
