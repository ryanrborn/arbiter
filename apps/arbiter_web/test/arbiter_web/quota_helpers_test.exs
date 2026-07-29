defmodule ArbiterWeb.QuotaHelpersTest do
  use ExUnit.Case, async: true

  import ArbiterWeb.QuotaHelpers

  describe "quota_provider_label/1" do
    test "maps known provider codes to display names" do
      assert quota_provider_label("claude") == "Claude"
      assert quota_provider_label("codex") == "Codex"
      assert quota_provider_label("gemini_cli") == "Gemini CLI"
      assert quota_provider_label("antigravity") == "Antigravity"
    end

    test "title-cases unknown provider codes as a fallback" do
      assert quota_provider_label("some_new_provider") == "Some New Provider"
    end
  end

  describe "quota_elapsed_pct_5h/2" do
    test "nil reset_at yields no marker" do
      assert quota_elapsed_pct_5h("claude", nil) == nil
    end

    test "midpoint of the 5h window is 50% elapsed" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)
      assert quota_elapsed_pct_5h("claude", reset_at) == 50
    end

    test "clamps to 0 when the window hasn't opened yet" do
      reset_at = DateTime.add(DateTime.utc_now(), 10 * 60 * 60, :second)
      assert quota_elapsed_pct_5h("claude", reset_at) == 0
    end

    test "clamps to 100 when the window is overdue to reset" do
      reset_at = DateTime.add(DateTime.utc_now(), -60, :second)
      assert quota_elapsed_pct_5h("claude", reset_at) == 100
    end

    test "non-Anthropic providers get no marker, even with a reset_at present" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)
      assert quota_elapsed_pct_5h("codex", reset_at) == nil
      assert quota_elapsed_pct_5h("gemini_cli", reset_at) == nil
      assert quota_elapsed_pct_5h("antigravity", reset_at) == nil
    end
  end

  describe "quota_elapsed_pct_7d/2" do
    test "nil reset_at yields no marker" do
      assert quota_elapsed_pct_7d("claude", nil) == nil
    end

    test "a third of the way through a 7d window" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)
      assert quota_elapsed_pct_7d("claude", reset_at) == 33
    end

    test "non-Anthropic providers get no marker" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)
      assert quota_elapsed_pct_7d("codex", reset_at) == nil
      assert quota_elapsed_pct_7d("gemini_cli", reset_at) == nil
      assert quota_elapsed_pct_7d("antigravity", reset_at) == nil
    end
  end

  describe "quota_tooltip_5h/3" do
    test "nil reset_at yields no tooltip" do
      assert quota_tooltip_5h("claude", 0.62, nil) == nil
    end

    test "states both usage and elapsed numbers in words" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)

      assert quota_tooltip_5h("claude", 0.62, reset_at) ==
               "62% quota used · 50% of window elapsed (2.5h into 5h)"
    end

    test "falls back to a neutral phrase when utilization is unknown" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)

      assert quota_tooltip_5h("claude", nil, reset_at) ==
               "no usage data · 50% of window elapsed (2.5h into 5h)"
    end

    test "non-Anthropic providers get no tooltip" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)
      assert quota_tooltip_5h("codex", 0.62, reset_at) == nil
      assert quota_tooltip_5h("gemini_cli", 0.62, reset_at) == nil
      assert quota_tooltip_5h("antigravity", 0.62, reset_at) == nil
    end
  end

  describe "quota_color_5h/4 — deficit-minutes pace coloring (bd-l4epbc)" do
    # 5h window = 300 minutes. `reset_at` is built so `elapsed_min` lands on
    # a specific value: reset_at = now + (300 - elapsed_min) minutes.
    defp reset_at_after(elapsed_min, window_min \\ 300) do
      DateTime.add(DateTime.utc_now(), round((window_min - elapsed_min) * 60), :second)
    end

    test "over-pace mid-window renders red (would dry out long before reset)" do
      # 35% used at 10% elapsed (30min into 300) — on this pace the window
      # dries out ~56min from now, ~214min before the 270min-away reset.
      reset_at = reset_at_after(30)
      assert quota_color_5h("claude", 0.35, reset_at, nil) == "#ef4444"
    end

    test "under-pace near reset renders green (the 21:45Z/0.89 false-alarm case)" do
      # 89% used at 98% elapsed (294min into 300) — coasts to reset with
      # minutes to spare, never runs dry.
      reset_at = reset_at_after(294)
      assert quota_color_5h("claude", 0.89, reset_at, nil) == "#22c55e"
    end

    test "early-window high pace renders grey, not red — the sampling floor" do
      # Only 2 minutes elapsed: far below the 15-minute sampling floor, so a
      # single burst can't yet be projected as a burn rate.
      reset_at = reset_at_after(2)
      assert quota_color_5h("claude", 0.5, reset_at, nil) == "#9ca3af"
    end

    test "low utilization renders grey regardless of elapsed time — the usage floor" do
      reset_at = reset_at_after(200)
      assert quota_color_5h("claude", 0.02, reset_at, nil) == "#9ca3af"
    end

    test "used = 0.99 on-pace renders amber, not green — the wall guard" do
      # 99% used at 99% elapsed: deficit computes to ~0 (on pace), but the
      # wall guard forbids green once utilization crosses 0.95.
      reset_at = reset_at_after(297)
      assert quota_color_5h("claude", 0.99, reset_at, nil) == "#f59e0b"
    end

    test "20 < deficit <= 60 minutes renders amber" do
      # 23% used at 20% elapsed (60min into 300) — dries out ~201min from
      # now, ~39min before the 240min-away reset: squarely in the amber band.
      reset_at = reset_at_after(60)
      assert quota_color_5h("claude", 0.23, reset_at, nil) == "#f59e0b"
    end

    test "in_overage forces solid red regardless of pace" do
      reset_at = reset_at_after(294)
      assert quota_color_5h("claude", 0.89, reset_at, "in_overage") == "#ef4444"
    end

    test "nil utilization renders green (no usage data, distinct from sampling)" do
      assert quota_color_5h("claude", nil, reset_at_after(30), nil) == "#22c55e"
    end

    test "non-Anthropic providers fall back to absolute-utilization thresholds" do
      reset_at = reset_at_after(30)
      assert quota_color_5h("codex", 0.35, reset_at, nil) == "#22c55e"
      assert quota_color_5h("codex", 0.95, reset_at, nil) == "#ef4444"
    end

    test "nil reset_at falls back to absolute-utilization thresholds" do
      assert quota_color_5h("claude", 0.95, nil, nil) == "#ef4444"
      assert quota_color_5h("claude", 0.35, nil, nil) == "#22c55e"
    end
  end

  describe "quota_color_7d/4 — deficit-minutes pace coloring applies identically" do
    test "over-pace mid-window renders red" do
      window_min = 7 * 24 * 60
      reset_at = reset_at_after(round(window_min * 0.1), window_min)
      assert quota_color_7d("claude", 0.35, reset_at, nil) == "#ef4444"
    end

    test "under-pace near reset renders green" do
      window_min = 7 * 24 * 60
      reset_at = reset_at_after(round(window_min * 0.98), window_min)
      assert quota_color_7d("claude", 0.89, reset_at, nil) == "#22c55e"
    end
  end

  describe "quota_pace_label_5h/5 — on_exhaustion-aware label text" do
    test "labels the throttle mode as \"stalls in Nm\"" do
      reset_at = reset_at_after(30)
      assert quota_pace_label_5h("claude", 0.35, reset_at, nil, :throttle) =~ ~r/^stalls in \d+m$/
    end

    test "labels the continue mode as \"starts billing overage in Nm\"" do
      reset_at = reset_at_after(30)

      assert quota_pace_label_5h("claude", 0.35, reset_at, nil, :continue) =~
               ~r/^starts billing overage in \d+m$/
    end

    test "no label when the bar is green (no exhaustion projected)" do
      reset_at = reset_at_after(294)
      assert quota_pace_label_5h("claude", 0.89, reset_at, nil, :throttle) == nil
    end

    test "no label while sampling" do
      reset_at = reset_at_after(2)
      assert quota_pace_label_5h("claude", 0.5, reset_at, nil, :throttle) == nil
    end
  end

  describe "quota_pace_ratio_5h/3 — pace ratio exposed for tooltip text" do
    test "reports how many times faster than on-pace the current burn is" do
      reset_at = reset_at_after(30)
      assert quota_pace_ratio_5h("claude", 0.35, reset_at) == "3.5x pace"
    end

    test "reports sampling instead of a bogus ratio below the floor" do
      reset_at = reset_at_after(2)
      assert quota_pace_ratio_5h("claude", 0.5, reset_at) =~ "sampling"
    end

    test "nil for non-Anthropic providers" do
      assert quota_pace_ratio_5h("codex", 0.5, reset_at_after(30)) == nil
    end
  end

  describe "quota_binding_class/2 — de-emphasize the non-binding window" do
    test "no emphasis class when this window is the binding one" do
      assert quota_binding_class("five_hour", "five_hour") == nil
    end

    test "de-emphasis class when this window isn't the binding one" do
      assert quota_binding_class("five_hour", "seven_day") == "opacity-50"
    end

    test "no emphasis class when representative_claim is unknown" do
      assert quota_binding_class(nil, "five_hour") == nil
    end
  end

  describe "quota_tooltip_7d/3" do
    test "renders window durations in days" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)

      assert quota_tooltip_7d("claude", 0.45, reset_at) ==
               "45% quota used · 33% of window elapsed (2.3d into 7d)"
    end

    test "non-Anthropic providers get no tooltip" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)
      assert quota_tooltip_7d("codex", 0.45, reset_at) == nil
      assert quota_tooltip_7d("gemini_cli", 0.45, reset_at) == nil
      assert quota_tooltip_7d("antigravity", 0.45, reset_at) == nil
    end
  end
end
