defmodule Arbiter.Quota.PaceTest do
  @moduledoc """
  The per-window pace verdict (bd-clzkvp) — the one definition of "ahead of
  pace" shared by the paced dispatch gate and the quota bars. Pure, so every
  case states its inputs outright.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Quota.Pace

  @five_hours 18_000
  @seven_days 604_800

  # The gate's defaults with the account in paced mode: 5h floor 0.35, 7d
  # floor 0.20, and the flat ceilings a paced side falls back to when the
  # window's elapsed fraction is unknown.
  @paced_5h %{sides: [{:paced, 0.35, nil}], default: 0.85}
  @paced_7d %{sides: [{:paced, 0.20, nil}], default: 0.90}
  @flat_5h %{sides: [], default: 0.85}

  defp at(u, elapsed, window, thresholds),
    do: Pace.evaluate(u, elapsed * window, window, thresholds)

  defp verdict(u, elapsed, window, thresholds), do: at(u, elapsed, window, thresholds).verdict

  describe "5h window, paced (floor 0.35, margin #{Pace.approaching_margin()})" do
    test "holding starts exactly at the ceiling" do
      # 30% elapsed: the 0.35 floor is the ceiling.
      assert verdict(0.35, 0.3, @five_hours, @paced_5h) == :holding
      assert verdict(0.3499, 0.3, @five_hours, @paced_5h) == :approaching
    end

    test "approaching starts exactly one margin below the ceiling" do
      assert verdict(0.25, 0.3, @five_hours, @paced_5h) == :approaching
      assert verdict(0.2499, 0.3, @five_hours, @paced_5h) == :ok
    end

    test "past the floor the ceiling is elapsed" do
      assert %{verdict: :holding, ceiling: 0.6, mode: :paced, elapsed: 0.6} =
               at(0.6, 0.6, @five_hours, @paced_5h)

      assert verdict(0.59, 0.6, @five_hours, @paced_5h) == :approaching
      assert verdict(0.49, 0.6, @five_hours, @paced_5h) == :ok
    end

    test "sampling: under 5% of the window elapsed or under 5% used, when otherwise ok" do
      # 5% of 5h is 15 minutes.
      assert verdict(0.10, 0.049, @five_hours, @paced_5h) == :sampling
      assert verdict(0.10, 0.05, @five_hours, @paced_5h) == :ok
      assert verdict(0.049, 0.5, @five_hours, @paced_5h) == :sampling
      assert verdict(0.05, 0.5, @five_hours, @paced_5h) == :ok
    end

    test "holding and approaching outrank sampling — the gate holds however early" do
      assert verdict(0.40, 0.01, @five_hours, @paced_5h) == :holding
      assert verdict(0.30, 0.01, @five_hours, @paced_5h) == :approaching
    end

    test "in the last minute of the window 0.99 is approaching, not holding" do
      assert verdict(0.99, 1 - 30 / @five_hours, @five_hours, @paced_5h) == :approaching
    end
  end

  describe "7d window, paced (floor 0.20)" do
    test "holding starts exactly at the ceiling" do
      assert verdict(0.20, 0.1, @seven_days, @paced_7d) == :holding
      assert verdict(0.1999, 0.1, @seven_days, @paced_7d) == :approaching
      assert verdict(0.0999, 0.1, @seven_days, @paced_7d) == :ok
    end

    test "35% used at 29% elapsed is 1.2x pace — over the paced ceiling" do
      assert %{verdict: :holding, ceiling: c} = at(0.35, 0.29, @seven_days, @paced_7d)
      assert_in_delta c, 0.29, 1.0e-9
    end

    test "the same reading under a looser weekly floor is only approaching" do
      thresholds = %{@paced_7d | sides: [{:paced, 0.40, nil}]}
      assert verdict(0.35, 0.29, @seven_days, thresholds) == :approaching
    end

    test "sampling floor is 5% of the window — about 8.4 hours for 7d" do
      assert verdict(0.06, 8 * 3600 / @seven_days, @seven_days, @paced_7d) == :sampling
      assert verdict(0.06, 9 * 3600 / @seven_days, @seven_days, @paced_7d) == :ok
    end
  end

  describe "flat and fallback thresholds" do
    test "flat: a fixed ceiling, independent of elapsed" do
      assert %{verdict: :holding, ceiling: 0.85, mode: :flat} =
               at(0.85, 0.99, @five_hours, @flat_5h)

      assert verdict(0.75, 0.01, @five_hours, @flat_5h) == :approaching
      assert verdict(0.74, 0.5, @five_hours, @flat_5h) == :ok
    end

    test "a paced side with no known elapsed falls back to its own flat ceiling" do
      thresholds = %{sides: [{:paced, 0.35, 0.6}], default: 0.85}

      assert %{verdict: :holding, ceiling: 0.6, mode: :flat, elapsed: nil} =
               Pace.evaluate(0.6, nil, nil, thresholds)
    end

    test "... or to the default when it has none" do
      assert %{verdict: :approaching, ceiling: 0.85, mode: :flat} =
               Pace.evaluate(0.8, 100, nil, @paced_5h)
    end

    test "the strictest side at the moment of the check binds" do
      thresholds = %{sides: [{:paced, 0.35, nil}, {:flat, 0.6}], default: 0.85}

      assert %{ceiling: 0.35, mode: :paced} = at(0.1, 0.1, @five_hours, thresholds)
      assert %{ceiling: 0.6, mode: :flat} = at(0.1, 0.9, @five_hours, thresholds)
    end

    test "elapsed is clamped to the window" do
      assert %{elapsed: +0.0} = Pace.evaluate(0.1, -60, @five_hours, @paced_5h)
      assert %{elapsed: 1.0} = Pace.evaluate(0.1, @five_hours + 60, @five_hours, @paced_5h)
    end

    test "no utilization reading is ok, never holding" do
      assert %{verdict: :ok} = at(nil, 0.5, @five_hours, @paced_5h)
    end
  end

  describe "elapsed_seconds/3" do
    test "how far into the window `now` is" do
      now = ~U[2026-09-23 12:00:00Z]
      assert Pace.elapsed_seconds(DateTime.add(now, 3600, :second), @five_hours, now) == 14_400.0
    end

    test "nil without a reset or a window length" do
      now = ~U[2026-09-23 12:00:00Z]
      assert Pace.elapsed_seconds(nil, @five_hours, now) == nil
      assert Pace.elapsed_seconds(now, nil, now) == nil
    end
  end
end
