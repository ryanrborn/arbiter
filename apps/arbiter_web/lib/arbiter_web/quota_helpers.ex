defmodule ArbiterWeb.QuotaHelpers do
  @moduledoc false

  alias Arbiter.Quota
  alias Arbiter.Quota.Gate

  # `reset_5h_at`/`reset_7d_at` are stored as absolute timestamps with no
  # window-duration field (bd-d8wo5m), so the pace math needs each window's
  # length from somewhere. It comes from `Gate.window_seconds/2`, the same
  # resolver the paced dispatch gate uses (bd-2daof2) — two sources of window
  # length would let a bar read "on pace" while the gate holds.

  # Providers whose quota windows are fixed-duration, so the burn-rate
  # projection (pace ratio, "stalls in Nm") and the elapsed-time hairline
  # apply (bd-7uwovg). Every other provider shows neither — its colour still
  # comes from the gate, which falls back to its flat ceiling:
  #   - "codex" is excluded because its `reset_5h_at` slot is a *session*
  #     reset, not a fixed-duration window.
  #   - "gemini_cli" is excluded because it has no time window at all.
  #   (both per bd-d8wo5m review round 1)
  @fixed_window_providers ~w(claude antigravity)

  # Providers with a paid-overage mode (Arbiter.Quota.default_workspace_on_exhaustion/0).
  # Antigravity has no such billing path, so it always "stalls" rather than
  # "starts billing overage" under `:continue`.
  @overage_billing_providers ~w(claude)

  # Clamp utilization float to a 0-100 integer percentage.
  # Accepts both floats and integers (SQLite can return integers for
  # whole-number floats under certain driver/migration paths).
  def quota_pct(nil), do: 0
  def quota_pct(u) when is_number(u), do: min(100, round(u * 100))

  @doc """
  The pace of one quota bar (bd-clzkvp), read from the dispatch gate's own
  thresholds so a bar's colour says what the scheduler will do.

  `bar` carries `provider`, `window` (`"5h"` / `"7d"`, which picks the
  primary or long window's settings), `label` (the snapshot's window label —
  `"5h"`, `"7d"`, `"session"`, `"weekly"`, `"used"` — which
  `Arbiter.Quota.Gate.window_seconds/2` turns into a length), `utilization`,
  `reset_at` and `overage_status`. `gate_policy` is the view's
  `Arbiter.Quota.gate_policy/2`; `nil` resolves the install default.

  The colour follows `Arbiter.Quota.Gate.pace/6` under
  `Gate.paced_policy/1` — the paced thresholds, whether or not the account
  has opted into them — mapped `:ok` → `:green` (the provider hue),
  `:approaching` → `:amber`, `:holding` → `:red`, `:sampling` → `:grey`. The
  gate's *real* policy is evaluated too, and when it is holding this window
  the bar is red whatever pacing says. `holding` then tells the two apart:

    * `:enforcing` — the gate is holding dispatch on this window now;
    * `:not_enforcing` — it would hold at the paced thresholds, but the
      account is not paced (or the workspace is `:continue`), so it isn't;
    * `nil` — not holding.

  Paid overage (`overage_status == "in_overage"`) is always `:red`.
  """
  def quota_pace(bar, gate_policy \\ nil, now \\ DateTime.utc_now()) do
    %{policy: {account, _workspace} = policy, enforcing?: enforcing?} =
      gate_policy || Quota.gate_policy(nil, nil)
    kind = if bar.window == "5h", do: :primary, else: :long
    label = Map.get(bar, :label) || bar.window
    opts = [now: now]

    paced =
      Gate.pace(Gate.paced_policy(policy), kind, label, bar.utilization, bar.reset_at, opts)

    actual = Gate.pace(policy, kind, label, bar.utilization, bar.reset_at, opts)
    holding_now? = enforcing? and actual.verdict == :holding
    pace = if holding_now?, do: actual, else: paced

    %{
      verdict: pace.verdict,
      ceiling: pace.ceiling,
      mode: pace.mode,
      elapsed: pace.elapsed,
      holding: holding(pace.verdict, holding_now?),
      window_seconds: Gate.window_seconds(label, account),
      state: pace_state(pace.verdict, Map.get(bar, :overage_status))
    }
  end

  defp holding(:holding, true), do: :enforcing
  defp holding(:holding, false), do: :not_enforcing
  defp holding(_verdict, _holding_now?), do: nil

  defp pace_state(_verdict, "in_overage"), do: :red
  defp pace_state(:holding, _overage_status), do: :red
  defp pace_state(:approaching, _overage_status), do: :amber
  defp pace_state(:sampling, _overage_status), do: :grey
  defp pace_state(:ok, _overage_status), do: :green

  @doc """
  The bar colour for a pace `state` from `quota_pace/3`: red and amber are
  the state tokens, grey the neutral sampling token, and green the
  provider's own hue.
  """
  def quota_state_color(:red, _provider), do: "var(--arb-fail)"
  def quota_state_color(:amber, _provider), do: "var(--arb-attention)"
  def quota_state_color(:grey, _provider), do: "var(--arb-done)"
  def quota_state_color(:green, provider), do: quota_provider_hue(provider)

  @doc """
  Tooltip phrase for where a bar sits against the gate's ceiling, from
  `quota_pace/3`, or `nil` when it is comfortably under it:

      "holding dispatch — 40% used ≥ paced ceiling 35%"
      "would hold — 40% used ≥ paced ceiling 35% (gate not enforcing)"
      "approaching paced ceiling 35%"
  """
  def quota_hold_text(%{holding: :enforcing} = pace, utilization),
    do: "holding dispatch — #{used_vs_ceiling(pace, utilization)}"

  def quota_hold_text(%{holding: :not_enforcing} = pace, utilization),
    do: "would hold — #{used_vs_ceiling(pace, utilization)} (gate not enforcing)"

  def quota_hold_text(%{verdict: :approaching} = pace, _utilization),
    do: "approaching #{ceiling_text(pace)}"

  def quota_hold_text(_pace, _utilization), do: nil

  defp used_vs_ceiling(pace, utilization),
    do: "#{quota_pct(utilization)}% used ≥ #{ceiling_text(pace)}"

  defp ceiling_text(%{mode: :paced, ceiling: c}), do: "paced ceiling #{round(c * 100)}%"
  defp ceiling_text(%{ceiling: c}), do: "ceiling #{round(c * 100)}%"

  @doc """
  Text colour token for a quota bar's note/countdown, derived only from the
  bar's pace `state` (`:red | :amber | :green | :grey`):
    - `:red` -> `"var(--arb-fail)"`
    - `:amber` -> `"var(--arb-attention)"`
    - `:green`, `:grey`, or stale -> `nil` (neutral)
  """
  def quota_note_color(_state, true), do: nil
  def quota_note_color(:red, false), do: "var(--arb-fail)"
  def quota_note_color(:amber, false), do: "var(--arb-attention)"
  def quota_note_color(_state, false), do: nil

  @doc """
  Pace-ratio text for a bar's tooltip, e.g. `"3.5x pace"` — how many times
  faster (or slower) than the burn rate that would land exactly at 100% by
  reset. `"sampling — too little elapsed to project pace"` when `pace` (from
  `quota_pace/3`) is `:sampling`. `nil` when there's no usage/elapsed data or
  `bar.provider` isn't in `@fixed_window_providers`.
  """
  def quota_pace_ratio(%{provider: provider, utilization: u}, pace)
      when provider in @fixed_window_providers and is_number(u) do
    cond do
      pace.verdict == :sampling -> "sampling — too little elapsed to project pace"
      is_float(pace.elapsed) and pace.elapsed > 0 -> "#{format_ratio(u / pace.elapsed)}x pace"
      true -> nil
    end
  end

  def quota_pace_ratio(_bar, _pace), do: nil

  @doc """
  Warning label for an amber/red bar (bd-l4epbc): how long until the window
  runs dry at the current burn rate — `"stalls in Nm"` under `:throttle`,
  `"starts billing overage in Nm"` under `:continue` for `"claude"`. Every
  other fixed-window provider (e.g. `"antigravity"`) always gets "stalls in
  Nm", since `on_exhaustion`'s paid-overage mode is Anthropic-specific. `nil`
  when `pace.state` (from `quota_pace/3`) is green/grey, or for a provider
  outside `@fixed_window_providers`, so callers fall back to
  `quota_reset_label/1`.

  Only the text is a projection; whether it shows is the gate's call.
  """
  def quota_pace_label(
        %{provider: provider, utilization: u},
        %{state: state, elapsed: elapsed, window_seconds: seconds},
        on_exhaustion
      )
      when provider in @fixed_window_providers and state in [:amber, :red] and is_number(u) and
             u > 0 and is_float(elapsed) and elapsed > 0 and is_integer(seconds) do
    # used / elapsed_min is the burn rate; what's left, at that rate.
    elapsed_min = elapsed * seconds / 60
    minutes_to_exhaust = max(1 - u, 0) * elapsed_min / u

    "#{pace_label_verb(provider, on_exhaustion)} #{format_minutes(minutes_to_exhaust)}"
  end

  def quota_pace_label(_bar, _pace, _on_exhaustion), do: nil

  @doc """
  De-emphasis CSS class for a bar row that isn't the binding window per
  `representative_claim` (`"five_hour"` / `"seven_day"`) — the window
  that's actually about to bind should stand out over the one that isn't.
  `nil` (no de-emphasis) when this row IS the binding window, or when
  `representative_claim` is unknown (both rows render at equal weight, same
  as before this feature).
  """
  def quota_binding_class(nil, _window), do: nil

  def quota_binding_class(representative_claim, window) when representative_claim == window,
    do: nil

  def quota_binding_class(_representative_claim, _window), do: "opacity-50"

  @doc """
  Tooltip explanation for a dimmed bar row that isn't the binding window per
  `representative_claim` (`"five_hour"` / `"seven_day"`).
  `nil` when this row IS the binding window, or when `representative_claim`
  is unknown.
  """
  def quota_binding_title(nil, _window), do: nil

  def quota_binding_title(representative_claim, window) when representative_claim == window,
    do: nil

  def quota_binding_title("five_hour", _window),
    do: "not the binding window — Anthropic is currently limiting on 5h"

  def quota_binding_title("seven_day", _window),
    do: "not the binding window — Anthropic is currently limiting on 7d"

  def quota_binding_title(claim, _window) when is_binary(claim),
    do: "not the binding window — Anthropic is currently limiting on #{claim}"

  @doc """
  Combine a list of tooltip fragments (some possibly `nil`) into a single
  `" · "`-joined title string, or `nil` if every fragment was `nil` — so a
  `title` attribute is omitted rather than rendered empty.
  """
  def quota_bar_title(parts) do
    case Enum.reject(parts, &is_nil/1) do
      [] -> nil
      list -> Enum.join(list, " · ")
    end
  end

  defp window_seconds(label), do: Gate.window_seconds(label)

  defp pace_label_verb(provider, :continue) when provider in @overage_billing_providers,
    do: "starts billing overage in"

  defp pace_label_verb(_provider, _on_exhaustion), do: "stalls in"

  defp format_ratio(ratio) do
    ratio
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_minutes(minutes) when is_number(minutes) do
    secs = round(minutes * 60)

    cond do
      secs <= 0 -> "0m"
      secs < 3600 -> "#{div(secs, 60)}m"
      true -> "#{div(secs, 3600)}h#{div(rem(secs, 3600), 60)}m"
    end
  end

  # Short countdown string for compact contexts (topbar): "5m", "2h30m", "—".
  def quota_reset_label(nil), do: "—"

  def quota_reset_label(%DateTime{} = dt) do
    secs = DateTime.diff(dt, DateTime.utc_now())

    cond do
      secs <= 0 -> "now"
      secs < 60 -> "#{secs}s"
      secs < 3600 -> "#{div(secs, 60)}m"
      true -> "#{div(secs, 3600)}h#{div(rem(secs, 3600), 60)}m"
    end
  end

  # Full-sentence reset label for prose UI contexts; avoids "resets in now".
  def quota_reset_text(nil), do: "no data"

  def quota_reset_text(%DateTime{} = dt) do
    secs = DateTime.diff(dt, DateTime.utc_now())
    if secs <= 0, do: "resetting now", else: "resets in #{quota_reset_label(dt)}"
  end

  # Display label for a quota's `provider` code. Known providers get a
  # human-friendly name; anything else is title-cased as a fallback so a
  # newly-added provider still renders sensibly before this list is updated.
  @provider_labels %{
    "claude" => "Claude",
    "codex" => "Codex",
    "gemini_cli" => "Gemini CLI",
    "antigravity" => "Antigravity"
  }

  def quota_provider_label(provider) when is_binary(provider) do
    Map.get(@provider_labels, provider, title_case(provider))
  end

  defp title_case(provider) do
    provider
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Provider identity hues for the quota-bar fill (bd-gukyy1). Only `--arb-*`
  # custom properties, never raw hex, so the fill follows the dark-mode
  # redefinitions in app.css. Red (`--arb-fail`) and amber (`--arb-attention`)
  # are deliberately absent: red is the one pace state allowed to override the
  # fill, and a provider hue must never read as that state.
  @provider_hues %{
    "claude" => "var(--arb-proposal)",
    "antigravity" => "var(--arb-info)"
  }

  # An unmapped provider has no identity to show, so it gets a neutral slate
  # rather than borrowing another provider's hue or a state colour.
  @fallback_provider_hue "var(--arb-text-faint)"

  @doc """
  The fill hue for `provider`'s quota bars: a `var(--arb-*)` reference from
  `@provider_hues`, or `#{@fallback_provider_hue}` for any provider not in the
  map (including `nil`).
  """
  def quota_provider_hue(provider), do: Map.get(@provider_hues, provider, @fallback_provider_hue)

  @doc """
  The bar windows to render for one quota view, in order: `window` picks the
  pace math (`"5h"` or `"7d"` duration), `label` is what the bar shows — the
  view's own `primary_label` / `secondary_label` (Claude "5h"/"7d",
  Antigravity "5h"/"weekly", collapsed Google "used"). A view with no
  `secondary_label` (bd-7mro0t's collapsed fallback) yields one window, not a
  second bar pinned at 0%.
  """
  def quota_windows(view) do
    primary = %{
      window: "5h",
      label: Map.get(view, :primary_label) || "5h",
      utilization: view.utilization_5h,
      reset_at: view.reset_5h_at
    }

    case Map.get(view, :secondary_label, "7d") do
      nil ->
        [primary]

      label ->
        [
          primary,
          %{
            window: "7d",
            label: label,
            utilization: view.utilization_7d,
            reset_at: view.reset_7d_at
          }
        ]
    end
  end

  # Antigravity's two bucket groups, keyed as `CloudCode` persists them
  # (`"<group>_5h"` / `"<group>_weekly"` model ids) and labelled as the `agy`
  # CLI names them.
  @antigravity_groups [
    {"gemini_models", "Gemini Models"},
    {"claude_and_gpt_models", "Claude and GPT models"}
  ]

  @doc """
  Antigravity's per-group bucket windows, read from the view's `models` list by
  `model_id` via `Arbiter.Quota.CloudCode.antigravity_bucket/3` — one
  `%{group: id, label: name, windows: [...]}` per group that has any bucket,
  each window shaped like `quota_windows/1`'s. `[]` when the snapshot carries
  no parseable buckets, so the caller falls back to `quota_windows/1`.
  """
  def quota_antigravity_groups(view) do
    models = Map.get(view, :models) || []

    for {group, label} <- @antigravity_groups,
        windows = antigravity_group_windows(models, group),
        windows != [] do
      %{group: group, label: label, windows: windows}
    end
  end

  defp antigravity_group_windows(models, group) do
    for {window, bucket_window, label} <- [{"5h", "5h", "5h"}, {"7d", "weekly", "weekly"}],
        %{} = reading <- [
          Arbiter.Quota.CloudCode.antigravity_bucket(models, group, bucket_window)
        ] do
      %{
        window: window,
        label: label,
        utilization: reading.utilization,
        reset_at: reading.reset_at
      }
    end
  end

  @doc """
  Fraction of the 5h window elapsed so far, as a 0-100 integer — the
  time-elapsed marker position on the 5h usage bars. `nil` when there's no
  `reset_5h_at` to derive a window from (marker isn't rendered), or when
  `provider` isn't in `@fixed_window_providers` (Codex's `reset_5h_at` slot
  is a session reset, not a fixed-duration window; Gemini CLI has no time
  window at all; see bd-d8wo5m review round 1).
  """
  def quota_elapsed_pct_5h(provider, reset_at) when provider in @fixed_window_providers,
    do: elapsed_pct(reset_at, window_seconds("5h"))

  def quota_elapsed_pct_5h(_provider, _reset_at), do: nil

  @doc "Same as `quota_elapsed_pct_5h/2`, for the 7d window."
  def quota_elapsed_pct_7d(provider, reset_at) when provider in @fixed_window_providers,
    do: elapsed_pct(reset_at, window_seconds("7d"))

  def quota_elapsed_pct_7d(_provider, _reset_at), do: nil

  @doc """
  Hover-tooltip / aria-label text for a 5h usage bar, stating both the
  usage-fill and time-elapsed numbers in words, e.g.
  `"62% quota used · 50% of window elapsed (2.5h into 5h)"`. `nil` when
  there's no `reset_5h_at` to derive a window from, or when `provider` isn't
  in `@fixed_window_providers`.
  """
  def quota_tooltip_5h(provider, utilization, reset_at) when provider in @fixed_window_providers,
    do: tooltip(utilization, reset_at, window_seconds("5h"))

  def quota_tooltip_5h(_provider, _utilization, _reset_at), do: nil

  @doc "Same as `quota_tooltip_5h/3`, for the 7d window."
  def quota_tooltip_7d(provider, utilization, reset_at) when provider in @fixed_window_providers,
    do: tooltip(utilization, reset_at, window_seconds("7d"))

  def quota_tooltip_7d(_provider, _utilization, _reset_at), do: nil

  defp elapsed_pct(nil, _window_seconds), do: nil

  defp elapsed_pct(%DateTime{} = reset_at, window_seconds) do
    window_start = DateTime.add(reset_at, -window_seconds, :second)
    elapsed_seconds = DateTime.diff(DateTime.utc_now(), window_start)

    (elapsed_seconds / window_seconds * 100)
    |> max(0)
    |> min(100)
    |> round()
  end

  defp tooltip(_utilization, nil, _window_seconds), do: nil

  defp tooltip(utilization, %DateTime{} = reset_at, window_seconds) do
    elapsed_pct = elapsed_pct(reset_at, window_seconds)
    elapsed_seconds = window_seconds * elapsed_pct / 100

    used_part =
      if utilization, do: "#{quota_pct(utilization)}% quota used", else: "no usage data"

    "#{used_part} · #{elapsed_pct}% of window elapsed (#{duration_label(elapsed_seconds)} into #{duration_label(window_seconds)})"
  end

  # Formats a duration in seconds as "2.5h" (< 24h) or "2.1d" (>= 24h), with
  # a trailing ".0" trimmed for whole numbers.
  defp duration_label(seconds) do
    hours = seconds / 3600

    if hours < 24 do
      "#{trim_trailing_zero(hours)}h"
    else
      "#{trim_trailing_zero(hours / 24)}d"
    end
  end

  defp trim_trailing_zero(f) do
    f
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace_suffix(".0", "")
  end
end
