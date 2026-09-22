defmodule Arbiter.Agents.AuthHold do
  @moduledoc """
  The auth-shaped dispatch hold (bd-21bmdh): N consecutive `:auth_expired`
  worker deaths on one provider refuse every further dispatch for that
  provider until a recovery signal or an operator clears it.

  ## Why a count, not the first death

  bd-2jgs2h retired the per-dispatch live auth probe, so a worker dying at
  spawn is now the normal way the fleet learns a credential is bad. And a
  worker that dies with `:auth_expired` returns its task to Ready
  (`Arbiter.Worker.AuthDeath`) instead of stranding it `:in_progress`. Those
  two together make a single auth death a *retry*: the task goes back in the
  queue, and the next dispatch either works (a blip) or dies too. The second
  death is the evidence the credential really is dead — so that is where the
  hold opens (`:threshold`, default 2). Without the hold, reopening would
  feed the wave: every death would put its task straight back in the queue.

  "Consecutive" is per provider: a worker that *completes* on the provider
  (`record_success/2`) resets the streak, because it just proved the
  credential works.

  ## What an open hold does

    * `Arbiter.Worker.Dispatch`'s auth guard refuses any agent dispatch for
      the provider before the task transitions, before a worktree is
      provisioned and before a worker registers — `open?/2`.
    * `Arbiter.Board.Snapshot.quota_hold/1` shows it as the board-wide hold
      for a workspace whose default provider is held, so
      `Arbiter.Board.Autopilot` does not even attempt the dispatch — `held/2`.
    * Opening it marks `Arbiter.Agents.CredentialWatchdog` expired for the
      provider (`mark_expired/3`), which escalates once to every workspace's
      coordinator, reports `credentials_expired` on the quota surfaces, and
      switches the watchdog to its fast recovery poll.

  ## Fail-closed

  `open?/2` — the dispatch guard's read — answers `true` when the hold
  cannot be read at all (process down, call timed out). Every handler here is
  a map update, so a timeout is a genuine fault, and refusing a dispatch for
  one Autopilot tick is recoverable; a wave of 401ing spawns is the thing
  this exists to stop. `held/2`, the board's *display* read, fails open
  (`nil`) instead: the guard is the backstop, and the board must not paint a
  hold that is not there.

  Only a positive signal closes an open hold. A worker completing while it is
  open does not (it may have started before the credential died), and time
  passing does not.

  ## Reset paths

    1. **The watchdog's recovery signal.** `CredentialWatchdog` calls
       `recovered/2` whenever an expired adapter recovers: its own periodic
       probe passing, or `mark_recovered/2` from
       `Arbiter.Quota.CloudProbe` — the free usage-poll check passing
       (Claude's `/api/oauth/usage`, Codex's usage GET, agy's `/usage`).
       CloudProbe sends it on a passing check whenever this hold is open, not
       only after its own 401 streak.
    2. **An operator.** `breaker_reset` with `provider` (MCP),
       `POST /api/breakers/reset` with `provider`, or
       `arb breaker reset --auth-hold <provider>` → `reset/2`. Clears the
       streak and the watchdog mark the hold set. `breaker_list` /
       `arb breaker list` show every hold and live streak.

  An automatic recovery leaves the provider on **probation**: the next auth
  death re-opens the hold at once instead of after another N. The free checks
  read the operator's host credentials, which are not always the ones a
  worker spawns with (a per-workspace token, a provider account), so "the
  free check passes" and "workers still die" can both be true. Probation
  bounds that case to one death per recovery signal rather than N; a worker
  completing on the provider ends probation. An operator reset is a full
  reset — no probation.

  ## State is in-memory

  Like `CredentialWatchdog` and `Arbiter.CircuitBreaker`, a restart clears
  every hold. The worst case is N more fast auth deaths before it re-opens
  (and the free checks re-mark the watchdog within two poll cycles). Each
  task additionally carries its own bound — `Arbiter.Worker.AuthDeath` stops
  reopening a task after `:max_task_reopens` auth deaths — so no restart
  pattern can cycle one task forever.

  ## Configuration

      config :arbiter, :auth_hold,
        threshold: 2,          # consecutive auth deaths that open the hold
        max_task_reopens: 3    # auth deaths after which a task is no longer reopened

  Explicit `start_link/1` opts outrank app env for `:threshold` (tests).
  """

  use GenServer

  require Logger

  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Worker.StopReason

  @default_threshold 2
  @default_max_task_reopens 3

  @typedoc "Per-provider hold state."
  @type entry :: %{
          deaths: non_neg_integer(),
          open?: boolean(),
          probation?: boolean(),
          opened_at: DateTime.t() | nil,
          reason: map() | nil
        }

  # ---- public API ----------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Record an `:auth_expired` worker death on `adapter`.

  Returns `:counted` (streak below the threshold), `:opened` (this death
  opened the hold) or `:held` (already open). `:unavailable` if the hold
  process could not be reached — the caller has nothing else to do about it.
  """
  @spec record_death(module(), StopReason.t(), GenServer.server()) ::
          :counted | :opened | :held | :unavailable
  def record_death(adapter, %StopReason{} = reason, server \\ __MODULE__)
      when is_atom(adapter) do
    GenServer.call(server, {:record_death, adapter, reason}, 5_000)
  catch
    :exit, _ -> :unavailable
  end

  @doc """
  A worker on `adapter` completed: the credential works, so the streak (and
  any probation) resets. Does not close an open hold. Fire-and-forget.
  """
  @spec record_success(module(), GenServer.server()) :: :ok
  def record_success(adapter, server \\ __MODULE__) when is_atom(adapter) do
    GenServer.cast(server, {:record_success, adapter})
  end

  @doc """
  A recovery signal for `adapter` (sent by `CredentialWatchdog` when an
  expired adapter recovers). Closes an open hold onto probation; otherwise
  just resets the streak. Idempotent. Fire-and-forget.
  """
  @spec recovered(module(), GenServer.server()) :: :ok
  def recovered(adapter, server \\ __MODULE__) when is_atom(adapter) do
    GenServer.cast(server, {:recovered, adapter})
  end

  @doc """
  Whether dispatch for `adapter` is held. **Fail-closed**: `true` when the
  hold cannot be read. This is the dispatch guard's read.
  """
  @spec open?(module(), GenServer.server()) :: boolean()
  def open?(adapter, server \\ __MODULE__) when is_atom(adapter) do
    GenServer.call(server, {:open?, adapter}, 1_000)
  catch
    :exit, _ -> true
  end

  @doc """
  The open hold for `adapter` as a display map, or `nil` when it is not open
  — or cannot be read (fails open; see the moduledoc). The board's read.
  """
  @spec held(module(), GenServer.server()) :: map() | nil
  def held(adapter, server \\ __MODULE__) when is_atom(adapter) do
    case GenServer.call(server, {:status, adapter}, 1_000) do
      %{open?: true} = status -> status
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc "The full state for `adapter` (a zeroed entry when nothing is recorded)."
  @spec status(module(), GenServer.server()) :: map()
  def status(adapter, server \\ __MODULE__) when is_atom(adapter) do
    GenServer.call(server, {:status, adapter}, 1_000)
  end

  @doc "Every provider with an open hold or a live streak. `[]` if unreadable."
  @spec list(GenServer.server()) :: [map()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list, 1_000)
  catch
    :exit, _ -> []
  end

  @doc """
  Operator reset: clear `adapter`'s hold (or every provider's, with `:all`)
  — streak, probation and the `CredentialWatchdog` mark an open hold set.
  Returns `{:ok, adapters_that_were_open}`.
  """
  @spec reset(module() | :all, GenServer.server()) :: {:ok, [module()]}
  def reset(adapter_or_all, server \\ __MODULE__)
      when is_atom(adapter_or_all) do
    GenServer.call(server, {:reset, adapter_or_all}, 5_000)
  end

  @doc "Consecutive auth deaths that open a hold (opts › app env › #{@default_threshold})."
  @spec threshold(keyword()) :: pos_integer()
  def threshold(opts \\ []), do: config(:threshold, opts, @default_threshold)

  @doc """
  Auth deaths after which `Arbiter.Worker.AuthDeath` stops returning a task
  to Ready (app env › #{@default_max_task_reopens}).
  """
  @spec max_task_reopens() :: pos_integer()
  def max_task_reopens, do: config(:max_task_reopens, [], @default_max_task_reopens)

  # ---- GenServer -----------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       adapters: %{},
       opts: opts,
       credential_watchdog: Keyword.get(opts, :credential_watchdog, CredentialWatchdog)
     }}
  end

  @impl true
  def handle_call({:record_death, adapter, reason}, _from, state) do
    entry = entry(state, adapter)
    threshold = threshold(state.opts)

    cond do
      entry.open? ->
        {:reply, :held, put_entry(state, adapter, %{entry | deaths: entry.deaths + 1})}

      entry.probation? or entry.deaths + 1 >= threshold ->
        deaths = entry.deaths + 1
        {:reply, :opened, put_entry(state, adapter, open(state, adapter, entry, deaths, reason))}

      true ->
        {:reply, :counted, put_entry(state, adapter, %{entry | deaths: entry.deaths + 1})}
    end
  end

  def handle_call({:open?, adapter}, _from, state),
    do: {:reply, entry(state, adapter).open?, state}

  def handle_call({:status, adapter}, _from, state),
    do: {:reply, render(state, adapter, entry(state, adapter)), state}

  def handle_call(:list, _from, state) do
    listing =
      state.adapters
      |> Enum.filter(fn {_adapter, e} -> e.open? or e.deaths > 0 or e.probation? end)
      |> Enum.sort_by(fn {adapter, _} -> inspect(adapter) end)
      |> Enum.map(fn {adapter, e} -> render(state, adapter, e) end)

    {:reply, listing, state}
  end

  def handle_call({:reset, :all}, _from, state) do
    was_open = for {adapter, %{open?: true}} <- state.adapters, do: adapter
    Enum.each(was_open, &clear_watchdog(state, &1))
    {:reply, {:ok, was_open}, %{state | adapters: %{}}}
  end

  def handle_call({:reset, adapter}, _from, state) do
    was_open = if entry(state, adapter).open?, do: [adapter], else: []
    Enum.each(was_open, &clear_watchdog(state, &1))

    if was_open != [] do
      Logger.info("AuthHold: #{name(adapter)} dispatch hold cleared by operator reset")
    end

    {:reply, {:ok, was_open}, %{state | adapters: Map.delete(state.adapters, adapter)}}
  end

  @impl true
  def handle_cast({:record_success, adapter}, state) do
    entry = entry(state, adapter)

    if entry.open? do
      {:noreply, state}
    else
      {:noreply, put_entry(state, adapter, %{entry | deaths: 0, probation?: false})}
    end
  end

  def handle_cast({:recovered, adapter}, state) do
    entry = entry(state, adapter)

    if entry.open? do
      Logger.info(
        "AuthHold: #{name(adapter)} dispatch hold cleared by a recovery signal " <>
          "(on probation: the next auth death re-opens it)"
      )

      {:noreply,
       put_entry(state, adapter, %{
         entry
         | open?: false,
           probation?: true,
           deaths: 0,
           opened_at: nil,
           reason: nil
       })}
    else
      {:noreply, put_entry(state, adapter, %{entry | deaths: 0})}
    end
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  # ---- internals ----------------------------------------------------------

  defp open(state, adapter, entry, deaths, %StopReason{} = reason) do
    hold_reason = hold_stop_reason(adapter, deaths, reason)

    Logger.warning(
      "AuthHold: #{name(adapter)} dispatch hold OPEN after #{deaths} consecutive " <>
        "auth death(s) — #{reason.summary}"
    )

    # Escalates (once) to every workspace and flips the quota surfaces'
    # `credentials_expired`; the watchdog's recovery then calls `recovered/2`.
    CredentialWatchdog.mark_expired(adapter, hold_reason, state.credential_watchdog)

    %{
      entry
      | deaths: deaths,
        open?: true,
        probation?: false,
        opened_at: DateTime.utc_now(),
        reason: StopReason.to_map(hold_reason)
    }
  end

  defp hold_stop_reason(adapter, deaths, %StopReason{} = reason) do
    provider = name(adapter)

    %StopReason{
      reason
      | summary:
          "#{deaths} consecutive #{provider} worker(s) died on auth — dispatch for " <>
            "#{provider} is held (last: #{reason.summary})",
        remediation:
          "Re-authenticate the #{provider} CLI. The hold clears on its own when the " <>
            "free credential check or the CredentialWatchdog probe next passes, and the " <>
            "reopened tasks then dispatch again. To clear it by hand: " <>
            "`arb breaker reset --auth-hold #{provider_key(adapter)}`."
    }
  end

  defp clear_watchdog(state, adapter),
    do: CredentialWatchdog.mark_recovered(adapter, state.credential_watchdog)

  defp entry(state, adapter), do: Map.get(state.adapters, adapter, empty_entry())

  defp empty_entry,
    do: %{deaths: 0, open?: false, probation?: false, opened_at: nil, reason: nil}

  defp put_entry(state, adapter, entry),
    do: %{state | adapters: Map.put(state.adapters, adapter, entry)}

  defp render(state, adapter, entry) do
    Map.merge(entry, %{
      adapter: adapter,
      provider: provider_key(adapter),
      threshold: threshold(state.opts)
    })
  end

  # The agent-type key ("claude", "codex", "gemini") an operator types.
  defp provider_key(adapter) do
    case Enum.find(Arbiter.Agents.adapters(), fn {_type, mod} -> mod == adapter end) do
      {type, _} -> Atom.to_string(type)
      nil -> name(adapter) |> String.downcase()
    end
  end

  defp name(adapter), do: adapter |> Module.split() |> List.last()

  defp config(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 ->
        value

      _ ->
        case Keyword.get(Application.get_env(:arbiter, :auth_hold, []), key) do
          value when is_integer(value) and value > 0 -> value
          _ -> default
        end
    end
  end
end
