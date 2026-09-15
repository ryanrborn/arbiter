defmodule Arbiter.Sessions.IdleReaper do
  @moduledoc """
  RFC §4.6 item 2 (phase 10, bd-3qkbch): terminates coordinator sessions that
  have gone idle past a configured TTL.

  "Idle" is measured from whichever of `last_client_at`, `last_turn_at`, or
  (absent both) `started_at` is most recent — a client attaching and a turn
  actually running are both activity, and a session with neither yet is timed
  from its own launch. `keep_alive` is an unconditional exemption: a session the
  operator pinned (`Arbiter.Sessions.set_keep_alive/2`) is never a candidate
  here, however stale the clock reads.

  This is *routine* housekeeping, distinct from `Arbiter.Sessions.OrphanReaper`
  (§4.6 item 1's kill-after-grace policy for scopes with no row at all) and
  from the in-scope dead-man's switch (§4.6 item 3, the launch wrapper's own
  watchdog) — §4.6 names all three separately because they cover different
  failure modes: a live-but-forgotten session (this one), a live scope
  Arbiter's own model of the host does not recognise (`OrphanReaper`), and
  Arbiter never coming back at all (the wrapper).

  ## Configuration

  Via `config :arbiter, :sessions_idle_reaper`:

    * `:enabled`     — master switch (default `true`; `false` in test, where
                       tests drive `reap/1` synchronously).
    * `:interval_ms` — sweep cadence (default 900 000, 15 minutes).
    * `:idle_ttl_ms` — age past last activity before a `:running`,
                       non-`keep_alive` session is reaped (default 86 400 000,
                       24 hours — §4.6's suggested figure).
    * `:fetch_limit` — max `:running` sessions scanned per sweep (default 200).
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Session

  @default_interval_ms 15 * 60_000
  @default_idle_ttl_ms 24 * 60 * 60_000
  @default_fetch_limit 200

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Reap every `:running`, non-`keep_alive` session whose last activity is older
  than `:idle_ttl_ms` (default from config, overridable via opts — mainly for
  tests). Each match is killed through `Arbiter.Sessions.kill/2` with a reason
  naming the deadline. Best-effort: a failure killing one session is logged
  and does not stop the sweep; a read failure is logged and the sweep is
  skipped this cycle.
  """
  @spec reap(keyword()) :: :ok
  def reap(opts \\ []) do
    idle_ttl_ms = Keyword.get(opts, :idle_ttl_ms, cfg(:idle_ttl_ms, @default_idle_ttl_ms))
    fetch_limit = Keyword.get(opts, :fetch_limit, cfg(:fetch_limit, @default_fetch_limit))
    now = Keyword.get(opts, :now, DateTime.utc_now())
    runner = Keyword.get(opts, :runner)

    Session
    |> Ash.Query.filter(status == :running and keep_alive == false)
    |> Ash.Query.limit(fetch_limit)
    |> Ash.read!()
    |> Enum.filter(&idle?(&1, now, idle_ttl_ms))
    |> Enum.each(&reap_one(&1, idle_ttl_ms, runner))

    :ok
  rescue
    e ->
      Logger.error("Arbiter.Sessions.IdleReaper sweep failed: #{Exception.message(e)}")
      :ok
  end

  @doc "The last-activity timestamp `reap/1` measures a session against."
  @spec last_activity(Session.t()) :: DateTime.t()
  def last_activity(%Session{last_client_at: c, last_turn_at: t, started_at: s}) do
    [c, t, s]
    |> Enum.filter(& &1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond))
  end

  defp idle?(session, now, idle_ttl_ms) do
    DateTime.diff(now, last_activity(session), :millisecond) >= idle_ttl_ms
  end

  defp reap_one(session, idle_ttl_ms, runner) do
    reason =
      "idle timeout: no client or turn activity for at least #{idle_ttl_ms}ms " <>
        "(§4.6 item 2) — pin keep_alive to exempt this session"

    kill_opts = if runner, do: [reason: reason, runner: runner], else: [reason: reason]

    case Sessions.kill(session.id, kill_opts) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error(
          "Arbiter.Sessions.IdleReaper failed to reap #{session.id}: #{inspect(error)}"
        )
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
  def handle_info(:reap, state) do
    reap()
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(pid, ms), do: Process.send_after(pid, :reap, ms)

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> cfg(key, default)
    end
  end

  defp cfg(key, default) do
    case get_in(Application.get_env(:arbiter, :sessions_idle_reaper, []), [key]) do
      nil -> default
      val -> val
    end
  end
end
