defmodule Arbiter.Sessions.Terminal.TmuxTest do
  @moduledoc """
  Command shapes for the real terminal back end (bd-3ymdvi, phase 4).

  Every streaming operation is still a **synchronous shell-out that returns**
  — the same property phase 1 established for the control operations, and the
  reason `Arbiter.Sessions.NoPtyHandleTest` can keep asserting that nothing in
  the session path owns a handle on the PTY. So the seam is the same scripted
  `Arbiter.Sessions.Runner`, and what is asserted here is the argv.

  `Arbiter.Integration.SessionTmuxTest` runs the same operations against a
  real tmux server; this file pins the exact arguments so a silent change
  ("`-e` dropped from capture-pane") fails loudly rather than degrading colour
  output in a browser nobody is looking at.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Sessions.Session
  alias Arbiter.Sessions.Terminal.Tmux
  alias Arbiter.Test.SessionRunnerStub

  @socket "/run/user/1000/arbiter/session-abc.sock"
  @pipe "/run/user/1000/arbiter/session-abc.out"

  setup do
    SessionRunnerStub.reset()
    SessionRunnerStub.script(fn _cmd, _args, _opts -> {"", 0} end)
    %{session: %Session{id: "abc", tmux_socket: @socket}}
  end

  defp opts, do: [runner: SessionRunnerStub]

  defp last_args do
    {"tmux", args, _opts} = List.last(SessionRunnerStub.calls("tmux"))
    args
  end

  describe "start_stream/3" do
    test "enables pipe-pane and captures the snapshot in one tmux command list", %{
      session: session
    } do
      SessionRunnerStub.script(fn "tmux", _args, _opts ->
        {"\x011\t2\x02\nscrollback\e[0m\n", 0}
      end)

      assert {:ok, %{snapshot: "scrollback\e[0m\e[3;2H"}} =
               Tmux.start_stream(session, @pipe, opts() ++ [snapshot_lines: 500])

      assert last_args() == [
               "-S",
               @socket,
               "pipe-pane",
               "-O",
               "-t",
               "coord",
               "cat >> '#{@pipe}'",
               ";",
               "display-message",
               "-p",
               "-t",
               "coord",
               "\x01\#{cursor_x}\t\#{cursor_y}\x02",
               ";",
               "capture-pane",
               "-p",
               "-e",
               "-S",
               "-500",
               "-t",
               "coord"
             ]
    end

    test "rewrites bare LFs to CRLF so a repaint doesn't staircase", %{session: session} do
      # `\n` right after the \x02 marker is `display-message`'s own trailing
      # newline (same as everywhere else this command talks to
      # `display-message`); the `\n` terminating the last line is
      # `capture-pane`'s — real tmux emits both, and finalize_capture must
      # drop each rather than let it become a spurious blank line or an
      # extra scroll on repaint.
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"\x010\t0\x02\none\ntwo\n", 0} end)

      assert {:ok, %{snapshot: snapshot}} = Tmux.start_stream(session, @pipe, opts())
      assert snapshot == "one\r\ntwo\e[1;1H"
    end

    test "leaves the snapshot untouched when the cursor query is unparseable", %{
      session: session
    } do
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"no cursor marker here", 0} end)

      assert {:ok, %{snapshot: "no cursor marker here"}} =
               Tmux.start_stream(session, @pipe, opts())
    end

    test "does not merge stderr into the snapshot bytes", %{session: session} do
      # capture-pane's stdout *is* the terminal content. A tmux warning folded
      # into it would be rendered as if the agent had printed it.
      assert {:ok, _} = Tmux.start_stream(session, @pipe, opts())

      {"tmux", _args, run_opts} = List.last(SessionRunnerStub.calls("tmux"))
      assert Keyword.get(run_opts, :stderr_to_stdout) != true
    end

    test "single-quotes the pipe path so a path with a space cannot split", %{session: session} do
      assert {:ok, _} = Tmux.start_stream(session, "/tmp/odd dir/s.out", opts())
      assert "cat >> '/tmp/odd dir/s.out'" in last_args()
    end

    test "surfaces a non-zero exit as an error", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"no server running", 1} end)

      assert {:error, {:tmux_failed, 1, "no server running"}} =
               Tmux.start_stream(session, @pipe, opts())
    end
  end

  describe "stop_stream/2" do
    test "closes the pipe with a bare pipe-pane", %{session: session} do
      assert :ok = Tmux.stop_stream(session, opts())
      assert last_args() == ["-S", @socket, "pipe-pane", "-t", "coord"]
    end

    test "is best-effort — a dead server is not an error", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"no server running", 1} end)
      assert :ok = Tmux.stop_stream(session, opts())
    end

    test "swallows tmux's stderr rather than printing it", %{session: session} do
      assert :ok = Tmux.stop_stream(session, opts())

      {"tmux", _args, run_opts} = List.last(SessionRunnerStub.calls("tmux"))
      assert Keyword.get(run_opts, :stderr_to_stdout) == true
    end
  end

  describe "streaming?/2" do
    test "reads pane_pipe", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"1\n", 0} end)

      assert Tmux.streaming?(session, opts())

      assert last_args() == [
               "-S",
               @socket,
               "display-message",
               "-p",
               "-t",
               "coord",
               "\#{pane_pipe}"
             ]
    end

    test "is false when the pane is not piping", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"0\n", 0} end)
      refute Tmux.streaming?(session, opts())
    end

    test "is false when tmux fails", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"", 1} end)
      refute Tmux.streaming?(session, opts())
    end
  end

  describe "snapshot/2" do
    test "captures with escape sequences preserved and the cursor restored", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts ->
        {"\x0110\t3\x02\n\e[31mred\e[0m\n", 0}
      end)

      assert {:ok, "\e[31mred\e[0m\e[4;11H"} =
               Tmux.snapshot(session, opts() ++ [snapshot_lines: 100])

      assert last_args() == [
               "-S",
               @socket,
               "display-message",
               "-p",
               "-t",
               "coord",
               "\x01\#{cursor_x}\t\#{cursor_y}\x02",
               ";",
               "capture-pane",
               "-p",
               "-e",
               "-S",
               "-100",
               "-t",
               "coord"
             ]
    end

    test "rewrites bare LFs to CRLF so a repaint doesn't staircase", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts ->
        {"\x010\t0\x02\nfirst\nsecond\n", 0}
      end)

      assert {:ok, "first\r\nsecond\e[1;1H"} = Tmux.snapshot(session, opts())
    end

    test "does not touch an already-CRLF line ending", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"\x010\t0\x02\na\r\nb\n", 0} end)

      assert {:ok, "a\r\nb\e[1;1H"} = Tmux.snapshot(session, opts())
    end

    test "errors on a non-zero exit", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"no server running", 1} end)
      assert {:error, {:tmux_failed, 1, "no server running"}} = Tmux.snapshot(session, opts())
    end
  end

  describe "send_input/3" do
    test "sends raw bytes as hex so control characters survive", %{session: session} do
      assert :ok = Tmux.send_input(session, <<0x1B, ?[, ?A, 0x0D>>, opts())

      assert last_args() == [
               "-S",
               @socket,
               "send-keys",
               "-t",
               "coord",
               "-H",
               "1b",
               "5b",
               "41",
               "0d"
             ]
    end

    test "zero-pads bytes below 0x10", %{session: session} do
      assert :ok = Tmux.send_input(session, <<0x03, 0x00>>, opts())
      assert last_args() == ["-S", @socket, "send-keys", "-t", "coord", "-H", "03", "00"]
    end

    test "chunks a large paste rather than building one enormous argv", %{session: session} do
      assert :ok = Tmux.send_input(session, :binary.copy("a", 1500), opts())

      calls = SessionRunnerStub.calls("tmux")
      assert length(calls) == 3

      hex_counts =
        Enum.map(calls, fn {_cmd, args, _opts} ->
          length(args) - Enum.find_index(args, &(&1 == "-H")) - 1
        end)

      assert hex_counts == [512, 512, 476]
    end

    test "sends nothing for empty input", %{session: session} do
      assert :ok = Tmux.send_input(session, "", opts())
      assert SessionRunnerStub.calls("tmux") == []
    end
  end

  describe "resize/4" do
    test "resizes the window, which pins window-size to manual", %{session: session} do
      assert :ok = Tmux.resize(session, 120, 40, opts())

      assert last_args() == [
               "-S",
               @socket,
               "resize-window",
               "-t",
               "coord",
               "-x",
               "120",
               "-y",
               "40"
             ]
    end
  end

  describe "geometry/2" do
    test "parses width, height and title out of one display-message", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"120\t40\tclaude — arbiter\n", 0} end)

      assert {:ok, %{cols: 120, rows: 40, title: "claude — arbiter"}} =
               Tmux.geometry(session, opts())
    end

    test "tolerates a title containing tabs by taking the first two fields", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"80\t24\ta\tb\n", 0} end)
      assert {:ok, %{cols: 80, rows: 24, title: "a\tb"}} = Tmux.geometry(session, opts())
    end

    test "errors when tmux has no session to describe", %{session: session} do
      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"can't find session", 1} end)
      assert {:error, {:tmux_failed, 1, "can't find session"}} = Tmux.geometry(session, opts())
    end
  end

  describe "alive?/2" do
    test "is has-session's exit status", %{session: session} do
      assert Tmux.alive?(session, opts())
      assert last_args() == ["-S", @socket, "has-session", "-t", "coord"]

      SessionRunnerStub.script(fn "tmux", _args, _opts -> {"", 1} end)
      refute Tmux.alive?(session, opts())
    end
  end
end
