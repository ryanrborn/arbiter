defmodule ArbiterWeb.QuotaHelpers do
  @moduledoc false

  # Fixed window durations for Anthropic's rate-limit windows (bd-d8wo5m).
  # `reset_5h_at`/`reset_7d_at` are stored as absolute timestamps with no
  # window-duration field, so the duration is a constant here (mirrors
  # `Arbiter.Quota.Overage.@five_hours_seconds`).
  @five_hours_seconds 5 * 60 * 60
  @seven_days_seconds 7 * 24 * 60 * 60

  # Clamp utilization float to a 0-100 integer percentage.
  # Accepts both floats and integers (SQLite can return integers for
  # whole-number floats under certain driver/migration paths).
  def quota_pct(nil), do: 0
  def quota_pct(u) when is_number(u), do: min(100, round(u * 100))

  @color_red "#ef4444"
  @color_amber "#f59e0b"
  @color_green "#22c55e"
  @color_grey "#9ca3af"

  @doc """
  Quota-bar color thresholds (bd-l4epbc), overridable via
  `config :arbiter_web, :quota_bar_colors` without a redeploy.
  """
  def quota_deficit_thresholds do
    cfg = Application.get_env(:arbiter_web, :quota_bar_colors, [])

    %{
      red_minutes: Keyword.get(cfg, :deficit_red_minutes, 60),
      amber_minutes: Keyword.get(cfg, :deficit_amber_minutes, 20),
      sampling_floor_minutes: Keyword.get(cfg, :sampling_floor_elapsed_minutes, 15),
      sampling_floor_used: Keyword.get(cfg, :sampling_floor_used, 0.05),
      wall_guard_used: Keyword.get(cfg, :wall_guard_used, 0.95)
    }
  end

  @doc """
  Progress-bar color for the 5h bar (bd-l4epbc). Colors on projected
  *deficit minutes* — how long the window would run dry before reset at the
  current burn rate — not on absolute utilization: a bare `used/elapsed`
  ratio is alarming early in the window and meaningless late in it, but
  minutes-until-dry degrades correctly at both ends. See module thresholds
  in `quota_deficit_thresholds/0`.

  Falls back to the old absolute-utilization thresholds (>=0.9 red, >=0.7
  amber) when `provider` isn't `"claude"` or there's no `reset_at` to derive
  a window from — the fixed 5h/7d window shape is Anthropic-specific (see
  `quota_elapsed_pct_5h/2`).
  """
  def quota_color_5h(provider, utilization, reset_at, overage_status),
    do:
      pace_state(provider, utilization, reset_at, overage_status, @five_hours_seconds)
      |> color_hex()

  @doc "Same as `quota_color_5h/4`, for the 7d window."
  def quota_color_7d(provider, utilization, reset_at, overage_status),
    do:
      pace_state(provider, utilization, reset_at, overage_status, @seven_days_seconds)
      |> color_hex()

  @doc """
  Pace-ratio text for the 5h bar's tooltip, e.g. `"3.5x pace"` — how many
  times faster (or slower) than the burn rate that would land exactly at
  100% by reset. `nil` when there's no usage/reset data or the provider
  isn't `"claude"`. Reports `"sampling"` instead of a ratio when the
  sampling floor isn't met (too little elapsed / usage to project a burn
  rate).
  """
  def quota_pace_ratio_5h(provider, utilization, reset_at),
    do: pace_ratio_text(provider, utilization, reset_at, @five_hours_seconds)

  @doc "Same as `quota_pace_ratio_5h/3`, for the 7d window."
  def quota_pace_ratio_7d(provider, utilization, reset_at),
    do: pace_ratio_text(provider, utilization, reset_at, @seven_days_seconds)

  @doc """
  Warning label for the 5h bar when the current burn pace threatens to
  exhaust the window before reset (bd-l4epbc): `"stalls in Nm"` under
  `:throttle`, `"starts billing overage in Nm"` under `:continue` — same
  color, materially different stakes. `nil` when the bar isn't amber/red on
  pace (including while sampling), so callers should fall back to
  `quota_reset_label/1`.
  """
  def quota_pace_label_5h(provider, utilization, reset_at, overage_status, on_exhaustion),
    do:
      pace_label(
        provider,
        utilization,
        reset_at,
        overage_status,
        @five_hours_seconds,
        on_exhaustion
      )

  @doc "Same as `quota_pace_label_5h/5`, for the 7d window."
  def quota_pace_label_7d(provider, utilization, reset_at, overage_status, on_exhaustion),
    do:
      pace_label(
        provider,
        utilization,
        reset_at,
        overage_status,
        @seven_days_seconds,
        on_exhaustion
      )

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

  defp color_hex(:red), do: @color_red
  defp color_hex(:amber), do: @color_amber
  defp color_hex(:green), do: @color_green
  defp color_hex(:grey), do: @color_grey

  defp pace_state(_provider, _u, _reset_at, "in_overage", _window_seconds), do: :red

  defp pace_state("claude", u, %DateTime{} = reset_at, _overage_status, window_seconds)
       when is_number(u) do
    u |> pace(reset_at, window_seconds) |> pace_state_from_metrics(u)
  end

  defp pace_state(_provider, nil, _reset_at, _overage_status, _window_seconds), do: :green

  defp pace_state(_provider, u, _reset_at, _overage_status, _window_seconds) when is_number(u) do
    cond do
      u >= 0.9 -> :red
      u >= 0.7 -> :amber
      true -> :green
    end
  end

  defp pace_state_from_metrics(%{sampling?: true}, _u), do: :grey

  defp pace_state_from_metrics(%{deficit: deficit}, u) do
    thresholds = quota_deficit_thresholds()

    base =
      cond do
        deficit == nil -> :green
        deficit > thresholds.red_minutes -> :red
        deficit > thresholds.amber_minutes -> :amber
        true -> :green
      end

    if u >= thresholds.wall_guard_used and base == :green, do: :amber, else: base
  end

  defp pace_ratio_text("claude", u, %DateTime{} = reset_at, window_seconds) when is_number(u) do
    case pace(u, reset_at, window_seconds) do
      %{sampling?: true} -> "sampling — too little elapsed to project pace"
      %{ratio: nil} -> nil
      %{ratio: ratio} -> "#{format_ratio(ratio)}x pace"
    end
  end

  defp pace_ratio_text(_provider, _utilization, _reset_at, _window_seconds), do: nil

  defp pace_label(
         "claude",
         u,
         %DateTime{} = reset_at,
         overage_status,
         window_seconds,
         on_exhaustion
       )
       when is_number(u) do
    case pace_state("claude", u, reset_at, overage_status, window_seconds) do
      state when state in [:amber, :red] ->
        case pace(u, reset_at, window_seconds) do
          %{minutes_to_exhaust: t} when is_number(t) and t >= 0 ->
            verb =
              if on_exhaustion == :continue, do: "starts billing overage in", else: "stalls in"

            "#{verb} #{format_minutes(t)}"

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp pace_label(_provider, _u, _reset_at, _overage_status, _window_seconds, _on_exhaustion),
    do: nil

  # Core deficit-minutes pace math (bd-l4epbc):
  #
  #   elapsed_min = now - window_start
  #   burn        = used / elapsed_min
  #   t_exhaust   = (1 - used) / burn        # minutes until the window hits zero
  #   t_reset     = reset_at - now
  #   deficit     = t_reset - t_exhaust      # minutes spent dry before reset
  #
  # Below the sampling floor (too little elapsed time or usage to project a
  # burn rate), returns `sampling?: true` instead of guessing — a single
  # early burst implies a nonsense burn rate.
  defp pace(u, %DateTime{} = reset_at, window_seconds) when is_number(u) do
    thresholds = quota_deficit_thresholds()
    window_start = DateTime.add(reset_at, -window_seconds, :second)
    now = DateTime.utc_now()
    elapsed_min = DateTime.diff(now, window_start) / 60
    window_min = window_seconds / 60

    if elapsed_min < thresholds.sampling_floor_minutes or u < thresholds.sampling_floor_used do
      %{sampling?: true, deficit: nil, ratio: nil, minutes_to_exhaust: nil}
    else
      burn_per_min = u / elapsed_min
      ratio = u / (elapsed_min / window_min)
      minutes_to_exhaust = if burn_per_min > 0, do: (1 - u) / burn_per_min, else: nil
      t_reset_min = DateTime.diff(reset_at, now) / 60

      deficit =
        case minutes_to_exhaust do
          nil -> nil
          t -> t_reset_min - t
        end

      %{sampling?: false, deficit: deficit, ratio: ratio, minutes_to_exhaust: minutes_to_exhaust}
    end
  end

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

  @doc """
  Fraction of the 5h window elapsed so far, as a 0-100 integer — the
  time-elapsed marker position on the 5h usage bars. `nil` when there's no
  `reset_5h_at` to derive a window from (marker isn't rendered), or when
  `provider` isn't `"claude"` — the fixed 5h/7d window shape is Anthropic-
  specific (Codex's `reset_5h_at` slot is a session reset, Gemini CLI's has
  no time window at all; see bd-d8wo5m review round 1).
  """
  def quota_elapsed_pct_5h("claude", reset_at), do: elapsed_pct(reset_at, @five_hours_seconds)
  def quota_elapsed_pct_5h(_provider, _reset_at), do: nil

  @doc "Same as `quota_elapsed_pct_5h/2`, for the 7d window."
  def quota_elapsed_pct_7d("claude", reset_at), do: elapsed_pct(reset_at, @seven_days_seconds)
  def quota_elapsed_pct_7d(_provider, _reset_at), do: nil

  @doc """
  Hover-tooltip / aria-label text for a 5h usage bar, stating both the
  usage-fill and time-elapsed numbers in words, e.g.
  `"62% quota used · 50% of window elapsed (2.5h into 5h)"`. `nil` when
  there's no `reset_5h_at` to derive a window from, or when `provider` isn't
  `"claude"`.
  """
  def quota_tooltip_5h("claude", utilization, reset_at),
    do: tooltip(utilization, reset_at, @five_hours_seconds)

  def quota_tooltip_5h(_provider, _utilization, _reset_at), do: nil

  @doc "Same as `quota_tooltip_5h/3`, for the 7d window."
  def quota_tooltip_7d("claude", utilization, reset_at),
    do: tooltip(utilization, reset_at, @seven_days_seconds)

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
