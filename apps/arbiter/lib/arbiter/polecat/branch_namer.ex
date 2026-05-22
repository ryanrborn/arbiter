defmodule Arbiter.Polecat.BranchNamer do
  @moduledoc """
  Derive a git branch name from a `Arbiter.Beads.Issue` following the Verus
  naming convention:

      feature/VR-17585-add-monitor-controller-tests
      bugfix/VR-17612-fix-token-refresh-race
      epic/VR-17000-migrate-to-elixir
      chore/gte-010-branch-namer

  ## Mapping

  Issue `issue_type` → branch prefix:

      :bug                 -> "bugfix"
      :feature, :task      -> "feature"
      :epic                -> "epic"
      :chore, :decision    -> "chore"

  The ref segment uses `issue.tracker_ref` when non-empty (e.g. `"VR-17585"`),
  otherwise falls back to `issue.id` (e.g. `"gte-010"`). This makes `derive/1`
  total: every well-formed Issue yields a branch name.

  The slug is derived from `issue.title`:

    * lowercased
    * non-alphanumeric replaced with whitespace (strips punctuation and most
      non-ASCII, including emoji)
    * stopwords (articles + a small set of common particles) dropped
    * collapsed whitespace, first 6 remaining words joined with `-`
    * empty after stopword filtering → `"untitled"`
    * total branch name truncated to 60 chars max (slug-side only — the prefix
      and ref are never sacrificed)

  Per-workspace overrides of the prefix mapping and stopword list are a future
  hook (gte-P2 Vernacular). For now the mapping is hard-coded.
  """

  alias Arbiter.Beads.Issue

  @stopwords ~w(a an the of to for and or in on with)

  @max_branch_length 60

  @doc """
  Returns the branch name for an Issue. Raises `ArgumentError` if the issue
  has an unrecognised `issue_type` or a missing/blank `title` and `id`.
  """
  @spec derive(Issue.t()) :: String.t()
  def derive(%Issue{} = issue) do
    prefix = prefix_for(issue.issue_type)
    ref = ref_for(issue)
    slug = slug_from_title(issue.title)

    base = "#{prefix}/#{ref}"
    truncate_slug(base, slug)
  end

  def derive(other) do
    raise ArgumentError,
          "BranchNamer.derive/1 expected %Arbiter.Beads.Issue{}, got: #{inspect(other)}"
  end

  # ---- prefix ----

  defp prefix_for(:bug), do: "bugfix"
  defp prefix_for(:feature), do: "feature"
  defp prefix_for(:task), do: "feature"
  defp prefix_for(:epic), do: "epic"
  defp prefix_for(:chore), do: "chore"
  defp prefix_for(:decision), do: "chore"

  defp prefix_for(other) do
    raise ArgumentError,
          "BranchNamer.derive/1: unknown issue_type #{inspect(other)}"
  end

  # ---- ref ----

  defp ref_for(%Issue{tracker_ref: ref}) when is_binary(ref) and ref != "", do: ref

  defp ref_for(%Issue{id: id}) when is_binary(id) and id != "", do: id

  defp ref_for(_issue) do
    raise ArgumentError,
          "BranchNamer.derive/1: issue has neither tracker_ref nor id"
  end

  # ---- slug ----

  defp slug_from_title(nil), do: "untitled"

  defp slug_from_title(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.reject(&(&1 in @stopwords))
    |> Enum.take(6)
    |> case do
      [] -> "untitled"
      words -> Enum.join(words, "-")
    end
  end

  # ---- truncation ----

  defp truncate_slug(base, slug) do
    full = "#{base}-#{slug}"

    if String.length(full) <= @max_branch_length do
      full
    else
      # Reserve room for `base` + "-"; truncate the slug to fit.
      reserved = String.length(base) + 1
      available = max(@max_branch_length - reserved, 1)
      truncated = slug |> String.slice(0, available) |> String.trim_trailing("-")
      "#{base}-#{truncated}"
    end
  end
end
