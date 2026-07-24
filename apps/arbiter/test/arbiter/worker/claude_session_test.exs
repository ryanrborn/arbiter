defmodule Arbiter.Worker.ClaudeSessionTest do
  # async: false — Port + Phoenix.PubSub + shared Worker registry are all
  # global resources. Per-test unique task_ids keep cases independent.
  use ExUnit.Case, async: false

  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

  @fixture Path.expand("../../fixtures/echo_with_done.sh", __DIR__)

  defp new_task_id, do: "gte-013-#{System.unique_integer([:positive])}"

  defp start_worker(extra_opts \\ []) do
    task_id = new_task_id()

    {:ok, pid} =
      Worker.start(Keyword.merge([task_id: task_id, repo: "arbiter"], extra_opts))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    {pid, task_id}
  end

  defp tmp_dir!(tag) do
    dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Write a list of stream-json events (maps) as JSONL and return a `cat`
  # command that replays them — one event per line, exactly like the real
  # `claude --output-format stream-json` port stream. Using a file + cat
  # avoids any shell-quoting of the JSON.
  defp stream_json_command(dir, events) do
    path = Path.join(dir, "events-#{System.unique_integer([:positive])}.jsonl")
    body = events |> Enum.map_join("\n", &Jason.encode!/1)
    File.write!(path, body <> "\n")
    ["cat", path]
  end

  defp os_process_alive?(os_pid) do
    {_, code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    code == 0
  end

  defp wait_for_exit(pid) do
    eventually(fn ->
      case Worker.state(pid).meta do
        %{exit_status: s} when not is_nil(s) -> s
        _ -> nil
      end
    end)
  end

  # Wait until `fun.()` is truthy or we've slept past `timeout_ms`. Returns
  # the truthy value or fails the test.
  defp eventually(fun, timeout_ms \\ 2_000, step_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, step_ms)
  end

  defp do_eventually(fun, deadline, step_ms) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("eventually/2 timed out")
        else
          Process.sleep(step_ms)
          do_eventually(fun, deadline, step_ms)
        end

      false ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("eventually/2 timed out")
        else
          Process.sleep(step_ms)
          do_eventually(fun, deadline, step_ms)
        end

      truthy ->
        truthy
    end
  end

  setup do
    setup_assertions()
    :ok
  end

  # Sanity: the fixture must exist and be executable; otherwise every test
  # below would fail with a misleading exec-not-found error.
  defp setup_assertions do
    unless File.exists?(@fixture) and File.stat!(@fixture).mode |> Bitwise.band(0o100) > 0 do
      flunk("fixture missing or not executable: #{@fixture}")
    end
  end

  describe "start/1" do
    test "returns {:ok, port} with a valid command override" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-ok")

      assert {:ok, port} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: cwd,
                 command: [@fixture]
               )

      assert is_port(port)
    end

    test "returns {:error, {:executable_not_found, _}} for a nonexistent absolute path" do
      {pid, _} = start_worker()
      cwd = tmp_dir!("cs-bad")

      assert {:error, {:executable_not_found, "/nope/definitely/missing/binary"}} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: cwd,
                 command: ["/nope/definitely/missing/binary"]
               )
    end

    test "returns {:error, {:invalid_worktree, _}} when cwd doesn't exist" do
      {pid, _} = start_worker()

      assert {:error, {:invalid_worktree, "/no/such/dir/here"}} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: "/no/such/dir/here",
                 command: [@fixture]
               )
    end

    test "requires :owner pid" do
      assert {:error, :missing_owner} =
               ClaudeSession.start(worktree_path: System.tmp_dir!(), command: [@fixture])
    end
  end

  describe "output streaming" do
    test "fixture lines land in meta[:output_lines] in order" do
      {pid, task_id} = start_worker()
      cwd = tmp_dir!("cs-lines")

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [@fixture],
          topic: "worker:#{task_id}"
        )

      # Wait until the exit_status is recorded — by then all output has
      # already been processed by the worker.
      eventually(fn ->
        case Worker.state(pid) do
          %{meta: %{exit_status: status}} when not is_nil(status) -> status
          _ -> nil
        end
      end)

      lines = Worker.state(pid).meta.output_lines

      assert "starting fake claude session" in lines
      assert "doing important work" in lines
      assert "arb done" in lines
      # Order is preserved (oldest first).
      assert Enum.find_index(lines, &(&1 == "starting fake claude session")) <
               Enum.find_index(lines, &(&1 == "arb done"))
    end

    test "broadcasts :worker_output on the configured topic" do
      {pid, task_id} = start_worker()
      cwd = tmp_dir!("cs-bcast")
      topic = "worker:#{task_id}"

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [@fixture],
          topic: topic
        )

      assert_receive {:worker_output, ^task_id, "starting fake claude session"}, 2_000
      assert_receive {:worker_output, ^task_id, "doing important work"}, 2_000
      assert_receive {:worker_output, ^task_id, "arb done"}, 2_000
    end

    test "default topic is worker:<task_id> when :topic not provided" do
      {pid, task_id} = start_worker()
      cwd = tmp_dir!("cs-default-topic")

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:#{task_id}")

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [@fixture]
        )

      assert_receive {:worker_output, ^task_id, "starting fake claude session"}, 2_000
    end
  end

  describe "completion detection" do
    test "a line matching ~r/\\barb done\\b/ triggers Worker.complete/2" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-done")

      # Must be :running for :completed to be a legal transition.
      :ok = Worker.advance(pid, :implement)

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture])

      status =
        eventually(fn ->
          case Worker.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
      assert Worker.state(pid).meta.result == :claude_done
    end

    test "completion signal completes the worker even when status is :idle" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-idle-done")

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture])

      # claude_driven mode keeps the worker at :idle (the Machine is not
      # ticked, so advance/2 is never called). The "arb done" signal must
      # still complete the worker from :idle.
      status =
        eventually(fn ->
          case Worker.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
      assert Worker.state(pid).meta.result == :claude_done
    end

    test "a prose line that only mentions the marker as a substring does not trip" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-no-trip")

      :ok = Worker.advance(pid, :implement)

      # "arb doneness" embeds "arb done" but a word char follows "done", so the
      # word-bounded regex must NOT match. The child exits 0 without ever
      # printing the bare marker.
      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo 'discussing arb doneness in the abstract'; exit 0"]
        )

      # Wait until the child has exited — by then all output is processed.
      eventually(fn ->
        case Worker.state(pid).meta do
          %{exit_status: s} when not is_nil(s) -> s
          _ -> nil
        end
      end)

      # The prose line is buffered, but it never flipped the worker to
      # :completed (it stayed in the :running state from the advance above).
      refute Worker.state(pid).status == :completed
      assert "discussing arb doneness in the abstract" in Worker.state(pid).meta.output_lines
    end
  end

  # bd-7a0pi8: the completion marker must be the SOLE content of a display line
  # (the worker prompt says to print it "on a line by itself, exactly"). Before
  # this fix the detector matched `\barb done\b` ANYWHERE in a line, so an agent
  # merely narrating its plan ("...then print arb done") falsely completed the
  # run mid-task — the premature/false `arb done` that failed run 7abf4049.
  #
  # These assert on the detection primitive directly: handle_data/3 sends the
  # `{:__claude_session_done__, _}` signal to the CALLING process (here, the
  # test), so detection is observed synchronously with no worker/port races.
  describe "done-marker detection is anchored to a whole line (bd-7a0pi8)" do
    defp detection_session do
      %{
        task_id: "bd-detect",
        topic: "worker:detect-#{System.unique_integer([:positive])}",
        line_cap: ClaudeSession.line_cap(),
        done_regex: ClaudeSession.done_regex(),
        output_lines: [],
        line_buf: ""
      }
    end

    test "the marker alone on a line trips, with or without simple decoration" do
      for line <- ["arb done", "  arb done  ", ">> arb done <<", "`arb done`"] do
        ClaudeSession.handle_data(detection_session(), line, true)
        assert_received {:__claude_session_done__, _}, "expected #{inspect(line)} to trip"
      end
    end

    test "a prose line that merely mentions the marker does NOT trip" do
      for line <- [
            "I will commit the fix and then print arb done shortly",
            "remember to run arb done at the very end",
            "the completion sentinel is `arb done` on its own line",
            "discussing arb doneness in the abstract"
          ] do
        ClaudeSession.handle_data(detection_session(), line, true)
        refute_received {:__claude_session_done__, _}, "expected #{inspect(line)} NOT to trip"
      end
    end

    test "the marker embedded mid-sentence in assistant TEXT does NOT trip" do
      event = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "text", "text" => "Next I will commit and print arb done at the end."}
          ]
        }
      }

      ClaudeSession.handle_data(detection_session(), Jason.encode!(event), true)
      refute_received {:__claude_session_done__, _}
    end

    test "the marker on its OWN line inside a multi-line assistant TEXT block trips" do
      event = %{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "all finished here\narb done"}]
        }
      }

      ClaudeSession.handle_data(detection_session(), Jason.encode!(event), true)
      assert_received {:__claude_session_done__, _}
    end
  end

  describe "failed run terminates a live agent (bd-7a0pi8)" do
    test "failing a run SIGKILLs a live port and confirms exit before :failed is observable" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-fail-live")

      :ok = Worker.advance(pid, :implement)

      # A long-lived child. Without the teardown fix it would keep running (and
      # could execute commands against a cwd a worktree-reap is about to delete)
      # long after the run is failed — the orphaned-agent bug (bd-7a0pi8).
      {:ok, port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: ["sh", "-c", "sleep 60"])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      assert os_process_alive?(os_pid)

      :ok = Worker.fail(pid, :simulated_failure)

      # fail_now/2 kills the port synchronously, so by the time the run is
      # observably :failed (the signal the Driver / a :close after-action keys
      # off to reap the worktree) the agent is already dead.
      assert Worker.state(pid).status == :failed
      refute os_process_alive?(os_pid)
      assert Port.info(port) == nil
    end
  end

  describe "exit handling" do
    test "exit status is captured in meta[:exit_status]" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-exit")

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture])

      status =
        eventually(fn ->
          case Worker.state(pid).meta do
            %{exit_status: s} when not is_nil(s) -> s
            _ -> nil
          end
        end)

      assert status == 0
    end

    test ":worker_exited is broadcast on child exit" do
      {pid, task_id} = start_worker()
      cwd = tmp_dir!("cs-exit-bcast")
      topic = "worker:#{task_id}"

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture], topic: topic)

      assert_receive {:worker_exited, ^task_id, 0}, 2_000
    end

    test "non-zero exit status propagates" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-nonzero")

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo failing; exit 42"]
        )

      status =
        eventually(fn ->
          case Worker.state(pid).meta do
            %{exit_status: s} when not is_nil(s) -> s
            _ -> nil
          end
        end)

      assert status == 42
    end
  end

  describe "DATABASE_PATH isolation for worker child processes (bd-bzsqbu)" do
    test "child sees a task-scoped DATABASE_PATH, not the inherited live one" do
      System.put_env("DATABASE_PATH", "/home/ryan/dev/arbiter_dev.sqlite3")
      on_exit(fn -> System.delete_env("DATABASE_PATH") end)

      {pid, task_id} = start_worker()
      cwd = tmp_dir!("cs-db-path")

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo DATABASE_PATH=$DATABASE_PATH"]
        )

      eventually(fn ->
        case Worker.state(pid).meta do
          %{exit_status: s} when not is_nil(s) -> s
          _ -> nil
        end
      end)

      lines = Worker.state(pid).meta.output_lines
      db_line = Enum.find(lines, &String.starts_with?(&1, "DATABASE_PATH="))

      refute db_line == "DATABASE_PATH=/home/ryan/dev/arbiter_dev.sqlite3"
      assert db_line =~ task_id
      assert db_line =~ ".sqlite3"
    end
  end

  describe "buffering" do
    test "output_lines is capped at the configured line cap" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-cap")
      cap = ClaudeSession.line_cap()
      to_emit = cap + 50

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "for i in $(seq 1 #{to_emit}); do echo line-$i; done"]
        )

      eventually(
        fn ->
          case Worker.state(pid).meta do
            %{exit_status: s} when not is_nil(s) -> s
            _ -> nil
          end
        end,
        5_000
      )

      lines = Worker.state(pid).meta.output_lines
      assert length(lines) == cap
      # The cap drops the OLDEST entries (we keep the most recent `cap`).
      assert List.last(lines) == "line-#{to_emit}"
      refute "line-1" in lines
    end
  end

  describe "stream-json parsing" do
    test "assistant text is split into display lines (system/result events summarized)" do
      {pid, task_id} = start_worker()
      cwd = tmp_dir!("cs-sj-text")
      topic = "worker:#{task_id}"
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

      events = [
        %{"type" => "system", "subtype" => "init", "model" => "claude-opus-4-8"},
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "line one\nline two"}]}
        },
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "duration_ms" => 1500,
          "total_cost_usd" => 0.12,
          "result" => "line one\nline two"
        }
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events),
          topic: topic
        )

      wait_for_exit(pid)
      lines = Worker.state(pid).meta.output_lines

      # Assistant text appears as individual display lines, not a JSON blob.
      assert "line one" in lines
      assert "line two" in lines
      refute Enum.any?(lines, &String.contains?(&1, ~s("type":"assistant")))

      # System/result events are summarized, not dumped.
      assert Enum.any?(lines, &String.contains?(&1, "claude session started"))
      assert Enum.any?(lines, &String.contains?(&1, "claude session success"))

      # The result event's duplicated text is NOT re-emitted (only the
      # assistant turn carries it), so "line one" appears exactly once.
      assert Enum.count(lines, &(&1 == "line one")) == 1

      assert_receive {:worker_output, ^task_id, "line one"}, 2_000
    end

    test "tool_use renders as a compact call line" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-sj-tool")

      events = [
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "mix test"}}
            ]
          }
        }
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events)
        )

      wait_for_exit(pid)
      lines = Worker.state(pid).meta.output_lines
      assert "⏵ Bash(mix test)" in lines
    end

    test "decoded events refresh the session's live activity (mirrored into meta)" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-sj-activity")

      events = [
        %{"type" => "system", "subtype" => "init", "model" => "claude-opus-4-8"},
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => "lib/run.ex"}}
            ]
          }
        }
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events)
        )

      wait_for_exit(pid)
      meta = Worker.state(pid).meta

      # The worker is flagged claude-driven and the last activity reflects the
      # most recent action (editing the file), not a frozen workflow step.
      assert meta.claude_session == true
      assert meta.activity.label == "editing run.ex"
      assert %DateTime{} = meta.activity_at
    end

    test "arb done in assistant text completes the worker" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-sj-done")

      events = [
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "text", "text" => "all finished here\narb done"}]
          }
        }
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events)
        )

      status =
        eventually(fn ->
          case Worker.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
      assert Worker.state(pid).meta.result == :claude_done
    end

    test "arb done inside a tool result is displayed but does NOT complete" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-sj-toolresult")

      # Must be :running so :completed would be a legal transition — proving the
      # guard isn't what's keeping us out of :completed.
      :ok = Worker.advance(pid, :implement)

      events = [
        %{
          "type" => "user",
          "message" => %{
            "content" => [
              %{"type" => "tool_result", "content" => "grep hit: 'arb done' in claude_session.ex"}
            ]
          }
        },
        %{"type" => "result", "subtype" => "success", "is_error" => false, "result" => "ok"}
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events)
        )

      wait_for_exit(pid)

      refute Worker.state(pid).status == :completed
      lines = Worker.state(pid).meta.output_lines
      assert Enum.any?(lines, &String.contains?(&1, "grep hit:"))
    end

    test "a stream-json line larger than the port line limit is reassembled and parsed" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("cs-sj-big")

      # Force the port's {:line, 65_536} framing to split this event across
      # noeol/eol fragments; if reassembly fails, JSON.decode fails and the raw
      # braces leak instead of the clean marker line.
      big = String.duplicate("x", 100_000)

      events = [
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "text", "text" => big <> "\nUNIQUE-TAIL-MARKER"}]
          }
        }
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events)
        )

      wait_for_exit(pid)
      lines = Worker.state(pid).meta.output_lines

      assert "UNIQUE-TAIL-MARKER" in lines
      refute Enum.any?(lines, &String.contains?(&1, ~s("type":"assistant")))
    end
  end

  describe "gemini stream-json parsing" do
    test "gemini events render display lines and summarize init/result" do
      {pid, task_id} = start_worker()
      cwd = tmp_dir!("gem-sj-text")
      topic = "worker:#{task_id}"
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

      events = [
        %{"type" => "init", "session_id" => "g-1", "model" => "gemini-2.5-pro"},
        %{"type" => "message", "role" => "user", "content" => "the prompt — arb done"},
        %{"type" => "message", "role" => "assistant", "content" => "doing the work"},
        %{
          "type" => "result",
          "status" => "success",
          "stats" => %{"duration_ms" => 1500, "total_tokens" => 42, "models" => %{}}
        }
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events),
          topic: topic,
          provider: "gemini",
          model: "gemini-2.5-pro"
        )

      wait_for_exit(pid)
      lines = Worker.state(pid).meta.output_lines

      assert "doing the work" in lines
      assert Enum.any?(lines, &String.contains?(&1, "gemini session started"))
      assert Enum.any?(lines, &String.contains?(&1, "gemini session success"))
      # The user prompt echo is not displayed (and must not arm completion).
      refute Enum.any?(lines, &String.contains?(&1, "the prompt"))
      refute Worker.state(pid).status == :completed
    end

    test "arb done in gemini assistant text completes the worker" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("gem-sj-done")

      events = [
        %{"type" => "message", "role" => "assistant", "content" => "wrapping up\narb done"}
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events),
          provider: "gemini",
          model: "gemini-2.5-pro"
        )

      status =
        eventually(fn ->
          case Worker.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
    end

    test "arb done split across two assistant deltas still completes (rolling buffer)" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("gem-sj-split")

      # The sentinel straddles a `delta: true` chunk boundary — per-line
      # detection would miss it; the rolling buffer must still fire.
      events = [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => "all good now arb ",
          "delta" => true
        },
        %{"type" => "message", "role" => "assistant", "content" => "done\n", "delta" => true}
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events),
          provider: "gemini",
          model: "gemini-2.5-pro"
        )

      status =
        eventually(fn ->
          case Worker.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
    end

    test "arb done in a gemini tool result is displayed but does NOT complete" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("gem-sj-toolresult")
      :ok = Worker.advance(pid, :implement)

      events = [
        %{
          "type" => "tool_use",
          "tool_name" => "search_file_content",
          "parameters" => %{"pattern" => "arb done"}
        },
        %{
          "type" => "tool_result",
          "status" => "success",
          "output" => "match: 'arb done' in claude_session.ex"
        },
        %{"type" => "result", "status" => "success", "stats" => %{"models" => %{}}}
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events),
          provider: "gemini",
          model: "gemini-2.5-pro"
        )

      wait_for_exit(pid)

      refute Worker.state(pid).status == :completed
      lines = Worker.state(pid).meta.output_lines
      assert Enum.any?(lines, &String.contains?(&1, "match:"))
    end
  end

  describe "codex exec --json parsing" do
    test "codex events render display lines and summarize the run" do
      {pid, task_id} = start_worker()
      cwd = tmp_dir!("codex-text")
      topic = "worker:#{task_id}"
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

      events = [
        %{"type" => "task_started", "turn_id" => "t1", "model_context_window" => 258_400},
        %{"type" => "agent_message", "message" => "doing the work", "phase" => "final_answer"},
        %{
          "type" => "token_count",
          "info" => %{
            "total_token_usage" => %{
              "input_tokens" => 100,
              "cached_input_tokens" => 10,
              "output_tokens" => 20,
              "total_tokens" => 120
            }
          }
        },
        %{
          "type" => "task_complete",
          "last_agent_message" => "doing the work",
          "duration_ms" => 900
        }
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events),
          topic: topic,
          provider: "codex",
          model: "gpt-5-codex"
        )

      wait_for_exit(pid)
      state = Worker.state(pid)
      lines = state.meta.output_lines

      assert "doing the work" in lines
      assert Enum.any?(lines, &String.contains?(&1, "codex session started"))
      assert Enum.any?(lines, &String.contains?(&1, "codex session complete"))
      refute state.status == :completed
    end

    test "arb done in codex agent_message text completes the worker" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("codex-done")

      events = [
        %{
          "type" => "agent_message",
          "message" => "wrapping up\narb done",
          "phase" => "final_answer"
        }
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events),
          provider: "codex",
          model: "gpt-5-codex"
        )

      status =
        eventually(fn ->
          case Worker.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
    end

    test "arb done inside a codex exec command result does NOT complete" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("codex-toolresult")
      :ok = Worker.advance(pid, :implement)

      events = [
        %{"type" => "exec_command_begin", "command" => ["grep", "-r", "arb done", "."]},
        %{
          "type" => "exec_command_end",
          "exit_code" => 0,
          "aggregated_output" => "match: 'arb done' in claude_session.ex"
        },
        %{"type" => "task_complete", "duration_ms" => 100}
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events),
          provider: "codex",
          model: "gpt-5-codex"
        )

      wait_for_exit(pid)

      refute Worker.state(pid).status == :completed
    end

    test "codex events wrapped in an {id, msg} envelope are still parsed" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("codex-envelope")

      # Some codex builds wrap each event as {"id": ..., "msg": {payload}}. The
      # session must unwrap it so the inner agent_message still arms completion.
      events = [
        %{"id" => "0", "msg" => %{"type" => "agent_message", "message" => "all set\narb done"}}
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events),
          provider: "codex",
          model: "gpt-5-codex"
        )

      status =
        eventually(fn ->
          case Worker.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
    end
  end

  # bd-80kdgy: the exact stdout of a live `codex exec --json` run on codex-cli
  # 0.142.5, which replaced the `event_msg` vocabulary with thread/turn/item.
  # Before the fix every one of these lines decoded fine and then matched no
  # format clause, so the run produced a ZERO-line transcript, zero usage, and
  # never saw `arb done` — yet still exited 0 and looked like a clean success.
  describe "codex 0.142.5 thread/turn/item stream" do
    @codex_0_142_5_events [
      %{"type" => "thread.started", "thread_id" => "019f95ae-eb2a-7e30-ad7a-13502ef33e09"},
      %{"type" => "turn.started"},
      %{
        "type" => "item.completed",
        "item" => %{
          "id" => "item_0",
          "type" => "agent_message",
          "text" => "I'll read `a.txt` now and then return its contents."
        }
      },
      %{
        "type" => "item.started",
        "item" => %{
          "id" => "item_1",
          "type" => "command_execution",
          "command" => "/usr/bin/zsh -lc 'cat a.txt'",
          "aggregated_output" => "",
          "exit_code" => nil,
          "status" => "in_progress"
        }
      },
      %{
        "type" => "item.completed",
        "item" => %{
          "id" => "item_1",
          "type" => "command_execution",
          "command" => "/usr/bin/zsh -lc 'cat a.txt'",
          "aggregated_output" => "hi\n",
          "exit_code" => 0,
          "status" => "completed"
        }
      },
      %{
        "type" => "turn.completed",
        "usage" => %{
          "input_tokens" => 20_900,
          "cached_input_tokens" => 14_592,
          "output_tokens" => 126,
          "reasoning_output_tokens" => 42
        }
      }
    ]

    test "the run is transcribed instead of vanishing" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("codex-v2-transcript")

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, @codex_0_142_5_events),
          provider: "codex",
          model: "gpt-5-codex"
        )

      wait_for_exit(pid)
      lines = Worker.state(pid).meta.output_lines

      assert Enum.any?(lines, &String.contains?(&1, "codex session started"))
      assert Enum.any?(lines, &String.contains?(&1, "I'll read"))
      assert Enum.any?(lines, &String.contains?(&1, "cat a.txt"))
      assert Enum.any?(lines, &String.contains?(&1, "codex session complete"))
      refute Enum.any?(lines, &String.contains?(&1, "unrecognized"))
    end

    # The ticket's `model: null` symptom: no codex `--json` schema names the
    # model the CLI chose, so the ledger can only carry the id Arbiter resolved
    # at spawn time. Assert it survives the whole session pipeline, not just
    # `Stream.usage_fields/2`.
    test "the usage summary carries real tokens and the pre-resolved model" do
      session =
        ClaudeSession.build_session_config("bd-80kdgy", "worker:bd-80kdgy",
          provider: "codex",
          model: "gpt-5-codex",
          redact_values: []
        )
        |> Map.merge(%{line_buf: "", output_lines: [], exit_status: nil, exited_at: nil})

      session =
        Enum.reduce(@codex_0_142_5_events, session, fn event, acc ->
          ClaudeSession.handle_data(acc, Jason.encode!(event), true)
        end)

      usage = ClaudeSession.usage_summary(session)

      assert usage[:model] == "gpt-5-codex"
      assert usage[:session_id] == "019f95ae-eb2a-7e30-ad7a-13502ef33e09"
      assert usage[:tokens_in] > 0
      assert usage[:tokens_out] > 0
    end

    test "arb done in an item.completed agent_message completes the worker" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("codex-v2-done")

      events =
        @codex_0_142_5_events ++
          [
            %{
              "type" => "item.completed",
              "item" => %{"id" => "item_2", "type" => "agent_message", "text" => "hi\n\narb done"}
            }
          ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events),
          provider: "codex",
          model: "gpt-5-codex"
        )

      status =
        eventually(fn ->
          case Worker.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
    end

    test "arb done inside a command_execution result does NOT complete" do
      {pid, _task_id} = start_worker()
      cwd = tmp_dir!("codex-v2-toolresult")
      :ok = Worker.advance(pid, :implement)

      events = [
        %{
          "type" => "item.completed",
          "item" => %{
            "type" => "command_execution",
            "command" => "grep -r 'arb done' .",
            "aggregated_output" => "match: 'arb done' in claude_session.ex",
            "exit_code" => 0,
            "status" => "completed"
          }
        },
        %{"type" => "turn.completed", "usage" => %{"input_tokens" => 1, "output_tokens" => 1}}
      ]

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: stream_json_command(cwd, events),
          provider: "codex",
          model: "gpt-5-codex"
        )

      wait_for_exit(pid)

      refute Worker.state(pid).status == :completed
    end
  end

  describe "concurrent workers" do
    test "each worker sees only its own output" do
      {pid_a, task_a} = start_worker()
      {pid_b, task_b} = start_worker()

      cwd = tmp_dir!("cs-concurrent")

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:#{task_a}")
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:#{task_b}")

      {:ok, _} =
        ClaudeSession.start(
          owner: pid_a,
          worktree_path: cwd,
          command: ["sh", "-c", "echo from-a-1; echo from-a-2"]
        )

      {:ok, _} =
        ClaudeSession.start(
          owner: pid_b,
          worktree_path: cwd,
          command: ["sh", "-c", "echo from-b-1; echo from-b-2"]
        )

      # Wait for both exits.
      eventually(fn ->
        case {Worker.state(pid_a).meta, Worker.state(pid_b).meta} do
          {%{exit_status: a}, %{exit_status: b}} when not is_nil(a) and not is_nil(b) -> true
          _ -> nil
        end
      end)

      a_lines = Worker.state(pid_a).meta.output_lines
      b_lines = Worker.state(pid_b).meta.output_lines

      assert "from-a-1" in a_lines
      assert "from-a-2" in a_lines
      refute "from-b-1" in a_lines
      refute "from-b-2" in a_lines

      assert "from-b-1" in b_lines
      assert "from-b-2" in b_lines
      refute "from-a-1" in b_lines
      refute "from-a-2" in b_lines

      # Each PubSub topic only saw its own task's output.
      assert_receive {:worker_output, ^task_a, "from-a-1"}, 2_000
      assert_receive {:worker_output, ^task_b, "from-b-1"}, 2_000
      refute_receive {:worker_output, ^task_a, "from-b-1"}, 100
      refute_receive {:worker_output, ^task_b, "from-a-1"}, 100
    end
  end

  describe "durable output log" do
    # Drive the emit path directly (no port/DB) with an OutputLog handle wired
    # into the session, exactly as the worker does at session-open. This is
    # the acceptance test: a run longer than the in-memory cap keeps every line
    # in the durable store while the live buffer stays bounded.
    test "a >cap-line run retains ALL lines in the durable store, buffer stays capped" do
      run_id = "run-#{System.unique_integer([:positive])}"
      root = Path.join(System.tmp_dir!(), "cs-durable-#{System.unique_integer([:positive])}")
      prev = Application.get_env(:arbiter, :output_log_root)
      Application.put_env(:arbiter, :output_log_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if prev,
          do: Application.put_env(:arbiter, :output_log_root, prev),
          else: Application.delete_env(:arbiter, :output_log_root)
      end)

      {:ok, handle} = Arbiter.Worker.OutputLog.open(run_id)

      cap = ClaudeSession.line_cap()
      total = cap + 500

      session = %{
        task_id: "bd-durable",
        topic: "worker:durable-#{System.unique_integer([:positive])}",
        line_cap: cap,
        done_regex: ClaudeSession.done_regex(),
        output_lines: [],
        line_buf: "",
        output_log: handle
      }

      session =
        Enum.reduce(1..total, session, fn i, acc ->
          ClaudeSession.handle_data(acc, "line-#{i}", true)
        end)

      # Live buffer: bounded to the cap, holding the most recent lines.
      assert length(session.output_lines) == cap
      newest_first = session.output_lines
      assert List.first(newest_first) == "line-#{total}"
      refute "line-1" in newest_first

      # Durable store: every single line, append-only, oldest first.
      Arbiter.Worker.OutputLog.close(session.output_log)
      assert {:ok, durable} = Arbiter.Worker.OutputLog.read_lines(run_id)
      assert length(durable) == total
      assert List.first(durable) == "line-1"
      assert List.last(durable) == "line-#{total}"
    end

    test "a session without an :output_log handle behaves as before (no durable write)" do
      session = %{
        task_id: "bd-nolog",
        topic: "worker:nolog-#{System.unique_integer([:positive])}",
        line_cap: ClaudeSession.line_cap(),
        done_regex: ClaudeSession.done_regex(),
        output_lines: [],
        line_buf: ""
      }

      session = ClaudeSession.handle_data(session, "solo line", true)
      assert session.output_lines == ["solo line"]
    end
  end

  describe "secret redaction in the emit path (bd-62d3jh)" do
    defp redacting_session(topic, redact_values) do
      %{
        task_id: "bd-redact",
        topic: topic,
        line_cap: ClaudeSession.line_cap(),
        done_regex: ClaudeSession.done_regex(),
        output_lines: [],
        line_buf: "",
        redact_values: redact_values
      }
    end

    test "a secret value is scrubbed from the stored buffer and the PubSub stream" do
      task_id = "bd-redact"
      topic = "worker:redact-#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

      session = redacting_session(topic, ["tok_supersecret"])
      session = ClaudeSession.handle_data(session, "the token is tok_supersecret ok", true)

      # Stored line is redacted.
      assert session.output_lines == ["the token is [REDACTED] ok"]
      # Live stream is redacted — the raw secret never hits a subscriber.
      assert_receive {:worker_output, ^task_id, line}, 2_000
      assert line == "the token is [REDACTED] ok"
      refute line =~ "tok_supersecret"
    end

    test "a session with no redact_values passes lines through unchanged" do
      topic = "worker:noredact-#{System.unique_integer([:positive])}"
      session = redacting_session(topic, [])
      session = ClaudeSession.handle_data(session, "plain tok_supersecret line", true)
      assert session.output_lines == ["plain tok_supersecret line"]
    end
  end

  describe "activity_for_event/1" do
    test "system/init reports starting; result reports wrapping up" do
      assert ClaudeSession.activity_for_event(%{"type" => "system", "subtype" => "init"}) ==
               "starting"

      assert ClaudeSession.activity_for_event(%{"type" => "result", "subtype" => "success"}) ==
               "wrapping up"
    end

    test "thinking and plain text map to coarse phrases" do
      assert assistant([%{"type" => "thinking", "thinking" => "hmm"}]) == "thinking"
      assert assistant([%{"type" => "text", "text" => "Here is the plan"}]) == "responding"
      # Whitespace-only text carries no activity.
      assert assistant([%{"type" => "text", "text" => "  \n "}]) == nil
    end

    test "file tools name the file by basename" do
      assert tool("Edit", %{"file_path" => "apps/arbiter/lib/run.ex"}) == "editing run.ex"
      assert tool("Write", %{"file_path" => "/tmp/new.ex"}) == "writing new.ex"
      assert tool("Read", %{"file_path" => "mix.exs"}) == "reading mix.exs"
      # No path → a graceful placeholder, never a crash.
      assert tool("Edit", %{}) == "editing a file"
    end

    test "Bash distinguishes tests from other commands and truncates" do
      assert tool("Bash", %{"command" => "mix test apps/arbiter"}) == "running tests"
      assert tool("Bash", %{"command" => "git status"}) == "running: git status"

      long = String.duplicate("x", 200)
      activity = tool("Bash", %{"command" => long})
      assert String.starts_with?(activity, "running: ")
      assert String.ends_with?(activity, "…")
    end

    test "search, delegation, research, and unknown tools" do
      assert tool("Grep", %{"pattern" => "foo"}) == "searching"
      assert tool("Glob", %{}) == "searching"
      assert tool("Task", %{"description" => "audit deps"}) == "delegating (audit deps)"
      assert tool("WebSearch", %{}) == "researching"
      # An unrecognised tool surfaces by its own name, still a live signal.
      assert tool("mcp__shortcut__stories-get-by-id", %{}) == "mcp__shortcut__stories-get-by-id"
    end

    test "a turn ending in a tool call reports the tool, not the preceding prose" do
      blocks = [
        %{"type" => "text", "text" => "Let me edit the file"},
        %{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => "run.ex"}}
      ]

      assert assistant(blocks) == "editing run.ex"
    end

    test "events with no salient activity return nil (caller keeps prior activity)" do
      assert ClaudeSession.activity_for_event(%{
               "type" => "user",
               "message" => %{"content" => []}
             }) ==
               nil

      assert ClaudeSession.activity_for_event(%{"type" => "stream_event"}) == nil
    end

    defp assistant(content) do
      ClaudeSession.activity_for_event(%{
        "type" => "assistant",
        "message" => %{"content" => content}
      })
    end

    defp tool(name, input) do
      assistant([%{"type" => "tool_use", "name" => name, "input" => input}])
    end
  end
end
