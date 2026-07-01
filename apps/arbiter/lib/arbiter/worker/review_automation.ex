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

  ## Workspace config shape

      "review_automation" => %{
        "default" => "flag",        # "auto" | "flag" (default: "flag")
        "auto_authors" => ["alice", "bob"],
        "repo_overrides" => %{
          "atlas" => "flag"         # hard-flag atlas regardless of author
        }
      }
  """

  @type mode :: :auto | :flag

  @doc """
  Resolve the automation mode for a PR author given a workspace config map.

  - `ws_config` — the raw `workspace.config` map (may be `nil` or `%{}`).
  - `pr_author` — the login of the PR author (may be `nil`).
  - `rig_name`  — the rig/repo name (e.g. `"atlas"`); checked against
    `review_automation.repo_overrides` before the author lookup.

  Returns `:auto` or `:flag`.
  """
  @spec resolve(map() | nil, String.t() | nil, String.t() | nil) :: mode()
  def resolve(ws_config, pr_author, rig_name \\ nil) do
    block = ws_config && Map.get(ws_config, "review_automation")
    resolve_from_block(block, pr_author, rig_name)
  end

  defp resolve_from_block(nil, _author, _rig), do: :flag

  defp resolve_from_block(%{} = block, author, rig) do
    case repo_override(block, rig) do
      :auto -> :auto
      :flag -> :flag
      nil -> resolve_by_author(block, author)
    end
  end

  defp repo_override(_block, nil), do: nil
  defp repo_override(_block, ""), do: nil

  defp repo_override(%{"repo_overrides" => overrides}, rig) when is_map(overrides) do
    case Map.get(overrides, rig) do
      "auto" -> :auto
      "flag" -> :flag
      _ -> nil
    end
  end

  defp repo_override(_block, _rig), do: nil

  defp resolve_by_author(block, author) when is_binary(author) and author != "" do
    auto_authors = Map.get(block, "auto_authors") || []
    if author in auto_authors, do: :auto, else: default_from(block)
  end

  defp resolve_by_author(block, _author), do: default_from(block)

  defp default_from(%{"default" => "auto"}), do: :auto
  defp default_from(_), do: :flag
end
