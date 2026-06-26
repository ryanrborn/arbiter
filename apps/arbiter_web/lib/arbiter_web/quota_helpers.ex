defmodule ArbiterWeb.QuotaHelpers do
  @moduledoc false

  # Clamp utilization float to a 0-100 integer percentage.
  # Accepts both floats and integers (SQLite can return integers for
  # whole-number floats under certain driver/migration paths).
  def quota_pct(nil), do: 0
  def quota_pct(u) when is_number(u), do: min(100, round(u * 100))

  # Resolve a progress-bar color from utilization + optional overage status.
  # A non-nil/non-"ok" overage_status clamps to red regardless of utilization
  # (e.g. Anthropic's "in_overage" can arrive before utilization reaches 0.9).
  def quota_color(u, overage_status \\ nil)
  def quota_color(_, overage) when overage not in [nil, "ok"], do: "#ef4444"
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
end
