defmodule Arbiter.Sessions.Heartbeat do
  @moduledoc """
  Touches arbiter's own liveness file while this instance is up (§4.6.3,
  phase 10, bd-3qkbch) — the input side of the in-scope dead-man's switch.

  A session's watchdog (`Arbiter.Sessions.Provisioning`'s generated
  `watchdog.sh`) needs to answer "is arbiter still around?" without ever
  connecting *to* arbiter — the whole point is that it must keep working if
  arbiter never comes back at all (§4.2's measured case: `systemctl --user
  stop arbiter.service` and the scope keeps serving indefinitely). A file
  whose mtime this process refreshes periodically, and which simply goes
  stale when this process is gone, needs no network, no auth and no arbiter
  process to be alive to be *read* — only to have been *written*, at some
  point in the past, by an instance that was.

  Inert wherever `XDG_RUNTIME_DIR` is unset (no systemd user session, e.g. a
  bare container or the test suite) — there is nowhere to put the file and
  nothing to watch it in that case anyway.

  ## Configuration

  Via `config :arbiter, :sessions_heartbeat`:

    * `:enabled`     — master switch (default `true`; `false` in test).
    * `:interval_ms` — touch cadence (default 60 000, 1 minute — comfortably
                       inside any sane dead-man's-switch grace window).
  """

  use GenServer

  require Logger

  alias Arbiter.Sessions.Naming

  @default_interval_ms 60_000

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Touch the heartbeat file now. `:ok` even when there is nowhere to put it."
  @spec touch() :: :ok
  def touch do
    case Naming.heartbeat_path() do
      {:ok, path} ->
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, DateTime.to_iso8601(DateTime.utc_now())) do
          :ok
        else
          {:error, reason} ->
            Logger.warning(
              "Arbiter.Sessions.Heartbeat could not write #{inspect(path)}: #{inspect(reason)}"
            )

            :ok
        end

      {:error, :no_runtime_dir} ->
        :ok
    end
  end

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg_opt(:enabled, opts, true),
      interval_ms: cfg_opt(:interval_ms, opts, @default_interval_ms)
    }

    if state.enabled do
      touch()
      schedule(self(), state.interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:touch, state) do
    touch()
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(pid, ms), do: Process.send_after(pid, :touch, ms)

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        case get_in(Application.get_env(:arbiter, :sessions_heartbeat, []), [key]) do
          nil -> default
          val -> val
        end
    end
  end
end
