defmodule Arbiter.Worker.PromptLog do
  @moduledoc """
  Durable, per-run record of the composed prompt an agent was spawned with.

  Nothing recorded what an agent was told (bd-9rdwe4, #1017 gap G5): a
  temp-file-delivered oversized prompt is unlinked as soon as the port exits
  (`Arbiter.Agents.Claude.build_argv/3` / `Arbiter.Worker`'s tmpfile
  reclaim), and an inline prompt is never captured anywhere at all. This
  module is the write side of that gap, mirroring `Arbiter.Worker.OutputLog`
  exactly (same root, same one-file-per-run shape) so a reader who already
  knows how to fetch a transcript by `run_id` needs nothing new to fetch its
  prompt.

  ## Path

  `<output_log_root>/<run_id>.prompt` — literally beside the transcript
  (`<output_log_root>/<run_id>.log`), sharing `Arbiter.Worker.OutputLog.root/0`
  rather than a second configurable root.

  ## Redaction

  Callers MUST redact (`Arbiter.Redaction.redact/2`, the same choke-point
  that protects transcripts) before calling `write/2` or `append/2` — this
  module persists exactly the bytes it is given, no more, no less.

  ## Lifecycle

  One prompt per run: `write/2` truncates/creates. A gate nudge or
  session-resume that swaps in a short follow-up prompt on an
  already-running session calls `append/2` instead, so the file grows to
  reflect everything the agent was actually told over the life of the run
  rather than just the first message.
  """

  alias Arbiter.Worker.OutputLog

  @typedoc "SHA-256 hex digest, lowercase, 64 chars."
  @type digest :: String.t()

  @doc "Absolute path of the prompt file for `run_id`."
  @spec path_for(String.t()) :: String.t()
  def path_for(run_id) when is_binary(run_id) and run_id != "" do
    Path.join(OutputLog.root(), run_id <> ".prompt")
  end

  @doc """
  Write (creating parent dirs) the composed prompt for `run_id`, truncating
  any prior content — one prompt file per run, not an append-only log.
  """
  @spec write(String.t(), binary()) :: :ok | {:error, term()}
  def write(run_id, content) when is_binary(run_id) and run_id != "" and is_binary(content) do
    path = path_for(run_id)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, content)
    end
  end

  def write(_run_id, _content), do: {:error, :invalid_run_id}

  @doc """
  Append a follow-up prompt (a gate nudge, a resume's continue prompt) to the
  existing prompt file for `run_id`, separated from what came before. Creates
  the file (as if by `write/2`) when none exists yet.
  """
  @spec append(String.t(), binary()) :: :ok | {:error, term()}
  def append(run_id, content) when is_binary(run_id) and run_id != "" and is_binary(content) do
    path = path_for(run_id)

    case File.read(path) do
      {:ok, existing} -> write(run_id, existing <> "\n\n--- continued ---\n\n" <> content)
      {:error, :enoent} -> write(run_id, content)
      {:error, _} = err -> err
    end
  end

  def append(_run_id, _content), do: {:error, :invalid_run_id}

  @doc "Read the persisted prompt for `run_id`. `{:error, :enoent}` when none was ever written."
  @spec read(String.t()) :: {:ok, binary()} | {:error, term()}
  def read(run_id) when is_binary(run_id) and run_id != "", do: File.read(path_for(run_id))
  def read(_run_id), do: {:error, :invalid_run_id}

  @doc "Lowercase hex SHA-256 digest of `content`, for the run row's `prompt_sha256`."
  @spec sha256(binary()) :: digest()
  def sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
