defmodule Arbiter.Workflows.CodeReview.ConsumerTrace do
  @moduledoc """
  Deterministic, read-only cross-file consumer lookup for repo-scoped reviews.

  Diff-only review sees a changed function's new body but has no way to know
  who else in the repo calls it. This module fills that gap without giving
  the reviewer LLM any filesystem/tool access of its own (the repo checkout
  a review runs against is often the same shared rig checkout other workers
  are using, so mutation — even a branch switch — is not an option):

    1. Pull the identifiers touched by removed/changed lines out of the diff.
    2. `git grep` the repo checkout for each identifier, read-only (no
       checkout/branch/commit — just `git grep` against the working tree as
       it stands).
    3. Drop any hit inside a file the diff itself already touches, since
       those are already visible to the reviewer.

  The result is a list of consumer references that `Checks.build_prompt/2`
  folds into the reviewer prompt, so a repo-scoped review can flag a
  downstream call site a diff-only review would never see.
  """

  @type ref :: %{identifier: String.t(), file: String.t(), line: pos_integer(), snippet: String.t()}

  @def_re ~r/\bdef\s+([a-zA-Z_][a-zA-Z0-9_?!]*)/

  @doc """
  Trace consumers of identifiers changed by `diff` across `repo_path`,
  excluding matches inside files the diff already touches.
  """
  @spec trace(String.t(), String.t()) :: [ref()]
  def trace(diff, repo_path) when is_binary(diff) and is_binary(repo_path) do
    changed = changed_files(diff)

    diff
    |> changed_identifiers()
    |> Enum.flat_map(&grep_consumers(&1, repo_path, changed))
    |> Enum.uniq()
  end

  @doc "Paths touched by a unified diff, per its `+++ b/<path>` headers."
  @spec changed_files(String.t()) :: MapSet.t(String.t())
  def changed_files(diff) do
    ~r/^\+\+\+ b\/(.+)$/m
    |> Regex.scan(diff)
    |> Enum.map(fn [_, file] -> file end)
    |> MapSet.new()
  end

  defp changed_identifiers(diff) do
    diff
    |> String.split("\n")
    |> Enum.filter(&removed_or_added_line?/1)
    |> Enum.flat_map(fn line -> Regex.scan(@def_re, line) |> Enum.map(fn [_, id] -> id end) end)
    |> Enum.uniq()
  end

  defp removed_or_added_line?("---" <> _), do: false
  defp removed_or_added_line?("+++" <> _), do: false
  defp removed_or_added_line?("-" <> _), do: true
  defp removed_or_added_line?("+" <> _), do: true
  defp removed_or_added_line?(_), do: false

  defp grep_consumers(identifier, repo_path, changed_files) do
    case System.cmd("git", ["-C", repo_path, "grep", "-n", "-F", "-w", identifier],
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse_grep(output, identifier, changed_files)
      {_output, _nonzero} -> []
    end
  end

  defp parse_grep(output, identifier, changed_files) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_grep_line(&1, identifier, changed_files))
  end

  defp parse_grep_line(line, identifier, changed_files) do
    case String.split(line, ":", parts: 3) do
      [file, lineno, snippet] ->
        if MapSet.member?(changed_files, file) do
          []
        else
          [%{identifier: identifier, file: file, line: String.to_integer(lineno), snippet: String.trim(snippet)}]
        end

      _ ->
        []
    end
  end
end
