defmodule Arbiter.Worker.ReviewAutomation do
  @moduledoc """
  Resolves the ReviewPatrol automation mode for a given engagement.

  Mode resolution order:
    1. An explicit per-dispatch `automation` override always wins.
    2. If the rig name matches an entry in `review_automation.repo_overrides`,
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

  @type mode :: :auto | :report_only | :flag

  @doc """
  Resolve the automation mode for a PR author given a workspace config map.

  - `ws_config` — the raw `workspace.config` map (may be `nil` or `%{}`).
  - `pr_author` — the login of the PR author (may be `nil`).
  - `rig_name`  — the rig/repo name (e.g. `"atlas"`); checked against
    `review_automation.repo_overrides` before the author lookup.

  Returns `:auto`, `:report_only`, or `:flag`.
  """
  @spec resolve(map() | nil, String.t() | nil, String.t() | nil) :: mode()
  def resolve(ws_config, pr_author, rig_name \\ nil) do
    block = ws_config && Map.get(ws_config, "review_automation")
    resolve_from_block(block, pr_author, rig_name)
  end

  @doc """
  Coerce a free-form mode string/atom into a valid `mode()`, or `nil` when it
  isn't one of the recognized values. Accepts the `"propose"` alias for
  `:report_only` and the `"notify"` alias for `:flag`.
  """
  @spec normalize(term()) :: mode() | nil
  def normalize(m) when m in [:auto, :report_only, :flag], do: m
  def normalize("auto"), do: :auto
  def normalize("report_only"), do: :report_only
  def normalize("propose"), do: :report_only
  def normalize("flag"), do: :flag
  def normalize("notify"), do: :flag
  def normalize(_), do: nil

  defp resolve_from_block(nil, _author, _rig), do: :flag

  defp resolve_from_block(%{} = block, author, rig) do
    case repo_override(block, rig) do
      nil -> resolve_by_author(block, author)
      mode -> mode
    end
  end

  defp repo_override(_block, nil), do: nil
  defp repo_override(_block, ""), do: nil

  defp repo_override(%{"repo_overrides" => overrides}, rig) when is_map(overrides) do
    normalize(Map.get(overrides, rig))
  end

  defp repo_override(_block, _rig), do: nil

  defp resolve_by_author(block, author) when is_binary(author) and author != "" do
    auto_authors = Map.get(block, "auto_authors") || []
    if author in auto_authors, do: :auto, else: default_from(block)
  end

  defp resolve_by_author(block, _author), do: default_from(block)

  defp default_from(%{"default" => d}), do: normalize(d) || :flag
  defp default_from(_), do: :flag
end
