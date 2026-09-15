defmodule Arbiter.Sessions.OrphanReaper do
  @moduledoc """
  RFC §4.6 item 1's kill-after-grace policy for orphan scopes (phase 10,
  bd-3qkbch).

  `Arbiter.Sessions.Adoption` deliberately stops at *reporting* an orphan — a
  live `arb-session-*` scope with no matching row — because the sweep's model
  of the host is by definition already wrong in that case, and the first thing
  a wrong match would destroy is a session the operator is working in. Phase 1
  left "kill it anyway, eventually" for this phase.

  The policy: **an orphan is only ever killed after surviving a full grace
  window across repeated sweeps, never on the sweep that first notices it.**
  A session mid-launch — row written, scope not yet confirmed, or vice versa —
  looks exactly like an orphan for one instant, and the grace window is what
  keeps that instant from being fatal. This is the "documented grace" half of
  the acceptance criterion; the other half, "or operator confirmation", is the
  raw `systemctl --user stop` / `tmux kill-session` commands
  `Arbiter.Sessions.Adoption`'s own orphan log line already hands the operator
  — an immediate, deliberate kill outside this policy entirely.

  A grace-expired orphan is also held off, and re-checked next sweep, if
  `tmux list-clients` reports an attached client on its socket — the same
  "stale heartbeat AND zero clients" discipline the dead-man's switch uses,
  so an operator actively working in a session whose row was genuinely lost
  is never killed just because the clock ran out.

  `decide/4` is the whole policy, kept pure so it can be asserted directly
  against fakes without a systemd user manager or a tmux server in sight; the
  GenServer around it only adds the periodic sweep and the exact-name kill.

  ## Configuration

  Via `config :arbiter, :sessions_orphan_reaper`:

    * `:enabled`     — master switch (default `true`; `false` in test, where
                       tests drive `decide/4` and `sweep_once/2` synchronously).
    * `:interval_ms` — sweep cadence (default 900 000, 15 minutes).
    * `:grace_ms`    — how long an orphan must persist, across sweeps, before
                       it is killed (default 3 600 000, 1 hour — §4.6's own
                       suggested figure for the dead-man's switch, reused here
                       for the same "give arbiter a chance to catch up" reason).
  """

  use GenServer

  require Logger

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Adoption
  alias Arbiter.Sessions.Naming

  @default_interval_ms 15 * 60_000
  @default_grace_ms 60 * 60_000

  # Passed to `Adoption.sweep/1`'s `:launch_grace_ms`: this sweep runs on a
  # timer while the app is live, unlike the boot-only sweep, so a launch in
  # `Sessions.launch/1`'s row-written-but-not-yet-`:running` window can land
  # inside a sweep for real. See `Adoption.sweep/1`'s doc for the race.
  @launch_grace_ms 30_000

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Run one sweep + decide + kill cycle against a `seen` map (see `decide/4`).

  Returns `{%{orphans: [...], killed: [...]}, updated_seen}`. A failed
  enumeration (no systemd user manager, `systemctl` missing) is logged and
  touches nothing — `seen` passes through unchanged, exactly like
  `Adoption.sweep/1`'s own "cannot see the host" rule.
  """
  @spec sweep_once(map(), keyword()) :: {%{orphans: list(), killed: list()}, map()}
  def sweep_once(seen, opts \\ []) do
    runner = Sessions.runner(opts)
    grace_ms = Keyword.get(opts, :grace_ms, cfg(:grace_ms, @default_grace_ms))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Adoption.sweep(
           runner: runner,
           context: "periodic orphan-reaper sweep",
           now: now,
           launch_grace_ms: @launch_grace_ms
         ) do
      {:ok, result} ->
        {to_kill, decided_seen} = decide(seen, result.orphans, now, grace_ms)

        {killed, updated_seen} =
          Enum.reduce(to_kill, {[], decided_seen}, fn orphan, {killed_acc, seen_acc} ->
            if attached_client?(orphan, runner) do
              Logger.warning(
                "Arbiter.Sessions.OrphanReaper holding off on an orphan past its grace " <>
                  "window because a tmux client is attached: " <>
                  "session_id=#{inspect(orphan.session_id)}"
              )

              key = orphan_key(orphan)
              first_seen = Map.get(seen, key, now)
              {killed_acc, Map.put(seen_acc, key, first_seen)}
            else
              kill_orphan(orphan, runner)
              {[orphan | killed_acc], seen_acc}
            end
          end)

        {%{orphans: result.orphans, killed: Enum.reverse(killed)}, updated_seen}

      {:error, reason} ->
        Logger.warning("Arbiter.Sessions.OrphanReaper sweep skipped: #{inspect(reason)}")
        {%{orphans: [], killed: []}, seen}
    end
  end

  @doc """
  Pure decision: given the orphan keys already being watched (`seen`, a map
  of key => first-seen `DateTime.t()`), this sweep's orphan list
  (`Arbiter.Sessions.Adoption.orphan/0`), and `now`, decide which orphans have
  outlived `grace_ms` and should be killed.

  Returns `{orphans_to_kill, updated_seen}`.

    * An orphan seen for the first time is recorded, **never** killed on the
      same sweep it was first noticed on — that is the grace period.
    * An orphan that has been watched for at least `grace_ms` is returned for
      killing and dropped from `seen` (a fresh sighting after the kill starts
      the clock over, which is correct: something is still there).
    * An orphan that stops appearing — adopted, or it died on its own — is
      dropped from `seen` rather than carried forward, so a `seen` map cannot
      grow without bound across a long-running instance.
  """
  @spec decide(map(), [Adoption.orphan()], DateTime.t(), non_neg_integer()) ::
          {[Adoption.orphan()], map()}
  def decide(seen, orphans, now, grace_ms) do
    current_keys = Enum.map(orphans, &orphan_key/1)
    seen = Map.take(seen, current_keys)

    {kill, updated_seen} =
      Enum.reduce(orphans, {[], seen}, fn orphan, {kill_acc, seen_acc} ->
        key = orphan_key(orphan)

        case Map.fetch(seen_acc, key) do
          {:ok, first_seen} ->
            if DateTime.diff(now, first_seen, :millisecond) >= grace_ms do
              {[orphan | kill_acc], Map.delete(seen_acc, key)}
            else
              {kill_acc, seen_acc}
            end

          :error ->
            {kill_acc, Map.put(seen_acc, key, now)}
        end
      end)

    {Enum.reverse(kill), updated_seen}
  end

  defp orphan_key(%{unit: unit}) when is_binary(unit), do: {:unit, unit}
  defp orphan_key(%{socket: socket}) when is_binary(socket), do: {:socket, socket}

  # A grace-expired orphan is still held off if a tmux client is attached —
  # the grace window is purely time-based, so this is the only thing that
  # keeps an operator working in a session whose row was genuinely lost from
  # being killed out from under them, consistent with the watchdog's own
  # "stale heartbeat AND zero clients" rule.
  defp attached_client?(%{socket: nil}, _runner), do: false

  defp attached_client?(%{socket: socket}, runner) do
    case run(runner, "tmux", ["-S", socket, "list-clients", "-t", Naming.tmux_session()]) do
      {output, 0} -> String.trim(output) != ""
      {_output, _status} -> false
    end
  end

  # Exact-name kill only, never a pattern match — the same discipline
  # `Arbiter.Sessions.kill/2` uses for a session it actually has a row for.
  # `tmux kill-session` first, so an attached client sees a clean detach
  # before the scope is stopped out from underneath it.
  defp kill_orphan(%{unit: unit, socket: socket, session_id: id}, runner) do
    Logger.warning(
      "Arbiter.Sessions.OrphanReaper killing orphan past its grace window: " <>
        "session_id=#{inspect(id)} unit=#{inspect(unit)} socket=#{inspect(socket)}"
    )

    if socket do
      run(runner, "tmux", ["-S", socket, "kill-session", "-t", Naming.tmux_session()])
    end

    if unit, do: run(runner, "systemctl", ["--user", "stop", unit])

    :ok
  end

  defp run(runner, command, args), do: runner.run(command, args, stderr_to_stdout: true)

  @doc "Trigger a synchronous sweep now — mainly for tests and an operator-triggered check."
  @spec sweep_now(GenServer.server()) :: %{orphans: list(), killed: list()}
  def sweep_now(server \\ __MODULE__), do: GenServer.call(server, :sweep_now)

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg_opt(:enabled, opts, true),
      interval_ms: cfg_opt(:interval_ms, opts, @default_interval_ms),
      grace_ms: cfg_opt(:grace_ms, opts, @default_grace_ms),
      runner: Keyword.get(opts, :runner),
      # Test seam: defaults to the real global guard. Overridable so the
      # primary-gate branch below can be asserted without standing up a
      # losing `Arbiter.SingleInstance` lock.
      primary_check?: Keyword.get(opts, :primary_check?, &Arbiter.SingleInstance.primary?/0),
      seen: %{}
    }

    if state.enabled, do: schedule(self(), state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Gated exactly like `Adoption.sweep_on_boot/1`: `sweep_once/2` calls
    # `Adoption.sweep/1`, which is not read-only — it marks rows `:running` or
    # `:ended`. A duplicate/secondary instance running this on a 15-minute
    # timer, unlike the boot-only sweep this replaced, would otherwise mark
    # every live session `:ended` under the primary on its next tick.
    state =
      if state.primary_check?.() do
        {_result, seen} = sweep_once(state.seen, sweep_opts(state))
        %{state | seen: seen}
      else
        Logger.warning("Arbiter.Sessions.OrphanReaper sweep skipped: not the primary instance")
        state
      end

    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:sweep_now, _from, state) do
    {result, seen} = sweep_once(state.seen, sweep_opts(state))
    {:reply, result, %{state | seen: seen}}
  end

  defp sweep_opts(state) do
    base = [grace_ms: state.grace_ms]
    if state.runner, do: [{:runner, state.runner} | base], else: base
  end

  defp schedule(pid, ms), do: Process.send_after(pid, :sweep, ms)

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> cfg(key, default)
    end
  end

  defp cfg(key, default) do
    case get_in(Application.get_env(:arbiter, :sessions_orphan_reaper, []), [key]) do
      nil -> default
      val -> val
    end
  end
end
