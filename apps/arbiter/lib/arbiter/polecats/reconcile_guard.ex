defmodule Arbiter.Polecats.ReconcileGuard do
  @moduledoc """
  Single-instance gate for the boot-time orphan-run sweep.

  `Arbiter.Polecats.Reconciler` marks every `:running` `Run` row with no live
  *local* polecat as `:failed` on boot — crash recovery for a canonical server
  that died mid-run. But "no live local polecat" is judged against THIS node's
  `Arbiter.Polecat.Registry`, which a second OS process cannot see into. So a
  transient second boot against the same database — an acolyte running
  `iex -S mix` / `mix run` / `mix phx.server` while the real server is up —
  would see the primary instance's live `:running` runs as orphans and sweep
  them, corrupting active work. Observed live 2026-06-02 (bd-9rouwh; relates to
  bd-6k8519): a second instance failed the first instance's own running run,
  then died on the `:4848` port conflict.

  This guard makes the sweep single-instance. On boot it opens a dedicated
  Postgres connection and tries a session-level advisory lock
  (`pg_try_advisory_lock`). Only the instance that *acquires* the lock is
  canonical: it runs the sweep and then holds the lock — and its connection —
  for the lifetime of the node. A concurrent second boot fails to acquire the
  lock, skips the sweep entirely, and leaves the primary's runs untouched.

  When the canonical node stops or crashes, its session ends and Postgres
  releases the lock automatically, so the next legitimate single-server restart
  re-acquires it and the crash-recovery sweep still works. The dedicated
  connection is started with `backoff_type: :stop`, so a dropped connection
  takes the (linked) guard down with it rather than silently reconnecting on a
  fresh session that no longer holds the lock; the supervisor then restarts the
  guard, which re-acquires.

  Gated into the supervision tree only when the boot Tasks run (non-test); see
  `Arbiter.Application`.
  """
  use GenServer

  require Logger

  alias Arbiter.Polecats.Reconciler

  # A stable, arbitrary 64-bit key identifying the reconcile single-instance
  # lock. Private to this guard; any other client locking the same key would
  # contend. Tests override it via the `:lock_key` opt so concurrent suites and
  # a live dev server never share a key.
  @advisory_lock_key 4_269_217_001

  # Connection options forwarded from the Ecto repo config to the dedicated
  # Postgrex connection. `Arbiter.Repo.config/0` returns discrete keys even when
  # the repo is configured via a `:url` (Ecto parses and merges them). We drop
  # the pool keys (`:pool`, `:pool_size`) deliberately — the Sandbox pool in
  # particular is not a valid Postgrex pool — and force `backoff_type: :stop` so
  # the lock-holding session is never silently re-established without the lock.
  @connection_keys ~w(hostname port username password database socket_options ssl ssl_opts parameters)a

  @doc false
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  The default advisory-lock key used to gate the single-instance reconcile
  sweep. Exposed for tests that simulate a competing instance.
  """
  @spec advisory_lock_key() :: integer()
  def advisory_lock_key, do: @advisory_lock_key

  @doc """
  Open a dedicated Postgres connection using the repo's connection settings.

  Used internally to hold the advisory lock, and by tests to stand up a
  competing "primary instance" that holds the lock first.
  """
  @spec open_connection() :: {:ok, pid()} | {:error, term()}
  def open_connection do
    Arbiter.Repo.config()
    |> Keyword.take(@connection_keys)
    |> Keyword.put(:backoff_type, :stop)
    |> Postgrex.start_link()
  end

  @impl true
  def init(opts) do
    state = %{
      lock_key: Keyword.get(opts, :lock_key, @advisory_lock_key),
      conn: nil,
      reconciled: nil
    }

    {:ok, state, {:continue, :guard}}
  end

  @impl true
  def handle_continue(:guard, state) do
    {:noreply, guard(state)}
  end

  # Synchronous status probe. Because `init/1` returns `{:continue, :guard}`,
  # the continuation runs to completion before any call is serviced, so a test
  # can `start_link` then `call(:status)` and be certain the guard has decided.
  @impl true
  def handle_call(:status, _from, state) do
    status = if state.conn, do: :canonical, else: :skipped
    {:reply, {status, state.reconciled}, state}
  end

  defp guard(state) do
    case acquire_lock(state.lock_key) do
      {:ok, conn} ->
        Logger.info(
          "Polecats.ReconcileGuard: acquired single-instance lock — this node is canonical, running orphan-run sweep"
        )

        %{state | conn: conn, reconciled: run_sweep()}

      :unavailable ->
        Logger.info(
          "Polecats.ReconcileGuard: single-instance lock held by another instance — skipping orphan-run sweep (transient/duplicate boot)"
        )

        state

      {:error, reason} ->
        Logger.warning(
          "Polecats.ReconcileGuard: could not acquire single-instance lock (#{inspect(reason)}) — skipping orphan-run sweep"
        )

        state
    end
  end

  defp acquire_lock(lock_key) do
    case open_connection() do
      {:ok, conn} ->
        case Postgrex.query(conn, "SELECT pg_try_advisory_lock($1)", [lock_key]) do
          {:ok, %Postgrex.Result{rows: [[true]]}} ->
            {:ok, conn}

          {:ok, %Postgrex.Result{rows: [[false]]}} ->
            stop_connection(conn)
            :unavailable

          {:error, reason} ->
            stop_connection(conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_sweep do
    case Reconciler.reconcile_orphaned_runs() do
      {:ok, count} -> count
      {:error, _reason} -> nil
    end
  end

  defp stop_connection(conn) when is_pid(conn) do
    if Process.alive?(conn), do: GenServer.stop(conn, :normal)
  end
end
