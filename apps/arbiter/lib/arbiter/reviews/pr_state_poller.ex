defmodule Arbiter.Reviews.PrStatePoller do
  @moduledoc """
  Background job that keeps `ExternalReview` records' `pr_state` fresh
  (bd-3jjk0e), independent of any open dashboard.

  Before this, pr_state was resolved *only* lazily while a dashboard LiveView
  was mounted — so a PR that merged/closed while nobody was watching kept a
  stale `open` (or a frozen `unknown`) forever. This singleton GenServer runs on
  a recurring timer, walks the non-terminal records (per
  `Arbiter.Reviews.PrState.needs_refresh?/1`), and re-resolves each one, so the
  dashboard is now a *reader* of pr_state rather than its only writer.

  Terminal states (`merged` / `closed` / `gone` / `n/a`) are skipped, so the
  poll set shrinks to genuinely in-flight PRs. A transient failure leaves a row
  `unknown` and it is retried on the next cycle; a hard 404 lands on the terminal
  `gone` and drops out of the set.

  ## Configuration

  Via `config :arbiter, :pr_state_poller`:

    * `:enabled`     — master switch (default `true`; `false` in test, where
                       tests drive `poll/1` synchronously instead).
    * `:interval_ms` — poll interval (default 60 000, matching the dashboard's
                       old 60s force tick).
    * `:fetch_limit` — max records scanned per cycle (default 500).
  """

  use GenServer

  require Logger
  require Ash.Query

  alias Arbiter.Reviews.{PrState, Record}
  alias Arbiter.Tasks.Workspace

  @default_interval_ms 60_000
  @default_fetch_limit 500

  # ---- public API ----------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Run one poll cycle synchronously and wait for it to complete.

  Intended for tests (and manual triggering); the periodic timer calls the same
  cycle. Returns `:ok`.
  """
  @spec poll(GenServer.server()) :: :ok
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, 60_000)

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg(:enabled, opts, true),
      interval_ms: cfg(:interval_ms, opts, @default_interval_ms),
      fetch_limit: cfg(:fetch_limit, opts, @default_fetch_limit)
    }

    if state.enabled, do: schedule(self(), state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    run_cycle(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    run_cycle(state)
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- internals -----------------------------------------------------------

  # Resolve pr_state for every non-terminal record. Best-effort throughout: a DB
  # read failure yields an empty set, and each record is resolved under its own
  # rescue so one bad row never aborts the cycle.
  defp run_cycle(state) do
    records = stale_records(state.fetch_limit)

    if records != [] do
      workspaces_by_id = workspaces_by_id()

      Enum.each(records, fn record ->
        workspace = Map.get(workspaces_by_id, record.workspace_id)
        PrState.resolve_and_persist(record, workspace)
      end)
    end

    :ok
  rescue
    e ->
      Logger.debug("PrStatePoller cycle swallowed: #{Exception.message(e)}")
      :ok
  end

  defp stale_records(limit) do
    Record
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
    |> Enum.filter(&PrState.needs_refresh?/1)
  rescue
    _ -> []
  end

  defp workspaces_by_id do
    Workspace
    |> Ash.read!()
    |> Map.new(&{&1.id, &1})
  rescue
    _ -> %{}
  end

  defp schedule(pid, ms), do: Process.send_after(pid, :poll, ms)

  defp cfg(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        case get_in(Application.get_env(:arbiter, :pr_state_poller, []), [key]) do
          nil -> default
          val -> val
        end
    end
  end
end
