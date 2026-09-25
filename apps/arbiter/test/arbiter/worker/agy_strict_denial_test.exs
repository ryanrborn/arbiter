defmodule Arbiter.Worker.AgyStrictDenialTest do
  @moduledoc """
  bd-7wymls: under `:strict`, a command agy's `permissions.allow` does not name
  is *soft-denied* by headless agy, and agy then ENDS the turn (exit 0,
  `result.denied_actions`, a `jetski: no output produced …` stderr notice) —
  the model never gets to proceed without it. These tests drive the captured
  agy 1.2.11 streams (`test/fixtures/agy_strict_denial_*.jsonl`,
  `agy_explicit_deny_continues.jsonl`) through the real session parser and a
  real `Worker` + port, with a stub `agy` script standing in for the CLI.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

  @fixtures Path.expand("../../fixtures", __DIR__)
  @turn_end Path.join(@fixtures, "agy_strict_denial_turn_end.jsonl")
  @explicit_deny Path.join(@fixtures, "agy_explicit_deny_continues.jsonl")
  @conversation_id "fab40d9a-ea5a-4456-bcec-ee9bdde56f64"

  defp new_session(opts \\ []) do
    task_id = "bd-agy-deny-#{System.unique_integer([:positive])}"

    %{
      task_id: task_id,
      run_id: nil,
      topic: "worker:" <> task_id,
      line_cap: ClaudeSession.line_cap(),
      done_regex: ClaudeSession.done_regex(),
      output_lines: [],
      line_buf: "",
      provider: Keyword.get(opts, :provider, "gemini"),
      redact_values: []
    }
  end

  defp feed_lines(session, lines),
    do: Enum.reduce(lines, session, &ClaudeSession.handle_data(&2, &1, true))

  defp fixture_lines(path),
    do: path |> File.read!() |> String.split("\n", trim: true)

  describe "ClaudeSession: detecting a denial-ended agy turn" do
    test "the captured strict soft-deny marks the turn as denial-ended and names the command" do
      session = new_session() |> feed_lines(fixture_lines(@turn_end))

      assert ClaudeSession.denial_ended_turn?(session)
      # The denied step is a DONE step with no output — the command is
      # attributed from the last `run_command` agy started, not an ERROR step.
      assert session.denied_command == "whoami"
      assert session.denied_command_line == "whoami"
    end

    test "an explicit permissions.deny hit is returned to the model, so the turn is NOT denial-ended" do
      session = new_session() |> feed_lines(fixture_lines(@explicit_deny))

      refute ClaudeSession.denial_ended_turn?(session)
      # Still attributed, for the notes-gate failure reason.
      assert session.denied_command == "whoami"
    end

    test "the stderr notice alone (a build without result.denied_actions) is enough" do
      lines =
        @turn_end
        |> fixture_lines()
        |> Enum.map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"event" => "result"} = ev} ->
              Jason.encode!(update_in(ev, ["result"], &Map.delete(&1, "denied_actions")))

            _ ->
              line
          end
        end)

      session = new_session() |> feed_lines(lines)

      assert ClaudeSession.denial_ended_turn?(session)
      assert session.denied_command == "whoami"
    end

    test "the notice text inside a tool's OUTPUT does not count — only agy's own stderr line does" do
      notice = @turn_end |> fixture_lines() |> Enum.find(&String.starts_with?(&1, "jetski:"))

      tool_done =
        Jason.encode!(%{
          "event" => "step_update",
          "step_update" => %{
            "step_index" => 2,
            "state" => "DONE",
            "step_type" => "tool",
            "tool_name" => "run_command",
            "tool_info" => %{
              "name" => "run_command",
              "parameters" => %{"CommandLine" => "grep -r jetski lib"},
              "output" => notice
            }
          }
        })

      session = new_session() |> feed_lines([tool_done])

      refute ClaudeSession.denial_ended_turn?(session)
    end

    test "a non-gemini session never reads the notice as an agy denial" do
      notice = @turn_end |> fixture_lines() |> Enum.find(&String.starts_with?(&1, "jetski:"))
      session = new_session(provider: "claude") |> feed_lines([notice])

      refute ClaudeSession.denial_ended_turn?(session)
    end
  end

  describe "Worker.resume_continue_prompt/3 for :permission_denied" do
    test "names the denied command, forbids retrying it, and points at notes + arb done" do
      prompt =
        Worker.resume_continue_prompt(:permission_denied, "bd-x",
          denied_command: "echo probe > /tmp/agy-strict-probe.txt"
        )

      assert prompt =~ "`echo probe > /tmp/agy-strict-probe.txt`"
      assert prompt =~ "Do NOT retry"
      assert prompt =~ "one command per"
      assert prompt =~ "task_update_progress"
      assert prompt =~ "arb done"
    end

    test "still reads sensibly with no command attributed" do
      prompt = Worker.resume_continue_prompt(:permission_denied, "bd-x", [])
      assert prompt =~ "denied"
      assert prompt =~ "arb done"
    end
  end

  describe "Worker: a denial-ended agy session resumes the same conversation" do
    setup do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "agy-deny-ws-#{System.unique_integer([:positive])}",
          prefix: "ad",
          config: %{}
        })

      dir = Path.join(System.tmp_dir!(), "agy-deny-#{System.unique_integer([:positive])}")
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)
      on_exit(fn -> File.rm_rf(dir) end)

      # A stub `agy` — never the real CLI (the basename is what makes
      # `Gemini.splice_prompt/2` emit `--conversation`). The first run replays
      # the captured soft-deny turn; a `--conversation` resume records its
      # argv, then waits for the test's go-file before printing `arb done`.
      stub = Path.join(bin, "agy")

      File.write!(stub, """
      #!/bin/sh
      case " $* " in
        *" --conversation "*)
          printf '%s\\0' "$@" > '#{dir}/resume_argv'
          i=0
          while [ ! -f '#{dir}/go' ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
          echo 'arb done'
          exit 0 ;;
        *)
          cat '#{@turn_end}'
          exit 0 ;;
      esac
      """)

      File.chmod!(stub, 0o755)
      %{ws: ws, dir: dir, stub: stub}
    end

    defp wait_until(fun, timeout \\ 10_000) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_wait(fun, deadline)
    end

    defp do_wait(fun, deadline) do
      cond do
        fun.() ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          flunk("condition not met within timeout")

        true ->
          Process.sleep(25)
          do_wait(fun, deadline)
      end
    end

    test "a task-type worker is resumed with a denial prompt instead of failing the notes gate",
         %{ws: ws, dir: dir, stub: stub} do
      {:ok, task} =
        Ash.create(Issue, %{title: "strict probe", workspace_id: ws.id, issue_type: :task})

      {:ok, task} = Ash.update(task, %{status: :in_progress})

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "unknown",
          workspace_id: ws.id,
          # Cap 0: before bd-7wymls the clean exit went straight to the notes
          # gate and failed here with "strict policy denied … `whoami`".
          meta: %{issue_type: :task, review_spawn: false, notes_nudge_cap: 0}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: dir,
          provider: "gemini",
          command: [stub, "-p", "original task prompt", "--output-format", "stream-json"]
        )

      argv_file = Path.join(dir, "resume_argv")
      wait_until(fn -> File.exists?(argv_file) and File.read!(argv_file) =~ @conversation_id end)

      argv = argv_file |> File.read!() |> String.split(<<0>>, trim: true)
      idx = Enum.find_index(argv, &(&1 == "--conversation"))
      assert idx, "resume must continue the SAME agy conversation: #{inspect(argv)}"
      assert Enum.at(argv, idx + 1) == @conversation_id

      prompt = Enum.at(argv, Enum.find_index(argv, &(&1 == "-p")) + 1)
      assert prompt =~ "`whoami`"
      assert prompt =~ "Do NOT retry"
      refute prompt =~ "original task prompt"

      snap = Worker.state(pid)
      assert snap.status == :running
      assert snap.meta.resume_attempts == 1
      refute Map.has_key?(snap.meta, :notes_gate_detail)

      # The resumed agent records its findings, then prints `arb done`.
      {:ok, _} = Ash.update(task, %{notes: "## Findings\n\nwhoami was denied."}, action: :update)
      File.write!(Path.join(dir, "go"), "")

      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end)
    end
  end
end
