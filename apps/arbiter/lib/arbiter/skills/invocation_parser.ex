defmodule Arbiter.Skills.InvocationParser do
  @moduledoc """
  Parse worker transcripts for skill invocations and update usage counters.

  Detects `/<skill-name>` slash invocations in transcript lines and increments
  the corresponding skill's invoke_count. Designed to run after a worker run
  completes (bd-61hnbb).
  """

  require Logger

  @doc """
  Parse a transcript (list of lines) for skill invocations and increment
  counters. Returns `{count, failed}` — the number of invocations found
  and incremented, and the number of failures (best-effort).

  Invocations are detected as `/name` patterns at the start of a line or
  after certain punctuation (space, newline, etc). Only counts each (line, name)
  pair once even if the name appears multiple times in the same line.

  Errors in updating the counter are logged but never block transcript
  processing — the parser proceeds to the next line.
  """
  @spec parse_and_update(String.t() | nil, [String.t()]) :: {non_neg_integer(), non_neg_integer()}
  def parse_and_update(_run_id, lines) when is_list(lines) do
    lines
    |> Enum.reduce({0, 0}, fn line, {found, failed} ->
      case update_for_line(line) do
        {:ok, count} -> {found + count, failed}
        {:error, _reason} -> {found, failed + 1}
      end
    end)
  end

  # Find all skill invocations in a single transcript line and update counters.
  # Returns `{:ok, count}` — the number of skills incremented for this line.
  defp update_for_line(line) when is_binary(line) do
    skills = extract_skill_names(line)

    try do
      Enum.reduce(skills, 0, fn skill_name, count ->
        case increment_skill_usage(skill_name) do
          :ok -> count + 1
          # Log the error, but keep counting succeeding invocations
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

  defp update_for_line(_), do: {:ok, 0}

  # Extract all unique skill names from a line (slash-command invocations).
  # Pattern: `/name` where name is kebab-case (lowercase letters/digits/hyphens).
  # Matches: `/tdd` `/ tdd` `/` boundary, but NOT `/tdd-` (trailing dash invalid).
  defp extract_skill_names(line) when is_binary(line) do
    line
    |> String.split(~r/\s+/)
    |> Enum.reduce([], fn word, acc ->
      case parse_slash_command(word) do
        nil -> acc
        name -> [name | acc]
      end
    end)
    |> Enum.uniq()
    |> Enum.reverse()
  end

  # Parse a single word to check if it starts with / and contains a valid skill name.
  defp parse_slash_command(word) when is_binary(word) do
    case String.starts_with?(word, "/") do
      true ->
        name = String.slice(word, 1..-1//1)

        # Validate kebab-case: ^[a-z0-9]+(-[a-z0-9]+)*$
        case Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, name) do
          true -> name
          false -> nil
        end

      false ->
        nil
    end
  end

  # Increment invoke_count for a skill by name. Logs errors but doesn't raise.
  defp increment_skill_usage(skill_name) when is_binary(skill_name) do
    try do
      with {:ok, skill} <- Arbiter.Skills.get_skill_by_name(skill_name),
           {:ok, _updated} <- Arbiter.Skills.increment_usage(skill.id, :invoke_count) do
        :ok
      else
        {:error, :not_found} ->
          # Skill name not in registry — might be a bundled skill or a typo.
          # Don't log as error; this is expected for bundled skills.
          :ok

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
