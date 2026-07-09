defmodule Arbiter.Agents.CredentialWatchdog do
  @moduledoc """
  Fleet-level credential liveness monitor (bd-5wchp1).

  Runs as a singleton named GenServer and periodically probes each configured
  agent adapter via `Arbiter.Agents.Preflight.check/2`. When a probe returns
  `:auth_expired` the Watchdog:

    1. Records the adapter as credential-expired in its own state.
    2. Escalates to the Admiral across every active workspace so the operator
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

  Via `config :arbiter, :credential_watchdog`:

    * `:interval_ms`          — normal probe interval (default 5 minutes).
    * `:recovery_interval_ms` — re-probe interval while expired (default 1 min).
    * `:adapters`             — list of adapter modules to probe. Defaults to
                                all adapters in `Arbiter.Agents.adapters/0`.
    * `:enabled`              — set to `false` to disable all probing (default
                                `true`; set to `false` in the test config so the
                                suite never calls the real agent CLI).
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
  Immediately mark `adapter` as credential-expired and raise Admiral escalations.

  Called by `Arbiter.Worker.fail_stopped/2` when an worker dies with category
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

  # ---- GenServer -----------------------------------------------------------

  @impl true
  def init(opts) do
    interval_ms = watchdog_config(:interval_ms, opts, @default_interval_ms)
    recovery_ms = watchdog_config(:recovery_interval_ms, opts, @default_recovery_interval_ms)
    adapters = watchdog_config(:adapters, opts, nil) || default_adapters()
    enabled = watchdog_config(:enabled, opts, true)

    state = %{
      adapters: Map.new(adapters, &{&1, :ok}),
      interval_ms: interval_ms,
      recovery_interval_ms: recovery_ms,
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
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:check, state) do
    new_state = run_checks(state)
    schedule(self(), next_interval(new_state))
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- internals ----------------------------------------------------------

  defp run_checks(state) do
    Enum.reduce(state.adapters, state, fn {adapter, current}, acc ->
      probe_one(acc, adapter, current)
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

  # Send an Admiral escalation to every active workspace. Best-effort — a DB
  # hiccup or an empty workspace table must not crash the Watchdog.
  defp escalate_all(adapter, %StopReason{} = reason) do
    safe(fn ->
      workspaces = Ash.read!(Arbiter.Tasks.Workspace)

      Enum.each(workspaces, fn ws ->
        CoordinatorNotifier.credential_expired(%{workspace_id: ws.id}, adapter, reason)
      end)
    end)
  end

  defp next_interval(%{adapters: adapters, interval_ms: interval, recovery_interval_ms: recovery}) do
    if Enum.any?(adapters, fn {_, v} -> v != :ok end), do: recovery, else: interval
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

  defp adapter_name(adapter) when is_atom(adapter) do
    adapter |> Module.split() |> List.last()
  end

  defp watchdog_config(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        case get_in(Application.get_env(:arbiter, :credential_watchdog, []), [key]) do
          nil -> default
          val -> val
        end
    end
  end
end
