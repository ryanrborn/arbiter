defmodule Arbiter.Worker.ReviewAutomation do
  @moduledoc """
  Resolves the ReviewPatrol automation mode for a given engagement.

  Mode resolution order:
    1. An explicit per-dispatch `automation` override always wins.
    2. If the PR author is in `review_automation.auto_authors`, the mode is `:auto`.
    3. Otherwise, use `review_automation.default` from the workspace config.
    4. If no config is present, fall back to `:flag` (conservative default).

  ## Workspace config shape

      "review_automation" => %{
        "default" => "flag",        # "auto" | "flag" (default: "flag")
        "auto_authors" => ["alice", "bob"]
      }
  """

  @type mode :: :auto | :flag

  @doc """
  Resolve the automation mode for a PR author given a workspace config map.

  - `ws_config` — the raw `workspace.config` map (may be `nil` or `%{}`).
  - `pr_author` — the login of the PR author (may be `nil`).

  Returns `:auto` or `:flag`.
  """
  @spec resolve(map() | nil, String.t() | nil) :: mode()
  def resolve(ws_config, pr_author) do
    block = ws_config && Map.get(ws_config, "review_automation")
    resolve_from_block(block, pr_author)
  end

  defp resolve_from_block(nil, _author), do: :flag
  defp resolve_from_block(%{} = block, author) when is_binary(author) and author != "" do
    auto_authors = Map.get(block, "auto_authors") || []
    if author in auto_authors, do: :auto, else: default_from(block)
  end

  defp resolve_from_block(%{} = block, _author), do: default_from(block)

  defp default_from(%{"default" => "auto"}), do: :auto
  defp default_from(_), do: :flag
end
