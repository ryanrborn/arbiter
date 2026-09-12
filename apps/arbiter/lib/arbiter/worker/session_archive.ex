defmodule Arbiter.Worker.SessionArchive do
  @moduledoc """
  Durable, per-run archive of the agent CLI's **own session JSONL** — the
  full-fidelity record Arbiter reads but, until bd-db0p38, never kept.

  ## Why this exists

  Everything else Arbiter persists about a run is a *rendering*. The durable
  transcript (`Arbiter.Worker.OutputLog`) holds every emitted display line but
  truncates each tool result to 40 lines; `worker_runs.output_lines` keeps a
  1000-line tail; `Arbiter.Workers.RunStep` keeps a 200-char input summary and
  a 2000-char output summary. Thinking blocks, per-message token usage, model
  / effort / requestId, and full tool inputs exist *nowhere* in Arbiter.

  They do exist on disk: Claude Code writes every event to
  `<config_dir>/projects/<slug>/<session_id>.jsonl`, which
  `Arbiter.Usage.ClaudeSessionFile` already locates and parses.
  `Arbiter.Workers.StepBackfill`'s moduledoc calls that file "the only
  retroactive source of ground truth: the rendered transcript has thrown the
  structure away" — and then nothing archived it. **Claude Code prunes its
  session store at ~21 days** (no `cleanupPeriodDays` configured, so the CLI
  default applies), so the ground truth was being destroyed on a rolling
  basis: an audit on 2026-09-12 found 45% of runs with a `session_id` had
  already lost their file, and nothing survived before 2026-08-22.

  This module is the write side. It copies the file out of the CLI's
  self-pruning store into `Arbiter.Worker.OutputLog.root/0`, which Arbiter
  owns and never prunes.

  ## Path convention (stable — external readers may rely on it)

      <output_log_root>/<run_id>.log                        # rendered transcript (OutputLog)
      <output_log_root>/<run_id>.prompt                     # composed prompt   (PromptLog)
      <output_log_root>/<run_id>.jsonl.gz                   # this module
      <output_log_root>/<run_id>.subagents/agent-*.jsonl.gz # this module

  Keyed by `run_id`, exactly like its two neighbours, so a reader that can
  already fetch a run's transcript needs nothing new. Gzipped (measured 5:1 on
  the corpus): ~16 MB/day raw becomes ~3 MB/day on disk.

  ## Redaction: **both** paths, deliberately

  The raw JSONL is unredacted, and `Arbiter.Worker.StepSummary` warns that a
  second persistence path "is how a secret escapes redaction on one surface
  but not another". So this module does both of the things that were on the
  table, because neither alone is sufficient:

    * **Redact on ingest.** Every byte goes through `Arbiter.Redaction` — the
      same single choke-point every other surface uses — against the run's
      workspace secret values. A plain string replace over the raw bytes is
      safe for JSONL: the placeholder contains no JSON metacharacters, and
      matching is verbatim, so a redacted line still parses.
    * **Treat the root as secret-bearing anyway.** Redaction only knows the
      secrets someone marked; it cannot catch a live signing key a subprocess
      printed (2026-07-16) or a `ARBITER_CLOAK_KEY` an agent echoed into its
      own transcript (2026-09-12). So archives are written `0600` and the
      archive root is best-effort `chmod 0700`. **Operators must treat
      `output_log_root` as secret-bearing storage** — see
      `docs/operations/session-archive.md`.

  The alternative — redacting *nothing* to protect ground-truth fidelity —
  was rejected: `Arbiter.Redaction` only ever removes values a human
  explicitly marked secret, so what it damages is precisely what must not be
  archived in the first place.

  ## `--resume` shares one file across runs

  `Arbiter.Worker.Dispatch.resume_session/2` re-spawns with `--resume <sid>`
  and the CLI **appends to the same `<sid>.jsonl`**, while Arbiter opens a new
  `Run` row. The token reader and the step backfill each window that file by
  timestamp, because attributing another run's tokens or tool calls is a
  correctness bug. Archiving is the opposite case: windowing would drop
  undated lines and re-introduce exactly the lossiness this exists to end. So
  **the whole file is archived under each run id that points at it** — the
  parent's archive and the child's are byte-identical, and each is complete.
  Deduping is left to the filesystem/backup layer; a resumed run is a small
  minority and correctness beats a few MB.

  ## Non-Claude runs

  `config_dir` is a Claude-only column. A Gemini-driven run carries a
  `session_id` but no `config_dir` (its session lives in
  `~/.gemini/antigravity-cli/conversations/<sid>.db`), so `archive/4` returns
  `:no_config_dir` rather than pretending a Claude JSONL is missing. This is
  the whole of the "September loss channel" bd-db0p38 asked to diagnose: all
  32 of those runs are Gemini reviewer runs, not lost Claude files.
  """

  require Logger

  alias Arbiter.Redaction
  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Worker.OutputLog

  @typedoc """
  Outcome of one archive attempt.

    * `:ok` — the session JSONL was archived (`bytes_in`/`bytes_out` are the
      pre/post-gzip sizes, `subagents` the count of subagent transcripts).
    * `:no_config_dir` — not a Claude run (see the moduledoc).
    * `:no_session_id` — the run never reached a `system/init` event.
    * `:no_session_file` — the CLI's file is gone (pruned, or the config dir
      was reaped). Irrecoverable, and the reason this module exists.
    * `:too_large` — over `max_bytes/0`; skipped rather than risk the VM.
    * `:error` — read/write failed; `reason` carries the posix error.
  """
  @type status :: :ok | :no_config_dir | :no_session_id | :no_session_file | :too_large | :error

  @type report :: %{
          run_id: String.t(),
          status: status(),
          source: String.t() | nil,
          bytes_in: non_neg_integer(),
          bytes_out: non_neg_integer(),
          subagents: non_neg_integer(),
          reason: term()
        }

  # A session JSONL is read whole so redaction can match across the entire
  # file (a chunked replace would miss a secret straddling a chunk boundary).
  # The largest observed file is single-digit MB; this cap exists so a
  # pathological one can never take the worker down with it.
  @max_bytes 512 * 1024 * 1024

  @doc "Byte ceiling above which a session file is skipped rather than read whole."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "Absolute path of the gzipped session-JSONL archive for `run_id`."
  @spec path_for(String.t()) :: String.t()
  def path_for(run_id) when is_binary(run_id) and run_id != "" do
    Path.join(OutputLog.root(), run_id <> ".jsonl.gz")
  end

  @doc "Absolute path of the directory holding `run_id`'s subagent archives."
  @spec subagents_dir_for(String.t()) :: String.t()
  def subagents_dir_for(run_id) when is_binary(run_id) and run_id != "" do
    Path.join(OutputLog.root(), run_id <> ".subagents")
  end

  @doc "True when `run_id` has a session-JSONL archive on disk."
  @spec archived?(String.t() | nil) :: boolean()
  def archived?(run_id) when is_binary(run_id) and run_id != "",
    do: File.regular?(path_for(run_id))

  def archived?(_), do: false

  @doc """
  Read `run_id`'s archive back, decompressed. `{:error, :enoent}` when the run
  was never archived.
  """
  @spec read(String.t()) :: {:ok, binary()} | {:error, term()}
  def read(run_id) when is_binary(run_id) and run_id != "" do
    case File.read(path_for(run_id)) do
      {:ok, gz} -> {:ok, :zlib.gunzip(gz)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def read(_), do: {:error, :invalid_run_id}

  @doc """
  Archive the session JSONL for `run_id`, located via `config_dir` /
  `session_id` (`Arbiter.Usage.ClaudeSessionFile.locate/2` — no new capture
  path, no argv change).

  Always `{:ok, report}`: a missing file is a *result*, not an error, because
  this runs on the run-completion path and on sweeps over thousands of runs,
  neither of which may abort on one bad file.

  ## Options

    * `:redact_values` — secret values to scrub. Defaults to `[]`; callers on
      the live path pass the session's own list, the backfill passes the
      workspace's current one.

  """
  @spec archive(String.t(), String.t() | nil, String.t() | nil, keyword()) :: {:ok, report()}
  def archive(run_id, config_dir, session_id, opts \\ [])

  def archive(run_id, config_dir, session_id, opts)
      when is_binary(run_id) and run_id != "" do
    cond do
      # Session id first: a workflow-mode (bookkeeping-only) run has neither
      # coordinate, and `:no_session_id` — "never opened an agent session" — is
      # the informative half. That ordering also keeps `:no_config_dir` meaning
      # exactly one thing: a run that *did* open a session, on another
      # provider. See `Arbiter.Workers.SessionArchiveBackfill`'s report.
      not (is_binary(session_id) and session_id != "") ->
        {:ok, blank(run_id, :no_session_id)}

      not (is_binary(config_dir) and config_dir != "") ->
        {:ok, blank(run_id, :no_config_dir)}

      true ->
        case ClaudeSessionFile.locate(config_dir, session_id) do
          {:ok, path} -> do_archive(run_id, path, Keyword.get(opts, :redact_values) || [])
          :not_found -> {:ok, blank(run_id, :no_session_file)}
        end
    end
  rescue
    e ->
      Logger.warning("SessionArchive.archive/4 raised for run=#{run_id}: #{Exception.message(e)}")
      {:ok, %{blank(run_id, :error) | reason: Exception.message(e)}}
  end

  def archive(run_id, _config_dir, _session_id, _opts) do
    {:ok, %{blank(to_string(run_id), :error) | reason: :invalid_run_id}}
  end

  @doc """
  `archive/4` for a `Arbiter.Workers.Run` struct (or any map carrying `:id`,
  `:config_dir`, `:session_id` and `:task_id`).

  This is the single entry point both callers use — the run-completion hook in
  `Arbiter.Worker` and the one-time sweep in
  `Arbiter.Workers.SessionArchiveBackfill` — so there is exactly one place
  that decides what gets redacted and where the bytes land.

  `:redact_values` defaults to the run's workspace secret values
  (`Arbiter.Worker.WorkerEnv.secret_values/1`). On the live path that list is
  the run's *own* secrets; on a backfill it is whatever the workspace holds
  today, which is strictly weaker — a since-rotated credential is no longer in
  the list to scrub. That is the second reason the archive root is treated as
  secret-bearing regardless.
  """
  @spec archive_run(map(), keyword()) :: {:ok, report()}
  def archive_run(run, opts \\ []) do
    opts =
      Keyword.put_new_lazy(opts, :redact_values, fn ->
        Arbiter.Worker.WorkerEnv.secret_values(Map.get(run, :task_id))
      end)

    archive(Map.get(run, :id), Map.get(run, :config_dir), Map.get(run, :session_id), opts)
  end

  # ---- internals ---------------------------------------------------------

  defp do_archive(run_id, path, redact_values) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @max_bytes ->
        Logger.warning(
          "SessionArchive: skipping oversized session file run=#{run_id} size=#{size}"
        )

        {:ok, %{blank(run_id, :too_large) | source: path, bytes_in: size}}

      {:ok, _stat} ->
        write_archive(run_id, path, redact_values)

      {:error, reason} ->
        {:ok, %{blank(run_id, :error) | source: path, reason: reason}}
    end
  end

  defp write_archive(run_id, path, redact_values) do
    with {:ok, raw} <- File.read(path),
         gz = raw |> Redaction.redact(redact_values) |> :zlib.gzip(),
         :ok <- write_private(path_for(run_id), gz) do
      subagents = archive_subagents(run_id, path, redact_values)

      {:ok,
       %{
         blank(run_id, :ok)
         | source: path,
           bytes_in: byte_size(raw),
           bytes_out: byte_size(gz),
           subagents: subagents
       }}
    else
      {:error, reason} ->
        Logger.warning(
          "SessionArchive: could not archive run=#{run_id} path=#{path}: #{inspect(reason)}"
        )

        {:ok, %{blank(run_id, :error) | source: path, reason: reason}}
    end
  end

  # Subagent transcripts sit beside the parent session file, under a directory
  # named for the session:
  #   <slug>/<session_id>/subagents/agent-<id>.jsonl        (the transcript)
  #   <slug>/<session_id>/subagents/agent-<id>.meta.json    (its name/type)
  # Both are archived — the meta is what associates a transcript with the
  # subagent that produced it. Only the `.jsonl` transcripts are counted.
  defp archive_subagents(run_id, session_path, redact_values) do
    session_id = Path.basename(session_path, ".jsonl")

    sources =
      [Path.dirname(session_path), session_id, "subagents", "agent-*"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    if sources == [] do
      0
    else
      dir = subagents_dir_for(run_id)
      _ = File.mkdir_p(dir)
      _ = File.chmod(dir, 0o700)

      Enum.count(sources, fn src ->
        with {:ok, raw} <- File.read(src),
             gz = raw |> Redaction.redact(redact_values) |> :zlib.gzip(),
             :ok <- write_private(Path.join(dir, Path.basename(src) <> ".gz"), gz) do
          String.ends_with?(src, ".jsonl")
        else
          {:error, reason} ->
            Logger.warning(
              "SessionArchive: could not archive subagent run=#{run_id} src=#{src}: " <>
                inspect(reason)
            )

            false
        end
      end)
    end
  end

  # Write truncating (re-archiving converges rather than appending) and leave
  # the file readable only by the owner — the archive is unredacted material
  # by assumption. The root chmod is best-effort: a pre-existing root with
  # other semantics must not turn an archive into an error.
  defp write_private(dest, bytes) do
    root = Path.dirname(dest)

    with :ok <- File.mkdir_p(root),
         :ok <- File.write(dest, bytes) do
      _ = File.chmod(OutputLog.root(), 0o700)
      File.chmod(dest, 0o600)
    end
  end

  defp blank(run_id, status) do
    %{
      run_id: run_id,
      status: status,
      source: nil,
      bytes_in: 0,
      bytes_out: 0,
      subagents: 0,
      reason: nil
    }
  end
end
