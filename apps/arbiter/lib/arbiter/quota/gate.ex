defmodule Arbiter.Quota.Gate do
  @moduledoc """
  Behaviour for the quota-aware dispatch gate (bd-7cd38f).

  The gate is the single choke point the fleet dispatcher
  (`Arbiter.Worker.Dispatch.dispatch/2`) consults before mutating any task
  state, so a near-cap decision covers every dispatch path at once. It reads the
  workspace's latest Anthropic quota snapshot (bd-5boun6) and decides what to do
  when the workspace nears / crosses the 5h cap:

    * `:allow` — dispatch proceeds normally (there is headroom, or we are
      failing open because no snapshot exists).
    * `{:hold, reason}` — HOLD the dispatch. The dispatcher enqueues the intent
      in the per-workspace `Arbiter.Workflows.DispatchQueue` and does NOT
      transition the task to `:in_progress`; the queue drains it later in
      priority order as headroom frees.
    * `{:overage, spend_usd}` — dispatch proceeds past the cap (paid overage);
      `spend_usd` is the windowed overage spend the caller records + alerts on.

  ## Implementations

    * `Arbiter.Quota.Gate.Throttle` (default) — returns `{:hold, _}` near the cap.
    * `Arbiter.Quota.Gate.Continue` — always `:allow`, tagging `{:overage, _}`
      when the snapshot shows past-plan usage.

  The concrete module is resolved per-workspace by
  `Arbiter.Quota.gate_for_workspace/1`, which honours the config precedence
  (per-workspace > global > `:throttle`) and the `:arbiter, :quota` `:gate`
  app-env override (the kill switch / test injection seam).

  A `nil` quota snapshot (proxy disabled, or nothing captured yet) MUST
  fail open — every implementation returns `:allow` so dispatch never
  deadlocks on missing quota data.
  """

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @type decision :: :allow | {:hold, term()} | {:overage, float()}

  @callback check(
              task :: Issue.t() | nil,
              quota :: AnthropicQuota.t() | nil,
              workspace :: Workspace.t() | nil,
              opts :: keyword()
            ) :: decision()

  @doc """
  The configured `utilization_5h` at/above which the throttle gate holds.

  Reads the global `:arbiter, :quota` `:throttle_threshold` app-env, defaulting
  to `0.85` (Ryan's hand-enforced ceiling, between the dashboard's 0.7/0.9
  bands). A per-workspace `config["quota"]["throttle_threshold"]` overrides it.
  """
  @spec threshold(Workspace.t() | nil) :: float()
  def threshold(workspace \\ nil) do
    ws_threshold(workspace) || global_threshold() || 0.85
  end

  defp ws_threshold(workspace) do
    case get_in((workspace && workspace.config) || %{}, ["quota", "throttle_threshold"]) do
      n when is_number(n) and n > 0 and n <= 1 ->
        n * 1.0

      s when is_binary(s) ->
        case Float.parse(s) do
          {f, _} when f > 0 and f <= 1 -> f
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp global_threshold do
    case Application.get_env(:arbiter, :quota, [])[:throttle_threshold] do
      n when is_number(n) and n > 0 and n <= 1 -> n * 1.0
      _ -> nil
    end
  end

  @doc """
  Whether the snapshot indicates the workspace is at/over the 5h cap.

  True when the 5h status is anything other than `"allowed"` OR utilization has
  reached the configured threshold. A `nil` snapshot is never "over cap" (fail
  open). Shared by both gate implementations.
  """
  @spec over_cap?(AnthropicQuota.t() | nil, Workspace.t() | nil) :: boolean()
  def over_cap?(nil, _workspace), do: false

  def over_cap?(%AnthropicQuota{} = quota, workspace) do
    status_not_allowed?(quota.status_5h) or
      utilization_over?(quota.utilization_5h, threshold(workspace))
  end

  @doc """
  Whether the snapshot indicates active paid overage — Anthropic's
  `overage_status == "in_overage"`, or the 5h window is past-plan (not
  `"allowed"`). Used by `Continue` to decide when to tag overage spend.
  """
  @spec in_overage?(AnthropicQuota.t() | nil, Workspace.t() | nil) :: boolean()
  def in_overage?(nil, _workspace), do: false

  def in_overage?(%AnthropicQuota{} = quota, workspace) do
    quota.overage_status == "in_overage" or over_cap?(quota, workspace)
  end

  defp status_not_allowed?(status) when is_binary(status), do: status != "allowed"
  defp status_not_allowed?(_), do: false

  defp utilization_over?(u, threshold) when is_number(u) and is_number(threshold),
    do: u >= threshold

  defp utilization_over?(_, _), do: false
end
