defmodule GtElixir.TestWorkflows.Three do
  @moduledoc """
  Three-step linear workflow used by WorkflowMachine tests. Each step
  flips a sentinel key in the threaded state, and `:b` and `:c` assert
  the previous step ran by pattern-matching.
  """

  use GtElixir.Workflow, steps: [:a, :b, :c]

  step :a, description: "a", needs: [], vars: [:x]
  step :b, description: "b", needs: [:a], vars: []
  step :c, description: "c", needs: [:b], vars: []

  @impl GtElixir.Workflow
  def run_step(:a, state), do: {:ok, Map.put(state, "a_done", true)}
  def run_step(:b, %{"a_done" => true} = state), do: {:ok, Map.put(state, "b_done", true)}
  def run_step(:c, %{"b_done" => true} = state), do: {:ok, Map.put(state, "c_done", true)}
end

defmodule GtElixir.TestWorkflows.Failing do
  @moduledoc "Two-step workflow whose second step always returns {:error, _}."

  use GtElixir.Workflow, steps: [:start, :boom]

  step :start, description: "start", needs: [], vars: []
  step :boom, description: "boom", needs: [:start], vars: []

  @impl GtElixir.Workflow
  def run_step(:start, state), do: {:ok, Map.put(state, "started", true)}
  def run_step(:boom, _state), do: {:error, :kaboom}
end

defmodule GtElixir.TestWorkflows.NotAWorkflow do
  @moduledoc "Bare module with no behaviour — for module-validation tests."
  def hello, do: :world
end
