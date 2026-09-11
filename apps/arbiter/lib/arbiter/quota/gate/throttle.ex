defmodule Arbiter.Quota.Gate.Throttle do
  @moduledoc """
  Default `Arbiter.Quota.Gate` (bd-7cd38f): HOLD new dispatches near the cap.

  Returns `{:hold, reason}` when the latest quota snapshot for the dispatch's
  provider is at/over the cap in **either** window — the short one (Anthropic 5h,
  Codex session) or the long one (Anthropic 7d, Codex weekly) — so the dispatcher
  queues the intent in the per-workspace `Arbiter.Workflows.DispatchQueue`
  instead of spawning a worker. Otherwise `:allow`.

  The hold reason is `Arbiter.Quota.Gate.gating_window/2`'s map — which window
  bound, which signal in it (`:status` / `:utilization` / `:warning`), the
  numbers — plus a `:phrase` carrying the operator-facing wording, so the queue
  state and the logs say `7d quota 0.91 ≥ 0.90` rather than just "quota"
  (bd-1tuxv8).

  Provider-neutral (bd-2mpo3f): the snapshot may be an `AnthropicQuota`,
  `CodexQuota` or `GoogleQuota` row — `Arbiter.Quota.Gate.Snapshot` normalizes
  it, so a blown Codex or Gemini account holds exactly like a blown Anthropic
  one.

  Fails open — a `nil` (or unrecognized) snapshot always returns `:allow`, so
  dispatch never deadlocks on missing quota data.
  """

  @behaviour Arbiter.Quota.Gate

  alias Arbiter.Quota.Gate

  @impl true
  def check(_task, quota, workspace, _opts) do
    case Gate.gating_window(quota, workspace) do
      nil -> :allow
      binding -> {:hold, Map.put(binding, :phrase, Gate.hold_phrase(quota, workspace))}
    end
  end
end
