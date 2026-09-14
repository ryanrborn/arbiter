defmodule Arbiter.Reviews.CoverageShadow.Tally do
  @moduledoc """
  The in-memory half of P3's shadow counter (design #1635 §6.3).

  `Arbiter.Reviews.CoverageShadow` keeps two counters, for two different
  readers:

    * a **durable** one — one `Arbiter.Events.Record` row per distinct shadow
      observation, topic `coverage_shadow` — which is what the coordinator
      reads after a restart to answer "zero disagreements over ≥20 merges";
    * this one, a since-boot ETS tally, which is what makes that durable row
      *rare*. Without it a PR parked on the MergeQueue's unbounded stale-SHA
      retry (§2.3's M3) would write one event row per tick, forever.

  So this table does two jobs: it counts every evaluation (the honest
  denominator, including the re-polls the event log deliberately collapses),
  and it remembers which `{site, mr_ref, head, old, new}` observations have
  already been reported so each one logs and persists exactly once.

  Everything is best-effort by construction. `bump/1` and `first_time?/1` are
  called from the merge-guard path, so a missing table (the process is not
  running — every test that does not need the tally, and any window during a
  restart) must read as "could not count", never as an exception. `bump/1`
  returns `:ok` regardless and `first_time?/1` answers `true`, which degrades
  to the pre-dedup behaviour: report it.

  The dedup set is bounded by `@max_seen`; crossing it drops the whole set
  rather than evicting cleverly. Re-reporting a handful of observations after
  a flush is harmless (the durable counter is a floor, not a ledger), and an
  unbounded set on a control-plane process is not.
  """

  use GenServer

  @table __MODULE__
  @max_seen 5_000

  @counters [:evaluations, :agreements, :disagreements, :errors]

  @typedoc "Since-boot counts, plus the per-site and per-transition breakdowns."
  @type snapshot :: %{
          evaluations: non_neg_integer(),
          agreements: non_neg_integer(),
          disagreements: non_neg_integer(),
          errors: non_neg_integer(),
          by_site: %{optional(atom()) => non_neg_integer()},
          by_transition: %{optional(String.t()) => non_neg_integer()}
        }

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Add one to a counter. `key` is a bare counter name (`:evaluations`), a
  `{:site, site}` pair or a `{:transition, "old->new"}` pair.

  Never raises and never blocks: the write goes straight to the public table,
  not through this GenServer.
  """
  @spec bump(atom() | {atom(), term()}) :: :ok
  def bump(key) do
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Has this exact observation been reported before?

  `true` the first time a key is seen (and every time after the table has been
  flushed or is absent), `false` afterwards. Callers use it to report each
  distinct observation once rather than once per poll.
  """
  @spec first_time?(term()) :: boolean()
  def first_time?(key) do
    maybe_flush()
    :ets.insert_new(@table, {{:seen, key}, 1})
  rescue
    ArgumentError -> true
  end

  @doc "Every counter at zero — what `snapshot/0` answers when the tally is not running."
  @spec empty_snapshot() :: snapshot()
  def empty_snapshot do
    @counters
    |> Map.new(&{&1, 0})
    |> Map.merge(%{by_site: %{}, by_transition: %{}})
  end

  @doc """
  The counters as they stand, for `arb`/IEx/MCP readers. Answers
  `empty_snapshot/0` rather than raising when the tally is not running.
  """
  @spec snapshot() :: snapshot()
  def snapshot do
    base = Map.new(@counters, &{&1, count(&1)})

    Map.merge(base, %{
      by_site: grouped(:site),
      by_transition: grouped(:transition)
    })
  rescue
    ArgumentError -> empty_snapshot()
  end

  @doc "Drop every counter and the dedup set. Test/operator affordance."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp count(key) do
    case :ets.lookup(@table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  defp grouped(tag) do
    @table
    |> :ets.match({{tag, :"$1"}, :"$2"})
    |> Map.new(fn [label, n] -> {label, n} end)
  end

  defp maybe_flush do
    if :ets.info(@table, :size) > @max_seen, do: reset()
  end
end
