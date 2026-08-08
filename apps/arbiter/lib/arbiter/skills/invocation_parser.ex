defmodule Arbiter.Skills.InvocationParser do
  @moduledoc """
  Parse worker transcripts for skill invocations and update usage counters.

  Two detectors, in priority order:

  1. **Skill tool invocations** (the primary signal). A `claude --print`
     worker invokes a skill via the Skill *tool*, not by typing `/name`.
     `Arbiter.Worker.ClaudeSession.assistant_block_lines/1` renders that
     tool_use block as `⏵ Skill(tdd)` (`summarize_tool_input/1` special-cases
     the `"skill"` input key so the name is never lost to truncation of a
     long `args` value). Older transcripts recorded before that special-case
     was added may still contain the raw `⏵ Skill({"skill":"tdd"})` JSON
     rendering (the Skill tool's input fell through to `Jason.encode!/1`),
     so both forms are matched.
  2. **Bare `/name` slash-command mentions** in prose (fallback, weaker
     signal). Anchored to line-start or backtick/paren-wrapped tokens only,
     to avoid crediting a skill for every unrelated filesystem path or URL
     segment that happens to look like kebab-case (`/tmp`, `/proc`, `/api`,
     `/tasks`, ...) — those are common enough in real transcripts that an
     unanchored match would misattribute usage to any skill whose name
     collides with one.

  Designed to run after a worker run completes (bd-61hnbb).
  """

  require Logger

  @doc """
  Parse a transcript (list of lines) for skill invocations and increment
  counters. Returns `{found, failed}` — the number of invocations matched
  against a registered skill and actually incremented, and the number of
  line-level processing failures (best-effort). Names that don't resolve to a
  registered skill (bundled skills, typos) are silently skipped and don't
  count toward either total.

  See the moduledoc for the two detectors used. Only counts each (line, name)
  pair once even if the name appears multiple times in the same line.

  Errors in updating the counter are logged but never block transcript
  processing — the parser proceeds to the next line.

  `workspace_id` is used for skill resolution: workspace-scoped skills shadow
  global skills of the same name within that workspace.
  """
  @spec parse_and_update(String.t() | nil, [String.t()]) :: {non_neg_integer(), non_neg_integer()}
  def parse_and_update(workspace_id, lines) when is_list(lines) do
    lines
    |> Enum.reduce({0, 0}, fn line, {found, failed} ->
      case update_for_line(line, workspace_id) do
        {:ok, count} -> {found + count, failed}
        {:error, _reason} -> {found, failed + 1}
      end
    end)
  end

  # Find all skill invocations in a single transcript line and update counters.
  # Returns `{:ok, count}` — the number of skills incremented for this line.
  defp update_for_line(line, workspace_id) when is_binary(line) do
    skills = extract_skill_names(line)

    try do
      Enum.reduce(skills, 0, fn skill_name, count ->
        case increment_skill_usage(skill_name, workspace_id) do
          :ok -> count + 1
          # Not a registered skill (bundled skill, typo, path collision) or a
          # real failure — neither counts as a found invocation, but neither
          # aborts processing of the remaining names on the line.
          :skipped -> count
          :error -> count
        end
      end)
      |> then(&{:ok, &1})
    rescue
      e ->
        Logger.warning(
          "Arbiter.Skills.InvocationParser: error updating invocations for line: #{inspect(e)}"
        )

        {:error, e}
    end
  end

  defp update_for_line(_, _workspace_id), do: {:ok, 0}

  @kebab_name ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  # Matches the transcript rendering of a Skill tool_use block. Current
  # rendering is the bare name, e.g. `⏵ Skill(tdd)`; older transcripts may
  # still contain the raw JSON form `⏵ Skill({"skill":"tdd"})` — see
  # moduledoc detector 1. Anchored to a line starting with the tool-call
  # marker so an unrelated `"skill":"..."` key elsewhere in a JSON blob isn't
  # picked up.
  @skill_tool_name ~r/^⏵\s*Skill\(([a-z0-9]+(?:-[a-z0-9]+)*)\)/
  @skill_tool_call ~r/^⏵\s*Skill\(/
  @skill_tool_arg ~r/"skill"\s*:\s*"([a-z0-9]+(?:-[a-z0-9]+)*)"/

  # Extract all unique skill names invoked on a line, trying the Skill
  # tool-call detector first and falling back to bare slash-command mentions.
  defp extract_skill_names(line) when is_binary(line) do
    tool_names = extract_skill_tool_names(line)
    slash_names = extract_slash_command_names(line)

    (tool_names ++ slash_names) |> Enum.uniq()
  end

  defp extract_skill_tool_names(line) do
    case Regex.run(@skill_tool_name, line, capture: :all_but_first) do
      [name] ->
        [name]

      nil ->
        if Regex.match?(@skill_tool_call, line) do
          @skill_tool_arg
          |> Regex.scan(line, capture: :all_but_first)
          |> Enum.map(&hd/1)
        else
          []
        end
    end
  end

  # Bare `/name` mentions, kept as a weaker fallback signal. Only counted
  # when the token sits at the very start of the line, or is wrapped in
  # backticks/parens — the conventional ways a slash-command is referenced in
  # prose/markdown — so an unrelated filesystem path or URL segment
  # (`/tmp`, `/proc`, `/api`, ...) mid-sentence isn't credited to a
  # same-named skill.
  defp extract_slash_command_names(line) do
    line
    |> String.split(~r/\s+/)
    |> Enum.with_index()
    |> Enum.reduce([], fn {word, index}, acc ->
      case parse_slash_command(word, index == 0) do
        nil -> acc
        name -> [name | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Parse a single word to check if it's an (optionally wrapped) `/name`
  # slash-command reference. `at_line_start?` allows an unwrapped token only
  # when it's the first word on the line (a typed command); anywhere else it
  # must be genuinely wrapped in backticks or parens to count — `.` is never
  # a leading-wrap marker (so `./deps` isn't mistaken for a wrapped `/deps`),
  # and quotes don't count as wrapping either (so a quoted string literal
  # like `"/api"` in source code isn't mistaken for a prose reference).
  @lead_wrap ~r/^[`(]+/
  @trail_wrap ~r/[`),.:;"']+$/

  defp parse_slash_command(word, at_line_start?) when is_binary(word) do
    wrapped? = Regex.match?(@lead_wrap, word)

    stripped =
      word
      |> then(&Regex.replace(@lead_wrap, &1, ""))
      |> then(&Regex.replace(@trail_wrap, &1, ""))

    with true <- at_line_start? or wrapped?,
         true <- String.starts_with?(stripped, "/"),
         name = String.slice(stripped, 1..-1//1),
         true <- Regex.match?(@kebab_name, name) do
      name
    else
      _ -> nil
    end
  end

  # Increment invoke_count for a skill by name. Logs errors but doesn't raise.
  # workspace_id is used for skill resolution: workspace-scoped skills shadow
  # global skills of the same name within that workspace.
  defp increment_skill_usage(skill_name, workspace_id) when is_binary(skill_name) do
    try do
      with {:ok, skill} <- Arbiter.Skills.resolve_skill(skill_name, workspace_id),
           {:ok, _updated} <- Arbiter.Skills.increment_usage(skill.id, :invoke_count) do
        :ok
      else
        {:error, :not_found} ->
          # Skill name not in registry — might be a bundled skill or a typo.
          # Don't log as error; this is expected for bundled skills.
          :skipped

        {:error, reason} ->
          Logger.warning(
            "Arbiter.Skills.InvocationParser: failed to increment #{inspect(skill_name)}: #{inspect(reason)}"
          )

          :error
      end
    rescue
      e ->
        Logger.warning(
          "Arbiter.Skills.InvocationParser: exception incrementing #{inspect(skill_name)}: #{inspect(e)}"
        )

        :error
    end
  end
end
