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

  @impl true
  def start_stream(%Session{} = session, path, opts \\ []) do
    lines = snapshot_lines(opts)

    args =
      base(session) ++
        ["pipe-pane", "-O", "-t", Naming.tmux_session(), "cat >> #{shell_quote(path)}", ";"] ++
        capture_args(lines)

    case run(args, opts) do
      {snapshot, 0} -> {:ok, %{snapshot: snapshot}}
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
    case run(base(session) ++ capture_args(snapshot_lines(opts)), opts) do
      {snapshot, 0} -> {:ok, snapshot}
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
