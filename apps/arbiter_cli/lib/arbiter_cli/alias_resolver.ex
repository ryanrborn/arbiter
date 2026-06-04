defmodule ArbiterCli.AliasResolver do
  @moduledoc """
  Resolves user-typed CLI verbs against built-in subcommands + the active
  workspace's vernacular aliases.

  Lookup order:

    1. If `verb` is in `known_verbs/0`, return it as-is. (Fast path; no HTTP.)
    2. Otherwise, fetch the active workspace's vernacular and build a
       case-insensitive alias map (see `verb_aliases/0`). If `verb` matches
       an alias, return the canonical it maps to (provided that canonical is
       itself a known verb).
    3. If neither, return `{:unknown, suggestions}` — a list of close-by
       known/alias verbs ranked by string distance.

  ## Alias sources

  The alias map is built from two parts of the workspace vernacular, both
  matched case-insensitively against the typed verb:

    * **Explicit aliases** — `vernacular["aliases"]`, an
      `alias_term => canonical_verb` map.
    * **Derived label aliases** — any vernacular entry whose KEY is itself a
      known verb is treated as a command alias from its label. So
      `vernacular["sling"] == "Dispatch"` makes `arb dispatch` an alias for
      `arb sling`. This is what lets the command verb honor the vernacular
      without a second hardcoded branch.

  Explicit aliases win over derived ones on conflict.

  The "alias must resolve to a known verb" check (step 2) prevents a
  misconfigured workspace from sending users to a non-existent command.
  Misconfigured aliases surface as `:unknown` rather than silently
  dispatching to nothing.
  """

  @known_verbs ~w(init show create close reopen list update dep ready doctor start restart install-service where help sling review prime polecat inbox notify message msg claim sync usage convoy config)

  # Noun-vernacular keys that also name a command verb. Lets a renamed noun
  # double as a verb alias — e.g. when `vernacular["batch"] == "Vanguard"`,
  # `arb vanguard` resolves to `arb convoy`. Keyed: noun key => canonical verb.
  @noun_verb_aliases %{"batch" => "convoy"}

  @doc "The set of built-in verbs that arb dispatches to."
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
        case vernacular_for_active_workspace() do
          {:ok, vernacular} -> resolve_via_aliases(verb, alias_map(vernacular))
          # Workspace lookup failed — treat as no aliases configured. Suggest
          # against built-ins only.
          {:error, _} -> {:unknown, suggest(verb, @known_verbs)}
        end
    end
  end

  @doc """
  The active workspace's command-verb aliases: a case-insensitive map of
  `alias_term => canonical_verb` (keys lowercased). Combines explicit
  `vernacular["aliases"]` config with aliases derived from vernacular labels
  whose key is itself a known verb (e.g. `sling => "Dispatch"` yields
  `"dispatch" => "sling"`). Returns `%{}` when the workspace can't be reached.
  """
  @spec verb_aliases() :: %{String.t() => String.t()}
  def verb_aliases do
    case vernacular_for_active_workspace() do
      {:ok, vernacular} -> alias_map(vernacular)
      {:error, _} -> %{}
    end
  end

  defp resolve_via_aliases(verb, aliases) do
    case Map.fetch(aliases, String.downcase(verb)) do
      {:ok, canonical} when is_binary(canonical) and canonical in @known_verbs ->
        {:ok, canonical}

      _ ->
        candidates = @known_verbs ++ Map.keys(aliases)
        {:unknown, suggest(verb, candidates)}
    end
  end

  # Build the combined alias map from a workspace's vernacular. Derived aliases
  # come first so explicit `aliases` config wins on conflict.
  defp alias_map(vernacular) when is_map(vernacular) do
    derived_label_aliases(vernacular)
    |> Map.merge(derived_noun_aliases(vernacular))
    |> Map.merge(explicit_aliases(vernacular))
  end

  defp alias_map(_), do: %{}

  defp explicit_aliases(vernacular) do
    case Map.get(vernacular, "aliases") do
      m when is_map(m) ->
        for {alias, canonical} <- m, is_binary(alias), is_binary(canonical), into: %{} do
          {String.downcase(alias), canonical}
        end

      _ ->
        %{}
    end
  end

  # Any vernacular entry whose key is a known verb becomes an alias from its
  # label, unless the label is just the verb itself (the default, no aliasing).
  defp derived_label_aliases(vernacular) do
    for {key, label} <- vernacular,
        key in @known_verbs,
        is_binary(label),
        String.downcase(label) != key,
        into: %{} do
      {String.downcase(label), key}
    end
  end

  # A renamed noun (e.g. "batch" -> "Vanguard") aliases the verb that operates
  # on it (`convoy`). See `@noun_verb_aliases`.
  defp derived_noun_aliases(vernacular) do
    for {noun_key, verb} <- @noun_verb_aliases,
        label = Map.get(vernacular, noun_key),
        is_binary(label),
        String.downcase(label) != verb,
        into: %{} do
      {String.downcase(label), verb}
    end
  end

  defp vernacular_for_active_workspace do
    case ArbiterCli.Client.get("/api/settings") do
      {:ok, %{"data" => %{"vernacular" => vernacular}}} when is_map(vernacular) ->
        {:ok, vernacular}

      {:ok, _} ->
        {:ok, %{}}

      {:error, %ArbiterCli.Client.Error{} = err} ->
        {:error, err.message}
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
