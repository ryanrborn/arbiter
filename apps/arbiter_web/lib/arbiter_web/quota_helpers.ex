defmodule ArbiterWeb.QuotaHelpers do
  @moduledoc false

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
end
