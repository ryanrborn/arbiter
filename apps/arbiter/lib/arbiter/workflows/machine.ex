defmodule Arbiter.Workflows.Machine do
  @moduledoc """
  Workflow driver. A `GenStateMachine` per workflow instance that walks a
  `Arbiter.Workflow` module's declared steps for a specific bead,
  persisting progress to the DB on every transition so a crash + restart
  resumes at the same step.

  Pair with `Arbiter.Polecat` for orchestration: the polecat owns the
  agent process (load → design → implement etc.), the machine owns the
  *workflow's* step transitions. They collaborate but neither owns the
  other.

  ## Lifecycle

      attach(workflow_module, bead_id, vars)  →  {:ok, id}    # row created, idle
      start(id)                               →  {:ok, pid}   # GenStateMachine alive
      advance(id_or_pid)                      →  {:ok, next_step | :completed}
      pause(id_or_pid)  / resume(id_or_pid)   →  :ok
      Process.exit(pid, :kill); start(id)     →  resumes at the same current_step

  ## FSM states

  The GenStateMachine FSM state mirrors the `:status` field on
  `MachineState`: one of `:idle | :running | :paused | :completed |
  :failed`. The status is the source of truth for whether `advance/1` is
  allowed (`:idle`, `:running`) or rejected (`:paused`, `:completed`,
  `:failed`).

  ## Per-transition DB write

  Every successful or failed advance writes back to the `MachineState`
  row via `Ash.update/2` **before** returning to the caller. This makes
  crash-recovery trivial — the in-memory and on-disk state agree at every
  observable boundary. It also makes fast workflows N+1ish on writes;
  acceptable at this phase, batchable in Phase 5 if measurement shows it.

  ## Security: workflow_module loading

  The `workflow_module` column is a string. On `start/1` we reconstitute
  it via `Module.safe_concat/1` and then verify that the resulting atom
  implements the `Arbiter.Workflow` behaviour. Any module that does not
  is rejected with `{:error, :not_a_workflow}`. This is the allowlist —
  the surface attacker would need to compromise to load arbitrary code is
  "drop a module into the build that already declares the Workflow
  behaviour", which is identical to the surface they'd need to do
  anything else in the system.
  """

  use GenStateMachine, callback_mode: :handle_event_function

  alias Arbiter.Workflows.MachineRegistry
  alias Arbiter.Workflows.MachineState

  @type id :: String.t()
  @type ref :: id() | pid()
  @type status :: :idle | :running | :paused | :completed | :failed
  @type step :: atom()

  # Sentinel `current_step` value indicating the workflow is finished.
  @done :__done__

  defmodule Data do
    @moduledoc false
    defstruct [
      :id,
      :workflow_module,
      :bead_id,
      :vars,
      :current_step,
      :completed_steps,
      :state
    ]
  end

  # ---- public API ---------------------------------------------------------

  @doc """
  Attach a workflow to a bead. Creates a `MachineState` row in `:idle`
  status with `current_step` set to the workflow's first step. Does *not*
  start a GenStateMachine — call `start/1` to begin executing.

  `vars` should be a map of the workflow's declared `vars/0` keys.
  """
  @spec attach(module(), String.t(), map()) :: {:ok, id()} | {:error, term()}
  def attach(workflow_module, bead_id, vars \\ %{})
      when is_atom(workflow_module) and is_binary(bead_id) and is_map(vars) do
    with :ok <- validate_workflow_module(workflow_module) do
      first_step =
        case workflow_module.steps() do
          [head | _] -> head
          [] -> @done
        end

      stringified_vars = stringify_keys(vars)

      attrs = %{
        workflow_module: inspect(workflow_module),
        bead_id: bead_id,
        vars: stringified_vars,
        current_step: Atom.to_string(first_step),
        status: :idle,
        completed_steps: [],
        state: stringified_vars,
        error_reason: nil
      }

      case Ash.create(MachineState, attrs) do
        {:ok, row} -> {:ok, row.id}
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc """
  Start a `GenStateMachine` from a persisted `MachineState` row id.

  The process is registered under `Arbiter.Workflows.MachineRegistry`
  with `id` as the key, so a subsequent `start/1` with the same id while
  the machine is alive returns `{:error, {:already_started, pid}}`.

  The machine runs under `Arbiter.Workflows.MachineSupervisor` (a
  `DynamicSupervisor`), so it is **not** linked to the caller. This
  matters for short-lived callers like HTTP request handlers: linking
  would cause the machine to die when the handler returned.
  """
  @spec start(id()) :: {:ok, pid()} | {:error, term()}
  def start(id) when is_binary(id) do
    case DynamicSupervisor.start_child(
           Arbiter.Workflows.MachineSupervisor,
           {__MODULE__, id}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:error, {:already_started, pid}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec start_link(id()) :: GenStateMachine.on_start()
  def start_link(id) when is_binary(id) do
    with {:ok, row} <- get_row(id),
         {:ok, mod} <- load_workflow_module(row.workflow_module) do
      data = %Data{
        id: row.id,
        workflow_module: mod,
        bead_id: row.bead_id,
        vars: row.vars || %{},
        current_step: string_to_step(row.current_step),
        completed_steps: Enum.map(row.completed_steps || [], &String.to_existing_atom/1),
        state: row.state || %{}
      }

      GenStateMachine.start_link(__MODULE__, {row.status, data},
        name: MachineRegistry.via_tuple(id)
      )
    end
  end

  @doc false
  def child_spec(id) when is_binary(id) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [id]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "Return the pid for `id`, or `nil`."
  @spec whereis(id()) :: pid() | nil
  def whereis(id) when is_binary(id), do: MachineRegistry.whereis(id)

  @doc "Return the next step that will execute on `advance/1`."
  @spec current_step(ref()) :: step() | nil
  def current_step(ref), do: call(ref, :current_step)

  @doc "Return the current status atom (`:idle | :running | :paused | :completed | :failed`)."
  @spec status(ref()) :: status() | nil
  def status(ref), do: call(ref, :status)

  @doc "Return the threaded state map (the value passed to `run_step/2`)."
  @spec state_data(ref()) :: map() | nil
  def state_data(ref), do: call(ref, :state_data)

  @doc """
  Execute the next step. Persists the transition before returning.

  Returns:

    * `{:ok, next_step_atom}` — step succeeded, more remain
    * `{:ok, :completed}` — step succeeded, workflow done
    * `{:error, :paused}` — workflow is paused
    * `{:error, :already_done}` — workflow already completed
    * `{:error, :already_failed}` — workflow already failed
    * `{:error, {:unmet_needs, [...]}}` — the next step's `needs:` aren't met
    * `{:error, {:bad_return, term}}` — `run_step/2` returned something invalid
    * `{:error, reason}` — `run_step/2` returned `{:error, reason}`
  """
  @spec advance(ref()) :: {:ok, step() | :completed} | {:error, term()}
  def advance(ref), do: call(ref, :advance)

  @doc "Set status to `:paused`. Idempotent."
  @spec pause(ref()) :: :ok | {:error, term()}
  def pause(ref), do: call(ref, :pause)

  @doc "Set status to `:running`. Only valid from `:paused`."
  @spec resume(ref()) :: :ok | {:error, term()}
  def resume(ref), do: call(ref, :resume)

  @doc "Stop a running machine cleanly. Does not remove the row."
  @spec stop(ref(), term()) :: :ok | {:error, :not_found}
  def stop(ref, reason \\ :normal)
  def stop(pid, reason) when is_pid(pid), do: GenStateMachine.stop(pid, reason)

  def stop(id, reason) when is_binary(id) do
    case whereis(id) do
      nil -> {:error, :not_found}
      pid -> GenStateMachine.stop(pid, reason)
    end
  end

  @doc """
  Reconstitute a workflow module name (string) to its atom form, then
  verify it implements `Arbiter.Workflow`.
  """
  @spec load_workflow_module(String.t()) :: {:ok, module()} | {:error, term()}
  def load_workflow_module(name) when is_binary(name) do
    mod = Module.safe_concat([name])

    case validate_workflow_module(mod) do
      :ok -> {:ok, mod}
      {:error, _} = err -> err
    end
  rescue
    ArgumentError -> {:error, :unknown_module}
  end

  # ---- GenStateMachine callbacks -----------------------------------------

  @impl true
  def init({status, %Data{} = data}) do
    {:ok, status, data}
  end

  # `current_step` query — always reply with the current step atom.
  @impl true
  def handle_event({:call, from}, :current_step, _status, %Data{current_step: cs} = data) do
    {:keep_state, data, [{:reply, from, cs}]}
  end

  def handle_event({:call, from}, :status, status, data) do
    {:keep_state, data, [{:reply, from, status}]}
  end

  def handle_event({:call, from}, :state_data, _status, %Data{state: s} = data) do
    {:keep_state, data, [{:reply, from, s}]}
  end

  # advance — gated by status
  def handle_event({:call, from}, :advance, :paused, data) do
    {:keep_state, data, [{:reply, from, {:error, :paused}}]}
  end

  def handle_event({:call, from}, :advance, :completed, data) do
    {:keep_state, data, [{:reply, from, {:error, :already_done}}]}
  end

  def handle_event({:call, from}, :advance, :failed, data) do
    {:keep_state, data, [{:reply, from, {:error, :already_failed}}]}
  end

  def handle_event({:call, from}, :advance, status, %Data{} = data)
      when status in [:idle, :running] do
    do_advance(from, data)
  end

  # pause / resume
  def handle_event({:call, from}, :pause, status, %Data{} = data)
      when status in [:paused, :completed, :failed] do
    # idempotent for :paused; reject for terminal states
    case status do
      :paused ->
        {:keep_state, data, [{:reply, from, :ok}]}

      _ ->
        {:keep_state, data,
         [{:reply, from, {:error, {:invalid_transition, status, :paused}}}]}
    end
  end

  def handle_event({:call, from}, :pause, status, %Data{} = data)
      when status in [:idle, :running] do
    case persist(data, :paused, nil) do
      :ok -> {:next_state, :paused, data, [{:reply, from, :ok}]}
      {:error, err} -> {:keep_state, data, [{:reply, from, {:error, err}}]}
    end
  end

  def handle_event({:call, from}, :resume, :paused, %Data{} = data) do
    case persist(data, :running, nil) do
      :ok -> {:next_state, :running, data, [{:reply, from, :ok}]}
      {:error, err} -> {:keep_state, data, [{:reply, from, {:error, err}}]}
    end
  end

  def handle_event({:call, from}, :resume, status, %Data{} = data) do
    {:keep_state, data,
     [{:reply, from, {:error, {:invalid_transition, status, :running}}}]}
  end

  # ---- transition logic --------------------------------------------------

  defp do_advance(from, %Data{current_step: @done} = data) do
    case persist(data, :completed, nil) do
      :ok ->
        {:next_state, :completed, data, [{:reply, from, {:ok, :completed}}]}

      {:error, err} ->
        {:keep_state, data, [{:reply, from, {:error, err}}]}
    end
  end

  defp do_advance(from, %Data{workflow_module: mod, current_step: step} = data) do
    definition = mod.step_definition(step)
    missing = Enum.reject(definition.needs, &(&1 in data.completed_steps))

    cond do
      missing != [] ->
        {:keep_state, data, [{:reply, from, {:error, {:unmet_needs, missing}}}]}

      true ->
        case safe_run_step(mod, step, data.state) do
          {:ok, new_state} when is_map(new_state) ->
            new_completed = data.completed_steps ++ [step]
            next_step = next_step(mod.steps(), step)
            new_data = %Data{data | state: new_state, completed_steps: new_completed, current_step: next_step}

            case persist(new_data, advance_status(next_step), nil) do
              :ok ->
                reply =
                  case next_step do
                    @done -> {:ok, :completed}
                    s -> {:ok, s}
                  end

                next_fsm_state =
                  case next_step do
                    @done -> :completed
                    _ -> :running
                  end

                {:next_state, next_fsm_state, new_data, [{:reply, from, reply}]}

              {:error, err} ->
                {:keep_state, data, [{:reply, from, {:error, err}}]}
            end

          {:error, reason} ->
            fail_with(from, data, reason)

          other ->
            fail_with(from, data, {:bad_return, other})
        end
    end
  end

  defp safe_run_step(mod, step, state) do
    mod.run_step(step, state)
  rescue
    e -> {:error, {:exception, Exception.format(:error, e, __STACKTRACE__)}}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp fail_with(from, %Data{} = data, reason) do
    case persist(data, :failed, inspect(reason)) do
      :ok ->
        {:next_state, :failed, data, [{:reply, from, {:error, reason}}]}

      {:error, err} ->
        # Even DB write failed; reply with original failure reason — operator
        # gets the workflow error, DB error goes to logs.
        require Logger
        Logger.error("WorkflowMachine #{data.id}: failed to persist :failed status: #{inspect(err)}")
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp advance_status(@done), do: :completed
  defp advance_status(_), do: :running

  defp next_step(steps, current) do
    case Enum.drop_while(steps, &(&1 != current)) do
      [^current, next | _] -> next
      [^current] -> @done
      _ -> @done
    end
  end

  # ---- persistence -------------------------------------------------------

  defp persist(%Data{id: id} = data, status, error_reason) do
    attrs = %{
      current_step: Atom.to_string(data.current_step),
      status: status,
      completed_steps: Enum.map(data.completed_steps, &Atom.to_string/1),
      state: data.state,
      error_reason: error_reason
    }

    with {:ok, row} <- Ash.get(MachineState, id),
         {:ok, _updated} <- Ash.update(row, attrs) do
      :ok
    else
      {:error, err} -> {:error, err}
    end
  end

  defp get_row(id) do
    case Ash.get(MachineState, id) do
      {:ok, row} -> {:ok, row}
      {:error, _} = err -> err
    end
  end

  # ---- helpers -----------------------------------------------------------

  defp call(pid, msg) when is_pid(pid), do: GenStateMachine.call(pid, msg)

  defp call(id, msg) when is_binary(id) do
    case whereis(id) do
      nil -> nil
      pid -> GenStateMachine.call(pid, msg)
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp string_to_step(@done), do: @done
  defp string_to_step("__done__"), do: @done

  defp string_to_step(str) when is_binary(str) do
    # The atom must already exist — it's a declared step on the workflow
    # module, which has been loaded before this is called.
    String.to_existing_atom(str)
  end

  defp validate_workflow_module(mod) when is_atom(mod) do
    cond do
      not Code.ensure_loaded?(mod) ->
        {:error, :unknown_module}

      not function_exported?(mod, :steps, 0) ->
        {:error, :not_a_workflow}

      not function_exported?(mod, :run_step, 2) ->
        {:error, :not_a_workflow}

      not implements_workflow_behaviour?(mod) ->
        {:error, :not_a_workflow}

      true ->
        :ok
    end
  end

  defp validate_workflow_module(_), do: {:error, :not_a_workflow}

  defp implements_workflow_behaviour?(mod) do
    behaviours =
      mod.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    Arbiter.Workflow in behaviours
  end

  # ---- terminate ---------------------------------------------------------

  @impl true
  def terminate(_reason, _status, %Data{id: id}) do
    MachineRegistry.unregister(id)
    :ok
  end
end
