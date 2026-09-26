defmodule Arbiter.Quota.SpendCache do
  @moduledoc """
  Memoizes `Arbiter.Usage.spend_by_account/1` and `spend_by_workspace/1` —
  the two grouped SQL aggregates `Arbiter.Quota.provider_spend/1` and
  `workspace_spend/1` read from — so the top-bar `:quota` LiveView hook
  (`ArbiterWeb.LiveHooks.on_mount(:quota, ...)`) doesn't pay for a fresh
  30-day ledger scan on every mount (bd-4p6pw7: 46 queries, ~0.7-1.0s, one
  per account/workspace/view, before this cache existed).

  A 30-second TTL covers repeat mounts/navigations within the window with
  zero queries; `invalidate/0` (called from
  `Arbiter.Usage.Event`'s `:create` / `:refresh_snapshot` / `:backfill_usage`
  actions — see that resource's `actions` block) drops it early the moment
  new usage lands, so a worker's session finishing doesn't leave the top bar
  showing stale spend for up to the TTL.

  Backed by a `:public` ETS table owned by this GenServer so any process can
  read/write it without round-tripping a message — the table survives a
  crash-restart of this process (it isn't `:protected`ed to the owner), and
  reads never block on the GenServer being free. The SQL itself always runs
  in the *calling* process (never here), so it rides that process's own DB
  connection — required under `Ecto.Adapters.SQL.Sandbox` in tests, where
  only the calling (test) process holds a checked-out connection.
  """
  use GenServer

  alias Arbiter.Usage

  @table __MODULE__
  @ttl_ms 30_000

  @type totals :: %{optional(String.t()) => %{optional(String.t()) => float()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Every provider account's 30-day spend — `Arbiter.Usage.spend_by_account/1`, cached."
  @spec account_totals() :: totals()
  def account_totals, do: fetch(:account, &Usage.spend_by_account/0)

  @doc "Every workspace's 30-day spend — `Arbiter.Usage.spend_by_workspace/1`, cached."
  @spec workspace_totals() :: totals()
  def workspace_totals, do: fetch(:workspace, &Usage.spend_by_workspace/0)

  @doc """
  Drop every cached total, so the next `account_totals/0` /
  `workspace_totals/0` call recomputes from the ledger. Safe to call before
  the table exists (e.g. in a test that hasn't started the app's
  supervision tree) — a no-op rather than a raise.
  """
  @spec invalidate() :: :ok
  def invalidate do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp fetch(key, compute) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, inserted_at}] when now - inserted_at < @ttl_ms ->
        value

      _ ->
        value = compute.()
        :ets.insert(@table, {key, value, now})
        value
    end
  rescue
    ArgumentError -> compute.()
  end
end
