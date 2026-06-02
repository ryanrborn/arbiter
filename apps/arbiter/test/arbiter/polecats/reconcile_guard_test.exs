defmodule Arbiter.Polecats.ReconcileGuardTest do
  # DataCase (async: false → shared sandbox) so the guard process, started here
  # under no owner, reaches the same DB connection when it runs the sweep —
  # mirroring ReconcilerTest. The advisory lock itself lives on a *separate*,
  # non-sandboxed Postgres session, so the lock contention this exercises is the
  # real cross-session mutual exclusion a second app instance would hit.
  use Arbiter.DataCase, async: false

  alias Arbiter.Polecats.ReconcileGuard
  alias Arbiter.Polecats.Run
  require Ash.Query

  defp create_run(bead_id, status) do
    Ash.create!(Run, %{
      bead_id: bead_id,
      rig: "arbiter",
      workspace_id: "ws-guard",
      status: status,
      started_at: DateTime.utc_now(),
      output_lines: []
    })
  end

  defp reload(bead_id) do
    Run
    |> Ash.Query.filter(bead_id == ^bead_id)
    |> Ash.read_one!()
  end

  # A unique key per test isolates each scenario's lock from its neighbours and
  # from any live dev server sharing the DB.
  defp unique_key, do: System.unique_integer([:positive])

  # Stand up a competing "primary instance": a dedicated session that holds the
  # single-instance lock, exactly as a live canonical node would.
  defp hold_lock(key) do
    {:ok, conn} = ReconcileGuard.open_connection()
    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn, :normal) end)

    assert {:ok, %Postgrex.Result{rows: [[true]]}} =
             Postgrex.query(conn, "SELECT pg_try_advisory_lock($1)", [key])

    conn
  end

  defp start_guard(key) do
    {:ok, pid} = ReconcileGuard.start_link(name: nil, lock_key: key)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  test "a concurrent second-instance boot does NOT sweep the primary's live :running runs" do
    key = unique_key()

    # The primary instance is live and holds the single-instance lock.
    hold_lock(key)

    # A :running run that the LOCAL registry can't vouch for — to a second
    # instance it looks exactly like an orphan the sweep would fail.
    bead_id = "bd-guard-second-#{System.unique_integer([:positive])}"
    create_run(bead_id, :running)

    # The second instance boots its guard against the same DB and same key.
    guard = start_guard(key)

    # It loses the lock race and skips the sweep entirely.
    assert {:skipped, nil} = GenServer.call(guard, :status)

    # The primary's live run is untouched — no corruption of active work.
    assert reload(bead_id).status == :running
  end

  test "the canonical instance (lock free) runs the crash-recovery sweep" do
    key = unique_key()

    bead_id = "bd-guard-canonical-#{System.unique_integer([:positive])}"
    create_run(bead_id, :running)

    # No competing instance: the guard wins the lock and sweeps as on a normal
    # single-server restart.
    guard = start_guard(key)

    assert {:canonical, 1} = GenServer.call(guard, :status)

    run = reload(bead_id)
    assert run.status == :failed
    assert run.failure_reason == "server restarted"
  end

  test "the lock is released when its holder's session ends, so a restart re-sweeps" do
    key = unique_key()

    # Primary holds the lock, then its session ends — a crash or shutdown.
    conn = hold_lock(key)
    GenServer.stop(conn, :normal)

    # Postgres releases session advisory locks asynchronously as the socket
    # closes; wait for the release rather than assuming an instant.
    assert wait_until(fn -> lock_free?(key) end), "lock was not released after holder exit"

    bead_id = "bd-guard-restart-#{System.unique_integer([:positive])}"
    create_run(bead_id, :running)

    guard = start_guard(key)

    assert {:canonical, 1} = GenServer.call(guard, :status)
    assert reload(bead_id).status == :failed
  end

  # Probe whether the key can be acquired (then release immediately) on a fresh
  # session — i.e. nobody else holds it.
  defp lock_free?(key) do
    {:ok, conn} = ReconcileGuard.open_connection()

    try do
      case Postgrex.query!(conn, "SELECT pg_try_advisory_lock($1)", [key]) do
        %Postgrex.Result{rows: [[true]]} ->
          Postgrex.query!(conn, "SELECT pg_advisory_unlock($1)", [key])
          true

        _ ->
          false
      end
    after
      GenServer.stop(conn, :normal)
    end
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
