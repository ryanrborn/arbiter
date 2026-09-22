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

    # bd-8vnuy3: Claude Code writes its prompt cache with the 1-hour TTL
    # (`usage.cache_creation.ephemeral_1h_input_tokens` on every worker and
    # coordinator turn), which bills at 2x input, not the 5-minute 1.25x. Pricing
    # every write at 1.25x is what put the file estimate 12-15% below the CLI's
    # own `costUSD` for the same sessions.
    test "a 1-hour-TTL cache write prices at 2x input; the rest of the writes stay 1.25x" do
      # claude-sonnet-5: $2 input.
      #   300_000 cw of which 200_000 are 1h:
      #     200_000 * 4.0 / 1M = 0.8   (1h: 2x input)
      #     100_000 * 2.5 / 1M = 0.25  (5m: 1.25x input)
      buckets = %{cache_creation_tokens: 300_000, cache_creation_1h_tokens: 200_000}

      assert_in_delta ClaudePricing.cost_usd("claude-sonnet-5", buckets), 1.05, 0.0000001
    end

    test "a 1h count larger than the write total is clamped to it, never billed twice" do
      buckets = %{cache_creation_tokens: 100_000, cache_creation_1h_tokens: 900_000}

      # All 100_000 at the 1h rate: 100_000 * 4.0 / 1M.
      assert_in_delta ClaudePricing.cost_usd("claude-sonnet-5", buckets), 0.4, 0.0000001
    end

    # Fitted against the CLI's own `modelUsage["claude-opus-5-5"].costUSD` on
    # the live ledger (14 sessions, exact to the cent): $4 in, $20 out, $8 cache
    # write (the 1h tier, 2x), $0.20 cache read. Longest-prefix matching used to
    # hand it `claude-opus-5`'s $5/$25/$0.50, overstating a live figure by
    # 1.5-1.9x — enough to page `budget_exceeded` on a pass that is not over.
    test "claude-opus-5-5 has its own rates rather than inheriting claude-opus-5's" do
      # Real result event, session 425e331f: CLI costUSD 1.0275132.
      buckets = %{
        tokens_in: 36,
        tokens_out: 8909,
        cache_creation_tokens: 79_417,
        cache_creation_1h_tokens: 79_417,
        cache_read_tokens: 1_069_266
      }

      assert_in_delta ClaudePricing.cost_usd("claude-opus-5-5", buckets), 1.0275132, 0.0000001
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
