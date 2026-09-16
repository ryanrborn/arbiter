defmodule Arbiter.Sessions.Terminal.Tmux do
  @moduledoc """
  The real `Arbiter.Sessions.Terminal`: `tmux`, addressed by exact socket path
  (bd-3ymdvi, phase 4 of `docs/browser-hosted-coordinator-sessions.md` §5).

  Every operation is one `tmux -S <socket> … -t coord` invocation run through
  the injectable `Arbiter.Sessions.Runner`, so it inherits phase 1's two
  properties for free: the release-env scrub (`Runner.Host`, bd-2oelme) and
  "the call has already finished when it returns". Nothing here retains a
  handle — the live byte stream is a file `tmux` writes and
  `Arbiter.Sessions.Stream` reads.

  ## Addressing

  The socket path and the session name (`coord`) are exact strings derived
  from the session id by `Arbiter.Sessions.Naming`. Never a pattern, never a
  glob — this repo has an incident class around pattern-matching process
  control, and a `-t` that resolved loosely would type a browser's keystrokes
  into somebody else's pane.

  ## stdin as hex

  `send-keys -H` takes hex byte values, which is the only shape that survives
  arbitrary input: a literal `send-keys -l` argument would have tmux's key-name
  parsing, shell quoting and UTF-8 validation between the browser and the pane,
  and a terminal stream contains `C-c`, arrow-key escape sequences and
  half-characters from a split paste. Hex has none of that. Large pastes are
  chunked so argv stays a sane length.

  ## Capture and stderr

  `capture-pane -p` writes the pane's *contents* to stdout, so these calls
  deliberately do **not** set `:stderr_to_stdout` — a tmux warning folded into
  that stream would be rendered in the browser as if the agent had printed it.
  Failures are read from the exit status instead.
  """

  @behaviour Arbiter.Sessions.Terminal

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Naming
  alias Arbiter.Sessions.Session

  # `send-keys -H` argv length per invocation. 512 bytes ≈ 1 KB of argv, well
  # inside any `execve` limit, and a paste big enough to need several rounds is
  # already slower than the human who triggered it.
  @input_chunk_bytes 512

  @default_snapshot_lines 2_000

  # `capture-pane -p` is plain text: it carries neither the pane's cursor
  # position nor a `\r` before each `\n` (tmux's own line buffer has no `\r`,
  # only line boundaries). xterm is constructed with `convertEol: false`
  # (`session_terminal.mjs`) so it never supplies the missing `\r` on its own,
  # and without the cursor a repaint leaves xterm's cursor wherever the last
  # written byte put it rather than where tmux's own cursor sits — Claude
  # Code's next escape-relative redraw then lands in the wrong place (bd-c5udkj).
  #
  # Both are fixed here, once, so every snapshot caller (a fresh reader's
  # opening capture in `start_stream/3`, and a live re-capture in `snapshot/2`)
  # gets the same treatment: `finalize_capture/1` rewrites bare `\n` to `\r\n`
  # and appends a CUP escape built from the pane's cursor position. The cursor
  # is fetched in the *same* tmux invocation as the capture (chained with `;`,
  # same trick `start_stream/3` already used to pair `pipe-pane` with its
  # opening capture) rather than a second shell-out, so there is no seam for
  # the pane to move its cursor in between. It is prefixed with SOH/STX
  # (`\x01`/`\x02`) — control bytes no real terminal output uses — so it can be
  # split off the front of the capture unambiguously.
  @cursor_prefix "\x01"
  @cursor_suffix "\x02"

  @impl true
  def start_stream(%Session{} = session, path, opts \\ []) do
    lines = snapshot_lines(opts)

    args =
      base(session) ++
        ["pipe-pane", "-O", "-t", Naming.tmux_session(), "cat >> #{shell_quote(path)}", ";"] ++
        cursor_args() ++
        [";"] ++
        capture_args(lines)

    case run(args, opts) do
      {out, 0} -> {:ok, %{snapshot: finalize_capture(out)}}
      {out, status} -> {:error, {:tmux_failed, status, String.trim(out)}}
    end
  end

  @impl true
  def stop_stream(%Session{} = session, opts \\ []) do
    # A bare `pipe-pane` closes the current pipe (it does not open a new one).
    _ = run_quiet(base(session) ++ ["pipe-pane", "-t", Naming.tmux_session()], opts)
    :ok
  end

  @impl true
  def streaming?(%Session{} = session, opts \\ []) do
    args =
      base(session) ++ ["display-message", "-p", "-t", Naming.tmux_session(), "\#{pane_pipe}"]

    case run(args, opts) do
      {out, 0} -> String.trim(out) == "1"
      _ -> false
    end
  end

  @impl true
  def snapshot(%Session{} = session, opts \\ []) do
    args = base(session) ++ cursor_args() ++ [";"] ++ capture_args(snapshot_lines(opts))

    case run(args, opts) do
      {out, 0} -> {:ok, finalize_capture(out)}
      {out, status} -> {:error, {:tmux_failed, status, String.trim(out)}}
    end
  end

  @impl true
  def send_input(%Session{} = session, bytes, opts \\ []) when is_binary(bytes) do
    bytes
    |> chunk(@input_chunk_bytes)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      args =
        base(session) ++
          ["send-keys", "-t", Naming.tmux_session(), "-H"] ++
          for(<<byte <- chunk>>, do: Base.encode16(<<byte>>, case: :lower))

      case run_quiet(args, opts) do
        {_out, 0} -> {:cont, :ok}
        {out, status} -> {:halt, {:error, {:tmux_failed, status, String.trim(out)}}}
      end
    end)
  end

  @impl true
  def resize(%Session{} = session, cols, rows, opts \\ [])
      when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0 do
    args =
      base(session) ++
        [
          "resize-window",
          "-t",
          Naming.tmux_session(),
          "-x",
          Integer.to_string(cols),
          "-y",
          Integer.to_string(rows)
        ]

    case run_quiet(args, opts) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:tmux_failed, status, String.trim(out)}}
    end
  end

  @impl true
  def geometry(%Session{} = session, opts \\ []) do
    format = "\#{pane_width}\t\#{pane_height}\t\#{pane_title}"
    args = base(session) ++ ["display-message", "-p", "-t", Naming.tmux_session(), format]

    case run(args, opts) do
      {out, 0} -> parse_geometry(out)
      {out, status} -> {:error, {:tmux_failed, status, String.trim(out)}}
    end
  end

  @impl true
  def alive?(%Session{} = session, opts \\ []) do
    match?(
      {_out, 0},
      run_quiet(base(session) ++ ["has-session", "-t", Naming.tmux_session()], opts)
    )
  end

  # -- internals --------------------------------------------------------------

  defp base(%Session{tmux_socket: socket}), do: ["-S", socket]

  defp capture_args(lines) do
    ["capture-pane", "-p", "-e", "-S", "-#{lines}", "-t", Naming.tmux_session()]
  end

  # 0-based, relative to the top of the pane's *visible* area — the same frame
  # `capture-pane`'s un-scrolled-back lines land in, so a CUP built from these
  # coordinates addresses the right row once xterm has replayed the capture.
  defp cursor_args do
    format = @cursor_prefix <> "\#{cursor_x}\t\#{cursor_y}" <> @cursor_suffix
    ["display-message", "-p", "-t", Naming.tmux_session(), format]
  end

  # Splits the `cursor_args/0` prefix off the front of a combined capture,
  # rewrites bare `\n` to `\r\n`, and appends a CUP escape for the cursor —
  # see the moduledoc comment above `start_stream/3` for why all three happen
  # together, in one place, for both callers.
  defp finalize_capture(out) do
    {pane, cursor} = split_cursor(out)
    text = normalize_line_endings(pane)

    case cursor do
      {x, y} -> text <> cup(x, y)
      nil -> text
    end
  end

  defp split_cursor(out) do
    with @cursor_prefix <> rest <- out,
         [position, pane] <- String.split(rest, @cursor_suffix, parts: 2),
         [x, y] <- String.split(position, "\t", parts: 2),
         {x, ""} <- Integer.parse(x),
         {y, ""} <- Integer.parse(y) do
      {pane, {x, y}}
    else
      _ -> {out, nil}
    end
  end

  defp cup(x, y), do: "\e[#{y + 1};#{x + 1}H"

  # tmux's pane buffer has no `\r` — it is a grid of lines, not a byte stream —
  # so `capture-pane -p` prints a bare `\n` between them. xterm is constructed
  # with `convertEol: false` (so genuine output is never silently rewritten),
  # which means nothing downstream turns that into a carriage return, and a
  # repaint staircases: every line starts one column further right than the
  # last. A `\n` already preceded by `\r` (there should not be one in
  # `capture-pane` output, but a defensive check costs nothing) is left alone.
  defp normalize_line_endings(data), do: String.replace(data, ~r/(?<!\r)\n/, "\r\n")

  defp snapshot_lines(opts) do
    Keyword.get(opts, :snapshot_lines) ||
      Application.get_env(:arbiter, :sessions_snapshot_lines) ||
      @default_snapshot_lines
  end

  # `capture-pane -p` writes the pane's *contents* to stdout, so those calls
  # must not fold stderr in. Everywhere the output is discarded or only the
  # exit status matters, stderr is captured instead — otherwise a best-effort
  # teardown against an already-dead server prints "no server running" onto
  # the operator's (and the suite's) console.
  defp run(args, opts), do: Sessions.runner(opts).run("tmux", args, [])

  defp run_quiet(args, opts),
    do: Sessions.runner(opts).run("tmux", args, stderr_to_stdout: true)

  defp parse_geometry(out) do
    case String.split(String.trim_trailing(out, "\n"), "\t", parts: 3) do
      [cols, rows, title] ->
        with {cols, ""} <- Integer.parse(cols),
             {rows, ""} <- Integer.parse(rows) do
          {:ok, %{cols: cols, rows: rows, title: title}}
        else
          _ -> {:error, {:bad_geometry, out}}
        end

      _ ->
        {:error, {:bad_geometry, out}}
    end
  end

  defp chunk(<<>>, _size), do: []

  defp chunk(bytes, size) when byte_size(bytes) <= size, do: [bytes]

  defp chunk(bytes, size) do
    [
      :binary.part(bytes, 0, size)
      | chunk(:binary.part(bytes, size, byte_size(bytes) - size), size)
    ]
  end

  # Single-quote for `/bin/sh -c`, which is what tmux runs a pipe-pane command
  # through. A path is ours (derived from a UUID under XDG_RUNTIME_DIR), but
  # quoting is the difference between "cannot happen" and "cannot happen, and
  # here is why" — and tests point it at tmp dirs we do not choose.
  defp shell_quote(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
end
