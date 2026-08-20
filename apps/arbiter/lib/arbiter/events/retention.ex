defmodule Arbiter.Events.Retention do
  @moduledoc """
  Periodically prunes `Arbiter.Events.Record` rows older than the retention
  window, so the durable event log backing `GET /events?since=` doesn't grow
  without bound.

  ## Configuration

  Via `config :arbiter, :events_retention`:

    * `:enabled`         — master switch (default `true`; `false` in test,
                           where tests drive `sweep/1` synchronously).
    * `:interval_ms`     — sweep cadence (default 3 600 000, one hour).
    * `:retention_days`  — age past which a row is deleted, measured from
                           `inserted_at` (default 7).

  A row older than the retention window is unreplayable regardless of this
  sweeper's cadence — `Arbiter.Events.replay/3` has no special-casing for
  "gap predates retention", it just won't find the rows. A coordinator that
  reconnects after a longer outage than the retention window has a real gap;
  that's the tradeoff this setting makes explicit.
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Arbiter.Events.Record

  @default_interval_ms 60 * 60_000
  @default_retention_days 7

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Delete every `Record` row older than `:retention_days` (default from
  config, overridable via opts — mainly for tests). Best-effort: a delete
  failure is logged and swallowed rather than crashing the caller.

  Prunes by `seq`, not `inserted_at`: the only index on this table is
  `[:workspace_id, :seq]` (see `Arbiter.Events.Record`), so filtering on
  `inserted_at` directly would full-scan every sweep. Instead the cutoff
  timestamp is resolved to a `seq` once (via the highest-`seq` row still
  older than the cutoff), then rows are pruned with `seq <= cutoff_seq`,
  which reuses the primary key. Resolving against `occurred_at` — the same
  clock `Arbiter.Events.replay/3` filters on for its `{:timestamp, _}` mode
  — also removes the clock skew that existed between retention and replay
  when retention pruned by `inserted_at` instead.
  """
  @spec sweep(keyword()) :: :ok
  def sweep(opts \\ []) do
    retention_days =
      Keyword.get(opts, :retention_days, cfg(:retention_days, @default_retention_days))

    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    case cutoff_seq(cutoff) do
      nil ->
        :ok

      cutoff_seq ->
        Record
        |> Ash.Query.filter(seq <= ^cutoff_seq)
        |> Ash.bulk_destroy!(:destroy, %{}, return_errors?: false)

        :ok
    end
  rescue
    e ->
      Logger.error("Arbiter.Events.Retention sweep failed: #{Exception.message(e)}")
      :ok
  end

  # The highest seq among rows at or before the cutoff, or nil if none exist.
  defp cutoff_seq(cutoff) do
    Record
    |> Ash.Query.filter(occurred_at < ^cutoff)
    |> Ash.Query.sort(seq: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%Record{seq: seq}] -> seq
      [] -> nil
    end
  end

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg_opt(:enabled, opts, true),
      interval_ms: cfg_opt(:interval_ms, opts, @default_interval_ms)
    }

    if state.enabled, do: schedule(self(), state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(pid, ms), do: Process.send_after(pid, :sweep, ms)

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> cfg(key, default)
    end
  end

  defp cfg(key, default) do
    case get_in(Application.get_env(:arbiter, :events_retention, []), [key]) do
      nil -> default
      val -> val
    end
  end
end
