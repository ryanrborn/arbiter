defmodule Arbiter.Reviews.Transcript do
  @moduledoc """
  Durable, per-review transcript of an external review's Claude session
  (bd-7efini, #1425).

  A regular worker run gets the whole session on disk for free: the composed
  prompt via `Arbiter.Worker.PromptLog`, every emitted line via
  `Arbiter.Worker.OutputLog`, both keyed by `Arbiter.Workers.Run` id and
  surfaced through `worker_log` / `run_log_list`. An external review
  (`worker_review(pr:)`, `arb review --pr`) never spawns through
  `Arbiter.Worker`/`ClaudeSession` — it shells out from
  `Arbiter.Workflows.CodeReview.Checks.invoke_via_stdin/4` — so until now the
  only durable artifact it produced was its prompt. The full `stream-json`
  output (every model turn, every tool call and its result) was parsed for
  text + usage in memory and then dropped on the floor.

  This module is the write and read side of that gap.

  ## Keying — why the review record id, not a run id

  An external review is not task-linked, so it has no `Arbiter.Workers.Run`
  row and cannot ride `run_log_list`'s task-scoped lookup. Its stable,
  already-persisted identity is its `Arbiter.Reviews.Record` id, which is
  exactly what `Checks.persist_review_prompt/2` already keys the prompt file
  on. So this module keys on the record id and reuses
  `Arbiter.Worker.OutputLog.root/0`:

      <output_log_root>/<review_record_id>.log      # this module
      <output_log_root>/<review_record_id>.prompt   # Arbiter.Worker.PromptLog

  Record ids and run ids are both UUIDs drawn from disjoint tables, so the
  shared root has no collision to resolve, and an operator who already knows
  where a worker transcript lives needs nothing new to find a review's.

  `Arbiter.Workflows.ReviewPatrol`'s re-review shares the same invoker and
  seeds `:review_record_id` with its engagement `Issue` id instead, so it gets
  the same capture under `<engagement_id>.log` — again beside the prompt file
  that path already wrote.

  ## Content — raw `stream-json`, not display lines

  A worker transcript holds rendered display lines. This holds the reviewer's
  raw JSONL exactly as the CLI emitted it (redacted), one event per line: the
  `system/init` handshake, each assistant turn, each `tool_use` and the
  matching `tool_result`, and the terminal `result`. Storing the raw corpus
  keeps the tool-use record lossless; `events/1`, `tool_uses/1` and
  `summary/1` derive the readable views from it, so nothing that mattered has
  to be decided at write time.

  ## Retention

  One file per review, truncating (not appending): a retried review
  (`run_workflow_with_retries/3`) reuses its record id, and the transcript of
  the attempt that actually produced the verdict is the one worth keeping.
  """

  alias Arbiter.Redaction
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Worker.PromptLog

  @typedoc "A normalized transcript event — see `events/1`."
  @type event :: %{required(:kind) => atom(), optional(atom()) => term()}

  @typedoc "A tool call paired with the result it got back — see `tool_uses/1`."
  @type tool_use :: %{
          name: String.t(),
          tool_use_id: String.t() | nil,
          input: map(),
          result: String.t() | nil
        }

  @doc "Absolute path of the transcript file for `record_id`."
  @spec path_for(String.t()) :: String.t()
  def path_for(record_id) when is_binary(record_id) and record_id != "",
    do: OutputLog.path_for(record_id)

  @doc "Absolute path of the prompt file for `record_id` (written by `Arbiter.Worker.PromptLog`)."
  @spec prompt_path_for(String.t()) :: String.t()
  def prompt_path_for(record_id) when is_binary(record_id) and record_id != "",
    do: PromptLog.path_for(record_id)

  @doc """
  Persist `raw_output` (the reviewer's raw `stream-json` stdout) as this
  review's transcript, redacting every value in `secret_values` first.

  Truncates any prior content — one transcript per review record. Best-effort
  from the caller's view: a disk error returns `{:error, reason}` and never
  raises, so a capture failure can't fail the review it was recording.
  """
  @spec write(String.t(), binary(), [String.t() | nil]) :: :ok | {:error, term()}
  def write(record_id, raw_output, secret_values \\ [])

  def write(record_id, raw_output, secret_values)
      when is_binary(record_id) and record_id != "" and is_binary(raw_output) do
    path = path_for(record_id)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Redaction.redact(raw_output, secret_values))
    end
  end

  def write(_record_id, _raw_output, _secret_values), do: {:error, :invalid_record_id}

  @doc """
  Read the full transcript for `record_id` as a list of raw JSONL lines.

  `{:error, :enoent}` when the review predates transcript capture or its
  reviewer never produced output.
  """
  @spec read_lines(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def read_lines(record_id) when is_binary(record_id) and record_id != "",
    do: OutputLog.read_lines(record_id)

  def read_lines(_record_id), do: {:error, :invalid_record_id}

  @doc "True when a transcript file exists on disk for `record_id`."
  @spec exists?(String.t()) :: boolean()
  def exists?(record_id) when is_binary(record_id) and record_id != "",
    do: File.regular?(path_for(record_id))

  def exists?(_record_id), do: false

  @doc "Read the composed review prompt persisted for `record_id`."
  @spec prompt(String.t()) :: {:ok, binary()} | {:error, term()}
  def prompt(record_id), do: PromptLog.read(record_id)

  @doc """
  The transcript as ordered, normalized events — the readable projection of
  the raw JSONL, in emission order.

  Each event is a map with a `:kind`:

    * `:system` — the `system/init` handshake (`:model`, `:session_id`)
    * `:assistant_text` — one assistant text block (`:text`)
    * `:tool_use` — one tool call (`:name`, `:tool_use_id`, `:input`)
    * `:tool_result` — what that call returned (`:tool_use_id`, `:text`)
    * `:result` — the terminal result event (`:text`)
    * `:raw` — a line that isn't Claude JSON (stderr noise, a test stub's
      plain text); kept rather than dropped, since it's often the only clue
      a failed review left behind

  An absent or unreadable transcript yields `[]`.
  """
  @spec events(String.t()) :: [event()]
  def events(record_id) do
    case read_lines(record_id) do
      {:ok, lines} -> Enum.flat_map(lines, &line_events/1)
      {:error, _} -> []
    end
  end

  @doc """
  Every tool call the reviewer made, in order, paired with the result it got
  back (`nil` when the transcript ends before the result arrived).
  """
  @spec tool_uses(String.t()) :: [tool_use()]
  def tool_uses(record_id), do: record_id |> events() |> pair_tool_uses()

  @doc """
  Capture state and shape of one review's durable corpus, without reading the
  whole thing into the caller's context: `:path`, `:prompt_path`, `:exists`,
  `:prompt_exists`, `:line_count`, `:tool_use_count`, and `:tools_used` (a
  name/count histogram, sorted by name).

  Mirrors what `run_log_list`'s `transcript_exists` / `line_count` report for
  a regular worker run.
  """
  @spec summary(String.t()) :: map()
  def summary(record_id) when is_binary(record_id) and record_id != "" do
    lines =
      case read_lines(record_id) do
        {:ok, lines} -> lines
        {:error, _} -> []
      end

    tools = lines |> Enum.flat_map(&line_events/1) |> pair_tool_uses()

    %{
      path: path_for(record_id),
      prompt_path: prompt_path_for(record_id),
      exists: exists?(record_id),
      prompt_exists: File.regular?(prompt_path_for(record_id)),
      line_count: length(lines),
      tool_use_count: length(tools),
      tools_used: histogram(tools)
    }
  end

  # ---- internals ----------------------------------------------------------

  defp histogram(tool_uses) do
    tool_uses
    |> Enum.frequencies_by(& &1.name)
    |> Enum.map(fn {name, count} -> %{name: name, count: count} end)
    |> Enum.sort_by(& &1.name)
  end

  defp pair_tool_uses(events) do
    results =
      for %{kind: :tool_result, tool_use_id: id, text: text} <- events,
          is_binary(id),
          into: %{},
          do: {id, text}

    for %{kind: :tool_use} = e <- events do
      %{
        name: e.name,
        tool_use_id: e.tool_use_id,
        input: e.input,
        result: e.tool_use_id && Map.get(results, e.tool_use_id)
      }
    end
  end

  defp line_events(line) do
    case Jason.decode(line) do
      {:ok, decoded} when is_map(decoded) -> decoded_events(decoded)
      _ -> [%{kind: :raw, text: line}]
    end
  end

  defp decoded_events(%{"type" => "system"} = e) do
    [%{kind: :system, model: e["model"], session_id: e["session_id"], subtype: e["subtype"]}]
  end

  defp decoded_events(%{"type" => "result"} = e) do
    [%{kind: :result, text: e["result"] || "", subtype: e["subtype"]}]
  end

  defp decoded_events(%{"message" => %{"content" => content}}) when is_list(content),
    do: Enum.flat_map(content, &content_block_event/1)

  defp decoded_events(_other), do: []

  defp content_block_event(%{"type" => "text", "text" => text}) when is_binary(text),
    do: [%{kind: :assistant_text, text: text}]

  defp content_block_event(%{"type" => "tool_use"} = block) do
    [
      %{
        kind: :tool_use,
        name: block["name"] || "unknown",
        tool_use_id: block["id"],
        input: (is_map(block["input"]) && block["input"]) || %{}
      }
    ]
  end

  defp content_block_event(%{"type" => "tool_result"} = block) do
    [
      %{
        kind: :tool_result,
        tool_use_id: block["tool_use_id"],
        text: tool_result_text(block["content"])
      }
    ]
  end

  defp content_block_event(_block), do: []

  # `tool_result.content` is either a plain string or a list of content
  # blocks, depending on the tool; flatten both to text.
  defp tool_result_text(content) when is_binary(content), do: content

  defp tool_result_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp tool_result_text(nil), do: ""
  defp tool_result_text(other), do: inspect(other)
end
