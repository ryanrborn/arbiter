defmodule Arbiter.Sessions.Adoption do
  @moduledoc """
  Boot-time adoption sweep for coordinator sessions (bd-bpt0ag; RFC §4.6
  item 1, §4.3).

  Arbiter holds no handle to a session's PTY, which is the whole point — it is
  also why, after `systemctl --user restart arbiter`, the BEAM comes back
  knowing nothing about the sessions that are still running. This sweep is the
  reconnection: it asks systemd and tmux what is alive, and reconciles that
  against the `sessions` table.

  Reattach-after-restart and orphan detection are therefore the *same*
  machinery, not two mechanisms — which is exactly the argument §4.6 makes for
  doing it this way.

  ## The three rules

  1. **Re-adopt what is still live.** A row whose scope unit is listed by
     `systemctl --user list-units 'arb-session-*'`, *or* whose tmux socket
     still answers `has-session`, goes back to `:running`. Either signal is
     enough: the spike measured a scope staying `active` with tmux serving
     indefinitely after arbiter was stopped outright, so the conservative rule
     is to keep a row that has any evidence of life.

  2. **End what has vanished, with a reason.** A row with neither a live scope
     nor a live socket is marked `:ended` and its `end_reason` says the sweep
     did it. §4.6 asks for the reason specifically: a row that silently flips
     to ended is indistinguishable from an operator kill.

  3. **Never kill an unknown live scope.** A live `arb-session-*` scope with no
     matching non-ended row is *reported*, never stopped. The RFC's eventual
     reaping policy (§4.6) does kill era-orphans, but phase 1 deliberately does
     not: the first thing a wrong unit-name match would destroy is a session the
     operator is working in, and an unexpected scope is exactly the case where
     the sweep's model of the host is already known to be wrong. Orphans come
     back in the `:orphans` key and are logged at `:warning`; phase 10 (idle
     deadline + dead-man's switch) is where acting on them belongs.

  ## Failure is not "everything died"

  If the enumeration itself fails — no user manager, no D-Bus, `systemctl`
  missing — the sweep returns `{:error, {:enumerate_failed, output}}` and
  touches **no rows**. A sweep that cannot see the host must never conclude
  that the host is empty; that mistake would end every live session's row and
  orphan every one of them on the next pass.
  """

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Naming
  alias Arbiter.Sessions.Session

  require Ash.Query
  require Logger

  # `systemctl list-units` prints UNIT LOAD ACTIVE SUB DESCRIPTION; only these
  # ACTIVE values mean the scope still holds processes.
  @live_active_states ~w(active activating reloading deactivating)

  @type orphan :: %{
          session_id: String.t() | nil,
          unit: String.t() | nil,
          socket: String.t() | nil
        }

  @type result :: %{
          adopted: [String.t()],
          ended: [String.t()],
          orphans: [orphan()],
          live_units: non_neg_integer(),
          live_sockets: non_neg_integer()
        }

  @doc """
  Run the sweep. Options:

    * `:runner` — see `Arbiter.Sessions.Runner`.
    * `:context` — human-readable phrase for the `end_reason` written on rows
      this sweep ends, e.g. `"adoption sweep at boot"` (default) or
      `"periodic orphan-reaper sweep"` — the reason should say which one
      actually ended the row (§4.6: "say *why* it ended").
    * `:now` — test seam for the `:starting`-row launch grace below.
    * `:launch_grace_ms` — how long a `:starting` row is left alone before
      the sweep is allowed to judge it (default `0`, i.e. no grace).
      `Sessions.launch/1` writes the row, then provisions, then starts the
      scope — a row can be `:starting` with neither a live unit nor a live
      socket for that whole window. That race is harmless for the boot-only
      sweep (nothing else is launching sessions while the BEAM comes up, and
      a `:starting` row surviving a restart is exactly a crashed launch this
      sweep exists to clean up — hence the `0` default). It stops being
      harmless once a sweep runs on a timer while the app is live
      (`Arbiter.Sessions.OrphanReaper`), where a launch can land inside a
      sweep for real: the sweep would mark the row `:ended` under the
      launcher, and `start_scope/2`'s later `mark_running` would resurrect an
      already-ended row. Callers that run periodically pass a nonzero grace.
  """
  @spec sweep(keyword()) :: {:ok, result()} | {:error, term()}
  def sweep(opts \\ []) do
    runner = Sessions.runner(opts)
    context = Keyword.get(opts, :context, "adoption sweep at boot")
    now = Keyword.get(opts, :now, DateTime.utc_now())
    launch_grace_ms = Keyword.get(opts, :launch_grace_ms, 0)

    with {:ok, units} <- live_units(runner) do
      sockets = live_sockets(runner)
      reconcile(units, sockets, context, now, launch_grace_ms, opts)
    end
  end

  @doc """
  The boot entry point: sweep once, log the outcome, never crash the boot.

  Gated on the single-instance primary verdict for the same reason the worker-run
  reconcile sweep is (`Arbiter.Application`): a transient or duplicate boot must
  not be allowed to mark the live instance's sessions ended.
  """
  @spec sweep_on_boot(keyword()) :: :ok
  def sweep_on_boot(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      case sweep(Keyword.delete(opts, :primary?)) do
        {:ok, result} ->
          Logger.info(
            "Arbiter.Sessions adoption sweep: adopted=#{length(result.adopted)} " <>
              "ended=#{length(result.ended)} orphans=#{length(result.orphans)} " <>
              "(live scopes=#{result.live_units}, live sockets=#{result.live_sockets})"
          )

        {:error, reason} ->
          Logger.warning(
            "Arbiter.Sessions adoption sweep skipped, no rows touched: #{inspect(reason)}"
          )
      end
    else
      Logger.info("Arbiter.Sessions adoption sweep skipped: not the primary instance")
    end

    :ok
  rescue
    e ->
      Logger.error("Arbiter.Sessions adoption sweep crashed: #{Exception.message(e)}")
      :ok
  end

  # -- enumeration ------------------------------------------------------------

  # Live session scopes, as full unit names. Runs the exact command §4.6 names.
  defp live_units(runner) do
    case runner.run(
           "systemctl",
           ["--user", "list-units", Naming.unit_glob(), "--no-legend", "--plain"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, parse_units(output)}

      {output, status} ->
        Logger.warning(
          "Arbiter.Sessions could not enumerate session scopes " <>
            "(systemctl exited #{status}): #{String.trim(output)}"
        )

        {:error, {:enumerate_failed, String.trim(output)}}
    end
  end

  defp parse_units(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), ~r/\s+/, parts: 5) do
        [unit, _load, active | _] ->
          if active in @live_active_states and Naming.session_id_from_unit(unit),
            do: [unit],
            else: []

        _ ->
          []
      end
    end)
  end

  # Sockets that still have a tmux server answering. A stale socket file left
  # behind by a dead server is common, so the file's existence proves nothing —
  # `has-session` is the liveness check.
  defp live_sockets(runner) do
    case Naming.socket_glob() do
      {:ok, glob} ->
        glob
        |> Path.wildcard()
        |> Enum.filter(fn socket ->
          match?(
            {_out, 0},
            runner.run("tmux", ["-S", socket, "has-session", "-t", Naming.tmux_session()],
              stderr_to_stdout: true
            )
          )
        end)

      {:error, :no_runtime_dir} ->
        []
    end
  end

  # -- reconciliation ---------------------------------------------------------

  defp reconcile(units, sockets, context, now, launch_grace_ms, opts) do
    unit_set = MapSet.new(units)
    socket_set = MapSet.new(sockets)

    {adopted, ended} =
      now
      |> open_rows(launch_grace_ms)
      |> Enum.split_with(&live?(&1, unit_set, socket_set))

    adopted_ids =
      for session <- adopted, reduce: [] do
        acc ->
          case Sessions.mark_running(session) do
            {:ok, running} ->
              # Same rationale as `Sessions.start_scope/2` (bd-5pelo2 round
              # 5 finding 1): a re-adopted session is exactly as capturable
              # as a freshly launched one, and this is the other call path
              # the §11 raw transcript needs to start from, not from a
              # browser's first `attach/2`.
              _ = Arbiter.Sessions.Stream.ensure_reader(running, opts)
              [session.id | acc]

            {:error, reason} ->
              Logger.error(
                "Arbiter.Sessions could not re-adopt #{session.id}: #{inspect(reason)}"
              )

              acc
          end
      end
      |> Enum.reverse()

    ended_ids =
      for session <- ended, reduce: [] do
        acc ->
          reason =
            "scope #{session.scope_unit} is gone (#{context}) — " <>
              "no live unit and no tmux server on #{session.tmux_socket}"

          case Sessions.mark_ended(session, reason) do
            {:ok, _} ->
              [session.id | acc]

            {:error, error} ->
              Logger.error(
                "Arbiter.Sessions could not end vanished #{session.id}: #{inspect(error)}"
              )

              acc
          end
      end
      |> Enum.reverse()

    orphans = orphans(units, sockets, adopted_ids)
    Enum.each(orphans, &log_orphan/1)

    {:ok,
     %{
       adopted: adopted_ids,
       ended: ended_ids,
       orphans: orphans,
       live_units: MapSet.size(unit_set),
       live_sockets: MapSet.size(socket_set)
     }}
  end

  # Every row the sweep is allowed to judge: an `:ended` row is history, and
  # re-adopting one would resurrect a session the operator deliberately killed.
  # A `:starting` row younger than `launch_grace_ms` is excluded too — see
  # `sweep/1`'s `:launch_grace_ms` doc.
  defp open_rows(now, launch_grace_ms) do
    Session
    |> Ash.Query.filter(status != :ended)
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.read!()
    |> Enum.reject(&mid_launch?(&1, now, launch_grace_ms))
  end

  defp mid_launch?(%Session{status: :starting, started_at: started_at}, now, launch_grace_ms) do
    DateTime.diff(now, started_at, :millisecond) < launch_grace_ms
  end

  defp mid_launch?(_session, _now, _launch_grace_ms), do: false

  defp live?(session, unit_set, socket_set) do
    MapSet.member?(unit_set, session.scope_unit) or
      MapSet.member?(socket_set, session.tmux_socket)
  end

  # A live scope or socket with no adopted row behind it. Both are reported, and
  # a session showing up as both is reported once.
  defp orphans(units, sockets, adopted_ids) do
    adopted = MapSet.new(adopted_ids)

    unit_orphans =
      for unit <- units,
          id = Naming.session_id_from_unit(unit),
          not MapSet.member?(adopted, id),
          do: %{session_id: id, unit: unit, socket: nil}

    claimed = MapSet.union(adopted, MapSet.new(unit_orphans, & &1.session_id))

    socket_orphans =
      for socket <- sockets,
          id = Naming.session_id_from_socket(socket),
          not MapSet.member?(claimed, id),
          do: %{session_id: id, unit: nil, socket: socket}

    unit_orphans ++ socket_orphans
  end

  defp log_orphan(%{unit: unit, socket: socket, session_id: id}) do
    Logger.warning(
      "Arbiter.Sessions found an orphan live session and is NOT touching it: " <>
        "session_id=#{inspect(id)} unit=#{inspect(unit)} socket=#{inspect(socket)}. " <>
        "It has no adoptable row, so Arbiter cannot claim it — but killing an " <>
        "unrecognised live scope could destroy a session in use (§4.6). " <>
        "Attach with `tmux -S #{socket || "<socket>"} attach -t #{Naming.tmux_session()}` " <>
        "or stop it with `systemctl --user stop #{unit || "<unit>"}`."
    )
  end
end
