defmodule GtElixir.Polecat do
  @moduledoc """
  A `Polecat` is the unit of agent work in Gas Town: a supervised GenServer
  driving a single bead through a workflow (load → design → implement → verify
  → submit).

  This module is the Phase 2 skeleton — it provides the lifecycle, registry,
  and status FSM. The actual workflow logic ships separately as the
  `GtElixir.Polecat.Workflow` behaviour (gte-014) and the driver that walks
  steps lives in a later phase.

  ## Status FSM

      :idle      → :running     (advance/2 from :idle)
      :running   → :awaiting    (await/2  — parked waiting on external event)
      :awaiting  → :running     (resume/1)
      :running   → :completed   (complete/2 — normal exit)
      :running   → :failed      (fail/2)
      :awaiting  → :failed      (fail/2)

  Illegal transitions return `{:error, {:invalid_transition, from, to}}`.

  ## API choice: explicit `await/2` etc. vs sentinel atoms

  The spec gave us a choice between an `advance(pid, :__awaiting__)` sentinel
  and a split API (`advance/2`, `await/2`, `resume/1`, `complete/2`,
  `fail/2`). We picked the split API: each verb has a single meaning, the
  status FSM lives in dispatch heads rather than in a dictionary of sentinels,
  and the type signature is honest about what `advance/2` does (change the
  workflow step, not change the lifecycle state).

  ## Registry

  Each polecat registers under `GtElixir.Polecat.Registry` keyed by `bead_id`.
  Use `whereis/1` to look up by bead_id; most API functions accept either a
  pid or a bead_id string.

  ## Supervision

  Polecats are started under `GtElixir.Polecat.Supervisor`
  (a `DynamicSupervisor`) with `restart: :temporary`. A crashed polecat is
  not restarted — workflow runners that crash have lost their state, so
  resurrecting the GenServer would just confuse the orchestrator.
  """

  use GenServer

  alias GtElixir.Polecat.Registry, as: PRegistry

  @typedoc "Lifecycle status — distinct from `Issue.status`."
  @type status :: :idle | :running | :awaiting | :completed | :failed

  @typedoc "Current workflow step. Free-form atom; `:idle` until first advance."
  @type step :: atom()

  @typedoc "Accepted by most API functions in lieu of a bare pid."
  @type ref :: pid() | String.t()

  @typedoc "Snapshot returned by `state/1`."
  @type snapshot :: %{
          bead_id: String.t(),
          workspace_id: String.t() | nil,
          rig: String.t(),
          current_step: step(),
          status: status(),
          started_at: DateTime.t(),
          step_started_at: DateTime.t() | nil,
          meta: map()
        }

  defmodule State do
    @moduledoc false
    defstruct [
      :bead_id,
      :workspace_id,
      :rig,
      :current_step,
      :status,
      :started_at,
      :step_started_at,
      :meta
    ]
  end

  # ---- public API ---------------------------------------------------------

  @doc """
  Start a polecat under the dynamic supervisor.

  Required opts:
    * `:bead_id` — string, used as the registry key.
    * `:rig`    — string, the repo/project key the polecat operates on.

  Optional opts:
    * `:workspace_id` — string.
    * `:meta`         — initial map of workflow-specific state.
  """
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(GtElixir.Polecat.Supervisor, {__MODULE__, opts})
  end

  @doc """
  `GenServer.start_link/3`-style entry point. Prefer `start/1` for normal use.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.fetch(opts, :bead_id) do
      {:ok, bead_id} when is_binary(bead_id) and bead_id != "" ->
        case Keyword.fetch(opts, :rig) do
          {:ok, rig} when is_binary(rig) and rig != "" ->
            GenServer.start_link(__MODULE__, opts, name: PRegistry.via_tuple(bead_id))

          _ ->
            {:error, :missing_rig}
        end

      _ ->
        {:error, :missing_bead_id}
    end
  end

  @doc """
  Return the pid of the polecat registered for `bead_id`, or `nil`.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(bead_id) when is_binary(bead_id), do: PRegistry.whereis(bead_id)

  @doc """
  Return a snapshot of the polecat's state, or `nil` if no polecat is
  registered for the given bead_id.
  """
  @spec state(ref()) :: snapshot() | nil
  def state(pid) when is_pid(pid), do: GenServer.call(pid, :snapshot)

  def state(bead_id) when is_binary(bead_id) do
    case whereis(bead_id) do
      nil -> nil
      pid -> state(pid)
    end
  end

  @doc """
  Advance the workflow step. Permitted when status is `:idle` (transitions to
  `:running`) or `:running` (stays `:running`).
  """
  @spec advance(ref(), step()) :: :ok | {:error, term()}
  def advance(ref, step) when is_atom(step), do: call(ref, {:advance, step})

  @doc """
  Park the polecat — status becomes `:awaiting`. Only valid from `:running`.
  """
  @spec await(ref(), term()) :: :ok | {:error, term()}
  def await(ref, reason \\ nil), do: call(ref, {:await, reason})

  @doc """
  Resume a parked polecat. Only valid from `:awaiting`.
  """
  @spec resume(ref()) :: :ok | {:error, term()}
  def resume(ref), do: call(ref, :resume)

  @doc """
  Mark the workflow completed. Only valid from `:running`. The polecat keeps
  running (so callers can read the final state) but rejects further
  transitions.
  """
  @spec complete(ref(), term()) :: :ok | {:error, term()}
  def complete(ref, result \\ nil), do: call(ref, {:complete, result})

  @doc """
  Mark the workflow failed. Valid from `:running` or `:awaiting`.
  """
  @spec fail(ref(), term()) :: :ok | {:error, term()}
  def fail(ref, reason \\ nil), do: call(ref, {:fail, reason})

  @doc """
  Record an arbitrary key/value pair in the polecat's `:meta` map.
  """
  @spec report(ref(), atom() | String.t(), term()) :: :ok | {:error, term()}
  def report(ref, key, value), do: call(ref, {:report, key, value})

  @doc """
  Stop the polecat cleanly.
  """
  @spec stop(ref(), term()) :: :ok | {:error, :not_found}
  def stop(ref, reason \\ :normal)
  def stop(pid, reason) when is_pid(pid), do: GenServer.stop(pid, reason)

  def stop(bead_id, reason) when is_binary(bead_id) do
    case whereis(bead_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.stop(pid, reason)
    end
  end

  # ---- GenServer callbacks -----------------------------------------------

  @impl true
  def init(opts) do
    now = DateTime.utc_now()

    state = %State{
      bead_id: Keyword.fetch!(opts, :bead_id),
      workspace_id: Keyword.get(opts, :workspace_id),
      rig: Keyword.fetch!(opts, :rig),
      current_step: :idle,
      status: :idle,
      started_at: now,
      step_started_at: nil,
      meta: Keyword.get(opts, :meta, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:advance, step}, _from, %State{status: :idle} = state) do
    new_state = %State{
      state
      | current_step: step,
        status: :running,
        step_started_at: DateTime.utc_now()
    }

    {:reply, :ok, new_state}
  end

  def handle_call({:advance, step}, _from, %State{status: :running} = state) do
    new_state = %State{state | current_step: step, step_started_at: DateTime.utc_now()}
    {:reply, :ok, new_state}
  end

  def handle_call({:advance, step}, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, {:advance, step}}}, state}
  end

  def handle_call({:await, reason}, _from, %State{status: :running} = state) do
    meta =
      case reason do
        nil -> state.meta
        r -> Map.put(state.meta, :await_reason, r)
      end

    {:reply, :ok, %State{state | status: :awaiting, meta: meta}}
  end

  def handle_call({:await, _reason}, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, :awaiting}}, state}
  end

  def handle_call(:resume, _from, %State{status: :awaiting} = state) do
    {:reply, :ok, %State{state | status: :running, meta: Map.delete(state.meta, :await_reason)}}
  end

  def handle_call(:resume, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, :running}}, state}
  end

  def handle_call({:complete, result}, _from, %State{status: :running} = state) do
    meta =
      case result do
        nil -> state.meta
        r -> Map.put(state.meta, :result, r)
      end

    {:reply, :ok, %State{state | status: :completed, meta: meta}}
  end

  def handle_call({:complete, _result}, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, :completed}}, state}
  end

  def handle_call({:fail, reason}, _from, %State{status: status} = state)
      when status in [:running, :awaiting] do
    meta =
      case reason do
        nil -> state.meta
        r -> Map.put(state.meta, :failure_reason, r)
      end

    {:reply, :ok, %State{state | status: :failed, meta: meta}}
  end

  def handle_call({:fail, _reason}, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, :failed}}, state}
  end

  def handle_call({:report, key, value}, _from, %State{} = state) do
    {:reply, :ok, %State{state | meta: Map.put(state.meta, key, value)}}
  end

  # ---- child_spec --------------------------------------------------------

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  # ---- internals ---------------------------------------------------------

  defp call(pid, msg) when is_pid(pid), do: GenServer.call(pid, msg)

  defp call(bead_id, msg) when is_binary(bead_id) do
    case whereis(bead_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, msg)
    end
  end

  defp snapshot(%State{} = s) do
    %{
      bead_id: s.bead_id,
      workspace_id: s.workspace_id,
      rig: s.rig,
      current_step: s.current_step,
      status: s.status,
      started_at: s.started_at,
      step_started_at: s.step_started_at,
      meta: s.meta
    }
  end
end
