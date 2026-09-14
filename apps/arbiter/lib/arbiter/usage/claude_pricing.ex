defmodule Arbiter.Usage.ClaudePricing do
  @moduledoc """
  Per-model price table + token→dollar derivation for Claude sessions, used
  **only** as a fallback when the CLI gave us no dollar figure of its own.

  ## Why this exists at all

  The rule everywhere else in the ledger is *reuse the CLI's number, never
  recompute a price*: a `result` event's `total_cost_usd`, or a session
  JSONL's `cost-state` record, has already applied the cache-write / cache-read
  split and whatever tier the account is on. `Arbiter.Usage.ClaudeSessionFile`
  is built on that rule and still is.

  Then Claude Code **2.1.270 stopped writing `cost-state` records**. The live
  coordinator session (3,018 lines) carries not one; 2.1.246–2.1.269 wrote 18
  in a comparable file. Every row reconciled off a 2.1.270 transcript landed
  with `cost_usd: nil` — token counts in the six figures next to no money at
  all, which is indistinguishable from a broken parser when someone audits
  spend. A derived estimate is strictly better than a hole, as long as it is
  *labelled* as derived — which is what `estimated_note/0` is for, and why
  `ClaudeSessionFile` reports `cost_source: :cost_state | :estimated | nil`.

  Precedence never changes: `cost-state` when it exists, this table only when
  it does not.

  ## The price table

  Published Anthropic list prices, USD per **1M** tokens. `cache_write` is the
  5-minute-TTL write (1.25× input) and `cache_read` is 0.1× input, except where
  a model documents its own rate. Matching is longest-prefix-wins, so a future
  dated snapshot (`claude-opus-5-20260401`) prices as its family, and
  `claude-sonnet-5` can never inherit `claude-opus-5`'s rate.

  A model that is not in the table prices to `nil` — an unknown model must
  produce an honest absence, never a number derived from a guessed rate.

  ## Documented approximations

    * **One model per file.** `ClaudeSessionFile` records the first non-
      synthetic model it sees and the buckets are not split per model, so a
      session that switched models mid-flight is priced entirely at the first
      one's rate.
    * **Context-tier premium not modelled.** The CLI labels 1M-context usage
      `claude-opus-5[1m]`; the suffix is stripped and the base rate applied.
    * **Long-TTL cache writes.** A 1-hour-TTL write costs 2× input, not 1.25×;
      the buckets don't distinguish them, so a session leaning on the 1h TTL is
      under-priced.
    * **Fast mode not modelled.** Claude Code exposes a fast-mode toggle; Opus 5
      in fast mode bills at $10/$50 per MTok, double the table's rate. The
      transcript doesn't record the speed, so a fast-mode session is priced at
      the standard rate and reads ~2× low.
    * **Mythos 5.1's cache-read rate is assumed, not published.** It is priced
      as its Fable 5.1 sibling, including the $0.25/MTok cache read; whether
      Mythos shares that rate is documented upstream as open.
    * **List prices.** No account-level discount, batch discount or promotional
      credit is modelled.

  None of this applies when the CLI wrote a `cost-state` record — then this
  module is not consulted at all.
  """

  @typedoc "The four billed token buckets, as `ClaudeSessionFile` reports them."
  @type buckets :: %{
          optional(:tokens_in) => non_neg_integer(),
          optional(:tokens_out) => non_neg_integer(),
          optional(:cache_creation_tokens) => non_neg_integer(),
          optional(:cache_read_tokens) => non_neg_integer()
        }

  @per_million 1_000_000

  # input/output are the published rates; cache_write/cache_read are derived
  # from input unless the model publishes its own (see `expand/1`).
  @opus %{input: 5.0, output: 25.0}
  # Fable 5.1 reads cache at 0.025× input, not the usual 0.1×. Mythos 5.1 is
  # the same tier at the same per-token price and is priced from this entry,
  # but whether it shares the cache-read rate is open upstream — see the
  # moduledoc's approximations.
  @fable_5_1 %{input: 10.0, output: 50.0, cache_read: 0.25}
  @fable_5 %{input: 10.0, output: 50.0}

  @price_table %{
    "claude-opus-5" => @opus,
    "claude-opus-4-8" => @opus,
    "claude-opus-4-7" => @opus,
    "claude-opus-4-6" => @opus,
    "claude-sonnet-5" => %{input: 2.0, output: 10.0},
    "claude-sonnet-4-6" => %{input: 3.0, output: 15.0},
    "claude-haiku-4-5" => %{input: 1.0, output: 5.0},
    "claude-fable-5-1" => @fable_5_1,
    "claude-fable-5" => @fable_5,
    "claude-mythos-5-1" => @fable_5_1,
    "claude-mythos-5" => @fable_5
  }

  @doc """
  The full price table, USD per 1M tokens, with every rate resolved (the
  derived `cache_write` / `cache_read` included). For introspection and tests.
  """
  @spec price_table() :: %{optional(String.t()) => map()}
  def price_table do
    Map.new(@price_table, fn {model, prices} -> {model, expand(prices)} end)
  end

  @doc """
  The resolved rates for `model`, or `nil` when no table entry matches.

  Strips the CLI's `[1m]`-style context-tier suffix and matches the longest
  table key that prefixes the model id.
  """
  @spec prices_for(String.t() | nil) :: map() | nil
  def prices_for(model) when is_binary(model) do
    normalized = normalize(model)

    @price_table
    |> Enum.filter(fn {key, _} -> String.starts_with?(normalized, key) end)
    |> Enum.sort_by(fn {key, _} -> -String.length(key) end)
    |> case do
      [{_key, prices} | _] -> expand(prices)
      [] -> nil
    end
  end

  def prices_for(_model), do: nil

  @doc """
  Estimate the dollar cost of `buckets` at `model`'s list prices.

  Returns `nil` when the model is unknown or unnamed, and when every bucket is
  zero — a session that spent nothing has no cost to estimate, and a `0.0`
  there would read as a priced free session rather than as no data.
  """
  @spec cost_usd(String.t() | nil, buckets()) :: float() | nil
  def cost_usd(model, buckets) when is_map(buckets) do
    with prices when is_map(prices) <- prices_for(model),
         counts = counts(buckets),
         true <- Enum.any?(counts, fn {_k, n} -> n > 0 end) do
      (counts.tokens_in * prices.input +
         counts.tokens_out * prices.output +
         counts.cache_creation_tokens * prices.cache_write +
         counts.cache_read_tokens * prices.cache_read) / @per_million
    else
      _ -> nil
    end
  end

  @doc """
  The canonical `cost_note` for a ledger row whose cost came from this table
  rather than from the CLI's own accounting.

  Contains the phrase `estimated from tokens (no cost-state)` verbatim so the
  provenance of a dollar figure is greppable in the DB.
  """
  @spec estimated_note() :: String.t()
  def estimated_note do
    "estimated from tokens (no cost-state): this session JSONL carried no " <>
      "cost-state record (Claude Code 2.1.270+ writes none), so the figure is " <>
      "the deduped token buckets priced at published list rates, not the CLI's " <>
      "own number"
  end

  defp expand(%{input: input, output: output} = prices) do
    %{
      input: input,
      output: output,
      cache_write: Map.get(prices, :cache_write, input * 1.25),
      cache_read: Map.get(prices, :cache_read, input * 0.1)
    }
  end

  # `claude-opus-5[1m]` → `claude-opus-5`. The bracketed suffix is the CLI's
  # context-tier label, not part of the model id.
  defp normalize(model) do
    model
    |> String.split("[", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp counts(buckets) do
    %{
      tokens_in: non_neg(Map.get(buckets, :tokens_in)),
      tokens_out: non_neg(Map.get(buckets, :tokens_out)),
      cache_creation_tokens: non_neg(Map.get(buckets, :cache_creation_tokens)),
      cache_read_tokens: non_neg(Map.get(buckets, :cache_read_tokens))
    }
  end

  defp non_neg(n) when is_integer(n) and n > 0, do: n
  defp non_neg(_), do: 0
end
