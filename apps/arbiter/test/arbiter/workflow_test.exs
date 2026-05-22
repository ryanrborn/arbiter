defmodule Arbiter.WorkflowTest do
  use ExUnit.Case, async: true

  alias Arbiter.Workflow
  alias Arbiter.Workflow.Example.GreetThenWave

  describe "behaviour callbacks on the example workflow" do
    test "steps/0 returns declared steps in order" do
      assert GreetThenWave.steps() == [:greet, :wave]
    end

    test "step_definition/1 returns the right map per step" do
      assert GreetThenWave.step_definition(:greet) == %{
               description: "Say hi to the user by name",
               needs: [],
               vars: [:name]
             }

      assert GreetThenWave.step_definition(:wave) == %{
               description: "Wave goodbye",
               needs: [:greet],
               vars: []
             }
    end

    test "vars/0 is the union of all step vars, deduped" do
      assert GreetThenWave.vars() == [:name]
    end

    test "the module declares the Arbiter.Workflow behaviour" do
      behaviours = GreetThenWave.module_info(:attributes) |> Keyword.get_values(:behaviour)
      assert Workflow in List.flatten(behaviours)
    end
  end

  describe "Phase 5 composition placeholders" do
    test "extends/expansions/aspects defaults are empty / nil" do
      assert GreetThenWave.__workflow_extends__() == nil
      assert GreetThenWave.__workflow_expansions__() == []
      assert GreetThenWave.__workflow_aspects__() == []
    end

    test "composition options are stored on the module when provided" do
      mod_string = """
      defmodule Arbiter.WorkflowTest.PlaceholderShape do
        use Arbiter.Workflow,
          steps: [:only],
          extends: SomeOtherWorkflow,
          expansions: [tdd_cycle: :only],
          aspects: [security_audit: :only]

        step :only, description: "x", needs: [], vars: []

        @impl Arbiter.Workflow
        def run_step(:only, s), do: {:ok, s}
      end
      """

      [{mod, _}] = Code.compile_string(mod_string)
      assert mod.__workflow_extends__() == SomeOtherWorkflow
      assert mod.__workflow_expansions__() == [tdd_cycle: :only]
      assert mod.__workflow_aspects__() == [security_audit: :only]
    end
  end

  describe "run/2" do
    test "runs steps in order and threads state" do
      assert {:ok, final} = Workflow.run(GreetThenWave, %{name: "Ryan"})
      assert final.name == "Ryan"
      assert final.events == ["wave", "greet:Ryan"]
    end

    test "populates :completed_steps in order" do
      {:ok, final} = Workflow.run(GreetThenWave, %{name: "Ryan"})
      assert final.completed_steps == [:greet, :wave]
    end

    test "initializes :completed_steps to [] when absent" do
      {:ok, final} = Workflow.run(GreetThenWave, %{name: "x"})
      assert is_list(final.completed_steps)
    end

    test "halts on {:error, reason} and reports {step, reason}" do
      defmodule BoomWorkflow do
        use Arbiter.Workflow, steps: [:ok_step, :bad_step]

        step(:ok_step, description: "ok", needs: [], vars: [])
        step(:bad_step, description: "bad", needs: [:ok_step], vars: [])

        @impl Arbiter.Workflow
        def run_step(:ok_step, s), do: {:ok, Map.put(s, :ok_ran, true)}
        def run_step(:bad_step, _s), do: {:error, :kaboom}
      end

      assert Workflow.run(BoomWorkflow, %{}) == {:error, {:bad_step, :kaboom}}
    end

    test "bad return from run_step is reported as :bad_return" do
      defmodule BadReturnWorkflow do
        use Arbiter.Workflow, steps: [:one]

        step(:one, description: "x", needs: [], vars: [])

        @impl Arbiter.Workflow
        def run_step(:one, _s), do: :nope
      end

      assert {:error, {:one, {:bad_return, :nope}}} = Workflow.run(BadReturnWorkflow, %{})
    end

    test "needs: violation halts before invoking run_step" do
      # A workflow whose first step needs something that's never been
      # completed (because there's no earlier step) — we simulate a runtime
      # violation by passing an initial state that *strips* completed_steps
      # is impossible (run/2 adds it). Instead, construct a workflow with a
      # broken ordering: step ordered first, but declares it needs a later step.
      defmodule BadOrderWorkflow do
        use Arbiter.Workflow, steps: [:second_but_listed_first, :prereq]

        step(:second_but_listed_first,
          description: "needs prereq but runs first",
          needs: [:prereq],
          vars: []
        )

        step(:prereq, description: "the prereq", needs: [], vars: [])

        @impl Arbiter.Workflow
        def run_step(:second_but_listed_first, s),
          do: {:ok, Map.put(s, :should_not_run, true)}

        def run_step(:prereq, s), do: {:ok, s}
      end

      assert {:error, {:second_but_listed_first, {:unmet_needs, [:prereq]}}} =
               Workflow.run(BadOrderWorkflow, %{})
    end
  end

  describe "compile-time validation" do
    test "step in `steps:` without a `step :name, ...` declaration raises CompileError" do
      bad = """
      defmodule Arbiter.WorkflowTest.MissingStepDecl do
        use Arbiter.Workflow, steps: [:a, :b]

        step :a, description: "x", needs: [], vars: []

        @impl Arbiter.Workflow
        def run_step(_, s), do: {:ok, s}
      end
      """

      err = assert_raise CompileError, fn -> Code.compile_string(bad) end
      assert err.description =~ "missing `step :name, ...` definition"
      assert err.description =~ ":b"
    end

    test "orphan `step :name, ...` not in `steps:` raises CompileError" do
      bad = """
      defmodule Arbiter.WorkflowTest.OrphanStep do
        use Arbiter.Workflow, steps: [:a]

        step :a, description: "ok", needs: [], vars: []
        step :ghost, description: "not listed", needs: [], vars: []

        @impl Arbiter.Workflow
        def run_step(_, s), do: {:ok, s}
      end
      """

      err = assert_raise CompileError, fn -> Code.compile_string(bad) end
      assert err.description =~ "not in `steps:` list"
      assert err.description =~ ":ghost"
    end

    test "needs: referencing an unknown step raises CompileError" do
      bad = """
      defmodule Arbiter.WorkflowTest.UnknownNeed do
        use Arbiter.Workflow, steps: [:a, :b]

        step :a, description: "x", needs: [], vars: []
        step :b, description: "y", needs: [:phantom], vars: []

        @impl Arbiter.Workflow
        def run_step(_, s), do: {:ok, s}
      end
      """

      err = assert_raise CompileError, fn -> Code.compile_string(bad) end
      assert err.description =~ "needs:"
      assert err.description =~ ":phantom"
    end

    test "non-list / non-atom-list `steps:` raises CompileError" do
      bad = """
      defmodule Arbiter.WorkflowTest.BadStepsOpt do
        use Arbiter.Workflow, steps: ["not", "atoms"]
      end
      """

      assert_raise CompileError, ~r/must be a list of atoms/, fn ->
        Code.compile_string(bad)
      end
    end
  end
end
