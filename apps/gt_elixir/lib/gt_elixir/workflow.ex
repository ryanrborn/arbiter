defmodule GtElixir.Workflow do
  @moduledoc """
  Behaviour + macro DSL for defining workflows (the Elixir port of the Go GT
  "formula" system).

  In Go GT, formulas were YAML workflow templates (e.g. `mol-polecat-work`,
  `mol-polecat-code-review`). In gt-elixir, they are plain Elixir modules
  that `use GtElixir.Workflow` and declare a series of `step` definitions.

  ## Example

      defmodule Examples.Boring do
        use GtElixir.Workflow,
          steps: [:greet, :wave]

        step :greet, description: "Say hi", needs: [], vars: [:name]
        step :wave, description: "Wave goodbye", needs: [:greet], vars: []

        def run_step(:greet, %{name: name} = state) do
          {:ok, Map.update(state, :events, ["greet:\#{name}"], &["greet:\#{name}" | &1])}
        end

        def run_step(:wave, state) do
          {:ok, Map.update(state, :events, ["wave"], &["wave" | &1])}
        end
      end

  Then:

      iex> GtElixir.Workflow.run(Examples.Boring, %{name: "Ryan"})
      {:ok, %{name: "Ryan", events: ["wave", "greet:Ryan"], completed_steps: [:greet, :wave]}}

  ## Behaviour callbacks

    * `steps/0` — returns the declared step atoms in declaration order.
    * `step_definition/1` — returns `%{description, needs, vars}` for a step.
    * `vars/0` — union of all step `:vars`, deduped.
    * `run_step/2` — executes a step, returning `{:ok, new_state}` or
      `{:error, reason}`.

  ## Composition (Phase 5)

  `use GtElixir.Workflow` accepts `extends:`, `expansions:`, and `aspects:`
  options today. They are stored on the module as attributes but **not yet
  processed**. The shape is design-correct so Phase 5 can implement
  composition without rewriting call sites. See `extends/0`, `expansions/0`,
  `aspects/0`.

  ## Compile-time validation

    * Every atom in `steps:` must have a matching `step :name, ...` declaration.
    * Every `step :name, ...` declaration must appear in `steps:`.
    * Each step's `needs:` must reference a step that exists in `steps:`.

  Violations raise `CompileError` with a clear message.
  """

  @type step :: atom()
  @type state :: map()
  @type step_definition :: %{
          required(:description) => String.t(),
          required(:needs) => [step()],
          required(:vars) => [atom()]
        }

  @callback steps() :: [step()]
  @callback step_definition(step()) :: step_definition()
  @callback vars() :: [atom()]
  @callback run_step(step(), state()) :: {:ok, state()} | {:error, term()}

  defmacro __using__(opts) do
    steps = Keyword.fetch!(opts, :steps)

    unless is_list(steps) and Enum.all?(steps, &is_atom/1) do
      raise CompileError,
        description: "GtElixir.Workflow: `steps:` must be a list of atoms, got: #{inspect(steps)}"
    end

    # TODO Phase 5: process these options to compose workflows.
    # `extends:`    — a single workflow module to inherit from
    # `expansions:` — keyword list mapping insertion-point atom => workflow module
    #                 (e.g. [tdd_cycle: :implement] expands :implement into a
    #                 sub-workflow defined elsewhere)
    # `aspects:`    — keyword list mapping aspect module => target step atom
    #                 (cross-cutting concerns, like :security_audit before :submit)
    extends = Keyword.get(opts, :extends, nil)
    expansions = Keyword.get(opts, :expansions, [])
    aspects = Keyword.get(opts, :aspects, [])

    quote do
      @behaviour GtElixir.Workflow

      Module.register_attribute(__MODULE__, :__workflow_step_definitions, accumulate: true)

      @__workflow_steps unquote(steps)
      @__workflow_extends unquote(extends)
      @__workflow_expansions unquote(expansions)
      @__workflow_aspects unquote(aspects)

      import GtElixir.Workflow, only: [step: 2]

      @before_compile GtElixir.Workflow
    end
  end

  @doc """
  Declares a step's metadata. Must appear inside a `use GtElixir.Workflow`
  module.

  Accumulates into `@__workflow_step_definitions`; clauses for
  `step_definition/1` are generated at `@before_compile` time.
  """
  defmacro step(name, opts) when is_atom(name) do
    quote do
      @__workflow_step_definitions {unquote(name), unquote(opts)}
    end
  end

  defmacro __before_compile__(env) do
    module = env.module
    steps = Module.get_attribute(module, :__workflow_steps)

    # Accumulated attributes come back in reverse insertion order.
    declared =
      module
      |> Module.get_attribute(:__workflow_step_definitions)
      |> Enum.reverse()

    declared_names = Enum.map(declared, fn {n, _} -> n end)
    steps_set = MapSet.new(steps)
    declared_set = MapSet.new(declared_names)

    missing = Enum.reject(steps, &MapSet.member?(declared_set, &1))

    if missing != [] do
      raise CompileError,
        description:
          "GtElixir.Workflow #{inspect(module)}: steps declared in `use` but " <>
            "missing `step :name, ...` definition(s): #{inspect(missing)}"
    end

    orphans = Enum.reject(declared_names, &MapSet.member?(steps_set, &1))

    if orphans != [] do
      raise CompileError,
        description:
          "GtElixir.Workflow #{inspect(module)}: `step :name, ...` defined for " <>
            "step(s) not in `steps:` list: #{inspect(orphans)}"
    end

    # Validate `needs:` references.
    Enum.each(declared, fn {name, opts} ->
      needs = Keyword.get(opts, :needs, [])

      unknown = Enum.reject(needs, &MapSet.member?(steps_set, &1))

      if unknown != [] do
        raise CompileError,
          description:
            "GtElixir.Workflow #{inspect(module)}: step #{inspect(name)} declares " <>
              "needs: #{inspect(needs)} but #{inspect(unknown)} are not in `steps:`"
      end
    end)

    # Build step_definition/1 clauses and the union of vars/0.
    definition_clauses =
      Enum.map(declared, fn {name, opts} ->
        definition = %{
          description: Keyword.get(opts, :description, ""),
          needs: Keyword.get(opts, :needs, []),
          vars: Keyword.get(opts, :vars, [])
        }

        quote do
          @impl GtElixir.Workflow
          def step_definition(unquote(name)), do: unquote(Macro.escape(definition))
        end
      end)

    all_vars =
      declared
      |> Enum.flat_map(fn {_n, opts} -> Keyword.get(opts, :vars, []) end)
      |> Enum.uniq()

    quote do
      @impl GtElixir.Workflow
      def steps, do: @__workflow_steps

      unquote_splicing(definition_clauses)

      @impl GtElixir.Workflow
      def vars, do: unquote(all_vars)

      @doc false
      def __workflow_extends__, do: @__workflow_extends

      @doc false
      def __workflow_expansions__, do: @__workflow_expansions

      @doc false
      def __workflow_aspects__, do: @__workflow_aspects
    end
  end

  @doc """
  Run a workflow module against an initial state. Executes each step in the
  order returned by `workflow_module.steps/0`, threading state between calls
  to `run_step/2`.

  Before invoking `run_step/2` for a step, the runner checks that every entry
  in the step's `:needs` list appears in `state.completed_steps`. If a need
  is unmet, `run/2` returns `{:error, {step, {:unmet_needs, missing_needs}}}`
  *without* invoking `run_step/2`.

  After a successful `run_step/2`, the step name is appended to
  `state.completed_steps`. The key is initialized to `[]` if absent.

  Returns `{:ok, final_state}` on success, or `{:error, {step, reason}}` on
  the first failure.
  """
  @spec run(module(), state()) :: {:ok, state()} | {:error, {step(), term()}}
  def run(workflow_module, initial_state)
      when is_atom(workflow_module) and is_map(initial_state) do
    state = Map.put_new(initial_state, :completed_steps, [])

    Enum.reduce_while(workflow_module.steps(), {:ok, state}, fn step, {:ok, acc_state} ->
      definition = workflow_module.step_definition(step)
      completed = Map.get(acc_state, :completed_steps, [])
      missing = Enum.reject(definition.needs, &(&1 in completed))

      cond do
        missing != [] ->
          {:halt, {:error, {step, {:unmet_needs, missing}}}}

        true ->
          case workflow_module.run_step(step, acc_state) do
            {:ok, new_state} when is_map(new_state) ->
              new_completed = Map.get(new_state, :completed_steps, completed) ++ [step]
              {:cont, {:ok, Map.put(new_state, :completed_steps, new_completed)}}

            {:error, reason} ->
              {:halt, {:error, {step, reason}}}

            other ->
              {:halt, {:error, {step, {:bad_return, other}}}}
          end
      end
    end)
  end
end
