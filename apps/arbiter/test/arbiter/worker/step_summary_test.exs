defmodule Arbiter.Worker.StepSummaryTest do
  @moduledoc """
  bd-9isnkx: `output_summary/2` only had clauses for `nil` and `is_binary`.
  Any other shape (a map, a list, a number...) raised `FunctionClauseError`
  from inside `ClaudeSession.capture_steps/2` — i.e. mid-stream, while
  parsing a live agent's output — which took down the whole worker
  GenServer and lost an in-flight review round with it.

  The real trigger (bd-9isnkx): agy fails to cancel an orphaned background
  task on exit and emits a `step_update` DONE event whose `tool_info.output`
  is an object, `%{"message" => "cannot kill task \"<conv>/task-N\": ..."}`,
  instead of the string every other tool step's output has been. But the
  general case is the actual fix: `capture_steps/2` parses untrusted-ish
  output from a third-party CLI whose message shapes will keep changing, so
  a missing clause here must degrade to an unsummarised step, never kill the
  run.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbiter.Worker.StepSummary

  describe "output_summary/2 with the real agy crash payload" do
    test "a step whose output is `%{\"message\" => ...}` no longer raises (bd-9isnkx AC1)" do
      payload = %{
        "message" =>
          "cannot kill task \"d36d3e03-6627-4b7a-892e-0e8d80f5f65c/task-46\": task not found"
      }

      log =
        capture_log(fn ->
          assert StepSummary.output_summary(payload) =~ "cannot kill task"
        end)

      assert log =~ "output_summary"
    end
  end

  describe "output_summary/2 general robustness (bd-9isnkx AC2/AC3)" do
    test "unknown-shape maps never raise and are logged as discoverable" do
      log =
        capture_log(fn ->
          assert is_binary(StepSummary.output_summary(%{"unexpected" => "shape"}))
        end)

      assert log =~ "output_summary"
    end

    test "maps missing every recognised key fall back to an inspected string" do
      refute_raise_and_binary(%{"foo" => 1, "bar" => [1, 2, 3]})
    end

    test "non-map, non-string values (list) never raise" do
      refute_raise_and_binary(["cannot", "kill", "task"])
    end

    test "non-map, non-string values (integer) never raise" do
      refute_raise_and_binary(42)
    end

    test "non-map, non-string values (boolean) never raise" do
      refute_raise_and_binary(true)
    end

    test "an atom value never raises" do
      refute_raise_and_binary(:some_atom)
    end

    defp refute_raise_and_binary(term) do
      capture_log(fn ->
        result = StepSummary.output_summary(term)
        assert is_binary(result)
      end)
    end
  end

  describe "output_summary/2 redacts before logging unrecognized shapes" do
    test "a secret embedded in an unrecognized payload is redacted in the log line" do
      payload = %{"message" => "cannot kill task: token=super-secret-value failed"}

      log =
        capture_log(fn ->
          result = StepSummary.output_summary(payload, ["super-secret-value"])
          assert result =~ "[REDACTED]"
          refute result =~ "super-secret-value"
        end)

      assert log =~ "[REDACTED]"
      refute log =~ "super-secret-value"
    end
  end

  describe "output_summary/2 known shapes are unchanged (regression)" do
    test "nil still summarizes to an empty string" do
      assert StepSummary.output_summary(nil) == ""
    end

    test "a plain string is still redacted and truncated as before" do
      assert StepSummary.output_summary("hello world") == "hello world"
      assert StepSummary.output_summary("secret-value", ["secret-value"]) =~ "[REDACTED]"
    end
  end
end
