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

  # `agy` (the fork `resolve_executable/0` prefers when installed — see
  # `Arbiter.Agents.Gemini.resolve_executable/0`) speaks a *different*
  # stream-json wire schema from the upstream `gemini` CLI: a top-level
  # `"event"` discriminator (not `"type"`) with the payload nested under a
  # same-named key, and a flat `usage` map (no `stats`/per-model breakdown).
  # These fixtures are copied verbatim from a live `agy --output-format
  # stream-json` dispatch (bd-2fzwlc) — the CLI schemas the unit tests
  # against a fabricated shape were never checked against agy's actual
  # output, which is why every Gemini usage_events row carried zero tokens.
  describe "usage_fields/2 — agy wire schema" do
    test "init captures the conversation id as session_id" do
      event = %{
        "event" => "init",
        "conversation_id" => "f0351b1a-8cc5-40a6-bef7-16054b993ce6",
        "init" => %{"cwd" => "/tmp", "tools" => [], "permission_mode" => "always-proceed"}
      }

      assert Stream.usage_fields(event, nil) == %{
               session_id: "f0351b1a-8cc5-40a6-bef7-16054b993ce6"
             }
    end

    # bd-2fzwlc round 2: agy names no model in any event, and its real
    # catalogue (confirmed live) doesn't overlap the Gemini price table at
    # all — pricing off the pre-resolved `fallback_model` (which defaults to
    # the hardcoded gemini-2.5-pro) stamped a confident, wrong dollar figure
    # on a model agy never ran. So agy rows never derive cost from
    # `fallback_model`, and never stamp a guessed `:model` either — a nil
    # cost with an explanatory note beats a fabricated number, regardless of
    # what `fallback_model` is.
    test "result maps the flat usage object; cost is always unavailable and unpriced, model is never guessed" do
      event = %{
        "event" => "result",
        "result" => %{
          "conversation_id" => "f0351b1a-8cc5-40a6-bef7-16054b993ce6",
          "status" => "SUCCESS",
          "response" => "Hi\narb done\n",
          "duration_seconds" => 1.102868684,
          "num_turns" => 1,
          "usage" => %{
            "input_tokens" => 17529,
            "output_tokens" => 118,
            "thinking_tokens" => 110,
            "cache_read_tokens" => 0,
            "total_tokens" => 17647
          }
        }
      }

      fields = Stream.usage_fields(event, "gemini-2.5-pro")

      assert fields.tokens_in == 17529
      assert fields.tokens_out == 118
      assert fields.cache_read_tokens == 0
      assert fields.thinking_tokens == 110
      assert fields.duration_ms == 1103
      refute Map.has_key?(fields, :model)
      assert fields.is_error == false
      assert fields.result_status == "SUCCESS"
      assert fields.raw == event
      refute Map.has_key?(fields, :cost_usd)
      assert fields.cost_note =~ "Antigravity"
      assert fields.cost_note =~ "no cost"

      # bd-2fzwlc's live probe: thinking_tokens is a subset of output_tokens,
      # not an addition on top of it (input + output == total, with no third
      # bucket) — so tokens_out must NOT be inflated by adding thinking on
      # top, or the ledger would double-count every thinking token.
      assert fields.tokens_in + fields.tokens_out == 17647
      assert fields.thinking_tokens <= fields.tokens_out
    end

    test "thinking_tokens is nil when agy's usage carries none" do
      event = %{
        "event" => "result",
        "result" => %{
          "status" => "SUCCESS",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }
      }

      fields = Stream.usage_fields(event, nil)
      refute Map.has_key?(fields, :thinking_tokens)
    end

    test "result with no fallback model still records why cost is nil" do
      event = %{
        "event" => "result",
        "result" => %{
          "status" => "SUCCESS",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }
      }

      fields = Stream.usage_fields(event, nil)
      refute Map.has_key?(fields, :cost_usd)
      assert fields.cost_note =~ "no cost"
    end

    test "non-SUCCESS status flags is_error" do
      event = %{"event" => "result", "result" => %{"status" => "ERROR", "usage" => %{}}}
      fields = Stream.usage_fields(event, "gemini-2.5-pro")
      assert fields.is_error == true
    end

    test "step_update and other agy events yield an empty map" do
      assert Stream.usage_fields(
               %{
                 "event" => "step_update",
                 "step_update" => %{"step_type" => "agent_response", "text_delta" => "hi"}
               },
               nil
             ) == %{}
    end
  end

  describe "format_event/1 — agy wire schema" do
    test "agent_response step arms the done sentinel" do
      event = %{
        "event" => "step_update",
        "step_update" => %{
          "step_type" => "agent_response",
          "text_delta" => "all set\narb done"
        }
      }

      lines = Stream.format_event(event)
      assert {"all set", true} in lines
      assert {"arb done", true} in lines
    end

    test "non-agent_response steps render nothing" do
      event = %{
        "event" => "step_update",
        "step_update" => %{"step_type" => "user_input", "state" => "DONE"}
      }

      assert Stream.format_event(event) == []
    end

    test "init and result render session markers, never arming" do
      assert [{init_line, false}] =
               Stream.format_event(%{"event" => "init", "conversation_id" => "abc"})

      assert init_line =~ "gemini session started"

      result = %{
        "event" => "result",
        "result" => %{
          "status" => "SUCCESS",
          "duration_seconds" => 2.0,
          "usage" => %{"total_tokens" => 1234}
        }
      }

      assert [{res_line, false}] = Stream.format_event(result)
      assert res_line =~ "gemini session SUCCESS"
      assert res_line =~ "1234 tok"
    end

    test "an unrecognized agy event surfaces a drift line instead of vanishing silently" do
      assert [{line, false}] = Stream.format_event(%{"event" => "brand_new_thing"})
      assert line =~ "unrecognized"
      assert line =~ "brand_new_thing"
    end
  end

  # Verbatim from a live `agy v1.2.4 --output-format stream-json` probe
  # (bd-4gpx4a, reproduced in bd-7y3mm9) — including the `CommandLine`
  # parameter casing agy's `run_command` tool actually uses, which is why
  # `summarize_params/1`/`shell_activity/1` need a rename step before they
  # can read it.
  describe "format_event/1 — agy tool telemetry (bd-7y3mm9)" do
    @active_tool_event %{
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

    @done_tool_event %{
      "event" => "step_update",
      "step_update" => %{
        "step_index" => 2,
        "state" => "DONE",
        "step_type" => "tool",
        "tool_name" => "run_command",
        "duration_seconds" => 0.027,
        "tool_info" => %{
          "name" => "run_command",
          "parameters" => %{"CommandLine" => "echo hello-from-agy"},
          "output" => "hello-from-agy\r\n"
        }
      }
    }

    test "ACTIVE tool step renders name + summarized params, never arms" do
      assert [{line, false}] = Stream.format_event(@active_tool_event)
      assert line == "⏵ run_command(echo hello-from-agy)"
    end

    test "DONE tool step renders a result label + truncated output, never arms" do
      lines = Stream.format_event(@done_tool_event)
      assert {"⏴ tool result", false} in lines
      # agy's output carries the child shell's own \r\n; `lines/1` only
      # splits on \n (matching the existing Claude/gemini tool_result path),
      # so the trailing \r rides along on the line — not stripped here.
      assert {"hello-from-agy\r", false} in lines
      assert Enum.all?(lines, fn {_t, detect?} -> detect? == false end)
    end

    test "activity_for_event routes run_command through shell_activity, mix test -> running tests" do
      assert Stream.activity_for_event(@active_tool_event) == "running: echo hello-from-agy"

      mix_test_event =
        put_in(
          @active_tool_event,
          ["step_update", "tool_info", "parameters", "CommandLine"],
          "mix test"
        )

      assert Stream.activity_for_event(mix_test_event) == "running tests"
    end
  end

  describe "activity_for_event/1 — agy wire schema" do
    test "maps agy event shapes to coarse phrases" do
      assert Stream.activity_for_event(%{"event" => "init"}) == "starting"
      assert Stream.activity_for_event(%{"event" => "result"}) == "wrapping up"

      assert Stream.activity_for_event(%{
               "event" => "step_update",
               "step_update" => %{"step_type" => "agent_response", "text_delta" => "hi"}
             }) == "responding"
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
