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

  # Staleness thresholds, per `capture_source` — see
  # `staleness_threshold_seconds/1` for why the polled source gets twice the
  # margin of the header capture.
  @default_staleness_threshold_seconds 300
  @default_polled_staleness_threshold_seconds 600
  @oauth_poll_source "oauth_poll"
  @weekly_warning_policies ~w[ignore hold]

  # Both long windows this gate sees — Anthropic's 7d and Codex's weekly — are
  # seven days long. Used only as the bounded fallback in `long_window_stale?/1`
  # for a snapshot that carries no long-window `reset_at`.
  @long_window_seconds 7 * 24 * 60 * 60

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
  Whether the snapshot's **primary** window has already elapsed and can no
  longer be trusted for gate decisions. Returns `false` for `nil` (nil is
  handled as fail-open by both `over_cap?/2` and `in_overage?/2`).

  A snapshot is stale when either:
    * `reset_at` is set and lies in the past — the window has rolled (Anthropic
      5h, Codex session, Google representative model), so `utilization` /
      `status` no longer reflect the current window.
    * `captured_at` is older than the staleness threshold for the snapshot's
      own `capture_source` (300 s for proxy header capture, 600 s for a
      `/api/oauth/usage` poll — see `staleness_threshold_seconds/1`) — the
      snapshot is too old to trust for dispatch decisions even if the window
      hasn't rolled yet. After `/limit-reset` or other API state changes, the
      snapshot won't reflect the new state until a request is made, and if the
      gate holds all requests, the stale snapshot never updates (bd-y0yup0).

  This is the *primary-window* predicate, and it is what callers outside the
  gate mean by "too old to trust" — `Arbiter.Quota.RefreshProbe` uses it to
  decide a workspace is worth a real refresh request, `Arbiter.Loop.Scarcity`
  uses it to refuse to calibrate, and `arb quota` prints it as `STALE`.

  Staleness fails open **for the primary window only**: `over_cap?/2` and
  `in_overage?/2` drop the primary signals of a stale snapshot. If the
  workspace is still genuinely exhausted, at most one dispatch attempt per
  staleness window (default 5 min) will be let through before the gate
  re-captures the real `rejected` status and starts holding again (the clock
  resets on the captured_at timestamp).

  The **long** window does not fail open on age — see `long_window_stale?/1`.
  """
  @spec stale?(quota_source()) :: boolean()
  def stale?(quota), do: quota |> Snapshot.normalize() |> snapshot_stale?()

  defp snapshot_stale?(nil), do: false

  defp snapshot_stale?(%Snapshot{} = snapshot) do
    reset_elapsed?(snapshot.reset_at) or
      captured_older_than?(
        snapshot.captured_at,
        staleness_threshold_seconds(snapshot.capture_source)
      )
  end

  @doc """
  Whether the snapshot's **long** window (Anthropic 7d, Codex weekly) can no
  longer be trusted. Returns `false` for `nil` and for providers that report no
  long window at all (Google), whose long-window rules never bind anyway.

  Deliberately *not* the same predicate as `stale?/1` (bd-b7umwj). Age alone
  never invalidates a long-window reading, because the fail-open recovery
  `stale?/1` exists for does not work on this window:

    * On the primary window a hold means the provider is *refusing* requests.
      The one attempt per staleness window that fail-open lets through is
      rejected in milliseconds and re-captures a real `rejected` — cheap, and
      the only way out of the deadlock bd-y0yup0 describes.
    * On the long window a hold happens at `allowed_warning` — the provider
      still **accepts** the request. The let-through dispatch therefore
      succeeds and runs a worker for hours against the very budget the hold
      exists to protect, and because a held fleet makes no traffic, the
      snapshot is stale again five minutes later. That is not a recovery
      valve, it is a loop that burns the week (observed 2026-09-11: the 7d
      window walked 94% → 96% *after* the stop went live).

  So a long-window hold is sticky. It lifts when a **fresh** snapshot shows it
  cleared, or when the long window's own `reset_at` rolls — never on age alone.
  Refreshing the snapshot does not need a worker dispatch:
  `Arbiter.Quota.RefreshProbe` already issues a tiny direct request per held
  workspace every `active_interval_ms` (default 5 min), and it keys off
  `stale?/1`, which still goes true on age.

  The one age-based exception is a bounded safety valve: when the provider
  reports no long-window `reset_at` there is no rollover to key on, so a
  reading older than the long window's own length (#{@long_window_seconds}s /
  7 days — both Anthropic's 7d and Codex's weekly window) stops binding,
  since by then the window must have rolled at least once.
  """
  @spec long_window_stale?(quota_source()) :: boolean()
  def long_window_stale?(quota), do: quota |> Snapshot.normalize() |> snapshot_long_stale?()

  defp snapshot_long_stale?(nil), do: false

  defp snapshot_long_stale?(%Snapshot{secondary_window_label: nil}), do: false

  defp snapshot_long_stale?(%Snapshot{secondary_reset_at: %DateTime{} = reset_at}),
    do: reset_elapsed?(reset_at)

  defp snapshot_long_stale?(%Snapshot{} = snapshot),
    do: captured_older_than?(snapshot.captured_at, @long_window_seconds)

  defp reset_elapsed?(%DateTime{} = reset_at),
    do: DateTime.compare(reset_at, DateTime.utc_now()) == :lt

  defp reset_elapsed?(_), do: false

  defp captured_older_than?(%DateTime{} = captured_at, seconds),
    do: DateTime.diff(DateTime.utc_now(), captured_at, :second) >= seconds

  defp captured_older_than?(_, _), do: false

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
      _ -> @default_staleness_threshold_seconds
    end
  end

  @doc """
  The staleness threshold for a snapshot written by `capture_source`
  (bd-b0zody).

  Header capture rides on traffic the fleet is making anyway, so a gap in it
  means the fleet went quiet — 300 s is a fine trip-wire. The
  `/api/oauth/usage` poll is different: that endpoint's account-wide budget is
  roughly **one request per 5 minutes**, which is exactly the 300 s threshold,
  so a single 429 (the endpoint 429s readily, and
  `Arbiter.Quota.OAuthUsage` then sits out a 180 s cooldown) would age the row
  past the threshold and fail the primary window **open** — the fleet would
  dispatch straight into a cap it had just measured.

  A polled row therefore gets #{@default_polled_staleness_threshold_seconds} s
  (`:polled_staleness_threshold_seconds` app-env): two whole missed polls of
  margin, so it takes a sustained outage rather than one 429 to lose the gate.
  Raising the threshold was chosen over polling faster (e.g. every 240 s)
  because polling faster *spends* more of the same scarce budget to buy the
  margin, and with a 180 s cooldown after a 429 the next successful poll can
  still land ~480 s after the last one — more requests, and still no margin.

  Anything other than the poll marker — the proxy's `"headers"`, `nil` on
  legacy rows, and every non-Anthropic provider (Codex / Google, which carry
  no `capture_source`) — keeps `staleness_threshold_seconds/0`.
  """
  @spec staleness_threshold_seconds(String.t() | nil) :: integer()
  def staleness_threshold_seconds(@oauth_poll_source) do
    case Application.get_env(:arbiter, :quota, [])[:polled_staleness_threshold_seconds] do
      n when is_integer(n) and n > 0 -> n
      _ -> max(@default_polled_staleness_threshold_seconds, staleness_threshold_seconds())
    end
  end

  def staleness_threshold_seconds(_source), do: staleness_threshold_seconds()

  @doc """
  Whether the snapshot indicates the provider is at/over a cap in **either** of
  its windows. Sugar for `gating_window/2 != nil`.

  A `nil` snapshot is never "over cap" (fail open). Staleness is scoped to the
  window it actually describes (bd-b7umwj): a stale **primary** window fails
  open, a stale **long** window stays held. Shared by both gate
  implementations.
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

  Each window's rules are skipped when *that* window's reading can no longer be
  trusted — `stale?/1` drops rules 1 and 3, `long_window_stale?/1` drops rules
  2, 4 and 5 (bd-b7umwj). The severity order above is preserved across whatever
  survives, so a fail-open 5h window still reports the 7d hold underneath it
  rather than reporting nothing.

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
        binding(snapshot, workspace)
    end
  end

  defp binding(%Snapshot{} = s, workspace) do
    primary? = not snapshot_stale?(s)
    long? = not snapshot_long_stale?(s)

    [
      {primary?, &primary_status_binding/3},
      {long?, &secondary_status_binding/3},
      {primary?, &primary_utilization_binding/3},
      {long?, &secondary_utilization_binding/3},
      {long?, &secondary_warning_binding/3}
    ]
    |> Enum.filter(fn {trusted?, _rule} -> trusted? end)
    |> Enum.find_value(fn {_trusted?, rule} -> rule.(s, workspace, nil) end)
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

  Staleness is scoped per window exactly as in `gating_window/2` (bd-b7umwj):
  a stale primary window drops the `overage_status` / primary `status` signals
  (fail open), while a long-window reject keeps counting until
  `long_window_stale?/1` says otherwise.
  """
  @spec in_overage?(quota_source(), Workspace.t() | nil) :: boolean()
  def in_overage?(quota, _workspace) do
    case Snapshot.normalize(quota) do
      nil ->
        false

      %Snapshot{} = snapshot ->
        primary_overage?(snapshot) or long_window_overage?(snapshot)
    end
  end

  defp primary_overage?(%Snapshot{} = s) do
    not snapshot_stale?(s) and
      (s.overage_status == "in_overage" or status_not_allowed?(s.status))
  end

  defp long_window_overage?(%Snapshot{} = s) do
    not snapshot_long_stale?(s) and secondary_rejected?(s.secondary_status)
  end

  defp status_not_allowed?(status) when is_binary(status), do: status != "allowed"
  defp status_not_allowed?(_), do: false

  defp utilization_over?(u, threshold) when is_number(u) and is_number(threshold),
    do: u >= threshold

  defp utilization_over?(_, _), do: false
end
