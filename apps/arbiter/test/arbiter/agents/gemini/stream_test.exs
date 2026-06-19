defmodule Arbiter.Agents.Gemini.StreamTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Gemini.Stream

  describe "usage_fields/2 — init event" do
    test "captures model + session_id" do
      event = %{
        "type" => "init",
        "session_id" => "sess-123",
        "model" => "gemini-2.5-pro"
      }

      assert Stream.usage_fields(event, nil) == %{
               model: "gemini-2.5-pro",
               session_id: "sess-123"
             }
    end
  end

  describe "usage_fields/2 — result event" do
    test "maps stats tokens, derives cost, and flags non-error" do
      event = %{
        "type" => "result",
        "status" => "success",
        "stats" => %{
          "input_tokens" => 1_000_000,
          "input" => 800_000,
          "cached" => 200_000,
          "output_tokens" => 500_000,
          "total_tokens" => 1_500_000,
          "duration_ms" => 4200,
          "models" => %{
            "gemini-2.5-pro" => %{
              "input_tokens" => 1_000_000,
              "input" => 800_000,
              "cached" => 200_000,
              "output_tokens" => 500_000,
              "total_tokens" => 1_500_000
            }
          }
        }
      }

      fields = Stream.usage_fields(event, "fallback-model")

      assert fields.tokens_in == 1_000_000
      assert fields.tokens_out == 500_000
      assert fields.cache_read_tokens == 200_000
      assert fields.duration_ms == 4200
      assert fields.model == "gemini-2.5-pro"
      assert fields.is_error == false
      assert fields.result_status == "success"
      assert fields.raw == event
      # pro: 800k*1.25/1M + 200k*0.31/1M + 500k*10/1M = 1.0 + 0.062 + 5.0 = 6.062
      assert_in_delta fields.cost_usd, 6.062, 1.0e-6
      # No cache-creation analogue on Gemini.
      refute Map.has_key?(fields, :cache_creation_tokens)
    end

    test "falls back to the spawn-time model when stats carries no model breakdown" do
      event = %{"type" => "result", "status" => "success", "stats" => %{"input_tokens" => 10}}
      fields = Stream.usage_fields(event, "gemini-2.5-flash")
      assert fields.model == "gemini-2.5-flash"
    end

    test "error result flags is_error and drops cost when unpriced" do
      event = %{"type" => "result", "status" => "error", "stats" => %{"models" => %{}}}
      fields = Stream.usage_fields(event, "gemini-2.5-pro")
      assert fields.is_error == true
      refute Map.has_key?(fields, :cost_usd)
    end

    test "non-usage events yield an empty map" do
      assert Stream.usage_fields(%{"type" => "tool_use", "tool_name" => "x"}, nil) == %{}
      assert Stream.usage_fields(%{"type" => "message", "role" => "user"}, nil) == %{}
    end
  end

  describe "format_event/1 — display + done detection" do
    test "assistant text arms the done sentinel" do
      event = %{"type" => "message", "role" => "assistant", "content" => "all set\narb done"}
      lines = Stream.format_event(event)
      assert {"all set", true} in lines
      assert {"arb done", true} in lines
    end

    test "user prompt echo is never displayed nor armed" do
      event = %{"type" => "message", "role" => "user", "content" => "do the thing — arb done"}
      assert Stream.format_event(event) == []
    end

    test "tool_use renders a glyph line and never arms" do
      event = %{
        "type" => "tool_use",
        "tool_name" => "run_shell_command",
        "parameters" => %{"command" => "mix test"}
      }

      assert [{line, false}] = Stream.format_event(event)
      assert line =~ "run_shell_command"
      assert line =~ "mix test"
    end

    test "tool_result renders a result label and never arms" do
      event = %{"type" => "tool_result", "status" => "success", "output" => "ok\n"}
      lines = Stream.format_event(event)
      assert {"⏴ tool result", false} in lines
      assert Enum.all?(lines, fn {_t, detect?} -> detect? == false end)
    end

    test "init + result render session markers, never arming" do
      assert [{init_line, false}] =
               Stream.format_event(%{"type" => "init", "model" => "gemini-2.5-pro"})

      assert init_line =~ "gemini session started"
      assert init_line =~ "gemini-2.5-pro"

      result = %{
        "type" => "result",
        "status" => "success",
        "stats" => %{"duration_ms" => 2000, "total_tokens" => 1234, "models" => %{}}
      }

      assert [{res_line, false}] = Stream.format_event(result)
      assert res_line =~ "gemini session success"
      assert res_line =~ "1234 tok"
    end
  end

  describe "activity_for_event/1" do
    test "maps event types to coarse phrases" do
      assert Stream.activity_for_event(%{"type" => "init"}) == "starting"
      assert Stream.activity_for_event(%{"type" => "result"}) == "wrapping up"

      assert Stream.activity_for_event(%{
               "type" => "message",
               "role" => "assistant",
               "content" => "hi"
             }) == "responding"

      assert Stream.activity_for_event(%{
               "type" => "tool_use",
               "tool_name" => "run_shell_command",
               "parameters" => %{"command" => "mix test"}
             }) == "running tests"
    end

    test "returns nil for events with no salient activity" do
      assert Stream.activity_for_event(%{"type" => "tool_result"}) == nil
      assert Stream.activity_for_event(%{"type" => "message", "role" => "user"}) == nil
    end
  end
end
