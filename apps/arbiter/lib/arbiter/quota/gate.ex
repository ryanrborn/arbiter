defmodule Arbiter.Quota.Gate do
  @moduledoc """
  Behaviour for the quota-aware dispatch gate (bd-7cd38f).

  The gate is the single choke point the fleet dispatcher
  (`Arbiter.Worker.Dispatch.dispatch/2`) consults before mutating any task
  state, so a near-cap decision covers every dispatch path at once. It reads the
  latest quota snapshot for the workspace **and the provider this dispatch will
  actually run on** (bd-2mpo3f) and decides what to do when that provider nears
  / crosses its primary window cap:

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

  ## Providers (bd-2mpo3f)

  Every helper here takes a *snapshot* rather than an `AnthropicQuota` row:
  `Arbiter.Quota.Gate.Snapshot.normalize/1` projects `AnthropicQuota` (Claude),
  `CodexQuota` (Codex) and `GoogleQuota` (Gemini CLI / Antigravity) onto one
  provider-neutral shape — primary-window `utilization`, past-plan `status`,
  `reset_at` / `captured_at` — so the same near-cap semantics apply to all four
  providers without the gate knowing any provider's field names. The caller
  (`Arbiter.Worker.Dispatch`) resolves which provider the dispatch will run on
  and reads that provider's row via `Arbiter.Quota.latest_for_provider/2`.

  A `nil` quota snapshot (probe disabled, or nothing captured yet) MUST
  fail open — every implementation returns `:allow` so dispatch never
  deadlocks on missing quota data.
  """

  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @type decision :: :allow | {:hold, term()} | {:overage, float()}

  @typedoc """
  Any persisted provider quota row (`AnthropicQuota` / `CodexQuota` /
  `GoogleQuota`), an already-normalized `Snapshot`, or `nil`.
  """
  @type quota_source :: struct() | nil

  @callback check(
              task :: Issue.t() | nil,
              quota :: quota_source(),
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

  # Pre-existing complexity 11 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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
  Whether the snapshot's primary window has already elapsed and can no longer be
  trusted for gate decisions. Returns `false` for `nil` (nil is handled as
  fail-open by both `over_cap?/2` and `in_overage?/2`).

  A snapshot is stale when either:
    * `reset_at` is set and lies in the past — the window has rolled (Anthropic
      5h, Codex session, Google representative model), so `utilization` /
      `status` no longer reflect the current window.
    * `captured_at` is more than 5 hours ago — the snapshot is too old to
      throttle on even if `reset_at` is absent.
  """
  @spec stale?(quota_source()) :: boolean()
  def stale?(quota), do: quota |> Snapshot.normalize() |> snapshot_stale?()

  defp snapshot_stale?(nil), do: false

  defp snapshot_stale?(%Snapshot{} = snapshot) do
    now = DateTime.utc_now()

    reset_elapsed =
      match?(%DateTime{}, snapshot.reset_at) and
        DateTime.compare(snapshot.reset_at, now) == :lt

    too_old =
      match?(%DateTime{}, snapshot.captured_at) and
        DateTime.diff(now, snapshot.captured_at, :second) >= 18_000

    reset_elapsed or too_old
  end

  @doc """
  Whether the snapshot indicates the provider is at/over its primary-window cap.

  True when the provider's status is anything other than `"allowed"` (Anthropic
  `status_5h`, Codex `limit_reached`) OR utilization has reached the configured
  threshold. A `nil` snapshot is never "over cap" (fail open). A stale snapshot
  (window already elapsed) is treated as nil — fail open. Shared by both gate
  implementations.
  """
  @spec over_cap?(quota_source(), Workspace.t() | nil) :: boolean()
  def over_cap?(quota, workspace) do
    case Snapshot.normalize(quota) do
      nil ->
        false

      %Snapshot{} = snapshot ->
        if snapshot_stale?(snapshot) do
          false
        else
          status_not_allowed?(snapshot.status) or
            utilization_over?(snapshot.utilization, threshold(workspace))
        end
    end
  end

  @doc """
  Whether the snapshot indicates *genuine past-plan usage* — Anthropic's
  `overage_status == "in_overage"`, or the primary window is past-plan
  (`status != "allowed"`; for Codex that is `limit_reached`). Used by `Continue`
  to decide when to tag overage spend.

  Deliberately does NOT key on the throttle threshold (`over_cap?/2`): crossing
  `utilization >= throttle_threshold` while still `"allowed"` means we are near
  the cap, not past the plan. Tagging overage there would record overage spend —
  and fire the overage alert — before the account is actually paying overage
  (reviewer round 1, finding 2).

  A stale snapshot (window already elapsed) is treated as nil — fail open.
  """
  @spec in_overage?(quota_source(), Workspace.t() | nil) :: boolean()
  def in_overage?(quota, _workspace) do
    case Snapshot.normalize(quota) do
      nil ->
        false

      %Snapshot{} = snapshot ->
        if snapshot_stale?(snapshot) do
          false
        else
          snapshot.overage_status == "in_overage" or status_not_allowed?(snapshot.status)
        end
    end
  end

  defp status_not_allowed?(status) when is_binary(status), do: status != "allowed"
  defp status_not_allowed?(_), do: false

  defp utilization_over?(u, threshold) when is_number(u) and is_number(threshold),
    do: u >= threshold

  defp utilization_over?(_, _), do: false
end
