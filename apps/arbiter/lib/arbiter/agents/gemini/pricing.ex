defmodule Arbiter.Agents.Gemini.Pricing do
  @moduledoc """
  Per-model price table + cost derivation for Gemini sessions.

  Unlike Claude — whose CLI hands us a `total_cost_usd` straight off the
  `result` event — the gemini CLI emits **no per-session dollar cost** (see
  `docs/agent-harness-design.md` section 11). Cost must be *derived* from the
  token counts in the `result.stats` payload × a per-model price table, which
  this module owns.

  ## Token buckets

  The gemini CLI's `stream-json` `result.stats` exposes, per model, the
  following (snake_case) counts — confirmed against the installed CLI's
  `StreamJsonFormatter.convertToStreamStats`:

    * `input_tokens`  — the prompt token count (Gemini's `promptTokenCount`),
      which **includes** the cached portion.
    * `cached`        — the cache-read token count (`cachedContentTokenCount`),
      a subset of `input_tokens`, billed at the discounted cache rate.
    * `input`         — `max(0, input_tokens - cached)`, the *non-cached* prompt
      tokens billed at the full input rate.
    * `output_tokens` — the response token count (`candidatesTokenCount`).
    * `total_tokens`  — all tokens (`totalTokenCount`); equals
      `prompt + candidates + thoughts + tool`.

  Gemini's **thinking** (`thoughtsTokenCount`) and **tool-prompt**
  (`toolUsePromptTokenCount`) tokens are folded into `total_tokens` but are
  *not* broken out by the CLI's stream-json. Thinking tokens bill at the output
  rate for the 2.5 family, so we approximate billable output as
  `max(output_tokens, total_tokens - input_tokens)` — i.e. we treat the residual
  (`thoughts + tool`) as output-rate tokens. This slightly over-prices the
  (usually negligible) tool-prompt tokens but recovers the otherwise-dropped
  thinking cost, which can be large for `gemini-2.5-pro`.

  ## Caveats (documented, intentional approximations)

    * **Long-context premium not modelled.** Gemini charges a higher rate once a
      prompt exceeds 200k tokens. We always apply the base (`<= 200k`) tier; a
      session that blows past 200k will be *under*-costed. Worker runs rarely
      approach that ceiling.
    * **Estimate, not a billing source of truth.** The CLI gives us no dollar
      figure, so this is a derived approximation for the ledger/dashboards.
    * Prices are the published Google paid-tier rates as of mid-2026 and can be
      overridden per-workspace in the future; keep them in one place here.
  """

  # Published Gemini API paid-tier prices, USD per **1M** tokens, base
  # (`<= 200k` prompt) context tier. `cached` is the cache-read (discounted)
  # input rate. Keyed by the model-id prefix the CLI reports.
  #
  # Longest-prefix-wins matching (see `prices_for/1`) so `gemini-2.5-flash-lite`
  # resolves before `gemini-2.5-flash`.
  @price_table %{
    "gemini-2.5-pro" => %{input: 1.25, output: 10.0, cached: 0.31},
    "gemini-2.5-flash-lite" => %{input: 0.10, output: 0.40, cached: 0.025},
    "gemini-2.5-flash" => %{input: 0.30, output: 2.50, cached: 0.075}
  }

  @per_million 1_000_000

  @doc "Built-in price table (USD per 1M tokens), for introspection/tests."
  @spec price_table() :: map()
  def price_table, do: @price_table

  @doc """
  Derive the total session cost in USD from a `result.stats` map.

  Prices each per-model entry under `stats["models"]` independently (a session
  may span several models) and sums them. Returns `nil` when no model in the
  payload is in the price table (graceful degradation — the row still records
  tokens), so an unknown/renamed model never fabricates a bogus dollar figure.
  """
  @spec cost_usd(map()) :: float() | nil
  def cost_usd(%{"models" => models}) when is_map(models) and map_size(models) > 0 do
    {total, priced?} =
      Enum.reduce(models, {0.0, false}, fn {model, entry}, {sum, priced?} ->
        case model_cost(model, entry) do
          nil -> {sum, priced?}
          c -> {sum + c, true}
        end
      end)

    if priced?, do: Float.round(total, 6), else: nil
  end

  def cost_usd(_stats), do: nil

  @doc """
  Cost for a single `{model, entry}` pair, where `entry` is one model's bucket
  map from `stats["models"]`. Returns `nil` when the model is unpriced.
  """
  @spec model_cost(String.t(), map()) :: float() | nil
  def model_cost(model, entry) when is_binary(model) and is_map(entry) do
    case prices_for(model) do
      nil ->
        nil

      %{input: in_rate, output: out_rate, cached: cached_rate} ->
        cached = num(entry["cached"]) || 0
        output = num(entry["output_tokens"]) || 0
        total = num(entry["total_tokens"]) || 0
        input_tokens = num(entry["input_tokens"]) || 0

        # Prefer the CLI's pre-computed non-cached `input`; otherwise back it out
        # of the prompt total minus the cached portion.
        non_cached_input = num(entry["input"]) || max(input_tokens - cached, 0)

        # Treat the residual (thoughts + tool) as output-rate tokens; falls back
        # to plain output_tokens when total is absent/smaller (see moduledoc).
        billable_output = max(output, total - input_tokens)

        (non_cached_input * in_rate + cached * cached_rate + billable_output * out_rate) /
          @per_million
    end
  end

  def model_cost(_model, _entry), do: nil

  # Resolve a (possibly version-suffixed) model id to its price row by
  # longest-matching prefix. Returns nil for unknown models.
  defp prices_for(model) when is_binary(model) do
    @price_table
    |> Enum.filter(fn {prefix, _} -> String.starts_with?(model, prefix) end)
    |> Enum.max_by(fn {prefix, _} -> String.length(prefix) end, fn -> nil end)
    |> case do
      {_prefix, prices} -> prices
      nil -> nil
    end
  end

  defp num(n) when is_integer(n), do: n
  defp num(n) when is_float(n), do: n
  defp num(_), do: nil
end
