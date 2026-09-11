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

  @default_weekly_threshold 0.90
  @weekly_warning_policies ~w[ignore hold]

  @type decision :: :allow | {:hold, term()} | {:overage, float()}

  @typedoc """
  Why the gate is holding: which window bound, what signal in it bound, and the
  numbers behind that call. `nil` when nothing binds. Returned by
  `gating_window/2` and carried verbatim as the `Throttle` hold reason.
  """
  @type binding_window :: %{
          provider: String.t() | nil,
          window: String.t(),
          signal: :status | :utilization | :warning,
          status: String.t() | nil,
          utilization: float() | nil,
          threshold: float() | nil
        }

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
    ws_fraction(workspace, "throttle_threshold") || global_fraction(:throttle_threshold) || 0.85
  end

  @doc """
  The configured long-window (`utilization_7d` / Codex weekly) utilization at or
  above which the throttle gate holds (bd-1tuxv8).

  Reads the global `:arbiter, :quota` `:weekly_threshold` app-env, overridable
  per-workspace via `config["quota"]["weekly_threshold"]`, defaulting to
  `#{@default_weekly_threshold}`.

  The default sits **above** the 5h ceiling (`0.85`) on purpose: the weekly
  window resets at most once a week, so holding early parks the whole fleet for
  days, which is a worse failure than running the budget down. `0.90` leaves a
  10% reserve for whatever the operator most wants to spend it on while still
  stopping Autopilot from burning the tail of the week in an afternoon.
  """
  @spec weekly_threshold(Workspace.t() | nil) :: float()
  def weekly_threshold(workspace \\ nil) do
    ws_fraction(workspace, "weekly_threshold") || global_fraction(:weekly_threshold) ||
      @default_weekly_threshold
  end

  @doc """
  What an `allowed_warning` on the long window does (bd-1tuxv8).

    * `:ignore` (default) — no effect. The `weekly_threshold` utilization rule is
      the control; the warning tier is advisory only.
    * `:hold` — treat the warning like a reject and hold every dispatch.

  `:ignore` is the default deliberately. Anthropic raises `allowed_warning` on
  the 7d window well before the budget is actually gone (it was already set at
  0.76 utilization when this was filed), so defaulting to `:hold` would park the
  entire fleet for the rest of the week the first time the warning appeared —
  the exact "fleet stops for days" failure the ticket warns against. Installs
  that would rather stop early can opt in.

  Reads `config["quota"]["weekly_warning_policy"]`, then the global
  `:arbiter, :quota` `:weekly_warning_policy` app-env.
  """
  @spec weekly_warning_policy(Workspace.t() | nil) :: :ignore | :hold
  def weekly_warning_policy(workspace \\ nil) do
    ws_policy(workspace) || global_policy() || :ignore
  end

  @doc "Valid `quota.weekly_warning_policy` value strings."
  @spec weekly_warning_policies() :: [String.t()]
  def weekly_warning_policies, do: @weekly_warning_policies

  # Both thresholds are 0..1 fractions and may arrive as a number or its JSON
  # string form (the workspace config UI posts strings).
  defp ws_fraction(workspace, key) do
    get_in((workspace && workspace.config) || %{}, ["quota", key]) |> parse_fraction()
  end

  defp global_fraction(key) do
    Application.get_env(:arbiter, :quota, [])[key] |> parse_fraction()
  end

  defp parse_fraction(n) when is_number(n) and n > 0 and n <= 1, do: n * 1.0

  defp parse_fraction(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} when f > 0 and f <= 1 -> f
      _ -> nil
    end
  end

  defp parse_fraction(_), do: nil

  defp ws_policy(workspace) do
    get_in((workspace && workspace.config) || %{}, ["quota", "weekly_warning_policy"])
    |> parse_policy()
  end

  defp global_policy do
    Application.get_env(:arbiter, :quota, [])[:weekly_warning_policy] |> parse_policy()
  end

  defp parse_policy(p) when p in [:ignore, :hold], do: p
  defp parse_policy(s) when is_binary(s), do: parse_policy_string(s)
  defp parse_policy(_), do: nil

  defp parse_policy_string(s) when s in @weekly_warning_policies, do: String.to_existing_atom(s)
  defp parse_policy_string(_), do: nil

  @doc """
  Whether the snapshot's primary window has already elapsed and can no longer be
  trusted for gate decisions. Returns `false` for `nil` (nil is handled as
  fail-open by both `over_cap?/2` and `in_overage?/2`).

  A snapshot is stale when either:
    * `reset_at` is set and lies in the past — the window has rolled (Anthropic
      5h, Codex session, Google representative model), so `utilization` /
      `status` no longer reflect the current window.
    * `captured_at` is older than the configured staleness threshold
      (default 300 seconds / 5 minutes) — the snapshot is too old to trust for
      dispatch decisions even if the window hasn't rolled yet. After `/limit-reset`
      or other API state changes, the snapshot won't reflect the new state until
      a request is made, and if the gate holds all requests, the stale snapshot
      never updates (bd-y0yup0).

  Stale snapshots fail open: `over_cap?/2` and `in_overage?/2` treat a stale
  snapshot as `nil` and return `false`. If the workspace is still genuinely
  exhausted, at most one dispatch attempt per staleness window (default 5 min)
  will be let through before the gate re-captures the real `rejected` status
  and starts holding again (the clock resets on the captured_at timestamp).
  """
  @spec stale?(quota_source()) :: boolean()
  def stale?(quota), do: quota |> Snapshot.normalize() |> snapshot_stale?()

  defp snapshot_stale?(nil), do: false

  defp snapshot_stale?(%Snapshot{} = snapshot) do
    now = DateTime.utc_now()

    reset_elapsed =
      match?(%DateTime{}, snapshot.reset_at) and
        DateTime.compare(snapshot.reset_at, now) == :lt

    threshold_seconds = staleness_threshold_seconds()

    too_old =
      match?(%DateTime{}, snapshot.captured_at) and
        DateTime.diff(now, snapshot.captured_at, :second) >= threshold_seconds

    reset_elapsed or too_old
  end

  @doc """
  The staleness threshold in seconds. A snapshot older than this is treated as
  stale and fails open (no longer trusted for gate decisions).

  Reads the `:arbiter, :quota` `:staleness_threshold_seconds` app-env,
  defaulting to 300 seconds (5 minutes). This ensures that quota snapshots are
  refreshed frequently enough to catch state changes like a `/limit-reset`
  clearing the rate-limit cap. Without this threshold, a rejected snapshot held
  indefinitely without being updated (since the gate prevents requests) would
  deadlock recovery (bd-y0yup0).
  """
  @spec staleness_threshold_seconds() :: integer()
  def staleness_threshold_seconds do
    case Application.get_env(:arbiter, :quota, [])[:staleness_threshold_seconds] do
      n when is_integer(n) and n > 0 -> n
      _ -> 300
    end
  end

  @doc """
  Whether the snapshot indicates the provider is at/over a cap in **either** of
  its windows. Sugar for `gating_window/2 != nil`.

  A `nil` snapshot is never "over cap" (fail open). A stale snapshot (window
  already elapsed, or captured too long ago) is treated as nil — fail open, for
  both windows. Shared by both gate implementations.
  """
  @spec over_cap?(quota_source(), Workspace.t() | nil) :: boolean()
  def over_cap?(quota, workspace), do: gating_window(quota, workspace) != nil

  @doc """
  Which window, if any, is currently gating dispatch — and why (bd-1tuxv8).

  Returns `nil` when dispatch is free to proceed, or a `t:binding_window/0`
  describing the binding constraint. Checked in severity order, so the reported
  reason is the most urgent one when several apply at once:

    1. primary status past-plan (Anthropic `status_5h`, Codex `limit_reached`) —
       the provider is refusing requests right now;
    2. long-window status *rejected* — the provider is refusing on the weekly
       budget (anything other than `nil` / `"allowed"` / `"allowed_warning"`);
    3. primary `utilization >= threshold/1` — our own 5h ceiling;
    4. long-window `utilization >= weekly_threshold/1` — our own weekly ceiling;
    5. long-window `"allowed_warning"`, when `weekly_warning_policy/1` is
       `:hold`.

  Note the asymmetry in how `status` is treated between the two windows, and
  that it is deliberate. On the primary window *any* non-`"allowed"` status
  holds, including `"allowed_warning"` — that window resets in hours, so
  stopping early is cheap. On the long window `"allowed_warning"` is routed
  through `weekly_warning_policy/1` instead (default `:ignore`): Anthropic sets
  it far from exhaustion, and treating it like a reject would hold the fleet for
  the remainder of the week. A genuine long-window reject always holds (rule 2).
  """
  @spec gating_window(quota_source(), Workspace.t() | nil) :: binding_window() | nil
  def gating_window(quota, workspace) do
    case Snapshot.normalize(quota) do
      nil ->
        nil

      %Snapshot{} = snapshot ->
        if snapshot_stale?(snapshot), do: nil, else: binding(snapshot, workspace)
    end
  end

  defp binding(%Snapshot{} = s, workspace) do
    Enum.find_value(
      [
        &primary_status_binding/3,
        &secondary_status_binding/3,
        &primary_utilization_binding/3,
        &secondary_utilization_binding/3,
        &secondary_warning_binding/3
      ],
      fn rule -> rule.(s, workspace, nil) end
    )
  end

  defp primary_status_binding(%Snapshot{} = s, _ws, _acc) do
    if status_not_allowed?(s.status) do
      %{
        provider: s.provider,
        window: s.window_label,
        signal: :status,
        status: s.status,
        utilization: s.utilization,
        threshold: nil
      }
    end
  end

  defp secondary_status_binding(%Snapshot{} = s, _ws, _acc) do
    if secondary_rejected?(s.secondary_status) do
      %{
        provider: s.provider,
        window: s.secondary_window_label,
        signal: :status,
        status: s.secondary_status,
        utilization: s.secondary_utilization,
        threshold: nil
      }
    end
  end

  defp primary_utilization_binding(%Snapshot{} = s, ws, _acc) do
    t = threshold(ws)

    if utilization_over?(s.utilization, t) do
      %{
        provider: s.provider,
        window: s.window_label,
        signal: :utilization,
        status: s.status,
        utilization: s.utilization,
        threshold: t
      }
    end
  end

  defp secondary_utilization_binding(%Snapshot{} = s, ws, _acc) do
    t = weekly_threshold(ws)

    if s.secondary_window_label && utilization_over?(s.secondary_utilization, t) do
      %{
        provider: s.provider,
        window: s.secondary_window_label,
        signal: :utilization,
        status: s.secondary_status,
        utilization: s.secondary_utilization,
        threshold: t
      }
    end
  end

  defp secondary_warning_binding(%Snapshot{} = s, ws, _acc) do
    if s.secondary_status == "allowed_warning" and weekly_warning_policy(ws) == :hold do
      %{
        provider: s.provider,
        window: s.secondary_window_label,
        signal: :warning,
        status: s.secondary_status,
        utilization: s.secondary_utilization,
        threshold: weekly_threshold(ws)
      }
    end
  end

  # Long-window statuses: nil / "allowed" are fine, "allowed_warning" is the
  # policy-governed warning tier, everything else ("rejected", …) is a hard stop.
  defp secondary_rejected?(status)
       when is_binary(status) and status not in ["allowed", "allowed_warning"],
       do: true

  defp secondary_rejected?(_), do: false

  @doc """
  A short human phrase for the current hold, or `nil` when nothing is gating.

  The 5h phrasing is unchanged (`"quota exhausted"` / `"quota near
  exhaustion (…)"`), so existing board copy and operator muscle memory still
  read the same. A long-window hold is deliberately worded differently — it
  leads with the window label, because "wait ~3 hours" and "wait until Sunday"
  are very different operator instructions:

      blocked — 7d quota 0.91 ≥ 0.90
      blocked — 7d quota exhausted (status=rejected)
      blocked — 7d quota allowed_warning (weekly_warning_policy: hold)
  """
  @spec hold_phrase(quota_source(), Workspace.t() | nil) :: String.t() | nil
  def hold_phrase(quota, workspace) do
    quota |> gating_window(workspace) |> phrase()
  end

  defp phrase(nil), do: nil

  defp phrase(%{window: window, signal: :status, status: status}) do
    if primary_window?(window) do
      "quota exhausted"
    else
      "#{window} quota exhausted (status=#{status})"
    end
  end

  defp phrase(%{window: window, signal: :utilization, utilization: u, threshold: t}) do
    if primary_window?(window) do
      "quota near exhaustion (#{percent(u)} of window used, ceiling #{percent(t)})"
    else
      "#{window} quota #{frac(u)} ≥ #{frac(t)}"
    end
  end

  defp phrase(%{window: window, signal: :warning, status: status}) do
    "#{window} quota #{status} (weekly_warning_policy: hold)"
  end

  # The long windows are the ones the secondary mapping names; everything else
  # ("5h", "session", "used", "primary") is the short/primary window.
  defp primary_window?(window), do: window not in ["7d", "weekly"]

  defp percent(n) when is_number(n), do: "#{round(n * 100)}%"
  defp percent(_), do: "—"

  defp frac(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
  defp frac(_), do: "—"

  @doc """
  Whether the snapshot indicates *genuine past-plan usage* — Anthropic's
  `overage_status == "in_overage"`, or the primary window is past-plan
  (`status != "allowed"`; for Codex that is `limit_reached`). Used by `Continue`
  to decide when to tag overage spend.

  Deliberately does NOT key on the throttle threshold (`over_cap?/2`): crossing
  `utilization >= throttle_threshold` while still `"allowed"` means we are near
  the cap, not past the plan. Tagging overage there would record overage spend —
  and fire the overage alert — before the account is actually paying overage
  (reviewer round 1, finding 2). For the same reason a long-window
  `"allowed_warning"` is not overage either; only an outright long-window
  reject is (bd-1tuxv8).

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
          snapshot.overage_status == "in_overage" or status_not_allowed?(snapshot.status) or
            secondary_rejected?(snapshot.secondary_status)
        end
    end
  end

  defp status_not_allowed?(status) when is_binary(status), do: status != "allowed"
  defp status_not_allowed?(_), do: false

  defp utilization_over?(u, threshold) when is_number(u) and is_number(threshold),
    do: u >= threshold

  defp utilization_over?(_, _), do: false
end
