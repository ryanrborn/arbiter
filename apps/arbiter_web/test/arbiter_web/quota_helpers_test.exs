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
