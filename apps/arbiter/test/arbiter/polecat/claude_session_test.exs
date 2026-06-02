defmodule Arbiter.Polecat.ClaudeSessionTest do
  # async: false — Port + Phoenix.PubSub + shared Polecat registry are all
  # global resources. Per-test unique bead_ids keep cases independent.
  use ExUnit.Case, async: false

  alias Arbiter.Polecat
  alias Arbiter.Polecat.ClaudeSession

  @fixture Path.expand("../../fixtures/echo_with_done.sh", __DIR__)

  defp new_bead_id, do: "gte-013-#{System.unique_integer([:positive])}"

  defp start_polecat(extra_opts \\ []) do
    bead_id = new_bead_id()

    {:ok, pid} =
      Polecat.start(Keyword.merge([bead_id: bead_id, rig: "arbiter"], extra_opts))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    {pid, bead_id}
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

  defp wait_for_exit(pid) do
    eventually(fn ->
      case Polecat.state(pid).meta do
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
      {pid, _bead_id} = start_polecat()
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
      {pid, _} = start_polecat()
      cwd = tmp_dir!("cs-bad")

      assert {:error, {:executable_not_found, "/nope/definitely/missing/binary"}} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: cwd,
                 command: ["/nope/definitely/missing/binary"]
               )
    end

    test "returns {:error, {:invalid_worktree, _}} when cwd doesn't exist" do
      {pid, _} = start_polecat()

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
      {pid, bead_id} = start_polecat()
      cwd = tmp_dir!("cs-lines")

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [@fixture],
          topic: "polecat:#{bead_id}"
        )

      # Wait until the exit_status is recorded — by then all output has
      # already been processed by the polecat.
      eventually(fn ->
        case Polecat.state(pid) do
          %{meta: %{exit_status: status}} when not is_nil(status) -> status
          _ -> nil
        end
      end)

      lines = Polecat.state(pid).meta.output_lines

      assert "starting fake claude session" in lines
      assert "doing important work" in lines
      assert "arb done" in lines
      # Order is preserved (oldest first).
      assert Enum.find_index(lines, &(&1 == "starting fake claude session")) <
               Enum.find_index(lines, &(&1 == "arb done"))
    end

    test "broadcasts :polecat_output on the configured topic" do
      {pid, bead_id} = start_polecat()
      cwd = tmp_dir!("cs-bcast")
      topic = "polecat:#{bead_id}"

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [@fixture],
          topic: topic
        )

      assert_receive {:polecat_output, ^bead_id, "starting fake claude session"}, 2_000
      assert_receive {:polecat_output, ^bead_id, "doing important work"}, 2_000
      assert_receive {:polecat_output, ^bead_id, "arb done"}, 2_000
    end

    test "default topic is polecat:<bead_id> when :topic not provided" do
      {pid, bead_id} = start_polecat()
      cwd = tmp_dir!("cs-default-topic")

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "polecat:#{bead_id}")

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [@fixture]
        )

      assert_receive {:polecat_output, ^bead_id, "starting fake claude session"}, 2_000
    end
  end

  describe "completion detection" do
    test "a line matching ~r/\\barb done\\b/ triggers Polecat.complete/2" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-done")

      # Must be :running for :completed to be a legal transition.
      :ok = Polecat.advance(pid, :implement)

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture])

      status =
        eventually(fn ->
          case Polecat.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
      assert Polecat.state(pid).meta.result == :claude_done
    end

    test "completion signal completes the polecat even when status is :idle" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-idle-done")

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture])

      # claude_driven mode keeps the polecat at :idle (the Machine is not
      # ticked, so advance/2 is never called). The "arb done" signal must
      # still complete the polecat from :idle.
      status =
        eventually(fn ->
          case Polecat.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
      assert Polecat.state(pid).meta.result == :claude_done
    end

    test "a prose line that only mentions the marker as a substring does not trip" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-no-trip")

      :ok = Polecat.advance(pid, :implement)

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
        case Polecat.state(pid).meta do
          %{exit_status: s} when not is_nil(s) -> s
          _ -> nil
        end
      end)

      # The prose line is buffered, but it never flipped the polecat to
      # :completed (it stayed in the :running state from the advance above).
      refute Polecat.state(pid).status == :completed
      assert "discussing arb doneness in the abstract" in Polecat.state(pid).meta.output_lines
    end
  end

  describe "exit handling" do
    test "exit status is captured in meta[:exit_status]" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-exit")

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture])

      status =
        eventually(fn ->
          case Polecat.state(pid).meta do
            %{exit_status: s} when not is_nil(s) -> s
            _ -> nil
          end
        end)

      assert status == 0
    end

    test ":polecat_exited is broadcast on child exit" do
      {pid, bead_id} = start_polecat()
      cwd = tmp_dir!("cs-exit-bcast")
      topic = "polecat:#{bead_id}"

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture], topic: topic)

      assert_receive {:polecat_exited, ^bead_id, 0}, 2_000
    end

    test "non-zero exit status propagates" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-nonzero")

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo failing; exit 42"]
        )

      status =
        eventually(fn ->
          case Polecat.state(pid).meta do
            %{exit_status: s} when not is_nil(s) -> s
            _ -> nil
          end
        end)

      assert status == 42
    end
  end

  describe "buffering" do
    test "output_lines is capped at the configured line cap" do
      {pid, _bead_id} = start_polecat()
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
          case Polecat.state(pid).meta do
            %{exit_status: s} when not is_nil(s) -> s
            _ -> nil
          end
        end,
        5_000
      )

      lines = Polecat.state(pid).meta.output_lines
      assert length(lines) == cap
      # The cap drops the OLDEST entries (we keep the most recent `cap`).
      assert List.last(lines) == "line-#{to_emit}"
      refute "line-1" in lines
    end
  end

  describe "stream-json parsing" do
    test "assistant text is split into display lines (system/result events summarized)" do
      {pid, bead_id} = start_polecat()
      cwd = tmp_dir!("cs-sj-text")
      topic = "polecat:#{bead_id}"
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
      lines = Polecat.state(pid).meta.output_lines

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

      assert_receive {:polecat_output, ^bead_id, "line one"}, 2_000
    end

    test "tool_use renders as a compact call line" do
      {pid, _bead_id} = start_polecat()
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
      lines = Polecat.state(pid).meta.output_lines
      assert "⏵ Bash(mix test)" in lines
    end

    test "arb done in assistant text completes the polecat" do
      {pid, _bead_id} = start_polecat()
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
          case Polecat.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
      assert Polecat.state(pid).meta.result == :claude_done
    end

    test "arb done inside a tool result is displayed but does NOT complete" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-sj-toolresult")

      # Must be :running so :completed would be a legal transition — proving the
      # guard isn't what's keeping us out of :completed.
      :ok = Polecat.advance(pid, :implement)

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

      refute Polecat.state(pid).status == :completed
      lines = Polecat.state(pid).meta.output_lines
      assert Enum.any?(lines, &String.contains?(&1, "grep hit:"))
    end

    test "a stream-json line larger than the port line limit is reassembled and parsed" do
      {pid, _bead_id} = start_polecat()
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
      lines = Polecat.state(pid).meta.output_lines

      assert "UNIQUE-TAIL-MARKER" in lines
      refute Enum.any?(lines, &String.contains?(&1, ~s("type":"assistant")))
    end
  end

  describe "concurrent polecats" do
    test "each polecat sees only its own output" do
      {pid_a, bead_a} = start_polecat()
      {pid_b, bead_b} = start_polecat()

      cwd = tmp_dir!("cs-concurrent")

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "polecat:#{bead_a}")
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "polecat:#{bead_b}")

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
        case {Polecat.state(pid_a).meta, Polecat.state(pid_b).meta} do
          {%{exit_status: a}, %{exit_status: b}} when not is_nil(a) and not is_nil(b) -> true
          _ -> nil
        end
      end)

      a_lines = Polecat.state(pid_a).meta.output_lines
      b_lines = Polecat.state(pid_b).meta.output_lines

      assert "from-a-1" in a_lines
      assert "from-a-2" in a_lines
      refute "from-b-1" in a_lines
      refute "from-b-2" in a_lines

      assert "from-b-1" in b_lines
      assert "from-b-2" in b_lines
      refute "from-a-1" in b_lines
      refute "from-a-2" in b_lines

      # Each PubSub topic only saw its own bead's output.
      assert_receive {:polecat_output, ^bead_a, "from-a-1"}, 2_000
      assert_receive {:polecat_output, ^bead_b, "from-b-1"}, 2_000
      refute_receive {:polecat_output, ^bead_a, "from-b-1"}, 100
      refute_receive {:polecat_output, ^bead_b, "from-a-1"}, 100
    end
  end

  describe "durable output log" do
    # Drive the emit path directly (no port/DB) with an OutputLog handle wired
    # into the session, exactly as the polecat does at session-open. This is
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

      {:ok, handle} = Arbiter.Polecat.OutputLog.open(run_id)

      cap = ClaudeSession.line_cap()
      total = cap + 500

      session = %{
        bead_id: "bd-durable",
        topic: "polecat:durable-#{System.unique_integer([:positive])}",
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
      Arbiter.Polecat.OutputLog.close(session.output_log)
      assert {:ok, durable} = Arbiter.Polecat.OutputLog.read_lines(run_id)
      assert length(durable) == total
      assert List.first(durable) == "line-1"
      assert List.last(durable) == "line-#{total}"
    end

    test "a session without an :output_log handle behaves as before (no durable write)" do
      session = %{
        bead_id: "bd-nolog",
        topic: "polecat:nolog-#{System.unique_integer([:positive])}",
        line_cap: ClaudeSession.line_cap(),
        done_regex: ClaudeSession.done_regex(),
        output_lines: [],
        line_buf: ""
      }

      session = ClaudeSession.handle_data(session, "solo line", true)
      assert session.output_lines == ["solo line"]
    end
  end
end
