defmodule Arbiter.Agents.CredentialWatchdog do
  @moduledoc """
  Fleet-level credential liveness monitor (bd-5wchp1).

  Runs as a singleton named GenServer and periodically probes each configured
  agent adapter via `Arbiter.Agents.Preflight.check/2`. When a probe returns
  `:auth_expired` the Watchdog:

    1. Records the adapter as credential-expired in its own state.
    2. Escalates to the coordinator across every active workspace so the operator
       is notified before any worker has to fail first.

  The stored state feeds two guards:

    * **Dispatch guard** — `Arbiter.Worker.Dispatch` calls `expired?/1` before
      dispatching a real worker. A known-expired adapter is refused immediately
      without re-running the probe, preventing a wave of identical 401 failures.
    * **Early mark** — `Arbiter.Worker` calls `mark_expired/2` when a worker
      dies with `:auth_expired`, so the Watchdog records the failure immediately
      rather than waiting for the next periodic probe.

  A successful probe on a previously-expired adapter clears the expired flag
  and schedules the next poll at the normal interval. While an adapter is
  known-expired the Watchdog polls at the shorter `:recovery_interval_ms` so it
  detects credential restoration promptly.

  ## Configuration

  Resolution order for `:adapters`, `:interval_ms` and `:recovery_interval_ms`
  (highest wins):

    1. explicit `start_link/1` opts (used by tests and embedded callers),
    2. `Arbiter.Settings` — the runtime-settable install-wide singleton
       (`credential_watchdog_adapters`, `credential_watchdog_interval_ms`,
       `credential_watchdog_recovery_interval_ms`), writable over MCP via
       `installation_config_set`,
    3. `config :arbiter, :credential_watchdog`,
    4. the hardcoded defaults below.

  These three are **re-resolved at the top of every poll cycle**, not frozen
  into GenServer state at `init/1` — mirroring how `Arbiter.Workflows.Conductor`
  consults `Arbiter.Settings.conductor_system_max_concurrent/0` inline. So
  dropping an adapter from the probe list (e.g. `codex`, whose probe is a real
  billed round-trip against the ChatGPT backend) takes effect on the next tick
  with no restart. The per-adapter *expiry* map is ordinary GenServer state and
  keeps persisting across polls as before.

  One consequence worth knowing: an adapter that is already marked expired and
  is then removed from the probe list keeps that mark (nothing probes it, so
  nothing can clear it) and stays refused by the dispatch guard. `mark_expired/3`
  likewise still records adapters outside the probe list. Use `reset/1` to clear.

  Settings:

    * `:interval_ms`          — normal probe interval (default 5 minutes).
    * `:recovery_interval_ms` — re-probe interval while expired (default 1 min).
    * `:adapters`             — adapters to probe. Adapter modules (opts / app
                                env) or agent-type name strings (`Arbiter.Settings`).
                                Unset probes all of `Arbiter.Agents.adapters/0`;
                                `[]` probes nothing.
    * `:enabled`              — set to `false` to disable all probing (default
                                `true`; set to `false` in the test config so the
                                suite never calls the real agent CLI). Read once
                                at `init/1` — unlike the three above, changing it
                                does require a restart.
  """

  use GenServer

  require Logger

  alias Arbiter.Agents.Preflight
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Worker.StopReason

  @default_interval_ms 300_000
  @default_recovery_interval_ms 60_000

  # ---- public API ----------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Returns `true` if `adapter`'s credentials are known to be expired.

  Safe to call from any process. Returns `false` if the Watchdog is not running
  (e.g. in test with `:enabled` false, or before it has started).
  Pass a `server` pid/name to target a specific instance (useful in tests).
  """
  @spec expired?(module(), GenServer.server()) :: boolean()
  def expired?(adapter, server \\ __MODULE__) when is_atom(adapter) do
    GenServer.call(server, {:expired?, adapter}, 1_000)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Immediately mark `adapter` as credential-expired and raise coordinator escalations.

  Called by `Arbiter.Worker.fail_stopped/2` when a worker dies with category
  `:auth_expired`, so the Watchdog records the failure and blocks future dispatches
  without waiting for the next periodic probe. Fire-and-forget; best-effort.
  Pass a `server` pid/name to target a specific instance (useful in tests).
  """
  @spec mark_expired(module(), StopReason.t(), GenServer.server()) :: :ok
  def mark_expired(adapter, %StopReason{} = reason, server \\ __MODULE__)
      when is_atom(adapter) do
    GenServer.cast(server, {:mark_expired, adapter, reason})
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Reset the Watchdog's per-adapter state to `:ok` (all credentials considered valid).
  Intended for test isolation only. The probe interval timer is unaffected.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @doc """
  The adapter modules that the next poll cycle will probe, resolved live
  (opts › `Arbiter.Settings` › app env › all of `Arbiter.Agents.adapters/0`).

  Pure — safe to call from anywhere, including to preview the effect of a
  settings change. Unknown names are dropped rather than raising, so a stale
  entry in the persisted list can never take the Watchdog down.
  """
  @spec probe_adapters(keyword()) :: [module()]
  def probe_adapters(opts \\ []) do
    case watchdog_config(:adapters, opts, nil) do
      nil -> default_adapters()
      list when is_list(list) -> list |> Enum.map(&to_adapter_module/1) |> Enum.reject(&is_nil/1)
      _ -> default_adapters()
    end
  end

  @doc "The normal poll interval (ms), resolved live. See `probe_adapters/1`."
  @spec poll_interval_ms(keyword()) :: pos_integer()
  def poll_interval_ms(opts \\ []),
    do: watchdog_config(:interval_ms, opts, @default_interval_ms)

  @doc "The while-expired re-probe interval (ms), resolved live."
  @spec recovery_interval_ms(keyword()) :: pos_integer()
  def recovery_interval_ms(opts \\ []),
    do: watchdog_config(:recovery_interval_ms, opts, @default_recovery_interval_ms)

  # ---- GenServer -----------------------------------------------------------

  @impl true
  def init(opts) do
    enabled = watchdog_config(:enabled, opts, true)

    # `opts` is kept so each poll can re-resolve the adapter list and intervals
    # (explicit opts still outrank Settings/app env). The `adapters` map is the
    # per-adapter *expiry* state and persists across polls as before; seeding it
    # here is just an initial all-healthy snapshot.
    state = %{
      adapters: Map.new(probe_adapters(opts), &{&1, :ok}),
      opts: opts,
      enabled: enabled
    }

    if enabled do
      schedule(self(), 0)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:expired?, adapter}, _from, state) do
    {:reply, Map.get(state.adapters, adapter, :ok) != :ok, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    cleared = Map.new(state.adapters, fn {k, _} -> {k, :ok} end)
    {:reply, :ok, %{state | adapters: cleared}}
  end

  @impl true
  def handle_cast({:mark_expired, adapter, reason}, state) do
    if already_expired?(state, adapter) do
      {:noreply, state}
    else
      {:noreply, record_expiry(state, adapter, reason, :worker_report)}
    end
  end

  @impl true
  def handle_info(:check, %{enabled: false} = state) do
    schedule(self(), poll_interval_ms(state.opts))
    {:noreply, state}
  end

  def handle_info(:check, state) do
    # Re-resolve the probe list on every tick so a runtime settings change
    # applies now rather than on the next restart.
    adapters = probe_adapters(state.opts)
    new_state = run_checks(state, adapters)
    schedule(self(), next_interval(new_state, adapters))
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- internals ----------------------------------------------------------

  defp run_checks(state, adapters) do
    Enum.reduce(adapters, state, fn adapter, acc ->
      probe_one(acc, adapter, Map.get(acc.adapters, adapter, :ok))
    end)
  end

  defp probe_one(state, adapter, current_status) do
    case safe_check(adapter) do
      :ok ->
        on_probe_ok(state, adapter, current_status)

      :skipped ->
        on_probe_ok(state, adapter, current_status)

      {:error, %StopReason{category: :auth_expired} = reason} ->
        if already_expired?(state, adapter) do
          Logger.debug(
            "CredentialWatchdog: #{adapter_name(adapter)} still expired (periodic re-check)"
          )

          state
        else
          record_expiry(state, adapter, reason, :periodic_probe)
        end

      {:error, %StopReason{}} ->
        # Rate-limit, crash, or other non-auth failure — don't mark as
        # credential-expired. The periodic poll will keep running.
        state
    end
  end

  defp on_probe_ok(state, adapter, {:expired, _}) do
    Logger.info("CredentialWatchdog: #{adapter_name(adapter)} credentials recovered")
    %{state | adapters: Map.put(state.adapters, adapter, :ok)}
  end

  defp on_probe_ok(state, _adapter, :ok), do: state

  defp record_expiry(state, adapter, reason, source) do
    source_label = if source == :periodic_probe, do: "periodic probe", else: "worker report"

    Logger.warning(
      "CredentialWatchdog: #{adapter_name(adapter)} credentials expired " <>
        "(detected via #{source_label}) — #{reason.summary}"
    )

    escalate_all(adapter, reason)
    %{state | adapters: Map.put(state.adapters, adapter, {:expired, StopReason.to_map(reason)})}
  end

  defp already_expired?(state, adapter) do
    case Map.get(state.adapters, adapter, :ok) do
      {:expired, _} -> true
      _ -> false
    end
  end

  # Send a coordinator escalation to every active workspace. Best-effort — a DB
  # hiccup or an empty workspace table must not crash the Watchdog.
  defp escalate_all(adapter, %StopReason{} = reason) do
    safe(fn ->
      workspaces = Ash.read!(Arbiter.Tasks.Workspace)

      Enum.each(workspaces, fn ws ->
        CoordinatorNotifier.credential_expired(%{workspace_id: ws.id}, adapter, reason)
      end)
    end)
  end

  # Scoped to the adapters we actually probe: an adapter that was marked expired
  # by a worker report but is no longer in the probe list can never recover via
  # a probe, so it must not pin the whole fleet to the fast recovery interval.
  # With no override configured the probe list is every adapter, so this is
  # identical to the previous whole-map check.
  defp next_interval(state, adapters) do
    if Enum.any?(adapters, &(Map.get(state.adapters, &1, :ok) != :ok)) do
      recovery_interval_ms(state.opts)
    else
      poll_interval_ms(state.opts)
    end
  end

  defp schedule(pid, ms) do
    Process.send_after(pid, :check, ms)
  end

  defp safe_check(adapter) do
    Preflight.check(adapter, [])
  rescue
    e -> {:error, probe_unavailable_reason(Exception.message(e))}
  catch
    :exit, reason -> {:error, probe_unavailable_reason(inspect(reason))}
  end

  defp probe_unavailable_reason(detail) do
    %StopReason{
      category: :crashed,
      summary: "credential probe failed to run: #{detail}",
      remediation: nil,
      exit_status: nil,
      signal: nil
    }
  end

  defp safe(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("CredentialWatchdog.escalate_all swallowed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp default_adapters, do: Map.values(Arbiter.Agents.adapters())

  # Accepts either an adapter module (opts / app env) or an agent-type name
  # (`Arbiter.Settings`, which persists strings). Anything unrecognized maps to
  # nil and is dropped by the caller.
  defp to_adapter_module(name) when is_binary(name) do
    case safe_existing_atom(name) do
      nil -> nil
      type -> Map.get(Arbiter.Agents.adapters(), type)
    end
  end

  defp to_adapter_module(mod) when is_atom(mod) and not is_nil(mod) do
    Map.get(Arbiter.Agents.adapters(), mod, mod)
  end

  defp to_adapter_module(_), do: nil

  defp safe_existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp adapter_name(adapter) when is_atom(adapter) do
    adapter |> Module.split() |> List.last()
  end

  # opts › Arbiter.Settings › app env › hardcoded default. `nil` at any layer
  # means "not set here, keep looking" — a literal `false` (`:enabled`) is a
  # real value and stops the search.
  defp watchdog_config(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> resolve_override(settings_override(key), app_env(key), default)
    end
  end

  defp resolve_override(nil, nil, default), do: default
  defp resolve_override(nil, app_value, _default), do: app_value
  defp resolve_override(settings_value, _app_value, _default), do: settings_value

  defp settings_override(:adapters), do: Arbiter.Settings.credential_watchdog_adapters()
  defp settings_override(:interval_ms), do: Arbiter.Settings.credential_watchdog_interval_ms()

  defp settings_override(:recovery_interval_ms),
    do: Arbiter.Settings.credential_watchdog_recovery_interval_ms()

  defp settings_override(_key), do: nil

  defp app_env(key), do: get_in(Application.get_env(:arbiter, :credential_watchdog, []), [key])
end
