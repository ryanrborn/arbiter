defmodule ArbiterWeb.SessionTranscriptChannelTest do
  @moduledoc """
  Replaying a finished session's persisted transcript over the *live*
  channel (bd-3tf4oo).

  The seam under test is deliberately the one phase 4 already built: topic
  `session:<id>`, and the same `snapshot` event a live attach sends. A
  transcript join opens no reader, accepts no input and reports no live
  state — it reads `Arbiter.Sessions.TranscriptReplay` and pushes the bytes.
  """
  use ArbiterWeb.ChannelCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Frame
  alias Arbiter.Sessions.Stream
  alias Arbiter.Sessions.Transcript
  alias Arbiter.Test.NoopRunner
  alias ArbiterWeb.SessionChannel
  alias ArbiterWeb.SessionSocket

  @moduletag :tmp_dir

  @loopback %{peer_data: %{address: {127, 0, 0, 1}, port: 55_555, ssl_cert: nil}}

  setup %{tmp_dir: tmp_dir} do
    Arbiter.Test.SessionEnv.sandbox("transcript-channel")
    put_env(:sessions_runtime_dir, tmp_dir)
    put_env(:sessions_runner, NoopRunner)

    {:ok, session} = Sessions.launch(runner: NoopRunner, ensure_reader: false)
    on_exit(fn -> Stream.stop(session.id) end)

    %{session: session, topic: "session:#{session.id}"}
  end

  defp end_session!(session) do
    {:ok, ended} = Sessions.kill(session.id)
    ended
  end

  defp join_transcript(topic, params \\ %{}) do
    {:ok, socket} = connect(SessionSocket, %{}, connect_info: @loopback)
    subscribe_and_join(socket, SessionChannel, topic, Map.put(params, "mode", "transcript"))
  end

  describe "joining in transcript mode" do
    test "replays the persisted bytes as a snapshot", %{session: session, topic: topic} do
      :ok = Transcript.append(session.id, "\e[32mhello\e[0m\r\n")
      end_session!(session)

      assert {:ok, reply, _socket} = join_transcript(topic)
      assert reply.mode == "transcript"
      assert reply.truncated? == false
      assert reply.total_bytes == byte_size("\e[32mhello\e[0m\r\n")

      assert_push("snapshot", %{data: data})
      assert data == "\e[32mhello\e[0m\r\n"
    end

    test "carries the end reason and ended-at", %{session: session, topic: topic} do
      :ok = Transcript.append(session.id, "bye")
      ended = end_session!(session)

      assert {:ok, reply, _socket} = join_transcript(topic)
      assert reply.end_reason == ended.end_reason
      assert reply.ended_at == ended.ended_at
    end

    test "starts no reader for the dead session", %{session: session, topic: topic} do
      :ok = Transcript.append(session.id, "bye")
      end_session!(session)

      assert {:ok, _reply, _socket} = join_transcript(topic)
      assert Stream.whereis(session.id) == nil
    end

    test "pushes no live meta", %{session: session, topic: topic} do
      :ok = Transcript.append(session.id, "bye")
      end_session!(session)

      assert {:ok, _reply, _socket} = join_transcript(topic)
      assert_push("snapshot", %{})
      refute_push("meta", %{})
    end

    test "replays only the tail of an over-cap transcript", %{session: session, topic: topic} do
      :ok = Transcript.append(session.id, String.duplicate("a", 100) <> String.duplicate("b", 60))
      end_session!(session)

      put_env(:sessions_transcript, replay_max_bytes: 60)

      assert {:ok, reply, _socket} = join_transcript(topic)
      assert reply.truncated?
      assert reply.total_bytes == 160
      assert reply.replay_bytes == 60

      assert_push("snapshot", %{data: data})
      assert data == String.duplicate("b", 60)
    end

    test "refuses when the transcript is gone, with the reason", %{session: session, topic: topic} do
      end_session!(session)

      assert {:error, %{code: "transcript_unavailable", reason: "never_captured"}} =
               join_transcript(topic)
    end

    test "refuses for a session that does not exist" do
      assert {:error, %{code: "session_gone"}} = join_transcript("session:#{Ash.UUID.generate()}")
    end
  end

  describe "a transcript channel is never a live one" do
    setup %{session: session, topic: topic} do
      :ok = Transcript.append(session.id, "output\r\n")
      end_session!(session)
      {:ok, _reply, socket} = join_transcript(topic)
      assert_push("snapshot", %{})
      %{socket: socket}
    end

    test "refuses stdin", %{socket: socket} do
      push(socket, "stdin", {:binary, Frame.encode(1, "rm -rf /\n")})

      assert_push("error", %{code: "read_only"})
    end

    test "refuses resize", %{socket: socket} do
      ref = push(socket, "resize", %{"cols" => 100, "rows" => 40})

      assert_reply(ref, :error, %{code: "read_only"})
    end

    test "refuses kill", %{socket: socket} do
      ref = push(socket, "kill", %{"confirm" => true})

      assert_reply(ref, :error, %{code: "read_only"})
    end

    test "refuses redraw", %{socket: socket} do
      ref = push(socket, "redraw", %{})

      assert_reply(ref, :error, %{code: "read_only"})
    end
  end

  describe "the live path is unchanged" do
    test "a live join for an ended session is still refused", %{session: session, topic: topic} do
      :ok = Transcript.append(session.id, "output")
      end_session!(session)

      {:ok, socket} = connect(SessionSocket, %{}, connect_info: @loopback)

      assert {:error, %{code: "session_gone"}} =
               subscribe_and_join(socket, SessionChannel, topic, %{})
    end
  end
end
