defmodule GtElixirCli.AliasResolver do
  @moduledoc """
  Resolves user-typed CLI verbs against built-in subcommands + the active
  workspace's vernacular aliases.

  Lookup order:

    1. If `verb` is in `known_verbs/0`, return it as-is. (Fast path; no HTTP.)
    2. Otherwise, fetch the workspace via `GtElixirCli.Workspace.resolve/0`
       and read `config["vernacular"]["aliases"]`. If `verb` is a key there,
       return the canonical it maps to (provided that canonical is itself a
       known verb).
    3. If neither, return `{:unknown, suggestions}` — a list of close-by
       known/alias verbs ranked by string distance.

  The "alias must resolve to a known verb" check (step 2 second condition)
  prevents a misconfigured workspace from sending users into an infinite
  loop or to a non-existent command. Misconfigured aliases surface as
  `:unknown` rather than silently dispatching to nothing.
  """

  @known_verbs ~w(show create close list update dep ready doctor where help sling)

  @doc "The set of built-in verbs that bd2 dispatches to."
  @spec known_verbs() :: [String.t()]
  def known_verbs, do: @known_verbs

  @typedoc "Result of resolution: a canonical verb or an `:unknown` with suggestions."
  @type t :: {:ok, String.t()} | {:unknown, [String.t()]}

  @spec resolve(String.t()) :: t
  def resolve(verb) when is_binary(verb) do
    cond do
      verb in @known_verbs ->
        {:ok, verb}

      true ->
        case aliases_for_active_workspace() do
          {:ok, aliases} -> resolve_via_aliases(verb, aliases)
          # Workspace lookup failed — treat as no aliases configured. Suggest
          # against built-ins only.
          {:error, _} -> {:unknown, suggest(verb, @known_verbs)}
        end
    end
  end

  defp resolve_via_aliases(verb, aliases) do
    case Map.fetch(aliases, verb) do
      {:ok, canonical} when is_binary(canonical) and canonical in @known_verbs ->
        {:ok, canonical}

      _ ->
        candidates = @known_verbs ++ Map.keys(aliases)
        {:unknown, suggest(verb, candidates)}
    end
  end

  defp aliases_for_active_workspace do
    case GtElixirCli.Workspace.resolve() do
      {:ok, ws} ->
        aliases = get_in(ws, ["config", "vernacular", "aliases"]) || %{}
        {:ok, aliases}

      err ->
        err
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
