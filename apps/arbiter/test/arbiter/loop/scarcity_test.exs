defmodule Arbiter.Loop.ScarcityTest do
  use ExUnit.Case, async: true

  alias Arbiter.Loop.Scarcity

  describe "weighted_tokens/1" do
    test "weights each token class by the documented vector" do
      counts = %{
        tokens_in: 1000,
        tokens_out: 100,
        cache_creation_tokens: 400,
        cache_read_tokens: 10_000
      }

      w = Scarcity.weights()

      expected =
        1000 * w.input + 100 * w.output + 400 * w.cache_write + 10_000 * w.cache_read

      assert Scarcity.weighted_tokens(counts) == expected
    end

    test "output tokens draw more than input tokens; cache reads draw least" do
      w = Scarcity.weights()
      assert w.output > w.input
      assert w.cache_read < w.input
      assert w.cache_write >= w.input
    end

    test "nil and missing counts are zero, and string keys are accepted" do
      assert Scarcity.weighted_tokens(%{}) == 0.0
      assert Scarcity.weighted_tokens(%{tokens_in: nil, tokens_out: nil}) == 0.0

      assert Scarcity.weighted_tokens(%{"tokens_in" => 10}) ==
               Scarcity.weighted_tokens(%{tokens_in: 10})
    end
  end

  describe "calibrate/2" do
    test "derives 5h capacity from observed weighted tokens and observed utilization" do
      cal =
        Scarcity.calibrate(1_200_000.0, %{
          utilization_5h: 0.4,
          captured_at: ~U[2026-09-04 10:00:00Z]
        })

      assert cal.status == :calibrated
      assert cal.window == :five_hour
      assert_in_delta cal.capacity_weighted_tokens, 3_000_000.0, 0.001
      assert cal.utilization == 0.4
      assert cal.observed_weighted_tokens == 1_200_000.0
      assert cal.captured_at == ~U[2026-09-04 10:00:00Z]
      assert cal.reason == nil
    end

    test "no snapshot means no calibration, with a machine-readable reason" do
      cal = Scarcity.calibrate(1_200_000.0, nil)
      assert cal.status == :uncalibrated
      assert cal.capacity_weighted_tokens == nil
      assert cal.reason == :no_snapshot
    end

    test "a snapshot without a 5h utilization figure cannot calibrate" do
      cal = Scarcity.calibrate(1_200_000.0, %{utilization_5h: nil})
      assert cal.status == :uncalibrated
      assert cal.reason == :no_utilization
    end

    test "zero utilization cannot calibrate (division by zero, not infinite capacity)" do
      cal = Scarcity.calibrate(1_200_000.0, %{utilization_5h: 0.0})
      assert cal.status == :uncalibrated
      assert cal.reason == :no_utilization
    end

    test "an idle window (no observed tokens) cannot calibrate" do
      cal = Scarcity.calibrate(0.0, %{utilization_5h: 0.4})
      assert cal.status == :uncalibrated
      assert cal.reason == :no_observed_tokens
    end

    # The dangerous case: a reading from a window that has already rolled would
    # otherwise calibrate plausibly — and wrongly — off a utilization figure that
    # describes a different interval than the observed draw.
    test "a stale snapshot is refused, and says so rather than producing a capacity" do
      cal =
        Scarcity.calibrate(1_200_000.0, nil,
          stale: %{utilization_5h: 0.4, captured_at: ~U[2026-09-01 10:00:00Z]}
        )

      assert cal.status == :uncalibrated
      assert cal.reason == :stale_snapshot
      assert cal.capacity_weighted_tokens == nil
      assert Scarcity.window_share(300_000.0, cal) == nil

      # The rejected reading is still cited, so the report can say how blind the
      # window is rather than only that it is blind.
      assert cal.captured_at == ~U[2026-09-01 10:00:00Z]
      assert cal.utilization == nil
    end
  end

  describe "window_share/2" do
    test "a run's share is its weighted draw over one 5h window's capacity" do
      cal = Scarcity.calibrate(1_200_000.0, %{utilization_5h: 0.4})
      assert_in_delta Scarcity.window_share(300_000.0, cal), 0.1, 0.0001
    end

    test "a global scale error in the weights cancels out of the share" do
      # Because capacity is calibrated from the SAME weighting, doubling every
      # weight leaves the share unchanged. Only relative weights matter — the
      # argument that lets the pricing-derived weight vector stand in for
      # Anthropic's unpublished one.
      cal = Scarcity.calibrate(1_200_000.0, %{utilization_5h: 0.4})
      doubled = Scarcity.calibrate(2_400_000.0, %{utilization_5h: 0.4})

      assert_in_delta Scarcity.window_share(300_000.0, cal),
                      Scarcity.window_share(600_000.0, doubled),
                      0.0001
    end

    test "an uncalibrated window yields nil, never a fabricated zero" do
      cal = Scarcity.calibrate(0.0, nil)
      assert Scarcity.window_share(300_000.0, cal) == nil
      assert Scarcity.window_share(300_000.0, nil) == nil
    end
  end

  describe "format_share/1" do
    test "renders a share as a percentage of one 5h window" do
      assert Scarcity.format_share(0.1234) == "12.3% of one 5h window"
      assert Scarcity.format_share(0.0) == "0.0% of one 5h window"
    end

    test "renders an unavailable share honestly rather than as zero" do
      assert Scarcity.format_share(nil) =~ "uncalibrated"
    end
  end

  describe "billing_mode/2" do
    test "explicit workspace config wins over inference" do
      config = %{"loop" => %{"billing_mode" => "metered"}}
      assert Scarcity.billing_mode(config, %{utilization_5h: 0.4}) == {:metered, :configured}

      config = %{"loop" => %{"billing_mode" => "subscription"}}
      assert Scarcity.billing_mode(config, nil) == {:subscription, :configured}
    end

    test "a unified-window snapshot infers subscription billing" do
      assert Scarcity.billing_mode(%{}, %{utilization_5h: 0.4}) == {:subscription, :inferred}
      assert Scarcity.billing_mode(nil, %{utilization_5h: 0.0}) == {:subscription, :inferred}
    end

    test "no window evidence at all falls back to metered — dollars still bind there" do
      assert Scarcity.billing_mode(%{}, nil) == {:metered, :default}
      assert Scarcity.billing_mode(nil, %{utilization_5h: nil}) == {:metered, :default}
    end

    test "an unrecognised configured mode is ignored rather than trusted" do
      config = %{"loop" => %{"billing_mode" => "barter"}}
      assert Scarcity.billing_mode(config, %{utilization_5h: 0.4}) == {:subscription, :inferred}
    end
  end

  describe "primary_metric/1" do
    test "quota denominates the objective under subscription billing" do
      assert Scarcity.primary_metric({:subscription, :inferred}) == :window_share_5h
    end

    test "dollars stay the objective under metered billing" do
      assert Scarcity.primary_metric({:metered, :default}) == :cost_usd
    end
  end
end
