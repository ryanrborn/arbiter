defmodule Arbiter.Polecat.OutputLog do
  @default_root "/home/rborn/dev/arbiter-polecat-logs"

  @moduledoc """
  Durable, append-only, per-run transcript of an worker's output.

  The live path keeps the dashboard responsive but lossy: the in-memory buffer
  is capped at `Arbiter.Polecat.ClaudeSession.line_cap/0` lines, and only the
  bounded tail of *that* reaches `polecat_runs.output_lines`. Anything earlier
  in a long run is discarded — not archivable, not auditable.

  This module persists **every** emitted display line to an on-disk file, one
  file per run, uncapped and append-only. The capped in-memory buffer / PubSub
  stream / row tail are unchanged; this is durable capture alongside them, not
  a replacement for the live tail.

  ## Path

  `<output_log_root>/<run_id>.log`, where `output_log_root` is

      config :arbiter, :output_log_root, "/some/dir"

  (default `#{@default_root}`). One file per `Arbiter.Polecats.Run`. The path
  is a pure function of the run id, so the writer (the live session) and any
  reader (`arb polecat log`, the REST log endpoint) agree on location with no
  coordination. Runs whose `Run` row never persisted (the create write failed,
  `run_id` nil) get no durable log — there is no row to anchor retrieval to,
  matching the rest of the best-effort Run write path.

  ## Lifecycle

      {:ok, handle} = OutputLog.open(run_id)   # at session start
      OutputLog.append(handle, line)            # per emitted line, uncapped
      OutputLog.close(handle)                   # at session exit

  `open/1` is best-effort from the caller's view — a caller that can't afford
  to crash on a disk error should match `{:error, _}` and carry on with `nil`.
  The file IO device is linked to the opening process (the polecat), so an
  unclean polecat death still flushes and closes the fd.
  """

  @typedoc "An open durable-log handle. Opaque; pass to `append/2` and `close/1`."
  @type handle :: %{run_id: String.t(), path: String.t(), io: pid()}

  @doc "Root directory for per-run transcript files."
  @spec root() :: String.t()
  def root, do: Application.get_env(:arbiter, :output_log_root, @default_root)

  @doc "Absolute path of the transcript file for `run_id`."
  @spec path_for(String.t()) :: String.t()
  def path_for(run_id) when is_binary(run_id) and run_id != "" do
    Path.join(root(), run_id <> ".log")
  end

  @doc """
  Open (creating parent dirs) the append-only transcript file for `run_id`.

  Returns `{:ok, handle}` or `{:error, reason}`. The file is opened in append
  mode, so re-opening an existing run's file (e.g. after a crash/restart)
  continues the transcript rather than truncating it.
  """
  @spec open(String.t()) :: {:ok, handle()} | {:error, term()}
  def open(run_id) when is_binary(run_id) and run_id != "" do
    path = path_for(run_id)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:append, :binary]) do
      {:ok, %{run_id: run_id, path: path, io: io}}
    end
  end

  def open(_), do: {:error, :invalid_run_id}

  @doc "Append one line (a trailing newline is added) to the transcript."
  @spec append(handle(), binary()) :: :ok
  def append(%{io: io}, line) when is_binary(line) do
    IO.binwrite(io, [line, ?\n])
    :ok
  end

  @doc "Close the transcript file. Safe to call once per handle."
  @spec close(handle()) :: :ok
  def close(%{io: io}) do
    _ = File.close(io)
    :ok
  end

  @doc """
  Read the full transcript for `run_id` as a list of lines (trailing newlines
  stripped). Returns `{:ok, lines}`, or `{:error, reason}` when the file is
  absent (`:enoent`) or unreadable.
  """
  @spec read_lines(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def read_lines(run_id) when is_binary(run_id) and run_id != "" do
    case File.read(path_for(run_id)) do
      {:ok, contents} ->
        case String.trim_trailing(contents, "\n") do
          "" -> {:ok, []}
          trimmed -> {:ok, String.split(trimmed, "\n")}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read_lines(_), do: {:error, :invalid_run_id}
end
