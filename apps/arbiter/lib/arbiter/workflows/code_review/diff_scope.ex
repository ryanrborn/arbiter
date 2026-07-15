defmodule Arbiter.Workflows.CodeReview.DiffScope do
  @moduledoc """
  Which `(file, new-file line)` pairs a unified diff actually touches.

  Tier 2 (bd-6onexk/#917) grants the reviewer read-only file tools at the
  PR-head checkout, so it can read whole files well outside the diff for
  context. When it (mis)reports a finding on one of those out-of-diff
  lines/files, GitHub's inline-comment API 422s — `pull_request_review_thread
  .line`/`.path` "could not be resolved" — because the (path, line) isn't
  part of any diff hunk (bd-2n3qm6). `Arbiter.Workflows.CodeReview` uses this
  module to check a finding against the diff *before* posting it inline, so
  an out-of-diff finding can be degraded to the review summary instead of
  failing the whole post.

  A `(file, line)` is "in diff" when `line` is a context or added line
  (right/new side) inside one of the file's hunks — i.e. exactly the set of
  positions GitHub itself accepts for a `side: "RIGHT"` inline comment.
  Removed-only lines, lines outside any hunk, and files the diff doesn't
  touch are never in scope.
  """

  @type t :: %{optional(String.t()) => MapSet.t(pos_integer())}

  @hunk_header ~r/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/

  @doc "Build the diff scope for a unified diff."
  @spec build(String.t()) :: t()
  def build(diff) when is_binary(diff) do
    diff
    |> String.split(~r/(?=^diff --git )/m)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn chunk, acc ->
      case file_lines(chunk) do
        {nil, _} -> acc
        {path, lines} -> Map.update(acc, path, lines, &MapSet.union(&1, lines))
      end
    end)
  end

  @doc "Is `(file, line)` part of the diff's new-file (RIGHT-side) content?"
  @spec in_diff?(t(), String.t() | nil, pos_integer() | nil) :: boolean()
  def in_diff?(scope, file, line) when is_map(scope) and is_binary(file) and is_integer(line) do
    case Map.get(scope, file) do
      nil -> false
      lines -> MapSet.member?(lines, line)
    end
  end

  def in_diff?(_scope, _file, _line), do: false

  defp file_lines(chunk) do
    path = new_file_path(chunk)

    lines =
      chunk
      |> String.split("\n")
      |> Enum.reduce({nil, MapSet.new()}, fn line, {cursor, set} ->
        cond do
          match = Regex.run(@hunk_header, line) ->
            [_, start] = match
            {String.to_integer(start), set}

          is_nil(cursor) ->
            {cursor, set}

          String.starts_with?(line, "+++") or String.starts_with?(line, "---") ->
            {cursor, set}

          String.starts_with?(line, "+") ->
            {cursor + 1, MapSet.put(set, cursor)}

          String.starts_with?(line, "-") ->
            {cursor, set}

          true ->
            {cursor + 1, MapSet.put(set, cursor)}
        end
      end)
      |> elem(1)

    {path, lines}
  end

  # `+++ b/<path>` — `/dev/null` (deleted file) yields no new-file path, so
  # the whole chunk contributes nothing to the scope.
  defp new_file_path(chunk) do
    case Regex.run(~r/^\+\+\+ b\/(.+)$/m, chunk) do
      [_, path] -> path
      _ -> nil
    end
  end
end
