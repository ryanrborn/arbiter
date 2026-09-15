defmodule ArbiterWeb.SessionWireFormatTest do
  @moduledoc """
  The one seam `Phoenix.ChannelTest` does not exercise (bd-3ymdvi, phase 4
  AC 1): the **serializer**.

  `ArbiterWeb.SessionChannelTest` drives the real channel, the real reader and
  the real frames, but `Phoenix.ChannelTest` installs a no-op serializer and
  hands payloads between processes as Elixir terms. So it proves the channel
  pushes `{:binary, frame}`; it cannot prove that what leaves the socket is
  those bytes. Since the entire claim of §5.2 is "stdin/stdout are binary
  frames, never JSON or UTF-8 decoded at the transport", that is exactly the
  step worth pinning: a serializer that JSON-encoded the payload, or that
  went anywhere near `String.valid?/1`, would corrupt a split escape sequence
  and every test above would still pass.

  This runs the production encoder, `Phoenix.Socket.V2.JSONSerializer` — the
  one a `vsn=2.0.0` WebSocket client negotiates against the `/session` socket.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Sessions.Frame
  alias Phoenix.Socket.Message

  @serializer Phoenix.Socket.V2.JSONSerializer

  # A payload that is hostile to anything that decodes: a lone UTF-8
  # continuation byte, a NUL, a bare ESC, and the tail of a split CSI.
  @hostile <<0x80, 0x00, 0x1B, "[1;3", 0xFF, 0xC3>>

  defp topic, do: "session:0197c0de-dead-beef-cafe-000000000001"

  # Exactly what phoenix.js puts on the wire for a binary push: the V2 client
  # frame carries a `ref` that the server's own push format omits, so this is
  # built by hand rather than round-tripped through `encode!/1`.
  defp client_binary_frame(event, data, join_ref \\ "1", ref \\ "3") do
    topic = topic()

    <<0::size(8), byte_size(join_ref)::size(8), byte_size(ref)::size(8),
      byte_size(topic)::size(8), byte_size(event)::size(8), join_ref::binary, ref::binary,
      topic::binary, event::binary, data::binary>>
  end

  test "the endpoint really declares the session socket" do
    paths = Enum.map(ArbiterWeb.Endpoint.__sockets__(), &elem(&1, 0))
    assert "/session" in paths

    assert {_path, ArbiterWeb.SessionSocket, opts} =
             Enum.find(ArbiterWeb.Endpoint.__sockets__(), &(elem(&1, 0) == "/session"))

    assert Keyword.get(opts, :websocket) != false
    # No longpoll: stdin/stdout are binary frames, and longpoll is JSON-only.
    assert Keyword.get(opts, :longpoll, false) == false
  end

  test "a stdout push leaves the socket as a binary frame containing the bytes verbatim" do
    frame = Frame.encode(4_096, @hostile)

    message = %Message{
      topic: topic(),
      event: "stdout",
      payload: {:binary, frame},
      ref: nil,
      join_ref: "1"
    }

    assert {:socket_push, :binary, encoded} = @serializer.encode!(message)
    encoded = IO.iodata_to_binary(encoded)

    # Binary opcode — not text, not JSON — and our frame is in there untouched.
    assert String.ends_with?(encoded, frame)
    assert :binary.match(encoded, frame) != :nomatch
  end

  test "a stdin binary frame decodes back to the exact bytes the client sent" do
    frame = Frame.encode(7, @hostile)

    decoded = @serializer.decode!(client_binary_frame("stdin", frame), opcode: :binary)

    assert %Message{event: "stdin", payload: {:binary, ^frame}} = decoded
    assert {:ok, 7, @hostile} = Frame.decode(frame)
  end

  test "every byte value survives both directions of the wire" do
    payload = :binary.list_to_bin(Enum.to_list(0..255))
    frame = Frame.encode(1, payload)

    # Server → client: the push's trailing bytes are the frame, verbatim.
    {:socket_push, :binary, raw} =
      @serializer.encode!(%Message{
        topic: topic(),
        event: "stdout",
        payload: {:binary, frame},
        ref: nil,
        join_ref: "1"
      })

    assert IO.iodata_to_binary(raw) |> String.ends_with?(frame)

    # Client → server: what the decoder hands the channel is the same bytes.
    assert %Message{payload: {:binary, round_tripped}} =
             @serializer.decode!(client_binary_frame("stdin", frame), opcode: :binary)

    assert round_tripped == frame
    assert {:ok, 1, ^payload} = Frame.decode(round_tripped)
  end

  test "the JSON events stay JSON" do
    message = %Message{
      topic: topic(),
      event: "meta",
      payload: %{cols: 132, rows: 43, attached_clients: 2, title: "coord"},
      ref: nil,
      join_ref: "1"
    }

    assert {:socket_push, :text, encoded} = @serializer.encode!(message)
    assert IO.iodata_to_binary(encoded) =~ "\"meta\""
  end
end
