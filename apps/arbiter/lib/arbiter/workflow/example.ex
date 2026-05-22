defmodule Arbiter.Workflow.Example.GreetThenWave do
  @moduledoc """
  Trivial 2-step example workflow exercising the `Arbiter.Workflow` behaviour
  + macro DSL.

  Lives in `lib/` (not `test/`) so the macro is exercised by a real top-level
  compile every time the umbrella builds — the compile-time validations
  (`needs:` references, step/declaration parity) are therefore covered by
  normal compilation, not just by the `Code.compile_string/1` tests.

  ## Run

      iex> Arbiter.Workflow.run(Arbiter.Workflow.Example.GreetThenWave, %{name: "Ryan"})
      {:ok,
       %{
         name: "Ryan",
         events: ["wave", "greet:Ryan"],
         completed_steps: [:greet, :wave]
       }}
  """

  use Arbiter.Workflow,
    steps: [:greet, :wave]

  step(:greet, description: "Say hi to the user by name", needs: [], vars: [:name])
  step(:wave, description: "Wave goodbye", needs: [:greet], vars: [])

  @impl Arbiter.Workflow
  def run_step(:greet, %{name: name} = state) do
    event = "greet:#{name}"
    {:ok, Map.update(state, :events, [event], &[event | &1])}
  end

  def run_step(:wave, state) do
    {:ok, Map.update(state, :events, ["wave"], &["wave" | &1])}
  end
end
