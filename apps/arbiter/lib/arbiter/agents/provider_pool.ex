defmodule Arbiter.Agents.ProviderPool do
  @moduledoc """
  Circuit-breaker state for multi-provider pools.

  When a workspace configures `agent.type` as a list (e.g. `["claude",
  "gemini"]`), dispatches pick the first *healthy* provider from the list.
  This module tracks per-provider availability so the dispatcher skips
  providers that are known to be exhausted (out of tokens or credits).

  ## Circuit-breaker model

  - A provider is marked unavailable by calling `mark_exhausted/1` — the
    stop-classification layer (bd-cqccsm) calls this when it detects a
    token/credit-exhaustion stop.
  - Availability resets automatically via a TTL: the cooldown window is
    30 minutes by default, overridable with
    `config :arbiter, :provider_pool_cooldown_ms`.
  - `record_success/1` may also reset availability eagerly (called after a
    successful dispatch completes).

  ## ETS table

  The ETS table (`:arbiter_provider_circuit_breakers`) is `:public` so reads
  bypass the GenServer and have O(1) cost at dispatch time. The GenServer
  owns the table and handles writes.

  When the GenServer is not running (e.g. in isolated unit tests), all
  providers are treated as healthy — `healthy?/1` returns `true`.
  """

  use GenServer

  @table :arbiter_provider_circuit_breakers
  @default_cooldown_ms 30 * 60 * 1_000

  # ---- Public API ----------------------------------------------------------

  @doc "Starts the ProviderPool GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the configured cooldown window in milliseconds.

  Reads `Application.get_env(:arbiter, :provider_pool_cooldown_ms)`, falling
  back to 30 minutes.
  """
  @spec cooldown_ms() :: pos_integer()
  def cooldown_ms do
    Application.get_env(:arbiter, :provider_pool_cooldown_ms, @default_cooldown_ms)
  end

  @doc """
  Marks `provider` as exhausted for the configured cooldown window.

  Called by the stop-classification layer (bd-cqccsm) when it detects a
  token/credit-exhaustion stop. Idempotent — calling it again extends the
  cooldown.
  """
  @spec mark_exhausted(atom()) :: :ok
  def mark_exhausted(provider) when is_atom(provider) do
    until = :erlang.monotonic_time(:millisecond) + cooldown_ms()
    :ets.insert(@table, {provider, until})
    :ok
  end

  @doc """
  Clears the circuit breaker for `provider`, marking it healthy again.

  Called after a successful dispatch from the provider completes. A no-op
  when the GenServer is not running.
  """
  @spec record_success(atom()) :: :ok
  def record_success(provider) when is_atom(provider) do
    if table_up?(), do: :ets.delete(@table, provider)
    :ok
  end

  @doc """
  Returns `true` if `provider` is currently healthy (not in the cooldown
  window). Always returns `true` when the GenServer is not running.
  """
  @spec healthy?(atom()) :: boolean()
  def healthy?(provider) when is_atom(provider) do
    case table_up?() && :ets.lookup(@table, provider) do
      false -> true
      [] -> true
      [{_, exhausted_until}] -> :erlang.monotonic_time(:millisecond) >= exhausted_until
    end
  end

  @doc """
  Picks the first healthy provider from `providers`.

  When no provider is healthy (all exhausted), falls back to the first entry
  in the list so the system degrades gracefully rather than stalling.
  Returns `nil` only when `providers` is empty.
  """
  @spec pick([atom()]) :: atom() | nil
  def pick([]), do: nil

  def pick(providers) when is_list(providers) do
    Enum.find(providers, &healthy?/1) || List.first(providers)
  end

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  # ---- Internals -----------------------------------------------------------

  defp table_up? do
    :ets.info(@table) != :undefined
  end
end
