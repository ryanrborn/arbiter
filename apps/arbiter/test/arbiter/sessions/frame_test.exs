defmodule Arbiter.Sessions.FrameTest do
  @moduledoc """
  Phase 4 AC 1 (bd-3ymdvi): `seq` is framed **into the binary payload**.

  RFC §5.2 puts `seq` "in metadata" on the `stdout` frame, and the RFC review
  caught that Phoenix binary frames have no metadata channel at all — a binary
  push is `{:binary, iodata}` and nothing else rides along. So the sequence
  number has to be in the bytes, and the bytes either side of it have to come
  back out byte-for-byte: a terminal stream splits multi-byte UTF-8 and ANSI
  escape sequences across reads, and anything that decodes at the transport
  corrupts them.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Sessions.Frame

  describe "encode/decode" do
    test "round-trips payload bytes and the sequence number" do
      encoded = Frame.encode(42, "hello")

      assert is_binary(encoded)
      assert {:ok, 42, "hello"} = Frame.decode(encoded)
    end

    test "carries a magic + version header so a client can reject junk" do
      assert <<"ARB1", 42::unsigned-big-64, "hello">> == Frame.encode(42, "hello")
    end

    test "accepts iodata payloads" do
      assert {:ok, 7, "abcdef"} = Frame.decode(Frame.encode(7, ["abc", ["d", "ef"]]))
    end

    test "round-trips an empty payload" do
      assert {:ok, 0, ""} = Frame.decode(Frame.encode(0, ""))
    end

    test "round-trips sequence numbers up to the 64-bit ceiling" do
      max = 18_446_744_073_709_551_615
      assert {:ok, ^max, "x"} = Frame.decode(Frame.encode(max, "x"))
    end

    test "rejects a frame with the wrong magic" do
      assert {:error, :bad_frame} = Frame.decode(<<"XXXX", 1::unsigned-big-64, "hi">>)
    end

    test "rejects a truncated header" do
      assert {:error, :bad_frame} = Frame.decode(<<"ARB1", 0, 0, 0>>)
    end

    test "rejects a non-binary payload" do
      assert {:error, :bad_frame} = Frame.decode(:not_a_frame)
    end
  end

  describe "byte transparency (AC 1)" do
    test "a multi-byte UTF-8 character split across two frames survives byte-for-byte" do
      # U+1F680 ROCKET is four bytes; a PTY read boundary can land anywhere.
      <<head::binary-size(2), tail::binary>> = "🚀"

      assert {:ok, 1, ^head} = Frame.decode(Frame.encode(1, head))
      assert {:ok, 2, ^tail} = Frame.decode(Frame.encode(2, tail))

      refute String.valid?(head)
      assert head <> tail == "🚀"
    end

    test "an ANSI escape sequence split mid-sequence survives byte-for-byte" do
      # CSI 1;31m — split between the introducer and the parameters.
      escape = <<0x1B, ?[, ?1, ?;, ?3, ?1, ?m>>
      <<head::binary-size(2), tail::binary>> = escape

      assert {:ok, 10, ^head} = Frame.decode(Frame.encode(10, head))
      assert {:ok, 11, ^tail} = Frame.decode(Frame.encode(11, tail))
      assert head <> tail == escape
    end

    test "every byte value 0..255 round-trips unchanged" do
      payload = :binary.list_to_bin(Enum.to_list(0..255))

      assert {:ok, 3, ^payload} = Frame.decode(Frame.encode(3, payload))
    end

    test "a lone continuation byte is not mangled into a replacement character" do
      payload = <<0x80, 0xFF, 0xFE>>

      assert {:ok, 4, ^payload} = Frame.decode(Frame.encode(4, payload))
      refute String.valid?(payload)
    end
  end

  describe "header_size/0" do
    test "is the fixed overhead the ring buffer accounts for" do
      assert Frame.header_size() == byte_size(Frame.encode(0, ""))
    end
  end
end
