defmodule Arbiter.Usage.ClaudePricingTest do
  use ExUnit.Case, async: true

  alias Arbiter.Usage.ClaudePricing

  # Every expected figure below is computed by hand from the published list
  # prices, never from the module's own table — a test that re-derives the
  # number the same way the code does would pass against any table at all.

  describe "cost_usd/2" do
    test "prices the four buckets at the model's published rates" do
      # claude-opus-5: $5 / $25 per MTok, cache write 1.25x input, read 0.1x.
      #   1_000_000 in  -> 5.0
      #     100_000 out -> 2.5
      #     200_000 cw  -> 1.25
      #   4_000_000 cr  -> 2.0
      buckets = %{
        tokens_in: 1_000_000,
        tokens_out: 100_000,
        cache_creation_tokens: 200_000,
        cache_read_tokens: 4_000_000
      }

      assert_in_delta ClaudePricing.cost_usd("claude-opus-5", buckets), 10.75, 0.0000001
    end

    test "a cheaper model prices the same buckets lower" do
      # claude-haiku-4-5: $1 / $5 per MTok.
      buckets = %{
        tokens_in: 1_000_000,
        tokens_out: 100_000,
        cache_creation_tokens: 0,
        cache_read_tokens: 0
      }

      assert_in_delta ClaudePricing.cost_usd("claude-haiku-4-5", buckets), 1.5, 0.0000001
    end

    test "strips the CLI's [1m] context-tier suffix" do
      buckets = %{
        tokens_in: 1_000_000,
        tokens_out: 0,
        cache_creation_tokens: 0,
        cache_read_tokens: 0
      }

      assert ClaudePricing.cost_usd("claude-opus-5[1m]", buckets) ==
               ClaudePricing.cost_usd("claude-opus-5", buckets)
    end

    test "an unknown or missing model is nil, never a fabricated zero" do
      buckets = %{
        tokens_in: 10,
        tokens_out: 10,
        cache_creation_tokens: 0,
        cache_read_tokens: 0
      }

      assert ClaudePricing.cost_usd("gpt-9-turbo", buckets) == nil
      assert ClaudePricing.cost_usd(nil, buckets) == nil
      assert ClaudePricing.cost_usd("<synthetic>", buckets) == nil
    end

    test "a priced model with no tokens at all is nil, not $0.00" do
      zero = %{tokens_in: 0, tokens_out: 0, cache_creation_tokens: 0, cache_read_tokens: 0}

      assert ClaudePricing.cost_usd("claude-opus-5", zero) == nil
    end

    test "missing buckets default to zero rather than raising" do
      assert_in_delta ClaudePricing.cost_usd("claude-opus-5", %{tokens_out: 1_000_000}),
                      25.0,
                      0.0000001
    end
  end

  describe "price_table/0" do
    test "every entry carries all four rates as positive numbers" do
      table = ClaudePricing.price_table()
      assert map_size(table) > 0

      for {model, prices} <- table do
        for key <- [:input, :output, :cache_write, :cache_read] do
          assert is_number(Map.fetch!(prices, key)), "#{model} is missing #{key}"
          assert Map.fetch!(prices, key) > 0, "#{model}'s #{key} must be positive"
        end
      end
    end

    test "longest prefix wins so a family member never inherits a sibling's price" do
      assert ClaudePricing.prices_for("claude-opus-5-some-future-snapshot").input ==
               ClaudePricing.prices_for("claude-opus-5").input

      refute ClaudePricing.prices_for("claude-sonnet-5").input ==
               ClaudePricing.prices_for("claude-opus-5").input
    end
  end

  describe "estimated_note/0" do
    test "names the estimate so a reader never mistakes it for the CLI's own figure" do
      assert ClaudePricing.estimated_note() =~ "estimated from tokens (no cost-state)"
    end
  end
end
