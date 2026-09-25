defmodule Arbiter.Worker.RunStepsTest do
  # DataCase so `Ash.create(Arbiter.Workers.RunStep, ...)` (called from the
  # emit path under test) can reach the sandboxed connection. Driven directly
  # via `ClaudeSession.handle_data/3` on a bare session map — same style as
  # the "secret redaction in the emit path" describe block in
  # claude_session_test.exs — so no Worker GenServer/port is needed and each
  # test can run its own isolated (async) sandbox connection.
  use Arbiter.DataCase, async: true

  import ExUnit.CaptureLog

  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Workers.RunStep
  require Ash.Query

  defp steps_for(task_id) do
    RunStep
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!()
  end

  defp new_session(task_id, opts \\ []) do
    %{
      task_id: task_id,
      run_id: Keyword.get(opts, :run_id),
      topic: "worker:" <> task_id,
      line_cap: ClaudeSession.line_cap(),
      done_regex: ClaudeSession.done_regex(),
      output_lines: [],
      line_buf: "",
      provider: Keyword.get(opts, :provider),
      redact_values: Keyword.get(opts, :redact_values, [])
    }
  end

  defp feed(session, events) do
    Enum.reduce(events, session, fn event, acc ->
      ClaudeSession.handle_data(acc, Jason.encode!(event), true)
    end)
  end

  defp assistant_tool_use(id, name, input) do
    %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
      }
    }
  end

  defp user_tool_result(tool_use_id, content, opts \\ []) do
    %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => tool_use_id,
            "is_error" => Keyword.get(opts, :is_error, false),
            "content" => content
          }
        ]
      }
    }
  end

  test "a matched tool_use/tool_result pair writes exactly one row, correlated by tool_use_id" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"
    run_id = Ash.UUID.generate()

    _session =
      new_session(task_id, run_id: run_id)
      |> feed([
        assistant_tool_use("toolu_01ABC", "Bash", %{"command" => "mix test"}),
        user_tool_result("toolu_01ABC", "1 test, 0 failures")
      ])

    assert [step] = steps_for(task_id)
    assert step.run_id == run_id
    assert step.tool_use_id == "toolu_01ABC"
    assert step.name == "Bash"
    assert step.is_error == false
    assert is_integer(step.duration_ms)
    assert step.duration_ms >= 0
    assert step.input_summary =~ "mix test"
    assert is_binary(step.input_digest)
    assert step.output_summary =~ "1 test, 0 failures"
  end

  test "is_error is stored as a real boolean, not inferred from rendered text" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"

    _session =
      new_session(task_id)
      |> feed([
        assistant_tool_use("toolu_err1", "Bash", %{"command" => "false"}),
        user_tool_result("toolu_err1", "command failed", is_error: true)
      ])

    assert [step] = steps_for(task_id)
    assert step.is_error == true
  end

  test "same input repeated across two calls yields the same input_digest" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"

    _session =
      new_session(task_id)
      |> feed([
        assistant_tool_use("toolu_a", "Bash", %{"command" => "mix test"}),
        user_tool_result("toolu_a", "ok"),
        assistant_tool_use("toolu_b", "Bash", %{"command" => "mix test"}),
        user_tool_result("toolu_b", "ok again")
      ])

    assert [a, b] = steps_for(task_id)
    assert a.input_digest == b.input_digest
  end

  test "secret-marked env values are redacted out of input/output summaries" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"
    secret = "super-secret-token-value"

    _session =
      new_session(task_id, redact_values: [secret])
      |> feed([
        assistant_tool_use("toolu_secret1", "Bash", %{"command" => "echo #{secret}"}),
        user_tool_result("toolu_secret1", secret)
      ])

    assert [step] = steps_for(task_id)
    refute step.input_summary =~ secret
    refute step.output_summary =~ secret
    assert step.output_summary =~ "[REDACTED]"
  end

  test "a tool_use with no matching tool_result writes no row" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"

    _session =
      new_session(task_id)
      |> feed([assistant_tool_use("toolu_orphan", "Bash", %{"command" => "sleep 1"})])

    assert steps_for(task_id) == []
  end

  test "non-stream-json (echo script) output writes no step rows" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"

    session = new_session(task_id)
    _session = ClaudeSession.handle_data(session, "plain echo output", true)

    assert steps_for(task_id) == []
  end

  test "a live-captured step records its provenance as source \"live\"" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"

    _session =
      new_session(task_id)
      |> feed([
        assistant_tool_use("toolu_src1", "Bash", %{"command" => "mix test"}),
        user_tool_result("toolu_src1", "ok")
      ])

    assert [step] = steps_for(task_id)
    assert step.source == "live"
  end

  test "gemini/codex provider events write no step rows" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"

    _session =
      new_session(task_id, provider: "gemini")
      |> feed([
        assistant_tool_use("toolu_gem", "Bash", %{"command" => "mix test"}),
        user_tool_result("toolu_gem", "ok")
      ])

    assert steps_for(task_id) == []
  end

  # agy's tool step (bd-7y3mm9): fixture copied verbatim from a live `agy
  # v1.2.4 --output-format stream-json` probe, including the `CommandLine`
  # parameter casing.
  defp agy_tool_done_event(step_index, opts \\ []) do
    %{
      "event" => "step_update",
      "step_update" => %{
        "step_index" => step_index,
        "state" => "DONE",
        "step_type" => "tool",
        "tool_name" => "run_command",
        "duration_seconds" => Keyword.get(opts, :duration_seconds, 0.027),
        "tool_info" => %{
          "name" => "run_command",
          "parameters" => %{"CommandLine" => Keyword.get(opts, :command, "echo hello-from-agy")},
          "output" => Keyword.get(opts, :output, "hello-from-agy\r\n")
        }
      }
    }
  end

  test "an agy tool step's DONE event writes exactly one row" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"
    run_id = Ash.UUID.generate()

    _session =
      new_session(task_id, run_id: run_id, provider: "gemini")
      |> feed([agy_tool_done_event(2)])

    assert [step] = steps_for(task_id)
    assert step.run_id == run_id
    assert step.tool_use_id == "2"
    assert step.name == "run_command"
    assert step.is_error == false
    assert step.duration_ms == 27
    assert step.input_summary == "echo hello-from-agy"
    assert is_binary(step.input_digest)
    assert step.output_summary =~ "hello-from-agy"
    assert step.source == "live"
  end

  test "an agy ACTIVE tool step (no DONE yet) writes no row" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"

    active_event = %{
      "event" => "step_update",
      "step_update" => %{
        "step_index" => 2,
        "state" => "ACTIVE",
        "step_type" => "tool",
        "tool_name" => "run_command",
        "tool_info" => %{
          "name" => "run_command",
          "parameters" => %{"CommandLine" => "echo hello-from-agy"}
        }
      }
    }

    _session = new_session(task_id, provider: "gemini") |> feed([active_event])

    assert steps_for(task_id) == []
  end

  # `error` defaults to the object shape (`%{"type" => ..., "message" => ...}`)
  # the real installed agy (1.2.8) actually sends — confirmed live
  # re-verifying bd-25ivqe's post-merge failure — not the bare string an
  # earlier version of this helper guessed before the ERROR state was ever
  # captured live.
  defp agy_tool_error_event(step_index, opts \\ []) do
    default_error = %{
      "type" => "TOOL_ERROR",
      "message" => "permission check failed for unsandboxed \"arb inbox\""
    }

    %{
      "event" => "step_update",
      "step_update" => %{
        "step_index" => step_index,
        "state" => "ERROR",
        "step_type" => "tool",
        "tool_name" => "run_command",
        "duration_seconds" => Keyword.get(opts, :duration_seconds, 0.01),
        "tool_info" => %{
          "name" => "run_command",
          "parameters" => %{
            "CommandLine" => Keyword.get(opts, :command, "arb inbox bd-ci0y74")
          },
          "error" => Keyword.get(opts, :error, default_error)
        }
      }
    }
  end

  test "an agy tool step's ERROR event writes exactly one row with is_error true (bd-25ivqe)" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"
    run_id = Ash.UUID.generate()

    _session =
      new_session(task_id, run_id: run_id, provider: "gemini")
      |> feed([agy_tool_error_event(3)])

    assert [step] = steps_for(task_id)
    assert step.run_id == run_id
    assert step.tool_use_id == "3"
    assert step.name == "run_command"
    assert step.is_error == true
    assert step.input_summary == "arb inbox bd-ci0y74"
    assert step.output_summary =~ "permission check failed"
    assert step.source == "live"
  end

  test "an agy ERROR tool step stashes the denied command's base token on the session" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"

    session =
      new_session(task_id, provider: "gemini")
      |> feed([agy_tool_error_event(3, command: "arb inbox bd-ci0y74")])

    assert session.denied_command == "arb"
  end

  test "an agy ERROR tool step that is NOT a permission denial does not stash denied_command (bd-25ivqe finding 2)" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"

    session =
      new_session(task_id, provider: "gemini")
      |> feed([
        agy_tool_error_event(3,
          command: "rm -rf ./tmp",
          error: %{"type" => "TOOL_ERROR", "message" => "no such file or directory"}
        )
      ])

    refute Map.has_key?(session, :denied_command)
  end

  test "secret-marked env values are redacted out of ERROR tool input/output summaries" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"
    secret = "super-secret-token-value"

    _session =
      new_session(task_id, provider: "gemini", redact_values: [secret])
      |> feed([agy_tool_error_event(3, command: "echo #{secret}", error: secret)])

    assert [step] = steps_for(task_id)
    refute step.input_summary =~ secret
    refute step.output_summary =~ secret
    assert step.output_summary =~ "[REDACTED]"
  end

  test "secret-marked env values are redacted out of agy tool input/output summaries" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"
    secret = "super-secret-token-value"

    _session =
      new_session(task_id, provider: "gemini", redact_values: [secret])
      |> feed([agy_tool_done_event(2, command: "echo #{secret}", output: secret)])

    assert [step] = steps_for(task_id)
    refute step.input_summary =~ secret
    refute step.output_summary =~ secret
    assert step.output_summary =~ "[REDACTED]"
  end

  # bd-9isnkx: on exit, agy tries to cancel an orphaned background task and,
  # on failure, reports the DONE step's `tool_info.output` as an object
  # (`%{"message" => "cannot kill task ..."}`) instead of the string every
  # other tool step's output has been. `StepSummary.output_summary/2` had no
  # clause for a map, so this raised `FunctionClauseError` mid-stream and
  # took the whole worker GenServer down with it — losing an in-flight
  # review round. This is the exact fixture shape captured off the real
  # crash (bd-2exkl0's reviewer round).
  test "an agy DONE tool step whose output is a `cannot kill task` object writes a row instead of crashing (bd-9isnkx)" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"
    run_id = Ash.UUID.generate()

    kill_failure = %{
      "message" =>
        "cannot kill task \"d36d3e03-6627-4b7a-892e-0e8d80f5f65c/task-46\": task not found"
    }

    session = new_session(task_id, run_id: run_id, provider: "gemini")

    log =
      capture_log(fn ->
        _session = feed(session, [agy_tool_done_event(2, output: kill_failure)])
      end)

    assert log =~ "output_summary"

    assert [step] = steps_for(task_id)
    assert step.is_error == false
    assert step.output_summary =~ "cannot kill task"
  end

  # bd-9isnkx finding 2: the real crash (bd-2exkl0) hit `output_summary/2` via
  # the ERROR-state clause at `claude_session.ex:850`, not the DONE-state one
  # above. `tool_step_error_reason/1` falls back to `tool_info.output` when
  # `tool_info.error` is absent, which is how the kill-failure map reached
  # `output_summary/2` as `error` on the crash stack. This fixture reproduces
  # that exact path.
  test "an agy ERROR tool step whose output falls back to a `cannot kill task` object writes a row instead of crashing (bd-9isnkx)" do
    task_id = "bd-runsteps-#{System.unique_integer([:positive])}"
    run_id = Ash.UUID.generate()

    kill_failure = %{
      "message" =>
        "cannot kill task \"d36d3e03-6627-4b7a-892e-0e8d80f5f65c/task-46\": task not found"
    }

    error_event = %{
      "event" => "step_update",
      "step_update" => %{
        "step_index" => 3,
        "state" => "ERROR",
        "step_type" => "tool",
        "tool_name" => "run_command",
        "duration_seconds" => 0.01,
        "tool_info" => %{
          "name" => "run_command",
          "parameters" => %{"CommandLine" => "some-background-command"},
          "output" => kill_failure
        }
      }
    }

    session = new_session(task_id, run_id: run_id, provider: "gemini")

    log =
      capture_log(fn ->
        _session = feed(session, [error_event])
      end)

    assert log =~ "output_summary"

    assert [step] = steps_for(task_id)
    assert step.is_error == true
    assert step.output_summary =~ "cannot kill task"
  end
end
