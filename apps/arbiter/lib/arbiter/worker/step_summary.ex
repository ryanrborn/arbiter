defmodule Arbiter.Worker.StepSummary do
  @moduledoc """
  The one place a tool call's input/output is turned into the bounded,
  redacted strings that land on `Arbiter.Workers.RunStep`.

  Extracted from `Arbiter.Worker.ClaudeSession` in bd-apwfmy Phase 2, when a
  second producer of step rows appeared (`Arbiter.Workers.StepBackfill`,
  reconstructing calls from the on-disk session JSONL). The parent issue is
  explicit about why that extraction is not optional:

  > All step capture must hang off the existing single `ClaudeSession` emit
  > path. Adding a second path is how a secret escapes redaction on one
  > surface but not another.

  So the backfill does not get its own summarizer. Both callers funnel
  through these three functions, each of which applies `Arbiter.Redaction`
  before bounding — never after, and never optionally.

  ## Redaction is best-effort by construction

  `Arbiter.Redaction` is a plain string replace over *known* secret-marked
  values. It cannot find a secret nobody told it about, and the backfill's
  position is worse than the live path's: it redacts against the values the
  workspace holds *today*, not the ones the run actually had. That is why
  backfilled rows are tagged `source: "backfill"` — the provenance of a
  summary is part of how much you should trust it.
  """

  @input_summary_max 200
  @output_summary_max 2000

  @doc """
  Bounded, redacted one-line summary of a `tool_use` block's input.

  Picks the field a human would recognise the call by (`command`,
  `file_path`, `path`, `pattern`, `description`, `skill`) and only falls back
  to raw JSON when none is present.
  """
  @spec input_summary(map() | nil, [String.t()]) :: String.t()
  def input_summary(input, redact_values \\ []) do
    input
    |> summarize_tool_input()
    |> redact(redact_values)
  end

  @doc """
  Bounded, redacted summary of a `tool_result` block's already-extracted text.
  """
  @spec output_summary(String.t() | nil, [String.t()]) :: String.t()
  def output_summary(text, redact_values \\ [])

  def output_summary(nil, _redact_values), do: ""

  def output_summary(text, redact_values) when is_binary(text) do
    text
    |> redact(redact_values)
    |> truncate(@output_summary_max)
  end

  @doc """
  sha256 (hex) of the redacted, JSON-encoded tool input — a cheap "same call
  again" comparison for retry/thrash detection without re-parsing JSON.

  Never raises: an input that somehow fails to encode (it was decoded from
  valid JSON moments earlier, so this is a backstop rather than an expected
  path) yields `nil` rather than losing the row.
  """
  @spec input_digest(map() | nil, [String.t()]) :: String.t() | nil
  def input_digest(input, redact_values \\ [])
  def input_digest(nil, _redact_values), do: nil

  def input_digest(input, redact_values) do
    input
    |> Jason.encode!()
    |> redact(redact_values)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  rescue
    _ -> nil
  end

  @doc """
  The unredacted summary field of a tool input. Public because
  `ClaudeSession` renders the same string into its `⏵ Tool(...)` transcript
  line, where the surrounding code applies redaction to the whole line.
  """
  @spec summarize_tool_input(map() | nil | term()) :: String.t()
  def summarize_tool_input(input) when is_map(input) do
    cond do
      is_binary(input["command"]) -> truncate(input["command"], @input_summary_max)
      is_binary(input["file_path"]) -> input["file_path"]
      is_binary(input["path"]) -> input["path"]
      is_binary(input["pattern"]) -> truncate(input["pattern"], @input_summary_max)
      is_binary(input["description"]) -> truncate(input["description"], @input_summary_max)
      # Skill tool: render the skill name directly rather than falling through
      # to Jason.encode!/1, whose key-sort order can push "skill" past a
      # length-based truncation cutoff when "args" is long. Also gives a more
      # readable transcript line (`⏵ Skill(tdd)` vs raw JSON).
      is_binary(input["skill"]) -> input["skill"]
      true -> truncate(Jason.encode!(input), @input_summary_max)
    end
  end

  def summarize_tool_input(_input), do: ""

  @doc "Truncate with an ellipsis marker, by graphemes."
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(str, max) when is_binary(str) do
    if String.length(str) > max, do: String.slice(str, 0, max) <> "…", else: str
  end

  defp redact(text, [_ | _] = values) when is_binary(text),
    do: Arbiter.Redaction.redact(text, values)

  defp redact(text, _values), do: text
end
