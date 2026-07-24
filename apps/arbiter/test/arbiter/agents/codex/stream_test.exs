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

    test "deliberately-absorbed events produce no display lines" do
      assert Stream.format_event(%{"type" => "agent_reasoning_delta"}) == []
      assert Stream.format_event(%{"type" => "turn.started"}) == []
    end

    # bd-80kdgy: an event type this module knows nothing about must be VISIBLE,
    # not silently dropped. The silent `_ -> []` catch-all is exactly what made
    # the 0.142.5 schema change invisible: the whole session vanished and the
    # run still exited 0.
    test "unrecognized events render a loud, non-arming drift warning" do
      assert [{line, false}] = Stream.format_event(%{"type" => "something_new"})
      assert line =~ "something_new"
      assert line =~ "unrecognized"
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

  # bd-80kdgy: codex 0.142.5 replaced `exec --json`'s `event_msg` vocabulary
  # with a thread/turn/item protocol. Every payload below is copied verbatim
  # from a live `codex exec --json --skip-git-repo-check
  # --dangerously-bypass-approvals-and-sandbox` run against codex-cli 0.142.5.
  # Under the old parser all of them fell through the silent `_ -> []`
  # catch-all, so the transcript, the usage ledger, and `arb done` detection
  # were all empty while the process still exited 0.
  describe "codex 0.142.5 thread/turn/item schema" do
    test "thread.started carries the session id" do
      event = %{"type" => "thread.started", "thread_id" => "019f95ae-63d4-7893-88e9-e560a016fc3f"}

      assert Stream.usage_fields(event, nil)[:session_id] ==
               "019f95ae-63d4-7893-88e9-e560a016fc3f"

      assert [{line, false}] = Stream.format_event(event)
      assert line =~ "codex session started"
      assert Stream.activity_for_event(event) == "starting"
    end

    # Neither codex schema reports the model the CLI actually chose, so the
    # ledger's model slot can only be filled from the id Arbiter pre-resolved at
    # spawn time. `usage_fields/2` documents a `fallback_model` for exactly this
    # and no clause was using it.
    test "thread.started stamps the pre-resolved fallback model" do
      event = %{"type" => "thread.started", "thread_id" => "019f95ae"}
      assert Stream.usage_fields(event, "gpt-5-codex")[:model] == "gpt-5-codex"
      refute Map.has_key?(Stream.usage_fields(event, nil), :model)
    end

    test "turn.completed carries the token buckets" do
      event = %{
        "type" => "turn.completed",
        "usage" => %{
          "input_tokens" => 20_900,
          "cached_input_tokens" => 14_592,
          "output_tokens" => 126,
          "reasoning_output_tokens" => 42
        }
      }

      fields = Stream.usage_fields(event, "gpt-5-codex")
      assert fields[:tokens_in] == 20_900
      assert fields[:tokens_out] == 126
      assert fields[:cache_read_tokens] == 14_592
      assert fields[:is_error] == false

      assert [{line, false}] = Stream.format_event(event)
      assert line =~ "codex session complete"
      assert Stream.activity_for_event(event) == "wrapping up"
    end

    test "turn.failed flags the run as an error" do
      event = %{"type" => "turn.failed", "error" => %{"message" => "model stream disconnected"}}

      fields = Stream.usage_fields(event, nil)
      assert fields[:is_error] == true
      assert fields[:result_status] == "error"

      assert [{line, false}] = Stream.format_event(event)
      assert line =~ "model stream disconnected"
    end

    test "item.completed agent_message is the only class that arms completion" do
      event = %{
        "type" => "item.completed",
        "item" => %{"id" => "item_2", "type" => "agent_message", "text" => "hi\n\narb done"}
      }

      tuples = Stream.format_event(event)
      assert Enum.all?(tuples, fn {_line, arm?} -> arm? end)
      assert Enum.any?(tuples, fn {line, _} -> line == "arb done" end)
      assert Stream.activity_for_event(event) == "responding"
    end

    test "command_execution renders begin/end lines that never arm completion" do
      started = %{
        "type" => "item.started",
        "item" => %{
          "id" => "item_1",
          "type" => "command_execution",
          # 0.142.5 sends the command as a pre-joined string, not an argv list.
          "command" => "/usr/bin/zsh -lc 'mix test'",
          "aggregated_output" => "",
          "exit_code" => nil,
          "status" => "in_progress"
        }
      }

      assert [{line, false}] = Stream.format_event(started)
      assert line =~ "mix test"
      assert Stream.activity_for_event(started) == "running tests"

      completed = %{
        "type" => "item.completed",
        "item" => %{
          "id" => "item_1",
          "type" => "command_execution",
          "command" => "/usr/bin/zsh -lc 'cat a.txt'",
          "aggregated_output" => "hi\n",
          "exit_code" => 0,
          "status" => "completed"
        }
      }

      tuples = Stream.format_event(completed)
      assert Enum.all?(tuples, fn {_line, arm?} -> arm? == false end)
      assert Enum.any?(tuples, fn {line, _} -> line =~ "command done" end)
      assert Enum.any?(tuples, fn {line, _} -> line =~ "hi" end)
    end

    test "a non-zero command_execution surfaces the exit code" do
      event = %{
        "type" => "item.completed",
        "item" => %{
          "type" => "command_execution",
          "command" => "mix test",
          "aggregated_output" => "1 failure",
          "exit_code" => 1,
          "status" => "failed"
        }
      }

      assert [{line, false} | _] = Stream.format_event(event)
      assert line =~ "exited 1"
    end

    test "reasoning items render as non-arming thinking lines" do
      event = %{
        "type" => "item.completed",
        "item" => %{"id" => "item_0", "type" => "reasoning", "text" => "planning the edit"}
      }

      assert [{line, false}] = Stream.format_event(event)
      assert line =~ "planning the edit"
      assert Stream.activity_for_event(event) == "thinking"
    end

    test "file_change items render the touched paths" do
      event = %{
        "type" => "item.completed",
        "item" => %{
          "id" => "item_3",
          "type" => "file_change",
          "status" => "completed",
          "changes" => [
            %{"path" => "lib/arbiter/agents/codex/stream.ex", "kind" => "update"},
            %{"path" => "lib/new_file.ex", "kind" => "add"}
          ]
        }
      }

      tuples = Stream.format_event(event)
      assert Enum.all?(tuples, fn {_line, arm?} -> arm? == false end)
      assert Enum.any?(tuples, fn {line, _} -> line =~ "stream.ex" end)
      assert Stream.activity_for_event(event) =~ "editing"
    end

    test "web_search and mcp_tool_call items render non-arming lines" do
      search = %{
        "type" => "item.completed",
        "item" => %{"type" => "web_search", "query" => "codex exec json schema"}
      }

      assert [{line, false}] = Stream.format_event(search)
      assert line =~ "codex exec json schema"
      assert Stream.activity_for_event(search) == "researching"

      mcp = %{
        "type" => "item.started",
        "item" => %{"type" => "mcp_tool_call", "server" => "arbiter", "tool" => "task_show"}
      }

      assert [{line, false}] = Stream.format_event(mcp)
      assert line =~ "task_show"
    end

    test "item.updated is absorbed so streamed text is not double-printed" do
      event = %{
        "type" => "item.updated",
        "item" => %{"id" => "item_2", "type" => "agent_message", "text" => "partial"}
      }

      assert Stream.format_event(event) == []
    end

    test "an item with an unknown item type still surfaces a drift warning" do
      event = %{"type" => "item.completed", "item" => %{"type" => "brand_new_item"}}

      assert [{line, false}] = Stream.format_event(event)
      assert line =~ "brand_new_item"
    end
  end
end
