defmodule Arbiter.Board.FileScope do
  @moduledoc """
  The set of repo paths a piece of work touches, and whether two such sets
  collide.

  The board's scheduler refuses to promote a Ready issue whose files intersect
  an in-flight worker's (bd-bqyeqa) — two agents editing the same file produce
  a merge conflict nobody asked for, and the cheapest place to prevent it is
  before dispatch.

  Arbiter has no `files` column on `Arbiter.Tasks.Issue`, so a Ready issue's
  scope is *declared*: the repo-relative paths its own text names. Tickets in
  this workspace are written that way already — "Replaces
  `lib/arbiter_web/live/dashboard_live.ex` entirely" — so the text is the best
  signal available pre-dispatch, and it costs nothing to read. A running
  worker's scope is the union of its issue's declared paths and the files its
  worktree has actually changed (supplied by the caller; see
  `Arbiter.Board.Snapshot`).

  This is deliberately a *heuristic*, and it is tuned to be quiet rather than
  exhaustive: a path is only recognised when it carries a directory separator
  and either an extension or a trailing slash, so prose ("3.5x faster",
  "version 1.2.3") never manufactures a phantom block. A missed path costs a
  conflict the operator would have had anyway; a false one silently stalls the
  queue, which is worse.
  """

  @typedoc "A set of repo-relative paths; a trailing `/` marks a directory scope."
  @type scope :: MapSet.t(String.t())

  # A path token: at least one `/`, ASCII path characters only, and it ends in
  # either `/` (a directory scope) or a filename carrying a short extension.
  # The lookbehind/lookahead pin the token to non-path characters, so
  # `` `lib/a.ex` `` and `(lib/a.ex)` both yield `lib/a.ex` while `and/or` and
  # the host part of `https://example.com/x` yield nothing.
  @path_re ~r"(?<![\w./-])(?:\./)?((?:[\w.-]+/)+(?:[\w.-]*\.[a-zA-Z0-9]{1,6})?)(?![\w.-])"

  @text_fields [:title, :description, :acceptance, :notes]

  @doc """
  The paths an issue's own text names.

  Reads `:title`, `:description`, `:acceptance` and `:notes` — whichever are
  present and non-nil. Accepts a plain map so callers can build one without an
  `Arbiter.Tasks.Issue` struct.
  """
  @spec declared_paths(map()) :: scope()
  def declared_paths(issue) when is_map(issue) do
    @text_fields
    |> Enum.map(&Map.get(issue, &1))
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&paths_in/1)
    |> MapSet.new()
  end

  def declared_paths(_), do: MapSet.new()

  @doc """
  Every path in `left` that also falls inside `right`, sorted and unique.

  A directory scope (`"lib/board/"`) contains any path beneath it, and the
  overlap is reported as the *file*, not the directory, so a caller can name
  the colliding file in a blocked reason. Prefix matching lands on segment
  boundaries only — `lib/board/` does not contain `lib/boardroom/x.ex`.
  """
  @spec overlap(scope(), scope()) :: [String.t()]
  def overlap(left, right) do
    left_files = files(left)
    right_files = files(right)
    left_dirs = dirs(left)
    right_dirs = dirs(right)

    shared = MapSet.intersection(left_files, right_files)

    from_left_dirs = Enum.filter(right_files, fn f -> under_any?(f, left_dirs) end)
    from_right_dirs = Enum.filter(left_files, fn f -> under_any?(f, right_dirs) end)

    shared
    |> Enum.concat(from_left_dirs)
    |> Enum.concat(from_right_dirs)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Whether `overlap/2` would return anything."
  @spec overlap?(scope(), scope()) :: boolean()
  def overlap?(left, right), do: overlap(left, right) != []

  defp paths_in(text) do
    @path_re
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [p] -> p end)
    |> Enum.reject(&(&1 == "" or &1 == "/"))
  end

  defp files(scope), do: scope |> Enum.reject(&String.ends_with?(&1, "/")) |> MapSet.new()
  defp dirs(scope), do: scope |> Enum.filter(&String.ends_with?(&1, "/")) |> MapSet.new()

  defp under_any?(file, dirs), do: Enum.any?(dirs, &String.starts_with?(file, &1))
end
