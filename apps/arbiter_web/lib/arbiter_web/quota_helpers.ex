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

  # Resolve a progress-bar color from utilization + optional overage status.
  # "in_overage" forces red because Anthropic signals active overage before
  # utilization reaches 0.9. "rejected" is a billing policy flag (no overage
  # plan) — not an active usage alert — so it follows utilization coloring.
  def quota_color(u, overage_status \\ nil)
  def quota_color(_, "in_overage"), do: "#ef4444"
  def quota_color(nil, _), do: "#22c55e"
  def quota_color(u, _) when u >= 0.9, do: "#ef4444"
  def quota_color(u, _) when u >= 0.7, do: "#f59e0b"
  def quota_color(_, _), do: "#22c55e"

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
