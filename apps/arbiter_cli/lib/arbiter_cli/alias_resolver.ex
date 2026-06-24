defmodule ArbiterCli.AliasResolver do
  @moduledoc """
  Resolves the user-typed first token (a **resource** or top-level command)
  against the canonical command surface.

  The CLI uses an `arb <resource> <verb>` grammar (e.g. `arb issue list`,
  `arb worker stop`). The resources are plain base terms — `issue`,
  `worker`, `repo`. This module resolves that first token to its canonical
  form.

  Lookup:

    1. If `verb` is in `known_verbs/0`, return it as-is.
    2. Otherwise, return `{:unknown, suggestions}` — a list of close-by known
       verbs ranked by string distance.

  (Legacy flat-command redirects — e.g. `arb list` → `arb issue list` — live
  in `ArbiterCli.Main`, not here.)
  """

  # The canonical command surface: resources, plus the flat meta commands that
  # carry no resource ambiguity, plus `dispatch` (the top-level shortcut for
  # `issue dispatch`).
  @known_verbs ~w(issue worker repo dep config server workspace message usage quota install mcp dispatch prime where init help version)

  @doc "The set of canonical resources/commands that arb dispatches to."
  @spec known_verbs() :: [String.t()]
  def known_verbs, do: @known_verbs

  @typedoc "Result of resolution: a canonical verb or an `:unknown` with suggestions."
  @type t :: {:ok, String.t()} | {:unknown, [String.t()]}

  @spec resolve(String.t()) :: t
  def resolve(verb) when is_binary(verb) do
    if verb in @known_verbs do
      {:ok, verb}
    else
      {:unknown, suggest(verb, @known_verbs)}
    end
  end

  @doc """
  Return up to 3 verbs closest to `verb` (by Levenshtein distance), from the
  given `candidates`. Distances > `floor(length(verb) / 2) + 1` are excluded.
  """
  @spec suggest(String.t(), [String.t()]) :: [String.t()]
  def suggest(verb, candidates) when is_binary(verb) and is_list(candidates) do
    max_dist = max(1, div(String.length(verb), 2) + 1)

    candidates
    |> Enum.uniq()
    |> Enum.map(fn c -> {c, distance(verb, c)} end)
    |> Enum.filter(fn {_, d} -> d <= max_dist end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 0))
  end

  # Iterative Levenshtein over codepoint lists. Fine for short verb-vs-verb
  # comparisons; not optimized for long strings.
  defp distance(a, b) do
    a = String.graphemes(a)
    b = String.graphemes(b)
    do_distance(a, b)
  end

  defp do_distance(a, b) do
    {la, lb} = {length(a), length(b)}

    cond do
      la == 0 -> lb
      lb == 0 -> la
      true -> lev(a, b)
    end
  end

  defp lev(a, b) do
    row0 = Enum.to_list(0..length(b))

    a
    |> Enum.with_index(1)
    |> Enum.reduce(row0, fn {ac, i}, prev_row ->
      [first | _] = [i | []]

      b
      |> Enum.with_index(1)
      |> Enum.reduce({[first], 0}, fn {bc, j}, {acc, _} ->
        prev = Enum.at(prev_row, j - 1)
        up = Enum.at(prev_row, j)
        left = List.last(acc)

        cost = if ac == bc, do: 0, else: 1
        v = Enum.min([up + 1, left + 1, prev + cost])
        {acc ++ [v], v}
      end)
      |> elem(0)
    end)
    |> List.last()
  end
end
