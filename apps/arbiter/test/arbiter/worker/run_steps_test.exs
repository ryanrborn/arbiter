defmodule Arbiter.Worker.RunStepsTest do
  # DataCase so `Ash.create(Arbiter.Workers.RunStep, ...)` (called from the
  # emit path under test) can reach the sandboxed connection. Driven directly
  # via `ClaudeSession.handle_data/3` on a bare session map — same style as
  # the "secret redaction in the emit path" describe block in
  # claude_session_test.exs — so no Worker GenServer/port is needed and each
  # test can run its own isolated (async) sandbox connection.
  use Arbiter.DataCase, async: true

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
end
