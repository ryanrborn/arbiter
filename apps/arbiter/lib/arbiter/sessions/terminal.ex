defmodule Arbiter.Sessions.Terminal do
  @moduledoc """
  The OS-facing seam for **streaming** a session's terminal
  (bd-3ymdvi, phase 4 of `docs/browser-hosted-coordinator-sessions.md` §5).

  `Arbiter.Sessions.Runner` is the seam for session *control* — launch, kill,
  enumerate. This is its sibling for the transport: attach a byte stream,
  capture scrollback, type, resize, ask how big the pane is, ask whether it is
  still there. Splitting them keeps phase 1's contract intact (a runner call is
  one command, run to completion) while giving phase 4 a vocabulary that is
  about a terminal rather than about systemd.

  ## Still no long-lived PTY handle

  Every callback here is implemented as a synchronous shell-out that returns
  (`Arbiter.Sessions.Terminal.Tmux` runs them through the same injectable
  `Runner`). The live byte stream is *not* a port on tmux: `start_stream/3`
  asks **tmux** to spawn `cat >> <path>` inside the session's own scope, and
  `Arbiter.Sessions.Stream` then reads that ordinary file. The BEAM holds a
  file descriptor on a regular file, which is not a PTY master and whose loss
  costs nothing — closing it does not SIGHUP anybody. That is what lets a
  browser detach, or an `arbiter` restart, drop the reader without touching
  the session. `Arbiter.Sessions.NoPtyHandleTest` asserts it structurally.

  ## Provider-agnostic (§5.4)

  Nothing in this behaviour names a provider. A terminal is bytes, a size and
  a lifecycle; provider differences live in the launch spec and in usage
  ingestion, both outside the transport.

  ## Implementations

    * `Arbiter.Sessions.Terminal.Tmux` — the real one.
    * `Arbiter.Test.SessionTerminalStub` — a scripted PTY for the suite. The
      transport is tested headlessly against it; no browser, no systemd.

  Resolution order mirrors the runner's — `Arbiter.Sessions.terminal/1`: the
  `:terminal` option, then `config :arbiter, :sessions_terminal`, then
  `Terminal.Tmux`.

  ## Shared options

  Implementations receive the caller's `opts` verbatim and MUST tolerate
  unknown keys. The ones with meaning here:

    * `:runner` — the `Arbiter.Sessions.Runner` to shell out through.
    * `:snapshot_lines` — scrollback lines a snapshot reaches back for.
  """

  alias Arbiter.Sessions.Session

  @type opts :: keyword()
  @type geometry :: %{cols: pos_integer(), rows: pos_integer(), title: String.t()}

  @doc """
  Start piping the pane's raw output into the file at `path`, and return the
  scrollback snapshot taken at the same moment.

  The two happen together because the seam between them is the one place
  ordering can go wrong (§4.5). Piping first and capturing second can only
  ever produce an *overlap* — bytes that are both in the snapshot and in the
  file — and §4.5 is explicit that "overlap is cheap to discard, a gap is not
  recoverable". `Arbiter.Sessions.Stream` discards the overlap by starting its
  read offset at the file's size *before* this call.

  The file is opened in append mode by the writer, so a session that is
  re-attached continues the same byte stream and `seq` stays monotonic for the
  session's whole life — including across an `arbiter` restart.
  """
  @callback start_stream(Session.t(), path :: String.t(), opts()) ::
              {:ok, %{snapshot: binary()}} | {:error, term()}

  @doc "Stop piping. Best-effort: a session that is already gone is still `:ok`."
  @callback stop_stream(Session.t(), opts()) :: :ok

  @doc """
  Whether a pipe is currently attached to the pane.

  Load-bearing for restart survival: after `arbiter` restarts, the `cat`
  spawned by `start_stream/3` is still running (it lives in the session's
  scope, not ours) and the file is still growing. The reader re-opens the
  existing file instead of restarting the pipe, so no bytes are lost between
  the crash and the reattach.
  """
  @callback streaming?(Session.t(), opts()) :: boolean()

  @doc "ANSI-preserving scrollback for a `snapshot` frame, without touching the pipe."
  @callback snapshot(Session.t(), opts()) :: {:ok, binary()} | {:error, term()}

  @doc "Type raw bytes into the pane. Control characters and escapes included."
  @callback send_input(Session.t(), bytes :: binary(), opts()) :: :ok | {:error, term()}

  @doc "Resize the pane. See `Arbiter.Sessions.Stream` for the multi-client policy."
  @callback resize(Session.t(), cols :: pos_integer(), rows :: pos_integer(), opts()) ::
              :ok | {:error, term()}

  @doc "Current pane size and title, for the `meta` event."
  @callback geometry(Session.t(), opts()) :: {:ok, geometry()} | {:error, term()}

  @doc "Whether the session still exists. The `exit` event's trigger."
  @callback alive?(Session.t(), opts()) :: boolean()
end
