defmodule ArbiterWeb.SessionChannelTest do
  @moduledoc """
  The §5.2 envelope, end to end over a real Phoenix channel (bd-3ymdvi,
  phase 4 AC 1/3/5/6).

  Headless: the terminal underneath is `Arbiter.Test.ScriptedPty`, so there is
  no tmux server, no systemd and no browser in this file — but the channel,
  its serializer contract, the binary frames and the reader are all real.
  """
  use ArbiterWeb.ChannelCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Frame
  alias Arbiter.Sessions.Stream
  alias Arbiter.Test.NoopRunner
  alias Arbiter.Test.ScriptedPty
  alias ArbiterWeb.SessionChannel
  alias ArbiterWeb.SessionSocket

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    put_env(:sessions_runtime_dir, tmp_dir)
    put_env(:sessions_terminal, ScriptedPty)
    put_env(:sessions_runner, NoopRunner)

    put_env(Arbiter.Sessions.Stream,
      poll_interval_ms: 5,
      alive_interval_ms: 50,
      linger_ms: 0
    )

    {:ok, session} = Sessions.launch(cwd: tmp_dir, runner: NoopRunner)
    ScriptedPty.install(session.id, snapshot: "SNAP", cols: 80, rows: 24, title: "scripted")

    on_exit(fn -> Stream.stop(session.id) end)

    %{session: session, topic: "session:#{session.id}"}
  end

  @loopback %{peer_data: %{address: {127, 0, 0, 1}, port: 55_555, ssl_cert: nil}}

  # `test_process:` lets a socket be built from a process that is not the test
  # one — `Phoenix.ChannelTest` otherwise refuses, and the two-client test needs
  # the second client to play transport for itself.
  defp session_socket(caller_session_id, test_process) do
    {:ok, socket} =
      connect(SessionSocket, %{"caller_session_id" => caller_session_id},
        connect_info: @loopback,
        test_process: test_process
      )

    socket
  end

  # The channel is linked to whoever joined it, so a channel that stops with a
  # `{:shutdown, _}` reason would take the test with it. Only the link is a
  # test artefact; the shutdown reason is what the real transport reads to
  # decide whether to send the client a `phx_close`.
  defp unlink_channel(socket) do
    Process.unlink(socket.channel_pid)
    socket
  end

  defp join_session(topic, params \\ %{}, caller_session_id \\ nil) do
    subscribe_and_join(session_socket(caller_session_id, self()), SessionChannel, topic, params)
  end

  describe "socket auth (§10.4 loopback only)" do
    test "a loopback peer connects without a token" do
      assert {:ok, _socket} = connect(SessionSocket, %{}, connect_info: @loopback)
    end

    test "an off-box peer without a token is refused" do
      assert :error = connect(SessionSocket, %{}, connect_info: off_box())
    end

    test "an off-box peer with an invalid token is refused" do
      assert :error = connect(SessionSocket, %{"token" => "nope"}, connect_info: off_box())
    end

    test "an off-box peer with a valid scope token connects" do
      token = Arbiter.MCP.Scope.mint_coordinator()

      assert {:ok, _socket} =
               connect(SessionSocket, %{"token" => token}, connect_info: off_box())
    end

    # bd-aprlbb (phase 3) made a session's own MCP token revocable, and this
    # socket is the newest thing that token can open. Revoking it has to close
    # the terminal door too, or "killing a session revokes its credential"
    # would be false for the one credential path that streams its keystrokes.
    test "an off-box peer with a revoked session token is refused", %{session: session} do
      token = Sessions.mint_mcp_token(session)

      assert {:ok, _socket} =
               connect(SessionSocket, %{"token" => token}, connect_info: off_box())

      {:ok, _} = Sessions.revoke_mcp_token(session)

      assert :error = connect(SessionSocket, %{"token" => token}, connect_info: off_box())
    end
  end

  describe "join" do
    test "a first join replies with the seq and pushes snapshot + meta", %{topic: topic} do
      assert {:ok, reply, _socket} = join_session(topic, %{"cols" => 100, "rows" => 30})

      assert reply.seq == 0
      assert reply.mode == "snapshot"

      assert_push "snapshot", %{seq: 0, data: "SNAP"}
      assert_push "meta", %{cols: 100, rows: 30, attached_clients: 1, title: "scripted"}
    end

    test "a frame delivered during the join is pushed after the snapshot", %{
      session: session,
      topic: topic
    } do
      early = Frame.encode(7, "early")

      # The reader starts streaming to the joining pid inside `Stream.attach/2`,
      # so a live frame can reach this channel's mailbox before `join/3` has got
      # as far as queueing its own `:after_join`. `:on_start_stream` runs in the
      # reader while the channel is blocked in exactly that call, which makes
      # the race — otherwise sub-microsecond against a 25 ms poll — deterministic.
      ScriptedPty.put(session.id,
        on_start_stream: fn opts ->
          send(opts[:subscriber], {:session_stdout, session.id, early})
        end
      )

      assert {:ok, _reply, _socket} = join_session(topic)

      # Strict mailbox order: a live frame must never precede the snapshot whose
      # seq it is newer than, or the client repaints backwards over it.
      assert {"snapshot", %{data: "SNAP"}} = next_push()
      assert {"meta", %{attached_clients: 1}} = next_push()
      assert {"stdout", {:binary, ^early}} = next_push()
    end

    test "a client reporting a zero-sized terminal leaves the others streaming", %{
      session: session,
      topic: topic
    } do
      {:ok, _reply, first} = join_session(topic)
      assert_push "snapshot", %{}
      assert_push "meta", %{cols: 80, rows: 24, attached_clients: 1}

      # xterm.js's fit addon reports 0 cols/rows for a terminal whose container
      # has not been laid out — a background tab, or a join before first paint.
      # The reader is shared, so a `0` reaching `Terminal.resize/4` would take
      # this already-attached client's stream down too.
      _second = spawn_second_client(topic, %{"cols" => 0, "rows" => 0})

      assert_push "meta", %{cols: 80, rows: 24, attached_clients: 2}
      assert Stream.stats(session.id).cols == 80

      ScriptedPty.emit(session.id, "still here")
      assert_push "stdout", {:binary, frame}
      assert {:ok, 10, "still here"} = Frame.decode(frame)
      assert Process.alive?(first.channel_pid)
    end

    test "an unknown session is refused with error :session_gone" do
      assert {:error, %{code: "session_gone"}} = join_session("session:#{Ash.UUID.generate()}")
    end

    test "an ended session is refused", %{session: session, topic: topic} do
      {:ok, _} = Sessions.mark_ended(session, "killed")

      assert {:error, %{code: "session_gone"}} = join_session(topic)
    end

    test "a terminal that cannot be attached is refused with :bridge_unavailable", %{
      session: session,
      topic: topic
    } do
      ScriptedPty.put(session.id, start_stream_result: {:error, {:tmux_failed, 1, "no server"}})

      assert {:error, %{code: "bridge_unavailable", detail: detail}} = join_session(topic)
      assert detail =~ "tmux_failed"
    end
  end

  describe "stdout (AC 1)" do
    test "pane output arrives as binary frames carrying seq", %{session: session, topic: topic} do
      {:ok, _reply, _socket} = join_session(topic)
      assert_push "snapshot", %{}

      ScriptedPty.emit(session.id, "hello")

      assert_push "stdout", {:binary, frame}
      assert {:ok, 5, "hello"} = Frame.decode(frame)
    end

    test "a split multi-byte character and a split escape survive byte-for-byte", %{
      session: session,
      topic: topic
    } do
      {:ok, _reply, _socket} = join_session(topic)
      assert_push "snapshot", %{}

      <<head::binary-size(2), tail::binary>> = "🚀"
      escape = <<0x1B, ?[, ?1, ?;, ?3, ?1, ?m>>
      <<esc_head::binary-size(3), esc_tail::binary>> = escape

      for piece <- [head, tail, esc_head, esc_tail] do
        ScriptedPty.emit(session.id, piece)
        assert_push "stdout", {:binary, frame}
        assert {:ok, _seq, ^piece} = Frame.decode(frame)
      end
    end
  end

  describe "stdin" do
    test "binary frames are typed into the pane verbatim", %{session: session, topic: topic} do
      {:ok, _reply, socket} = join_session(topic)

      push(socket, "stdin", {:binary, Frame.encode(1, <<0x1B, ?[, ?A>>)})
      push(socket, "stdin", {:binary, Frame.encode(2, "ls\r")})
      _ = :sys.get_state(socket.channel_pid)

      assert ScriptedPty.input(session.id) == <<0x1B, ?[, ?A, ?l, ?s, ?\r>>
    end

    test "a replayed stdin seq is dropped rather than typed twice", %{
      session: session,
      topic: topic
    } do
      {:ok, _reply, socket} = join_session(topic)

      push(socket, "stdin", {:binary, Frame.encode(7, "x")})
      push(socket, "stdin", {:binary, Frame.encode(7, "x")})
      push(socket, "stdin", {:binary, Frame.encode(6, "x")})
      _ = :sys.get_state(socket.channel_pid)

      assert ScriptedPty.input(session.id) == "x"
    end

    test "a malformed binary payload yields an error event, not a crash", %{topic: topic} do
      {:ok, _reply, socket} = join_session(topic)

      push(socket, "stdin", {:binary, "not a frame"})

      assert_push "error", %{code: "bad_frame"}
      assert Process.alive?(socket.channel_pid)
    end
  end

  describe "resize and meta (AC 5)" do
    test "two clients share the stream and a resize by one metas the other", %{
      session: session,
      topic: topic
    } do
      {:ok, _reply, first} = join_session(topic)
      assert_push "snapshot", %{}
      assert_push "meta", %{attached_clients: 1}

      second = spawn_second_client(topic)

      # The first client is told the client count changed.
      assert_push "meta", %{attached_clients: 2}

      ScriptedPty.emit(session.id, "shared")
      assert_push "stdout", {:binary, frame}
      assert {:ok, 6, "shared"} = Frame.decode(frame)
      assert_receive {:second, :push, "stdout", {:binary, ^frame}}, 1_000

      ref = push(second, "resize", %{"cols" => 132, "rows" => 43})
      assert_receive {:second, :reply, ^ref, :ok, _payload}, 1_000

      assert_push "meta", %{cols: 132, rows: 43, attached_clients: 2}
      assert {:resize, 132, 43} in ScriptedPty.calls(session.id)
      assert Process.alive?(first.channel_pid)
    end

    test "a resize with a bad payload is rejected", %{topic: topic} do
      {:ok, _reply, socket} = join_session(topic)

      ref = push(socket, "resize", %{"cols" => 0, "rows" => -1})
      assert_reply ref, :error, %{code: "bad_payload"}
    end
  end

  describe "resume (AC 3)" do
    test "a join with a valid last_seq replays the missed frames, no snapshot", %{
      session: session,
      topic: topic
    } do
      {:ok, _reply, first} = join_session(topic)
      assert_push "snapshot", %{}

      ScriptedPty.emit(session.id, "one")
      assert_push "stdout", {:binary, _}
      ScriptedPty.emit(session.id, "two")
      assert_push "stdout", {:binary, _}

      # A reconnecting client: same session, resuming from seq 3.
      leave_and_flush(first)
      {:ok, reply, _socket} = join_session(topic, %{"last_seq" => 3})

      assert reply.mode == "resumed"
      assert reply.seq == 6

      assert_push "stdout", {:binary, frame}
      assert {:ok, 6, "two"} = Frame.decode(frame)
      refute_push "snapshot", %{}
    end

    test "a join with an out-of-range last_seq repaints with a snapshot", %{
      session: session,
      topic: topic
    } do
      {:ok, _reply, first} = join_session(topic)
      assert_push "snapshot", %{}
      ScriptedPty.emit(session.id, "abc")
      assert_push "stdout", {:binary, _}

      leave_and_flush(first)
      {:ok, reply, _socket} = join_session(topic, %{"last_seq" => 99_999})

      assert reply.mode == "snapshot"
      assert_push "snapshot", %{seq: 3, data: "SNAP"}
    end
  end

  describe "detach (AC 2)" do
    test "detach stops the channel and leaves the session alive", %{
      session: session,
      topic: topic
    } do
      {:ok, _reply, socket} = join_session(topic)
      channel = unlink_channel(socket).channel_pid
      ref = Process.monitor(channel)

      push(socket, "detach", %{})

      assert_receive {:DOWN, ^ref, :process, ^channel, _reason}, 1_000
      assert ScriptedPty.fetch(session.id).alive?
      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end
  end

  describe "kill (AC 6)" do
    test "kill routes through Sessions.kill/2 and ends the row", %{
      session: session,
      topic: topic
    } do
      {:ok, _reply, socket} = join_session(topic)

      ref = push(socket, "kill", %{"confirm" => true})
      assert_reply ref, :ok, %{}

      assert {:ok, ended} = Sessions.get(session.id)
      assert ended.status == :ended
      assert ended.end_reason == "killed"
    end

    test "kill without confirmation is refused", %{session: session, topic: topic} do
      {:ok, _reply, socket} = join_session(topic)

      ref = push(socket, "kill", %{})
      assert_reply ref, :error, %{code: "confirmation_required"}

      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end

    test "a session cannot kill itself — the phase 1 guard applies", %{
      session: session,
      topic: topic
    } do
      {:ok, _reply, socket} = join_session(topic, %{}, session.id)

      ref = push(socket, "kill", %{"confirm" => true})
      assert_reply ref, :error, %{code: "self_kill_refused"}

      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end
  end

  describe "exit (AC 6)" do
    test "an exited session pushes exit and stops the channel", %{
      session: session,
      topic: topic
    } do
      {:ok, _reply, socket} = join_session(topic)
      channel = unlink_channel(socket).channel_pid
      ref = Process.monitor(channel)

      ScriptedPty.put(session.id, alive?: false)

      assert_push "exit", %{code: nil, reason: "exited"}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^channel, _reason}, 2_000
    end
  end

  describe "ping and usage" do
    test "ping round-trips the client timestamp", %{topic: topic} do
      {:ok, _reply, socket} = join_session(topic)

      ref = push(socket, "ping", %{"ts" => 1_234})
      assert_reply ref, :ok, %{ts: 1_234, server_ts: server_ts}
      assert is_integer(server_ts)
    end

    test "a usage broadcast reaches the client (phase 7 placeholder)", %{
      session: session,
      topic: topic
    } do
      {:ok, _reply, _socket} = join_session(topic)

      Sessions.broadcast_usage(session.id, %{
        tokens_in: 10,
        tokens_out: 20,
        cache_creation: 0,
        cache_read: 5,
        cost_usd: 0.01,
        model: "claude-opus-5"
      })

      assert_push "usage", %{tokens_in: 10, tokens_out: 20, model: "claude-opus-5"}
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp off_box, do: %{peer_data: %{address: {10, 0, 0, 7}, port: 1, ssl_cert: nil}}

  # A second channel client on the same topic. It joins from its **own**
  # process, so it is that process — not the test — that plays transport for
  # the second socket, and the two clients' traffic stays distinguishable.
  defp spawn_second_client(topic, params \\ %{}) do
    parent = self()

    spawn_link(fn ->
      {:ok, _reply, socket} =
        subscribe_and_join(session_socket(nil, parent), SessionChannel, topic, params)

      send(parent, {:second, :joined, socket})
      relay(parent)
    end)

    assert_receive {:second, :joined, socket}, 2_000
    socket
  end

  defp relay(parent) do
    receive do
      %Phoenix.Socket.Message{event: event, payload: payload} ->
        send(parent, {:second, :push, event, payload})

      %Phoenix.Socket.Reply{ref: ref, status: status, payload: payload} ->
        send(parent, {:second, :reply, ref, status, payload})

      other ->
        send(parent, {:second, :other, other})
    end

    relay(parent)
  end

  # `assert_push` matches on event name, so it happily skips over an earlier
  # push to find the one it wants — useless for asserting *order*. This takes
  # the next push whatever it is, so a sequence of calls is mailbox order.
  defp next_push do
    assert_receive %Phoenix.Socket.Message{event: event, payload: payload}, 1_000
    {event, payload}
  end

  defp leave_and_flush(socket) do
    socket |> unlink_channel() |> close()
    flush_messages()
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end
end
