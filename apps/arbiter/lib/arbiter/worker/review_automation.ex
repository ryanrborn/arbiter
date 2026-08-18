defmodule Arbiter.Worker.ReviewAutomation do
  @moduledoc """
  Resolves the ReviewPatrol automation mode for a given engagement.

  Mode resolution order:
    1. An explicit per-dispatch `automation` override always wins.
    2. If the repo name matches an entry in `review_automation.repo_overrides`,
       that value wins regardless of PR author.
    3. If the PR author is in `review_automation.auto_authors`, the mode is `:auto`.
    4. Otherwise, use `review_automation.default` from the workspace config.
    5. If no config is present, fall back to `:flag` (conservative default).

  ## The three modes (bd-36qzgx)

    * `:auto`        — review **and post**: the reviewer posts inline comments +
      a verdict directly to the PR. Used for authors/repos the fleet is trusted
      to comment on autonomously.
    * `:report_only` — review **and report**: the reviewer runs the full review
      (reads the diff, computes findings + a recommended verdict) but posts
      NOTHING to the PR. The findings and per-finding *proposed* comment text are
      surfaced to the coordinator, who greenlights which comments actually post
      (`Arbiter.Reviews.ExternalReview.greenlight/1`). This is the required
      default for infra repos (atlas, verus-infrastructure) — human-in-the-loop
      review. Accepts the alias `"propose"`.
    * `:flag`        — a pure escalation: do NOT review, just surface new
      commits / author replies to the coordinator mailbox so a human decides
      whether to act. Accepts the alias `"notify"`. (Historically the only
      non-`:auto` mode; kept for the rare "ping me, don't review" case.)
    * `:off`         — a hard opt-out (bd-7opdaf): refuse to dispatch a
      reviewer against this repo at all — no agent spawned, nothing posted,
      not even a flag/notify. Accepts the aliases `"never"` / `"disabled"`.
      Modeled on the self-approve guard: `force: true` overrides a single
      dispatch. Stricter than `:flag`, which still tracks new commits/replies.

  ## Workspace config shape

      "review_automation" => %{
        "default" => "report_only",     # "auto" | "report_only" | "flag" (default: "flag")
        "auto_authors" => ["alice", "bob"],
        "repo_overrides" => %{
          "atlas" => "report_only",     # infra: always review-and-report, never auto-post
          "verus-infrastructure" => "report_only"
        }
      }
  """

  @type mode :: :auto | :report_only | :flag | :off

  @typedoc """
  Where a resolved mode came from, most-specific first (bd-7opdaf):
  `:explicit` (a per-dispatch `automation` arg), `:repo_override`
  (`review_automation.repo_overrides[repo_name]`), or `:default` (the
  `auto_authors`/`default` fallback).
  """
  @type source :: :explicit | :repo_override | :default

  @doc """
  Resolve the automation mode for a PR author given a workspace config map.

  - `ws_config` — the raw `workspace.config` map (may be `nil` or `%{}`).
  - `pr_author` — the login of the PR author (may be `nil`).
  - `repo_name`  — the repo name (e.g. `"atlas"`); checked against
    `review_automation.repo_overrides` before the author lookup.

  Returns `:auto`, `:report_only`, or `:flag`.
  """
  @spec resolve(map() | nil, String.t() | nil, String.t() | nil) :: mode()
  def resolve(ws_config, pr_author, repo_name \\ nil) do
    block = ws_config && Map.get(ws_config, "review_automation")
    resolve_from_block(block, pr_author, repo_name)
  end

  @doc """
  Look up ONLY the repo override for `repo_name` — the highest-precedence,
  author-independent gate — without falling through to `auto_authors`/`default`.
  Returns `nil` when no override is configured for `repo_name` (or `repo_name` is
  `nil`/blank), `ws_config` is `nil`/`%{}`, etc.

  Used by `ReviewPatrol` (bd-3cpcw2) to re-check a repo's override live on every
  tick — independent of the PR author, which isn't always known at tick time —
  so flipping a repo to `report_only`/`flag` takes effect immediately on
  already-open engagements, instead of only on new dispatches.
  """
  @spec repo_override_mode(map() | nil, String.t() | nil) :: mode() | nil
  def repo_override_mode(ws_config, repo_name) do
    block = ws_config && Map.get(ws_config, "review_automation")
    repo_override(block, repo_name)
  end

  @doc """
  Coerce a free-form mode string/atom into a valid `mode()`, or `nil` when it
  isn't one of the recognized values. Accepts the `"propose"` alias for
  `:report_only`, the `"notify"` alias for `:flag`, and the `"never"` /
  `"disabled"` aliases for `:off` (bd-7opdaf).
  """
  @spec normalize(term()) :: mode() | nil
  def normalize(m) when m in [:auto, :report_only, :flag, :off], do: m
  def normalize("auto"), do: :auto
  def normalize("report_only"), do: :report_only
  def normalize("propose"), do: :report_only
  def normalize("flag"), do: :flag
  def normalize("notify"), do: :flag
  def normalize("off"), do: :off
  def normalize("never"), do: :off
  def normalize("disabled"), do: :off
  def normalize(_), do: nil

  @doc """
  Resolve the automation mode AND where it came from (bd-7opdaf) — used to log
  the resolved mode's provenance at dispatch time, so a wrong mode is visible
  immediately instead of after reviews have posted.

  - `explicit` — a raw `automation` arg/string; normalized internally. When it
    normalizes to a valid mode, it wins outright with source `:explicit`.
  - Otherwise resolution falls through to `repo_overrides[repo_name]`
    (`:repo_override`), then `auto_authors`/`default` (`:default`) — the same
    precedence as `resolve/3`.
  """
  @spec resolve_with_source(map() | nil, String.t() | nil, String.t() | nil, term()) ::
          {mode(), source()}
  def resolve_with_source(ws_config, pr_author, repo_name, explicit \\ nil) do
    case normalize(explicit) do
      mode when not is_nil(mode) ->
        {mode, :explicit}

      nil ->
        block = ws_config && Map.get(ws_config, "review_automation")

        case repo_override(block, repo_name) do
          nil when is_map(block) -> {resolve_by_author(block, pr_author), :default}
          nil -> {:flag, :default}
          mode -> {mode, :repo_override}
        end
    end
  end

  defp resolve_from_block(nil, _author, _repo), do: :flag

  defp resolve_from_block(%{} = block, author, repo) do
    case repo_override(block, repo) do
      nil -> resolve_by_author(block, author)
      mode -> mode
    end
  end

  defp repo_override(_block, nil), do: nil
  defp repo_override(_block, ""), do: nil

  defp repo_override(%{"repo_overrides" => overrides}, repo) when is_map(overrides) do
    normalize(Map.get(overrides, repo))
  end

  defp repo_override(_block, _repo), do: nil

  defp resolve_by_author(block, author) when is_binary(author) and author != "" do
    auto_authors = Map.get(block, "auto_authors") || []
    if author in auto_authors, do: :auto, else: default_from(block)
  end

  defp resolve_by_author(block, _author), do: default_from(block)

  defp default_from(%{"default" => d}), do: normalize(d) || :flag
  defp default_from(_), do: :flag
end
