defmodule Arbiter.Sessions.Frame do
  @moduledoc """
  The wire format for the terminal transport's **binary** frames
  (bd-3ymdvi, phase 4 of `docs/browser-hosted-coordinator-sessions.md` §5.2/§5.3).

      <<"ARB1", seq::unsigned-big-64, payload::binary>>

  ## Why the sequence number is in the bytes

  RFC §5.2 describes `stdout` as "`{:binary, bytes}` with `seq` in metadata".
  There is no metadata. A Phoenix channel binary push is `{:binary, iodata}`
  and the WebSocket frame carries the payload and nothing else — no event
  name, no ref, no headers. So §5.3's resume protocol, which is keyed on
  `session id + seq`, only works if `seq` is *framed into the payload*. That is
  the wrinkle the RFC review flagged, and this module is the answer to it.

  ## Why the payload is never touched

  `stdin`/`stdout` are raw terminal bytes. A PTY read boundary lands wherever
  the kernel put it: mid-UTF-8-character, mid-CSI-escape, mid-OSC-string.
  Anything that validates, decodes, or re-encodes at the transport turns a
  split `\\e[1;31m` into two broken halves or a split `🚀` into replacement
  characters, and the corruption is permanent by the time it reaches the
  renderer. `encode/2` prefixes bytes; `decode/1` strips the prefix. Neither
  looks at the payload. xterm.js reassembles split sequences by design — that
  is where decoding belongs.

  ## Header

  `"ARB1"` is a magic + version tag, so a client that is handed a stray binary
  (or a future v2 frame) can reject it instead of rendering garbage, and so an
  operator staring at a hexdump can tell what they are looking at. `seq` is a
  64-bit unsigned big-endian **byte offset** into the session's output stream —
  see `Arbiter.Sessions.Stream` for why an offset rather than a counter.

  Both directions use this format. Server → client, `seq` is the stream offset
  of the last byte in the frame. Client → server, it is the client's own
  monotonic stdin counter, which lets the server drop duplicate stdin after a
  reconnect rather than typing it into the pane twice.
  """

  @magic "ARB1"
  @header_size 12

  @type seq :: non_neg_integer()

  @doc """
  Frame `payload` (binary or iodata) under `seq`. Returns a binary.

  The payload is copied verbatim — no validation, no decoding (see moduledoc).
  """
  @spec encode(seq(), iodata()) :: binary()
  def encode(seq, payload) when is_integer(seq) and seq >= 0 do
    <<@magic, seq::unsigned-big-64, IO.iodata_to_binary(payload)::binary>>
  end

  @doc """
  Split a frame back into `{:ok, seq, payload}`, or `{:error, :bad_frame}`.

  Rejects anything that is not a binary with our header: a short read, a JSON
  string that arrived on the binary path, a frame from another protocol.
  """
  @spec decode(term()) :: {:ok, seq(), binary()} | {:error, :bad_frame}
  def decode(<<@magic, seq::unsigned-big-64, payload::binary>>), do: {:ok, seq, payload}
  def decode(_), do: {:error, :bad_frame}

  @doc """
  Bytes of framing overhead per frame — what the ring buffer has to account
  for on top of the payload so its bound is a bound on real memory.
  """
  @spec header_size() :: pos_integer()
  def header_size, do: @header_size
end
