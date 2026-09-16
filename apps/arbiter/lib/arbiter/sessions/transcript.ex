defmodule Arbiter.Sessions.Transcript do
  @moduledoc """
  Persistent raw PTY capture for a coordinator session (§11, phase 9 of
  `docs/browser-hosted-coordinator-sessions.md`).

  `Arbiter.Sessions.Stream` already taps tmux's `pipe-pane` output for the
  live transport (phase 4). This is the second, durable consumer of the same
  bytes — not a second `pipe-pane`: tmux's own docs and `Stream`'s moduledoc
  both note pipe-pane is a property of the pane, singular, so a second
  capture path has to read what the first already receives rather than issue
  its own. `Stream` opens a handle with `open/1` once, for its own lifetime
  (not per attach — see `Stream`'s moduledoc, bd-5pelo2 finding 1), and feeds
  every chunk it reads off the pipe file through `append_open/3`.

  ## Two entry points

  `append/3` is the simple, stateless form: opens the file, redacts and
  writes `data`, closes it again. Fine for a one-shot call (tests, anything
  outside the 25ms PTY poll).

  `open/1` + `append_open/3` + `close/1` are the form `Stream` actually uses
  on its hot path: `open/1` creates the file (mode `0600`, parent `0700`) and
  returns a handle holding an already-open append fd and the file's current
  size, so a caller writing many times — once per poll tick — pays the
  `File.open`/`mkdir_p`/`chmod` cost once rather than on every write
  (bd-5pelo2 finding 3).

  ## Two redaction passes

  Everything that reaches `append/3` goes through both, in order:

    * `Arbiter.Redaction.redact/2` against the session's own workspace
      secrets — the same choke-point `Arbiter.Worker.SessionArchive` uses.
    * `Arbiter.Redaction.redact_patterns/1` against common credential
      shapes — the raw screen can show a token nobody registered as a
      secret (an operator's paste, a subprocess echo).

  Neither is a substitute for treating the transcript directory as
  secret-bearing regardless: written `0600`, directory `0700` — the same
  posture `Arbiter.Worker.SessionArchive` and `docs/worker-security.md`
  take.

  ## Size cap

  `max_bytes/0` (default 100 MB) is a ceiling on the *file*, not the
  session: once a session's transcript reaches it, further bytes are
  dropped rather than growing the file without bound, matching the JSONL
  side's own `:too_large` skip in `Arbiter.Worker.SessionArchive`. Per §11
  the raw stream is smaller than the JSONL for the same session (rendered
  text, no tool-input duplication), so this is a safety ceiling, not an
  expected outcome.

  ## Retention

  `Arbiter.Sessions.TranscriptRetention` deletes a session's transcript file
  once the session has been `:ended` for longer than `retention_days/0`
  (default 30 days) — long enough to outlive the operator's own
  investigation window, short enough that a fleet of sessions doesn't
  accumulate raw transcripts forever.

  ## Configuration

  Via `config :arbiter, :sessions_transcript`:

    * `:max_bytes`      — per-file cap (default 104_857_600, 100 MB).
    * `:retention_days` — age past `ended_at` before the retention sweep
                          deletes the file (default 30).
  """

  require Logger

  alias Arbiter.Redaction
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Session
  alias Arbiter.Tasks.Workspace

  @default_max_bytes 100 * 1024 * 1024
  @default_retention_days 30

  @doc "Byte ceiling per session's raw transcript file."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: cfg(:max_bytes, @default_max_bytes)

  @doc "Days a session's transcript survives past `ended_at` before the retention sweep deletes it."
  @spec retention_days() :: pos_integer()
  def retention_days, do: cfg(:retention_days, @default_retention_days)

  @doc "Absolute path of `id`'s raw transcript file, `<sessions_root>/<id>/transcript/<id>.raw`."
  @spec path_for(String.t()) :: String.t()
  def path_for(id) when is_binary(id) and id != "" do
    Path.join(Layout.transcript_dir(id), id <> ".raw")
  end

  @doc "True when `id` has any bytes captured."
  @spec exists?(String.t()) :: boolean()
  def exists?(id) when is_binary(id) and id != "", do: File.regular?(path_for(id))

  @doc """
  Absolute path of `id`'s pipe-offset sidecar, `<id>.raw.offset`.

  Not the transcript file's own size: redaction is not length-preserving
  (`Redaction.redact/2` and `redact_patterns/1` both shrink matches to
  `[REDACTED]`), so the transcript file's byte count cannot double as a
  position in `Arbiter.Sessions.Naming.pipe_path/1`'s pipe file. This sidecar
  tracks that position directly — how far into the pipe file `Stream` has
  already fed through redaction — so a reader started after an `arbiter`
  restart can catch the transcript up on whatever the pane wrote while
  nobody was reading (bd-5pelo2 round 4 finding 1).
  """
  @spec offset_path_for(String.t()) :: String.t()
  def offset_path_for(id) when is_binary(id) and id != "" do
    path_for(id) <> ".offset"
  end

  @doc """
  The pipe-file offset last persisted for `id` by `write_offset/2`, or `nil`
  if none has been recorded yet (a session never captured, or one predating
  this sidecar).
  """
  @spec read_offset(String.t()) :: non_neg_integer() | nil
  def read_offset(id) when is_binary(id) and id != "" do
    case File.read(offset_path_for(id)) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {offset, ""} when offset >= 0 -> offset
          _ -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  @doc """
  Persist `offset` (a byte position in `id`'s pipe file) as the point its
  transcript capture has reached. Best-effort: a write failure is logged and
  swallowed, same posture as `append_open/3`.

  A one-shot open/write/close, for a caller that only writes once (tests,
  anything outside `Stream`'s hot path). `Stream` itself uses `open_offset/1`
  + `write_offset_fd/2` instead, to avoid paying this cost on every pumped
  chunk.
  """
  @spec write_offset(String.t(), non_neg_integer()) :: :ok
  def write_offset(id, offset) when is_binary(id) and id != "" and is_integer(offset) do
    path = offset_path_for(id)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Integer.to_string(offset)) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Sessions.Transcript: offset write failed path=#{path}: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Open `id`'s pipe-offset sidecar for repeated `write_offset_fd/2` writes,
  creating its parent directory if needed.

  For a caller (`Stream`) that persists the offset once per pumped chunk —
  up to ~40 times a second on the default 25ms poll — paying `File.mkdir_p`
  plus an open/write/close on every call is the same per-write cost round 1
  removed for the transcript fd itself (see the moduledoc). This opens the
  fd once; `write_offset_fd/2` reuses it with `:file.pwrite/3`.
  """
  @spec open_offset(String.t()) :: {:ok, :file.io_device()} | {:error, term()}
  def open_offset(id) when is_binary(id) and id != "" do
    path = offset_path_for(id)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      :file.open(path, [:read, :write, :raw, :binary])
    end
  end

  @doc """
  Persist `offset` through an already-open sidecar fd from `open_offset/1`.

  Always overwrites at position 0 rather than appending or truncating: the
  offset persisted here only ever grows (it tracks how far a monotonically
  growing pipe file has been transcribed), so its decimal width never
  shrinks between writes and the file is always left holding exactly one
  well-formed integer for `read_offset/1`. Best-effort, same posture as
  `write_offset/2`.
  """
  @spec write_offset_fd(:file.io_device(), non_neg_integer()) :: :ok
  def write_offset_fd(fd, offset) when is_integer(offset) and offset >= 0 do
    case :file.pwrite(fd, 0, Integer.to_string(offset)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Sessions.Transcript: offset pwrite failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Close a sidecar fd opened with `open_offset/1`."
  @spec close_offset(:file.io_device()) :: :ok
  def close_offset(fd) do
    _ = :file.close(fd)
    :ok
  end

  @doc """
  The redact-on-write secret list for `session` — its workspace's registered
  secrets, or `[]` for a cross-workspace session (`workspace_id: nil`, the
  coordinator's normal shape) or one whose workspace failed to load.

  Accepts a `Session.t()` or any map/struct carrying `:workspace_id` (a bare
  `%{workspace_id: ...}` pattern matches both) — `Arbiter.Worker.SessionArchive`
  reuses this for `archive_coordinator_session/2`, which takes the same loose
  shape `archive_run/2` already does.
  """
  @spec redact_values_for(Session.t() | %{workspace_id: String.t() | nil}) :: [String.t()]
  def redact_values_for(%{workspace_id: nil}), do: []

  def redact_values_for(%{workspace_id: workspace_id}) when is_binary(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, workspace} -> Workspace.worker_env_secret_values(workspace)
      {:error, _} -> []
    end
  end

  @typedoc "A handle from `open/1`: an already-open append fd plus the file's running size."
  @type handle :: %{fd: :file.io_device(), size: non_neg_integer(), path: String.t()}

  @doc """
  Open `id`'s raw transcript file for repeated appends via `append_open/3`,
  creating it (mode `0600`, parent `0700`) if it does not exist yet.

  The returned handle's `size` is the file's size at open time and is
  maintained by `append_open/3` from then on, so a long-lived caller (`Stream`)
  never needs to re-`File.stat` the file on its own hot path.
  """
  @spec open(String.t()) :: {:ok, handle()} | {:error, term()}
  def open(id) when is_binary(id) and id != "" do
    path = path_for(id)
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- chmod(dir, 0o700),
         {:ok, fd} <- :file.open(path, [:append, :raw, :binary]),
         :ok <- chmod(path, 0o600) do
      {:ok, %{fd: fd, size: file_size(path), path: path}}
    end
  end

  @doc """
  Redact and append `data` through an already-open `handle` (from `open/1`),
  returning the updated handle.

  Silently drops the bytes once `handle.size` is at or past `max_bytes/0` —
  this must never be the reason a session's pane stops working. A write
  failure is logged and swallowed for the same reason, returning `handle`
  unchanged.

  `redact_values` are the session's own workspace secrets (see
  `Arbiter.Worker.WorkerEnv.secret_values/1` for the run-side analogue);
  `Arbiter.Redaction.redact_patterns/1` runs unconditionally after. Redaction
  only sees exactly the bytes in `data` — a caller writing in chunks (as
  `Stream` does, every poll tick) is responsible for not splitting a secret
  across two calls; `Stream` itself holds a tail buffer back for this reason.
  """
  @spec append_open(handle(), binary(), [String.t() | nil]) :: handle()
  def append_open(%{size: size} = handle, data, redact_values \\ [])
      when is_binary(data) do
    if size < max_bytes() do
      scrubbed =
        data
        |> Redaction.redact(redact_values)
        |> Redaction.redact_patterns()

      case :file.write(handle.fd, scrubbed) do
        :ok ->
          %{handle | size: size + byte_size(scrubbed)}

        {:error, reason} ->
          Logger.warning(
            "Sessions.Transcript: append failed path=#{handle.path}: #{inspect(reason)}"
          )

          handle
      end
    else
      handle
    end
  end

  @doc "Close a handle opened with `open/1`."
  @spec close(handle()) :: :ok
  def close(%{fd: fd}) do
    _ = :file.close(fd)
    :ok
  end

  @doc """
  Redact and append `data` to `id`'s raw transcript file in one call —
  `open/1` + `append_open/3` + `close/1`, for a caller that only writes once
  (tests, anything outside `Stream`'s hot path).
  """
  @spec append(String.t(), binary(), [String.t() | nil]) :: :ok
  def append(id, data, redact_values \\ [])

  def append(id, data, redact_values)
      when is_binary(id) and id != "" and is_binary(data) do
    case open(id) do
      {:ok, handle} ->
        _ = append_open(handle, data, redact_values)
        close(handle)

      {:error, reason} ->
        Logger.warning("Sessions.Transcript: open failed id=#{id}: #{inspect(reason)}")
        :ok
    end
  end

  def append(_id, _data, _redact_values), do: :ok

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> 0
    end
  end

  defp cfg(key, default) do
    case get_in(Application.get_env(:arbiter, :sessions_transcript, []), [key]) do
      nil -> default
      val -> val
    end
  end
end
