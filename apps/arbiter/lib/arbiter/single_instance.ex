defmodule Arbiter.SingleInstance do
  @moduledoc """
  Single-instance gate backed by a Postgres session advisory lock.

  Only one Arbiter instance per database may perform *destructive* boot
  reconciliation — the orphan-run sweep in `Arbiter.Polecats.Reconciler`, which
  keys liveness off the LOCAL process registry. A second instance booting
  against the same DB has an empty registry, so without a gate it would see the
  primary instance's live `:running` runs as orphans and mark them `:failed`,
  corrupting active work (observed live 2026-06-02, bd-9rouwh / bd-igu12c).

  This GenServer opens a *dedicated* Postgrex connection — separate from the
  `Arbiter.Repo` pool — and holds `pg_try_advisory_lock/1` on it for its entire
  lifetime. The first instance to boot against a given DB acquires the lock and
  is the "primary"; any concurrent or later duplicate boot (an acolyte running
  `mix phx.server` / `iex -S mix` / `mix run` while the real server is up) finds
  the lock held and is a "secondary". `primary?/0` reports the verdict, and the
  boot reconcile task consults it before sweeping.

  Because the lock is *session*-scoped to the dedicated connection, Postgres
  releases it the instant this process (and its connection) dies — so a genuine
  crash-restart of the single canonical server re-acquires it and crash recovery
  proceeds normally. That is the key distinction from a transaction-scoped lock,
  which a later-booting duplicate would acquire freely once the primary's boot
  sweep had committed.

  We considered the bead's other options — gating on HTTP endpoint ownership
  (awkward: this core app boots, and the reconcile task runs, *before*
  `ArbiterWeb.Endpoint` ever attempts to bind its port) and gating on boot type
  (a second `mix phx.server` is still a "server" boot, so it wouldn't be
  excluded). The advisory lock is the one mechanism that covers every duplicate
  boot regardless of cross-app ordering or boot kind.

  Relates to bd-6k8519 (the reconciler) and bd-9rouwh (this gate).
  """

  use GenServer

  require Logger

  # Arbitrary but stable 64-bit advisory-lock key. Advisory locks live in a
  # per-database namespace shared only with other code that picks the same key,
  # and nothing else in Arbiter takes advisory locks — so a single fixed
  # constant is enough to identify "the Arbiter boot-reconcile instance lock".
  @lock_key 4_848_000_001

  @doc """
  Start the single-instance guard.

  Accepts `:name` (defaults to this module) and `:lock_key` (defaults to the
  canonical key — overridable so a test can stand up two competing guards).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Whether this node holds the single-instance lock (is the primary).

  Returns `false` when the guard is not running, so a caller in the boot path
  fails safe — a missing guard must never green-light the destructive sweep.
  """
  @spec primary?(GenServer.server()) :: boolean()
  def primary?(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> false
      pid -> GenServer.call(pid, :primary?)
    end
  end

  @impl true
  def init(opts) do
    # Trap exits so a supervisor shutdown runs terminate/2 (releasing the lock)
    # and so we observe the dedicated connection dying.
    Process.flag(:trap_exit, true)
    lock_key = Keyword.get(opts, :lock_key, @lock_key)

    case Postgrex.start_link(connection_opts()) do
      {:ok, conn} ->
        {:ok, %{conn: conn, lock_key: lock_key, primary?: acquire(conn, lock_key)}}

      {:error, reason} ->
        Logger.warning(
          "SingleInstance: could not open lock connection (#{inspect(reason)}); " <>
            "running as SECONDARY (boot reconciliation disabled)"
        )

        {:ok, %{conn: nil, lock_key: lock_key, primary?: false}}
    end
  end

  @impl true
  def handle_call(:primary?, _from, state), do: {:reply, state.primary?, state}

  @impl true
  # The dedicated connection died — we can no longer vouch for the lock. Stop so
  # the supervisor restarts us and we re-attempt acquisition cleanly.
  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) do
    {:stop, {:lock_connection_down, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  # Closing the dedicated connection ends its Postgres session, which releases
  # the advisory lock — so the next instance to boot can claim it. This runs on
  # a normal/supervisor shutdown; an abnormal crash or VM death drops the
  # connection (and thus the lock) just the same.
  def terminate(_reason, %{conn: conn}) when is_pid(conn) do
    if Process.alive?(conn), do: GenServer.stop(conn, :normal, 1_000)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # Try to take the session advisory lock on the dedicated connection. A `true`
  # row means we own it (primary); `false` means another instance holds it
  # (secondary); any error fails safe to secondary so a flaky lock query can
  # never authorize the destructive sweep.
  defp acquire(conn, lock_key) do
    case Postgrex.query(conn, "SELECT pg_try_advisory_lock($1)", [lock_key]) do
      {:ok, %{rows: [[true]]}} ->
        Logger.info("SingleInstance: acquired advisory lock; this is the PRIMARY instance")
        true

      {:ok, %{rows: [[false]]}} ->
        Logger.warning(
          "SingleInstance: advisory lock held by another instance; running as SECONDARY " <>
            "(boot reconciliation disabled)"
        )

        false

      {:error, reason} ->
        Logger.warning(
          "SingleInstance: advisory-lock query failed (#{inspect(reason)}); " <>
            "running as SECONDARY (boot reconciliation disabled)"
        )

        false
    end
  end

  # The Repo's runtime config, already normalised (any `:url` is parsed into
  # discrete host/credential fields by `Ecto.Repo.config/0`), pared down to the
  # keys Postgrex accepts. A single connection is all the lock needs.
  defp connection_opts do
    Arbiter.Repo.config()
    |> Keyword.take([
      :hostname,
      :port,
      :username,
      :password,
      :database,
      :socket_dir,
      :socket,
      :ssl,
      :ssl_opts,
      :parameters,
      # :socket_options carries [:inet6] on IPv6-only hosts (Fly.io et al.);
      # dropping it would make the lock connection try IPv4, fail, and silently
      # disable crash recovery on the real primary. (Tribunal finding, bd-9rouwh.)
      :socket_options
    ])
    |> Keyword.put(:pool_size, 1)
  end
end
