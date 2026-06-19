defmodule Arbiter.Agents.Gemini.PricingTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Gemini.Pricing

  describe "model_cost/2" do
    test "prices non-cached input + output at the model's per-1M rates" do
      # gemini-2.5-pro: input $1.25/1M, output $10/1M.
      # 1M non-cached input, 1M output, no cache.
      entry = %{
        "input_tokens" => 1_000_000,
        "input" => 1_000_000,
        "cached" => 0,
        "output_tokens" => 1_000_000,
        "total_tokens" => 2_000_000
      }

      assert Pricing.model_cost("gemini-2.5-pro", entry) == 11.25
    end

    test "applies the discounted cached rate to cache-read tokens" do
      # 800k non-cached input + 200k cached (of a 1M prompt), 0 output.
      # pro: 800k * 1.25/1M + 200k * 0.31/1M = 1.0 + 0.062 = 1.062
      entry = %{
        "input_tokens" => 1_000_000,
        "input" => 800_000,
        "cached" => 200_000,
        "output_tokens" => 0,
        "total_tokens" => 1_000_000
      }

      assert_in_delta Pricing.model_cost("gemini-2.5-pro", entry), 1.062, 1.0e-9
    end

    test "treats the residual (thoughts/tool) above output_tokens as output-rate" do
      # total - input = 1.5M billable output; output_tokens only 1M.
      # flash-lite: input 0.10/1M, output 0.40/1M.
      # input 1M * 0.10/1M = 0.10 ; output 1.5M * 0.40/1M = 0.60 ; total 0.70
      entry = %{
        "input_tokens" => 1_000_000,
        "input" => 1_000_000,
        "cached" => 0,
        "output_tokens" => 1_000_000,
        "total_tokens" => 2_500_000
      }

      assert_in_delta Pricing.model_cost("gemini-2.5-flash-lite", entry), 0.70, 1.0e-9
    end

    test "matches version-suffixed model ids by longest prefix" do
      entry = %{
        "input" => 1_000_000,
        "cached" => 0,
        "output_tokens" => 0,
        "total_tokens" => 1_000_000,
        "input_tokens" => 1_000_000
      }

      # flash-lite must win over flash for the -lite id.
      assert_in_delta Pricing.model_cost("gemini-2.5-flash-lite-preview-09", entry), 0.10, 1.0e-9
      assert_in_delta Pricing.model_cost("gemini-2.5-flash-002", entry), 0.30, 1.0e-9
    end

    test "returns nil for an unknown model" do
      entry = %{
        "input" => 1,
        "cached" => 0,
        "output_tokens" => 1,
        "total_tokens" => 2,
        "input_tokens" => 1
      }

      assert Pricing.model_cost("some-future-model", entry) == nil
    end
  end

  describe "cost_usd/1" do
    test "sums per-model costs across a multi-model session" do
      stats = %{
        "models" => %{
          "gemini-2.5-pro" => %{
            "input_tokens" => 1_000_000,
            "input" => 1_000_000,
            "cached" => 0,
            "output_tokens" => 1_000_000,
            "total_tokens" => 2_000_000
          },
          "gemini-2.5-flash-lite" => %{
            "input_tokens" => 1_000_000,
            "input" => 1_000_000,
            "cached" => 0,
            "output_tokens" => 0,
            "total_tokens" => 1_000_000
          }
        }
      }

      # pro 11.25 + flash-lite 0.10 = 11.35
      assert_in_delta Pricing.cost_usd(stats), 11.35, 1.0e-6
    end

    test "returns nil when no model in the payload is priced" do
      stats = %{
        "models" => %{
          "mystery-model" => %{
            "input" => 100,
            "output_tokens" => 100,
            "total_tokens" => 200,
            "input_tokens" => 100,
            "cached" => 0
          }
        }
      }

      assert Pricing.cost_usd(stats) == nil
    end

    test "prices known models and ignores unknown ones (best-effort)" do
      stats = %{
        "models" => %{
          "gemini-2.5-flash-lite" => %{
            "input_tokens" => 1_000_000,
            "input" => 1_000_000,
            "cached" => 0,
            "output_tokens" => 0,
            "total_tokens" => 1_000_000
          },
          "mystery-model" => %{
            "input" => 1_000_000,
            "output_tokens" => 1_000_000,
            "total_tokens" => 2_000_000,
            "input_tokens" => 1_000_000,
            "cached" => 0
          }
        }
      }

      assert_in_delta Pricing.cost_usd(stats), 0.10, 1.0e-6
    end

    test "returns nil when stats has no models map" do
      assert Pricing.cost_usd(%{"input_tokens" => 100}) == nil
      assert Pricing.cost_usd(%{"models" => %{}}) == nil
    end
  end
end
