defmodule Arbiter.Worker.ReviewScope do
  @moduledoc """
  Resolves the review depth (`:diff` vs `:repo`) for an external PR review
  (bd-5xsp25).

  Mode resolution order:
    1. An explicit per-dispatch `scope` override always wins.
    2. If any changed file matches a configured `review_scope.sensitive_globs`
       pattern, the review is auto-escalated to `:repo` — cross-cutting or
       security-sensitive PRs get the deeper pass without per-dispatch opt-in.
    3. Otherwise, `review_scope.default` from the workspace config.
    4. If no config is present, fall back to `:diff` (today's behavior, no
       filesystem access, cheapest — the conservative default for cost).

  ## The two scopes

    * `:diff` — the reviewer only sees the unified diff text (default, no
      change from pre-bd-5xsp25 behavior).
    * `:repo` — the reviewer additionally gets a deterministic cross-file
      consumer trace computed against a local repo checkout (see
      `Arbiter.Workflows.CodeReview.ConsumerTrace`), so it can flag a
      downstream call site a diff-only review would never see.

  ## Workspace config shape

      "review_scope" => %{
        "default" => "diff",              # "diff" | "repo" (default: "diff")
        "sensitive_globs" => [
          "**/sigv4/**",
          "**/*auth*",
          "kickstart*.json",
          "**/tasks/*.ex"
        ]
      }
  """

  @type scope :: :diff | :repo

  @doc """
  Coerce a free-form scope string/atom into a valid `scope()`, or `nil` when
  it isn't one of the recognized values.
  """
  @spec normalize(term()) :: scope() | nil
  def normalize(s) when s in [:diff, :repo], do: s
  def normalize("diff"), do: :diff
  def normalize("repo"), do: :repo
  def normalize(_), do: nil

  @doc """
  Resolve the effective scope for a review.

  - `ws_config` — the raw `workspace.config` map (may be `nil` or `%{}`).
  - `explicit` — a per-dispatch override (string or atom); wins outright.
  - `changed_files` — paths touched by the diff, checked against
    `review_scope.sensitive_globs` for auto-escalation.
  """
  @spec resolve(map() | nil, term(), [String.t()]) :: scope()
  def resolve(ws_config, explicit, changed_files \\ []) do
    case normalize(explicit) do
      nil -> resolve_from_config(ws_config, changed_files)
      scope -> scope
    end
  end

  defp resolve_from_config(ws_config, changed_files) do
    block = ws_config && Map.get(ws_config, "review_scope")

    if sensitive_match?(block, changed_files) do
      :repo
    else
      default_from(block)
    end
  end

  defp sensitive_match?(%{"sensitive_globs" => globs}, changed_files)
       when is_list(globs) and is_list(changed_files) do
    Enum.any?(changed_files, fn file -> Enum.any?(globs, &glob_match?(&1, file)) end)
  end

  defp sensitive_match?(_block, _changed_files), do: false

  defp default_from(%{"default" => d}), do: normalize(d) || :diff
  defp default_from(_), do: :diff

  @doc """
  Match a file path against a glob pattern. Any run of one-or-more `*`
  characters (so both `*` and `**`) is treated as a single greedy wildcard.
  """
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(glob, path) when is_binary(glob) and is_binary(path) do
    Regex.match?(glob_to_regex(glob), path)
  end

  # Deliberately more permissive than gitignore-style globbing (where a lone
  # `*` stops at `/`) because this list only ever *escalates* cost (diff ->
  # repo scope) — a false-positive match just means a cheap review became a
  # slightly more expensive one, so a broad "does this PR touch anything
  # auth-related" match beats missing one on a strict segment-boundary
  # technicality.
  #
  # Compiled with Regex.compile!/1 (not the ~r// sigil) since Regex.escape/1
  # leaves "/" untouched and a literal "/" would prematurely close a
  # `~r/.../` sigil.
  defp glob_to_regex(glob) do
    pattern =
      glob
      |> String.split(~r/\*+/)
      |> Enum.map(&Regex.escape/1)
      |> Enum.join(".*")

    Regex.compile!("^" <> pattern <> "$")
  end
end
