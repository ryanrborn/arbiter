defmodule Arbiter.Quota.Gate.Continue do
  @moduledoc """
  Overage `Arbiter.Quota.Gate` (bd-7cd38f): keep dispatching past the cap.

  For installs that pay the standard API rate once the plan quota is depleted.
  Always returns `:allow` so dispatch proceeds — but when the latest snapshot
  shows past-plan usage (`overage_status == "in_overage"`, or the 5h window is no
  longer `"allowed"`) it returns `{:overage, spend_usd}`, where `spend_usd` is
  the windowed overage spend the dispatcher records and alerts on. The guardrail
  is **cap + alert, never stop**: the dispatcher fires one alert per
  `overage_alert_usd` crossing but dispatch is never blocked.

  Fails open on a `nil` snapshot (proxy disabled / nothing captured) — plain
  `:allow`, no overage tag.
  """

  @behaviour Arbiter.Quota.Gate

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Overage

  @impl true
  def check(_task, nil, _workspace, _opts), do: :allow

  def check(_task, %AnthropicQuota{} = quota, workspace, _opts) do
    if Gate.in_overage?(quota, workspace) do
      {:overage, Overage.windowed_spend(workspace, quota)}
    else
      :allow
    end
  end
end
