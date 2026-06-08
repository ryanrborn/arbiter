defmodule ArbiterCli.AliasResolver do
  @moduledoc """
  Resolves the user-typed first token (a **resource** or top-level command)
  against the canonical command surface + the active workspace's vernacular
  aliases.

  The CLI uses an `arb <resource> <verb>` grammar (e.g. `arb issue list`,
  `arb worker stop`). The resources are neutral base terms — `issue`,
  `worker`, `batch`, `repo` — and themed vocabularies (the Sith "polecat",
  "bead", "convoy", "warship", "sling", …) are layered on top as *aliases*.
  This module resolves that first token to its canonical form.

  Lookup order:

    1. If `verb` is in `known_verbs/0`, return it as-is. (Fast path; no HTTP.)
    2. Otherwise, build a case-insensitive alias map (see `verb_aliases/0`)
       from the built-in default vernacular merged with the active
       workspace's vernacular, and look the token up. If it matches an alias,
       return the canonical it maps to (provided that canonical is itself a
       known verb).
    3. If neither, return `{:unknown, suggestions}` — a list of close-by
       known/alias verbs ranked by string distance.

  ## Alias sources

  The alias map is built from three layers, all matched case-insensitively
  against the typed token, later layers winning on conflict:

    * **Default vernacular** — the built-in `@default_vernacular` map below,
      which gives every install the Sith resource names (`polecat`, `bead`,
      `convoy`, `warship`, `sling`) out of the box even when the server is
      unreachable. Derived the same way as label aliases.
    * **Derived label aliases** — any vernacular entry from the server whose
      KEY is itself a known resource/verb is treated as a command alias from
      its label. So `vernacular["worker"] == "polecat"` makes `arb polecat`
      an alias for `arb worker`, and `vernacular["dispatch"] == "sling"`
      makes `arb sling` an alias for `arb dispatch`. This is what lets the
      command surface honor the vernacular without a hardcoded branch.
    * **Explicit aliases** — `vernacular["aliases"]`, an
      `alias_term => canonical_verb` map. Highest precedence.

  The "alias must resolve to a known verb" check (step 2) prevents a
  misconfigured workspace from sending users to a non-existent command.
  Misconfigured aliases surface as `:unknown` rather than silently
  dispatching to nothing.
  """

  # The canonical command surface: resources, plus the flat meta commands that
  # carry no resource ambiguity, plus `dispatch` (the top-level shortcut for
  # `issue dispatch`, which the Sith label "sling" aliases to).
  @known_verbs ~w(issue worker batch repo dep config server workspace message usage install dispatch prime where init help version)

  # Built-in default vernacular: the Sith resource names every install starts
  # with. Keys are canonical resources/verbs; values are their themed labels.
  # Derived into aliases so `arb polecat`/`arb bead`/`arb convoy`/`arb warship`/
  # `arb sling` resolve even offline. A live workspace vernacular overrides these.
  @default_vernacular %{
    "worker" => "polecat",
    "issue" => "bead",
    "batch" => "convoy",
    "repo" => "warship",
    "dispatch" => "sling"
  }

  @doc "The set of canonical resources/commands that arb dispatches to."
  @spec known_verbs() :: [String.t()]
  def known_verbs, do: @known_verbs

  @doc "The built-in default vernacular (canonical => themed label)."
  @spec default_vernacular() :: %{String.t() => String.t()}
  def default_vernacular, do: @default_vernacular

  @doc "The alias map (themed label => canonical) derived from the built-in defaults alone."
  @spec default_aliases() :: %{String.t() => String.t()}
  def default_aliases, do: alias_map(@default_vernacular)

  @typedoc "Result of resolution: a canonical verb or an `:unknown` with suggestions."
  @type t :: {:ok, String.t()} | {:unknown, [String.t()]}

  @spec resolve(String.t()) :: t
  def resolve(verb) when is_binary(verb) do
    if verb in @known_verbs do
      {:ok, verb}
    else
      resolve_via_aliases(verb, verb_aliases())
    end
  end

  @doc """
  The active command-verb aliases: a case-insensitive map of
  `alias_term => canonical_verb` (keys lowercased). Combines the built-in
  default vernacular, aliases derived from the server's vernacular labels
  whose key is itself a known verb (e.g. `worker => "polecat"` yields
  `"polecat" => "worker"`), and explicit `vernacular["aliases"]` config.
  Falls back to the default-derived aliases alone when the workspace can't be
  reached, so themed resource names keep resolving offline.
  """
  @spec verb_aliases() :: %{String.t() => String.t()}
  def verb_aliases do
    base = alias_map(@default_vernacular)

    case vernacular_for_active_workspace() do
      {:ok, vernacular} -> Map.merge(base, alias_map(vernacular))
      {:error, _} -> base
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

  # Build the combined alias map from a vernacular map. Derived label aliases
  # come first so explicit `aliases` config wins on conflict.
  defp alias_map(vernacular) when is_map(vernacular) do
    derived_label_aliases(vernacular)
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
