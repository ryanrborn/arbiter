defmodule ArbiterWeb.TaskFormTest do
  use ExUnit.Case, async: true

  alias ArbiterWeb.TaskForm

  describe "difficulty_options/0" do
    test "offers the whole D0..D5 scale plus the unset entry" do
      options = TaskForm.difficulty_options()

      assert {"— unset —", ""} in options
      assert length(options) == 7

      for d <- 0..5 do
        assert Enum.any?(options, fn {label, value} ->
                 value == to_string(d) and String.starts_with?(label, "D#{d} — ")
               end),
               "no option for D#{d} in #{inspect(options)}"
      end
    end

    test "D5 reads as a deliberate escalation, not merely 'harder than D4'" do
      # #1519: the operator picks D5 from this select. The hint has to say
      # what it costs, or the opt-in gate is only nominal.
      {label, "5"} = Enum.find(TaskForm.difficulty_options(), &match?({_, "5"}, &1))

      assert label =~ "flagship"
    end
  end

  describe "priority_options/0" do
    test "is unchanged at P0..P4 — priority and difficulty are separate scales" do
      assert length(TaskForm.priority_options()) == 5
    end
  end
end
