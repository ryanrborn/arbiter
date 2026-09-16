defmodule ArbiterWeb.SessionTransportSocketTest do
  @moduledoc """
  The terminal transport over a **real WebSocket**, driven by the same client
  the coordinator will run for acceptance criterion 8 (bd-3ymdvi).

  ## Why this exists on top of the other two channel test files

  `ArbiterWeb.SessionChannelTest` uses `Phoenix.ChannelTest`, which installs a
  no-op serializer and hands payloads to the test as Elixir terms — it proves
  the channel *pushes* `{:binary, frame}`, not that a browser receives those
  bytes. `ArbiterWeb.SessionWireFormatTest` closes half of that gap by running
  the production `Phoenix.Socket.V2.JSONSerializer` in both directions, but
  still never crosses a socket.

  This file crosses one: Bandit on a real port, a real WebSocket upgrade, the
  real `phoenix.js` the dashboard ships, and `scripts/verify_session_transport.mjs`
  doing the `seq` arithmetic. Nothing here is a stand-in except the pane.

  ## What it is for

  Criterion 8 is post-merge and coordinator-owned — it needs a running arbiter
  to `systemctl --user restart`, and phase 5's browser terminal does not exist
  yet, so the coordinator will point that script at the live host instead. What
  is reachable pre-merge is proving the *script* is right: that it decodes the
  `ARB1` frames, that its rejoin carries the newest `last_seq` rather than the
  one it first connected with (a real phoenix.js trap — join params are only
  re-evaluated when they are a closure), and that its gap/duplicate arithmetic
  reports `PASS` on a genuinely gapless resume and not by default.

  So the restart is simulated the way the real one behaves: the listener goes
  away *and* the reader (`Arbiter.Sessions.Stream`) is stopped, output keeps
  accumulating in the pipe file while both are down — which is what really
  happens, because the `cat` tmux spawned lives in the session's own systemd
  scope, not in the BEAM — and then both come back. If the script says `PASS`
  here, a `PASS` on the live host means what it claims.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the session row.
  use ArbiterWeb.ChannelCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Stream
  alias Arbiter.Test.NoopRunner
  alias Arbiter.Test.ScriptedPty

  @moduletag :tmp_dir
  @moduletag :node

  @root Path.expand("../../../../..", __DIR__)
  @script Path.join(@root, "scripts/verify_session_transport.mjs")

  # Bandit's own `child_spec/1` uses `id: {Bandit, make_ref()}`, which
  # `stop_supervised!` has no way to name — hence an explicit id.
  @listener_id :session_transport_listener

  @head "before-"
  @tail "the-restart\n"
  @during "during-the-outage\n"
  @resumed "after-the-restart\n"
  @total byte_size(@head) + byte_size(@tail) + byte_size(@during) + byte_size(@resumed)

  setup %{tmp_dir: tmp_dir} do
    put_env(:sessions_runtime_dir, tmp_dir)
    put_env(:sessions_terminal, ScriptedPty)
    put_env(:sessions_runner, NoopRunner)

    put_env(Arbiter.Sessions.Stream,
      poll_interval_ms: 5,
      alive_interval_ms: 50
    )

    {:ok, session} = Sessions.launch(cwd: tmp_dir, runner: NoopRunner)
    ScriptedPty.install(session.id, snapshot: "SNAP", cols: 80, rows: 24, title: "scripted")
    on_exit(fn -> Stream.stop(session.id) end)

    %{session: session, http_port: start_listener!()}
  end

  test "a real WebSocket client resumes gaplessly across a listener + reader restart",
       %{session: session, http_port: http_port} do
    client = start_client!(session.id, http_port)
    await_output(client, ~r/joined \(#1\)/, 15_000)

    # ---- 1. live output reaches a real browser-shaped client ---------------
    # Split across two writes so the pre-restart stream is more than one frame.
    ScriptedPty.emit(session.id, @head)
    ScriptedPty.emit(session.id, @tail)
    await_output(client, ~r/before-the-restart/, 10_000)

    # ---- 2. the restart: listener and reader both go away ------------------
    stop_supervised!(@listener_id)
    Stream.stop(session.id)

    # The pane keeps writing while arbiter is down. This is the byte range the
    # whole criterion is about: nobody is listening when it is produced.
    ScriptedPty.emit(session.id, @during)

    # Same port, so the client's own reconnect finds the server again — this
    # stands in for the unit coming back up on 4848.
    ^http_port = start_listener!(http_port)

    # ---- 3. the client comes back and picks the byte stream back up --------
    await_output(client, ~r/joined \(#2\)/, 20_000)
    ScriptedPty.emit(session.id, @resumed)

    output = await_output(client, ~r/RESULT: (PASS|FAIL)/, 20_000)

    # The transcript is the deliverable for AC 8, so make it printable:
    # `ARB_SHOW_TRANSCRIPT=1 mix test …` shows exactly what the coordinator
    # will read off the live host.
    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_session_transport.mjs ---\n" <> output)
    end

    assert output =~ "RESULT: PASS",
           "verify_session_transport.mjs did not report a clean resume:\n#{output}"

    assert output =~ "reconnects=1"
    assert output =~ "gaps=0"
    assert output =~ "duplicates=0"
    assert output =~ "bytes=#{@total}"

    # `--echo` writes the terminal bytes themselves, so the outage range is
    # asserted on its content and not only on the tally.
    assert output =~ @during

    assert {:ok, 0} = await_exit(client, 15_000)
  end

  # -- listener ---------------------------------------------------------------

  # `port: 0` lets the kernel pick, then we read the bound port back off Thousand
  # Island; the restart rebinds that exact port, which is safe (Thousand Island
  # sets `reuseaddr`) and, unlike probing for a free port and then binding it,
  # never leaves a window for a sibling VM on this host to take it.
  defp start_listener!(port \\ 0) do
    listener =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: ArbiterWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: port},
          id: @listener_id
        )
      )

    {:ok, {_address, bound}} = ThousandIsland.listener_info(listener)
    bound
  end

  # -- the node client --------------------------------------------------------

  defp start_client!(session_id, http_port) do
    node = System.find_executable("node") || flunk("node is required by the :node tag")

    args = [
      @script,
      "--session",
      session_id,
      "--url",
      # The socket mount point — phoenix.js appends `/websocket` itself.
      "ws://127.0.0.1:#{http_port}/session",
      "--echo",
      # Deterministic stop: report as soon as every byte this test emits has
      # been accounted for, rather than on a timer.
      "--until-bytes",
      to_string(@total),
      # A backstop so a wedged client cannot outlive the suite — on the happy
      # path `--until-bytes` fires long before this.
      "--seconds",
      "60"
    ]

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: @root
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    # Exact-PID teardown only. This repo has an incident class around
    # pattern-based kills reaching the live coordinator.
    on_exit(fn -> System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true) end)

    %{port: port}
  end

  # The client is chatty by design — that transcript is what an operator reads
  # on the live host — so the test drives off the very same lines, and keeps
  # the whole thing so a failure message starts at the join rather than
  # mid-stream.
  defp await_output(client, pattern, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    transcript = collect(client, pattern, deadline, Process.get(:transcript, ""))
    Process.put(:transcript, transcript)
    transcript
  end

  defp collect(client, pattern, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)
    port = client.port

    cond do
      Regex.match?(pattern, acc) ->
        acc

      remaining <= 0 ->
        flunk("timed out waiting for #{inspect(pattern)}. Client said:\n#{acc}")

      true ->
        receive do
          {^port, {:data, data}} ->
            collect(client, pattern, deadline, acc <> data)

          {^port, {:exit_status, status}} ->
            Process.put(:client_exit_status, status)

            if Regex.match?(pattern, acc) do
              acc
            else
              flunk("client exited (#{status}) before #{inspect(pattern)}. It said:\n#{acc}")
            end
        after
          min(remaining, 250) -> collect(client, pattern, deadline, acc)
        end
    end
  end

  defp await_exit(client, timeout) do
    case Process.get(:client_exit_status) do
      nil -> receive_exit(client, timeout)
      status -> {:ok, status}
    end
  end

  defp receive_exit(client, timeout) do
    port = client.port

    receive do
      {^port, {:exit_status, status}} -> {:ok, status}
      {^port, {:data, _}} -> receive_exit(client, timeout)
    after
      timeout -> flunk("client did not exit within #{timeout}ms")
    end
  end
end
