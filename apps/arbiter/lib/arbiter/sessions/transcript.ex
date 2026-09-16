defmodule Arbiter.Sessions.Transcript do
  @moduledoc """
  Persistent raw PTY capture for a coordinator session (§11, phase 9 of
  `docs/browser-hosted-coordinator-sessions.md`).

  `Arbiter.Sessions.Stream` already taps tmux's `pipe-pane` output for the
  live transport (phase 4). This is the second, durable consumer of the same
  bytes — not a second `pipe-pane`: tmux's own docs and `Stream`'s moduledoc
  both note pipe-pane is a property of the pane, singular, so a second
  capture path has to read what the first already receives rather than issue
  its own. `Stream`'s `push_frame/2` calls `append/3` with every chunk it
  reads off the pipe file, so the persistent copy exists for exactly as long
  as `Stream`'s reader is alive for that session — the same lifetime the
  transport pipe already has.

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

  @doc """
  Redact and append `data` to `id`'s raw transcript file, creating it (mode
  `0600`, parent `0700`) on first write.

  Silently drops the bytes once the file is at or past `max_bytes/0` — this
  must never be the reason a session's pane stops working. Any write failure
  is logged and swallowed for the same reason.

  `redact_values` are the session's own workspace secrets (see
  `Arbiter.Worker.WorkerEnv.secret_values/1` for the run-side analogue);
  `Arbiter.Redaction.redact_patterns/1` runs unconditionally after.
  """
  @spec append(String.t(), binary(), [String.t() | nil]) :: :ok
  def append(id, data, redact_values \\ [])

  def append(id, data, redact_values)
      when is_binary(id) and id != "" and is_binary(data) do
    path = path_for(id)

    with {:ok, size} <- current_size(path),
         true <- size < max_bytes() do
      scrubbed =
        data
        |> Redaction.redact(redact_values)
        |> Redaction.redact_patterns()

      write(path, scrubbed)
    else
      _ -> :ok
    end
  end

  def append(_id, _data, _redact_values), do: :ok

  defp current_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, :enoent} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(path, bytes) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok ->
        case File.write(path, bytes, [:append]) do
          :ok ->
            _ = File.chmod(dir, 0o700)
            _ = File.chmod(path, 0o600)
            :ok

          {:error, reason} ->
            Logger.warning("Sessions.Transcript: append failed path=#{path}: #{inspect(reason)}")
            :ok
        end

      {:error, reason} ->
        Logger.warning("Sessions.Transcript: mkdir_p failed dir=#{dir}: #{inspect(reason)}")
        :ok
    end
  end

  defp cfg(key, default) do
    case get_in(Application.get_env(:arbiter, :sessions_transcript, []), [key]) do
      nil -> default
      val -> val
    end
  end
end
