defmodule Arbiter.Integration.SessionTmuxTest do
  @moduledoc """
  The transport against a **real tmux server** (bd-3ymdvi, phase 4 AC 2/7).

  `Arbiter.Sessions.StreamTest` proves the protocol against a scripted PTY,
  which is the right way to test sequence numbers, ring bounds and
  backpressure — you cannot make a real terminal produce exactly 4,096 bytes
  on demand. It cannot prove the part that is not protocol: that
  `pipe-pane -O`, `capture-pane -p -e`, `send-keys -H`, `resize-window` and
  `has-session` actually behave the way `Arbiter.Sessions.Terminal.Tmux`
  assumes, on the tmux that is installed. Getting one of those wrong is silent
  — colour disappears, or a keystroke is interpreted as a key *name* — so it
  is measured here against the real thing.

  This is the cheap half of the live tests: a tmux server on a scratch socket
  in a private tmp dir, no systemd, no scope, no session row. It therefore runs in the
  normal suite; `test_helper.exs` excludes it only when tmux is not installed.
  (`Arbiter.Integration.SessionScopeTest` is the `:live_systemd` half, and
  stays opt-in.)

  ## Teardown discipline

  Every command here addresses an **exact** socket path in this test's own
  private scratch directory, and teardown is `kill-server` on that socket. Never a pattern: this repo has an incident class around pattern
  kills, and a `pkill -f tmux` here would take down the operator's own
  sessions along with the live coordinator's.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Sessions.Frame
  alias Arbiter.Sessions.Session
  alias Arbiter.Sessions.Stream
  alias Arbiter.Sessions.Terminal.Tmux

  @moduletag :tmux
  @moduletag timeout: 60_000

  # An interactive shell: it echoes what is typed, prints what it is told to
  # print, and exits when asked — which is every lifecycle this file needs.
  @payload "sh"

  @opts [poll_interval_ms: 10, alive_interval_ms: 100, linger_ms: 0]

  setup do
    id = Ash.UUID.generate()

    # NOT ExUnit's `tmp_dir`: a unix socket path is capped around 108 bytes and
    # `tmp/<Module>/<full test name>/` blows straight through it. Short, unique,
    # and private to this test — /tmp is shared with every other worker on the
    # host, so the name carries both a VM-unique integer and the OS pid.
    dir =
      Path.join(
        System.tmp_dir!(),
        "arb-tmux-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    socket = Path.join(dir, "s.sock")

    {_out, 0} =
      System.cmd(
        "tmux",
        ["-S", socket, "new-session", "-d", "-s", "coord", "-x", "80", "-y", "24", @payload],
        stderr_to_stdout: true
      )

    on_exit(fn ->
      Stream.stop(id)
      _ = System.cmd("tmux", ["-S", socket, "kill-server"], stderr_to_stdout: true)
      File.rm_rf(dir)
    end)

    session = %Session{id: id, tmux_socket: socket}

    %{id: id, session: session, socket: socket, opts: Keyword.put(@opts, :pipe_dir, dir)}
  end

  defp tmux(socket, args) do
    {out, status} = System.cmd("tmux", ["-S", socket | args], stderr_to_stdout: true)
    {String.trim(out), status}
  end

  # Drain stdout frames until `fun` says the accumulated bytes are enough.
  defp await_output(id, fun, acc \\ <<>>, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    cond do
      fun.(acc) ->
        acc

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out waiting for pane output; got #{inspect(acc, limit: 60)}")

      true ->
        receive do
          {:session_stdout, ^id, frame} ->
            {:ok, _seq, data} = Frame.decode(frame)
            await_output(id, fun, acc <> data, deadline)
        after
          250 -> await_output(id, fun, acc, deadline)
        end
    end
  end

  defp type(id, line), do: :ok = Stream.input(id, line <> "\r")

  test "attach streams real pane output and types real keystrokes", %{
    id: id,
    session: session,
    opts: opts
  } do
    assert {:ok, attached} = Stream.attach(session, opts)
    assert attached.mode == :snapshot
    assert is_binary(attached.snapshot)
    assert attached.meta.cols == 80
    assert attached.meta.rows == 24

    type(id, "printf 'phase-four-ok\\n'")

    output = await_output(id, &String.contains?(&1, "phase-four-ok"))
    assert output =~ "phase-four-ok"
  end

  test "a split multi-byte character and an ANSI escape survive the round trip", %{
    id: id,
    session: session,
    opts: opts
  } do
    {:ok, _attached} = Stream.attach(session, opts)

    # `printf` writes the raw bytes; the shell's echo of the typed line only
    # contains the literal backslash escapes, so finding the raw bytes in the
    # stream proves they came out of the pane, not out of the keyboard.
    type(id, "printf 'caf\\303\\251 \\033[31mRED\\033[0m end\\n'")

    accented = <<0xC3, 0xA9>>
    red = <<0x1B, "[31m">>
    reset = <<0x1B, "[0m">>

    output =
      await_output(id, fn acc ->
        String.contains?(acc, accented) and String.contains?(acc, red) and
          String.contains?(acc, reset)
      end)

    assert String.contains?(output, "caf" <> accented)
    assert String.contains?(output, red <> "RED" <> reset)
  end

  test "hex stdin puts control bytes into the pane, not key names", %{
    id: id,
    session: session,
    opts: opts
  } do
    {:ok, _attached} = Stream.attach(session, opts)

    # C-c: a `send-keys` that went through key-name parsing would type the
    # literal text "C-c" instead of interrupting.
    type(id, "printf 'before\\n'")
    _ = await_output(id, &String.contains?(&1, "before"))

    :ok = Stream.input(id, <<0x03>>)
    type(id, "printf 'after\\n'")

    assert await_output(id, &String.contains?(&1, "after")) =~ "after"
  end

  test "detaching drops the reader and leaves the tmux session alive (AC 2)", %{
    id: id,
    session: session,
    socket: socket,
    opts: opts
  } do
    {:ok, _attached} = Stream.attach(session, opts)
    reader = Stream.whereis(id)
    ref = Process.monitor(reader)

    assert tmux(socket, ["display-message", "-p", "-t", "coord", "\#{pane_pipe}"]) == {"1", 0}

    :ok = Stream.detach(id, self())
    assert_receive {:DOWN, ^ref, :process, ^reader, :normal}, 2_000

    # The session outlives its reader — which is the whole point.
    assert {_out, 0} = tmux(socket, ["has-session", "-t", "coord"])
    assert tmux(socket, ["display-message", "-p", "-t", "coord", "\#{pane_pipe}"]) == {"0", 0}
    assert Tmux.alive?(session)
  end

  test "a resize reaches the real pane and comes back in meta", %{
    id: id,
    session: session,
    socket: socket,
    opts: opts
  } do
    {:ok, _attached} = Stream.attach(session, opts)

    assert :ok = Stream.resize(id, 132, 43, self())

    assert tmux(socket, ["display-message", "-p", "-t", "coord", "\#{pane_width}x\#{pane_height}"]) ==
             {"132x43", 0}

    assert_receive {:session_meta, ^id, %{cols: 132, rows: 43}}, 2_000
    assert {:ok, %{cols: 132, rows: 43}} = Tmux.geometry(session)
  end

  test "a reader restarted mid-stream resumes from the pipe file, gapless", %{
    id: id,
    session: session,
    opts: opts
  } do
    {:ok, attached} = Stream.attach(session, opts)
    resume_from = attached.seq

    type(id, "printf 'before-the-restart\\n'")
    _ = await_output(id, &String.contains?(&1, "before-the-restart"))

    # Exactly what an `arbiter` restart looks like to a session: the reader
    # goes away, the tmux session does not, and the pipe file is still there.
    :ok = Stream.stop(id)

    {:ok, resumed} = Stream.attach(session, Keyword.put(opts, :last_seq, resume_from))

    assert resumed.mode == :resumed

    replayed =
      resumed.replay
      |> Enum.map(fn frame ->
        {:ok, _seq, data} = Frame.decode(frame)
        data
      end)
      |> IO.iodata_to_binary()

    assert replayed =~ "before-the-restart"
  end

  test "an exited pane yields an exit event and stops the reader (AC 6)", %{
    id: id,
    session: session,
    opts: opts
  } do
    {:ok, _attached} = Stream.attach(session, opts)
    reader = Stream.whereis(id)
    ref = Process.monitor(reader)

    type(id, "exit")

    assert_receive {:session_exit, ^id, %{reason: "exited"}}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^reader, :normal}, 2_000
  end
end
