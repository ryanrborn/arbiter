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
    * **Auth hold** — a worker dying with `:auth_expired` no longer marks this
      module directly. It feeds `Arbiter.Agents.AuthHold`'s per-provider streak
      (bd-21bmdh), and the hold calls `mark_expired/3` once N consecutive deaths
      open it — a single death is now a retry, not a fleet-wide refusal. In
      return, every recovery here (a passing periodic probe, or
      `mark_recovered/2`) is forwarded to `AuthHold.recovered/2`, which is what
      clears an open hold automatically.
    * **Usage-poll mark** — `Arbiter.Quota.CloudProbe` also calls `mark_expired/3`
      for Claude after N consecutive `{:http_error, 401}` responses from the
      `/api/oauth/usage` poll (bd-1pmf9h, default N=2). This is a second,
      independent expiry signal alongside the periodic CLI probe above — the
      original incident this closes went undetected for ~15h because the CLI
      probe never saw trouble until the credentials file was removed outright,
      while the usage poll had been 401ing (and, in between, hitting the
      endpoint's own tight rate-limit bucket) the whole time.

  A successful probe on a previously-expired adapter clears the expired flag
  and schedules the next poll at the normal interval. While an adapter is
  known-expired the Watchdog polls at the shorter `:recovery_interval_ms` so it
  detects credential restoration promptly.

  ## This is the only live probe left (bd-2jgs2h)

  `Arbiter.Worker.Dispatch` used to run its own live CLI probe on every
  dispatch and resume (`Arbiter.Worker.Dispatch.run_preflight/2`, via
  `Arbiter.Agents.Preflight.check/2`) — ~760 billed probes/day fleet-wide
  against 10 auth failures in 90 days, half of them mid-run and thus
  unreachable by any pre-flight check anyway. That probe was retired
  2026-09-18; `Dispatch`'s guard is now a free call to `expired?/1` on this
  module's held state, never a live CLI call. See `docs/quota-and-auth.md`
  for the full evidence and posture.

  That makes this module's own periodic probe (below) the *only* live probe
  left anywhere in the fleet, and an entirely optional one: the dispatch
  guard, `mark_expired/2` (from `AuthHold`, after N dying workers) and `mark_recovered/2` (from
  the usage-poll signal) all keep working off held state with **no probing at
  all**. Setting `:adapters` to `[]` — as already done for `gemini` here,
  cutting it from ~180 probes/day to 26 — is a supported, intentional
  low-cost posture, not a gap to route around. See "Configuration" below for
  what you give up by doing so (organic detection + auto-recovery for
  adapters nothing else watches).

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
  into GenServer state at `init/1` — mirroring how `Arbiter.Board.Snapshot`
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

  alias Arbiter.Agents.AuthHold
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
  Returns `true` if `adapter` has an outstanding credential-expiry escalation
  recorded, from *any* source (`:periodic_probe`, `:worker_report`, or
  `:usage_poll`).

  This is not the dispatch gate — see `expired?/2` for that. The two diverge
  for a `:usage_poll`-raised expiry (bd-6jjgk0 finding 1): `Arbiter.Quota
  .CloudProbe`'s `/api/oauth/usage` poll reads a credential the worker CLI
  never touches (#1875), so it raises/restates a mailbox escalation here
  without ever closing the dispatch gate on its own. Safe to call from any
  process; returns `false` if the Watchdog is not running.

  Exposed for tests and diagnostics (asserting episode state without reaching
  into the mailbox); no production caller depends on it.
  """
  @spec escalated?(module(), GenServer.server()) :: boolean()
  def escalated?(adapter, server \\ __MODULE__) when is_atom(adapter) do
    GenServer.call(server, {:escalated?, adapter}, 1_000)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Immediately mark `adapter` as credential-expired and raise coordinator escalations.

  Called by `Arbiter.Agents.AuthHold` when N consecutive `:auth_expired` worker
  deaths open its hold (bd-21bmdh), and by `Arbiter.Quota.CloudProbe`'s free
  401-streak signals, so the Watchdog records the failure and blocks future
  dispatches without waiting for the next periodic probe. Fire-and-forget; best-effort.
  Pass a `server` pid/name to target a specific instance (useful in tests).

  `source` tags *which* signal raised this (`:worker_report` — the default,
  covering `AuthHold` deaths — `:usage_poll`, or `:periodic_probe`) and is
  remembered alongside the expiry. Only a recovery signal carrying the same
  `source` is allowed to clear it (see `mark_recovered/3`) — this is what
  keeps a `CloudProbe` usage-poll expiry from being wiped out by an unrelated
  passing CLI probe mid-episode (bd-6jjgk0).
  """
  @spec mark_expired(module(), StopReason.t(), GenServer.server(), atom()) :: :ok
  def mark_expired(
        adapter,
        %StopReason{} = reason,
        server \\ __MODULE__,
        source \\ :worker_report
      )
      when is_atom(adapter) and is_atom(source) do
    GenServer.cast(server, {:mark_expired, adapter, reason, source})
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Clear `adapter`'s expired mark following an independent success signal.

  Called by `Arbiter.Quota.CloudProbe` when a `/api/oauth/usage` poll succeeds,
  so a usage-poll-detected expiry (`mark_expired/4`) can also recover without
  waiting for the Watchdog's own periodic CLI probe — the symmetric
  counterpart to that signal (bd-1pmf9h). A no-op if `adapter` isn't marked
  expired *by this same `source`* (bd-6jjgk0) — a periodic CLI probe passing
  does not clear an expiry that a usage-poll streak raised, since that probe
  reads a separately cached token (#1875) and its success says nothing about
  the usage poll's own credential. Fire-and-forget; best-effort. Pass a
  `server` pid/name to target a specific instance (useful in tests).
  """
  @spec mark_recovered(module(), GenServer.server(), atom()) :: :ok
  def mark_recovered(adapter, server \\ __MODULE__, source \\ :worker_report)
      when is_atom(adapter) and is_atom(source) do
    GenServer.cast(server, {:mark_recovered, adapter, source})
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  # Point this instance's recovery forwarding at a specific `AuthHold` (tests
  # pairing a private hold with a private watchdog).
  @spec set_auth_hold(GenServer.server(), GenServer.server()) :: :ok
  def set_auth_hold(auth_hold, server \\ __MODULE__) do
    GenServer.call(server, {:set_auth_hold, auth_hold})
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
  Every adapter with an outstanding expiry, as a display map — the operator
  inspection surface bd-3kg53c adds so "what does the Watchdog know" has an
  answer that doesn't require guessing which adapter to ask `expired?/2`
  about. `[]` when nothing is expired anywhere, or if the Watchdog cannot be
  reached (fails open, like `AuthHold.list/1`; a display read).

  Each entry: `%{adapter:, provider:, gated?:, sources: [%{source:, summary:}]}`.
  `gated?` mirrors `expired?/1` for this adapter (only `:periodic_probe` /
  `:worker_report` close the dispatch gate — see the moduledoc's `gate_source?/1`
  discussion); a `:usage_poll`-only entry is an outstanding mailbox episode
  that is not currently blocking dispatch.
  """
  @spec list(GenServer.server()) :: [map()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list_expired, 1_000)
  rescue
    _ -> []
  catch
    :exit, _ -> []
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
      adapters: %{},
      gate: Map.new(probe_adapters(opts), &{&1, :ok}),
      opts: opts,
      enabled: enabled,
      auth_hold: Keyword.get(opts, :auth_hold, AuthHold)
    }

    if enabled do
      schedule(self(), 0)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:expired?, adapter}, _from, state) do
    {:reply, Map.get(state.gate, adapter, :ok) != :ok, state}
  end

  @impl true
  def handle_call({:escalated?, adapter}, _from, state) do
    {:reply, adapter_escalated?(state, adapter), state}
  end

  def handle_call({:set_auth_hold, auth_hold}, _from, state),
    do: {:reply, :ok, %{state | auth_hold: auth_hold}}

  @impl true
  def handle_call(:reset, _from, state) do
    cleared_gate = Map.new(state.gate, fn {k, _} -> {k, :ok} end)
    {:reply, :ok, %{state | adapters: %{}, gate: cleared_gate}}
  end

  @impl true
  def handle_call(:list_expired, _from, state) do
    entries =
      state.adapters
      |> Enum.map(fn {adapter, per_source} -> list_entry(state, adapter, per_source) end)
      |> Enum.reject(&(&1.sources == []))

    {:reply, entries, state}
  end

  @impl true
  def handle_cast({:mark_expired, adapter, reason, source}, state) do
    if already_expired?(state, adapter, source) do
      # Still outstanding — don't touch `state.adapters`/`state.gate`, but do
      # restate the existing escalation so a growing counter (e.g. CloudProbe's
      # "N consecutive 401s") is visible on the one row instead of frozen at
      # whatever N it happened to be when the episode opened (bd-6jjgk0 finding 1
      # round 2). `credential_expired/5` already restates in place when a row is
      # outstanding (see `restate_credential_escalation/2`), so this reuses that
      # path rather than inserting anything new.
      gate_closed? = Map.get(state.gate, adapter, :ok) != :ok
      escalate_all(adapter, reason, source, gate_closed?)
      {:noreply, state}
    else
      {:noreply, record_expiry(state, adapter, reason, source)}
    end
  end

  @impl true
  def handle_cast({:mark_recovered, adapter, source}, state) do
    {:noreply, on_probe_ok(state, adapter, source)}
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
    Enum.reduce(adapters, state, fn adapter, acc -> probe_one(acc, adapter) end)
  end

  defp probe_one(state, adapter) do
    case safe_check(adapter) do
      :ok ->
        on_probe_ok(state, adapter, :periodic_probe)

      :skipped ->
        on_probe_ok(state, adapter, :periodic_probe)

      {:error, %StopReason{category: :auth_expired} = reason} ->
        if already_expired?(state, adapter, :periodic_probe) do
          Logger.debug(
            "CredentialWatchdog: #{adapter_name(adapter)} still expired (periodic re-check)"
          )

          state
        else
          record_expiry(state, adapter, reason, :periodic_probe)
        end

      # bd-svczq4: the probe outran its own watchdog. That is the one outcome
      # that says nothing about the credentials, so it is advisory only — it
      # must neither mark the adapter expired (which would refuse every
      # dispatch fleet-wide off a slow probe) nor count as a healthy probe and
      # clear a mark a dying worker just set. Leave the state exactly as it is.
      # See the decision section in `Arbiter.Agents.Preflight`'s moduledoc.
      {:warn, %StopReason{} = reason} ->
        Logger.warning(
          "CredentialWatchdog: #{adapter_name(adapter)} probe timed out, " <>
            "leaving its state unchanged — #{reason.summary}"
        )

        state

      {:error, %StopReason{}} ->
        # Rate-limit, crash, or other non-auth failure — don't mark as
        # credential-expired. The periodic poll will keep running.
        state
    end
  end

  # bd-21bmdh: every accepted recovery is also the `AuthHold` reset signal — a
  # hold that N worker deaths opened marked this adapter expired, and this
  # transition is how it clears without an operator.
  #
  # bd-6jjgk0: each adapter tracks one independent episode *per source* in
  # `state.adapters` (`%{adapter => %{source => {:expired, reason_map}}}`),
  # not one shared status. That is what lets a `:usage_poll` episode (raised
  # by `Arbiter.Quota.CloudProbe`'s `/api/oauth/usage` poll, which reads a
  # separately cached token, #1875) stay open on its own row while a
  # `:periodic_probe`/`:worker_report` expiry for the very same adapter is
  # independently recorded, escalated, and closes the gate (finding 1 —
  # sharing one row meant `already_expired?` silently dropped the second
  # source's expiry entirely). `recovers?/2` decides, per outstanding source,
  # whether *this* recovery signal is allowed to close that source's episode:
  # `:usage_poll` only recovers `:usage_poll` (its cached token says nothing
  # about the worker-facing credential and vice versa — finding 2), while
  # `:periodic_probe` and `:worker_report` recover each other, since both
  # read the credential workers actually dispatch with.
  defp on_probe_ok(state, adapter, recovering_source) do
    state = maybe_open_gate(state, adapter, recovering_source)
    per_source = Map.get(state.adapters, adapter, %{})

    {to_clear, remaining} =
      Enum.split_with(per_source, fn {raised_source, status} ->
        match?({:expired, _}, status) and recovers?(raised_source, recovering_source)
      end)

    if to_clear == [] do
      state
    else
      Logger.info("CredentialWatchdog: #{adapter_name(adapter)} credentials recovered")
      AuthHold.recovered(adapter, state.auth_hold)

      Enum.each(to_clear, fn {raised_source, _status} -> recover_all(adapter, raised_source) end)

      %{state | adapters: Map.put(state.adapters, adapter, Map.new(remaining))}
    end
  end

  defp recovers?(:usage_poll, recovering_source), do: recovering_source == :usage_poll
  defp recovers?(_raised_source, recovering_source), do: recovering_source != :usage_poll

  # `:usage_poll` (`Arbiter.Quota.CloudProbe`'s `/api/oauth/usage`-family poll)
  # reads a credential the worker CLI never touches (#1875) — it must never
  # close the dispatch gate, only raise/restate its own mailbox episode. Only
  # a signal that reads what workers actually dispatch with — the Watchdog's
  # own periodic CLI probe, or N worker deaths via `AuthHold` — is allowed to
  # close (or reopen) it. Before this, both sources wrote the same map that
  # both `expired?/1` and the escalation dedupe read, so a `:usage_poll`
  # episode held the gate closed for its whole duration even while the CLI
  # probe kept passing and workers kept dispatching fine (bd-6jjgk0 finding 1).
  defp gate_source?(:usage_poll), do: false
  defp gate_source?(_), do: true

  defp maybe_open_gate(state, adapter, source) do
    if gate_source?(source) do
      %{state | gate: Map.put(state.gate, adapter, :ok)}
    else
      state
    end
  end

  defp record_expiry(state, adapter, reason, source) do
    source_label = source_label(source)

    Logger.warning(
      "CredentialWatchdog: #{adapter_name(adapter)} credentials expired " <>
        "(detected via #{source_label}) — #{reason.summary}"
    )

    new_gate =
      if gate_source?(source) do
        Map.put(state.gate, adapter, {:expired, StopReason.to_map(reason)})
      else
        state.gate
      end

    gate_closed? = Map.get(new_gate, adapter, :ok) != :ok

    escalate_all(adapter, reason, source, gate_closed?)

    new_adapters =
      Map.update(
        state.adapters,
        adapter,
        %{source => {:expired, StopReason.to_map(reason)}},
        &Map.put(&1, source, {:expired, StopReason.to_map(reason)})
      )

    %{state | adapters: new_adapters, gate: new_gate}
  end

  defp source_label(:periodic_probe), do: "periodic probe"
  defp source_label(:usage_poll), do: "usage poll"
  defp source_label(_), do: "worker report"

  defp already_expired?(state, adapter, source) do
    case state.adapters |> Map.get(adapter, %{}) |> Map.get(source) do
      {:expired, _} -> true
      _ -> false
    end
  end

  defp adapter_escalated?(state, adapter) do
    state.adapters
    |> Map.get(adapter, %{})
    |> Map.values()
    |> Enum.any?(&match?({:expired, _}, &1))
  end

  # Send a coordinator escalation to every active workspace. Best-effort — a DB
  # hiccup or an empty workspace table must not crash the Watchdog.
  #
  # `gate_closed?` is this adapter's *actual* dispatch-gate state right after
  # this expiry was recorded (see `record_expiry/4` / `gate_source?/1`), not
  # inferred from `source` — a `:usage_poll` expiry leaves it `false` unless a
  # gate-source expiry also happens to be outstanding, so the escalation text
  # never claims dispatches are suspended when they are not (bd-6jjgk0 finding 1).
  defp escalate_all(adapter, %StopReason{} = reason, source, gate_closed?) do
    safe(fn ->
      workspaces = Ash.read!(Arbiter.Tasks.Workspace)

      Enum.each(workspaces, fn ws ->
        CoordinatorNotifier.credential_expired(
          %{workspace_id: ws.id},
          adapter,
          reason,
          source,
          gate_closed?
        )
      end)
    end)
  end

  # Mirrors `escalate_all/3`: tells every active workspace's coordinator
  # mailbox that `adapter` recovered, clearing whatever `credential_expired/4`
  # escalation is still outstanding for it (bd-6jjgk0) so the next expiry
  # starts a fresh episode rather than looking like a continuation of this
  # one. `source` is the one that actually recovered (and matched the one
  # that raised it, per `on_probe_ok/4` above) — passed through so the
  # cleared/restored message names the right episode. Best-effort, same as
  # `escalate_all/3`.
  defp recover_all(adapter, source) do
    safe(fn ->
      workspaces = Ash.read!(Arbiter.Tasks.Workspace)

      Enum.each(workspaces, fn ws ->
        CoordinatorNotifier.credential_restored(%{workspace_id: ws.id}, adapter, source)
      end)
    end)
  end

  # Scoped to the adapters we actually probe: an adapter that was marked expired
  # by a worker report but is no longer in the probe list can never recover via
  # a probe, so it must not pin the whole fleet to the fast recovery interval.
  # With no override configured the probe list is every adapter, so this is
  # identical to the previous whole-map check.
  defp next_interval(state, adapters) do
    if Enum.any?(adapters, &(Map.get(state.gate, &1, :ok) != :ok)) do
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

  defp list_entry(state, adapter, per_source) do
    sources =
      per_source
      |> Enum.filter(fn {_source, status} -> match?({:expired, _}, status) end)
      |> Enum.map(fn {source, {:expired, reason_map}} ->
        %{source: source, summary: Map.get(reason_map, :summary)}
      end)

    %{
      adapter: adapter,
      provider: provider_key(adapter),
      gated?: Map.get(state.gate, adapter, :ok) != :ok,
      sources: sources
    }
  end

  # The agent-type key ("claude", "codex", "gemini") an operator types —
  # mirrors `Arbiter.Agents.AuthHold.provider_key/1` so the two operator
  # surfaces (`arb breaker list`'s `auth_holds` and this `credential_watchdog`
  # inspection) name providers the same way.
  defp provider_key(adapter) do
    case Enum.find(Arbiter.Agents.adapters(), fn {_type, mod} -> mod == adapter end) do
      {type, _} -> Atom.to_string(type)
      nil -> adapter_name(adapter) |> String.downcase()
    end
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
