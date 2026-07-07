defmodule Arbiter.Agents.Codex.StreamTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Codex.Stream

  # Payloads confirmed against a real `codex` 0.142.3 session rollout — the
  # `event_msg` payload shapes are what `codex exec --json` emits on stdout.

  describe "usage_fields/2" do
    test "token_count carries cumulative token buckets" do
      event = %{
        "type" => "token_count",
        "info" => %{
          "total_token_usage" => %{
            "input_tokens" => 10_500,
            "cached_input_tokens" => 4_480,
            "output_tokens" => 59,
            "reasoning_output_tokens" => 42,
            "total_tokens" => 10_559
          }
        }
      }

      fields = Stream.usage_fields(event, "gpt-5-codex")
      assert fields[:tokens_in] == 10_500
      assert fields[:tokens_out] == 59
      assert fields[:cache_read_tokens] == 4_480
    end

    test "task_complete carries the duration and error status" do
      event = %{
        "type" => "task_complete",
        "turn_id" => "t1",
        "last_agent_message" => "arb done",
        "duration_ms" => 5394
      }

      fields = Stream.usage_fields(event, "gpt-5-codex")
      assert fields[:duration_ms] == 5394
      assert fields[:is_error] == false
    end

    test "turn_context surfaces the concrete model" do
      event = %{"type" => "turn_context", "model" => "gpt-5.4-mini"}
      assert Stream.usage_fields(event, "gpt-5-codex")[:model] == "gpt-5.4-mini"
    end

    test "error event flags is_error" do
      event = %{"type" => "error", "message" => "boom"}
      assert Stream.usage_fields(event, nil)[:is_error] == true
    end

    test "returns an empty map for events without usage" do
      assert Stream.usage_fields(%{"type" => "task_started"}, nil) == %{}
    end
  end

  describe "format_event/1" do
    test "agent_message text is the only class that arms completion" do
      event = %{"type" => "agent_message", "message" => "here is the plan\narb done"}
      tuples = Stream.format_event(event)
      assert Enum.all?(tuples, fn {_line, arm?} -> arm? end)
      assert Enum.any?(tuples, fn {line, _} -> line == "arb done" end)
    end

    test "exec_command_begin renders a tool line that never arms completion" do
      event = %{"type" => "exec_command_begin", "command" => ["mix", "test"]}
      assert [{line, false}] = Stream.format_event(event)
      assert line =~ "mix test"
    end

    test "exec_command_end renders a non-arming result line" do
      event = %{"type" => "exec_command_end", "exit_code" => 0}
      assert [{_line, false} | _] = Stream.format_event(event)
    end

    test "error events render a non-arming warning" do
      assert [{line, false}] = Stream.format_event(%{"type" => "error", "message" => "kaboom"})
      assert line =~ "kaboom"
    end

    test "task_complete renders a non-arming summary" do
      event = %{"type" => "task_complete", "duration_ms" => 1200}
      assert [{_line, false}] = Stream.format_event(event)
    end

    test "unknown events produce no display lines" do
      assert Stream.format_event(%{"type" => "something_new"}) == []
    end
  end

  describe "activity_for_event/1" do
    test "task_started → starting" do
      assert Stream.activity_for_event(%{"type" => "task_started"}) == "starting"
    end

    test "exec_command_begin → running phrase" do
      event = %{"type" => "exec_command_begin", "command" => ["mix", "test"]}
      assert Stream.activity_for_event(event) == "running tests"
    end

    test "unknown events keep the prior activity (nil)" do
      assert Stream.activity_for_event(%{"type" => "whatever"}) == nil
    end
  end
end
