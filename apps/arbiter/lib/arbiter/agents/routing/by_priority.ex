defmodule Arbiter.Agents.Routing.ByPriority do
  @moduledoc """
  Routing policy: pick an agent config based on the bead's priority.

  Reads `workspace.config["routing"]["rules"]` — a map from priority key
  (`"P0".."P4"`) to a partial agent-config map. The matched rule is
  merged on top of `config["agent"]["config"]` so a rule only needs to
  override the keys it cares about (typically `"model"`).

  ## Example workspace config

      %{
        "agent" => %{
          "type" => "claude",
          "config" => %{"model" => "sonnet"}
        },
        "routing" => %{
          "policy" => "by_priority",
          "rules" => %{
            "P0" => %{"model" => "opus"},
            "P1" => %{"model" => "opus"},
            "P4" => %{"model" => "haiku"}
          }
        }
      }

  A bead with `priority: 0` (P0) routes to Opus; a bead with `priority: 2`
  (P2) has no rule and falls back to the default `"sonnet"`.

  Priority semantics match `Arbiter.Beads.Issue.priority` — an integer
  `0..4` where `0` is highest (P0) and `4` is lowest (P4).
  """

  @behaviour Arbiter.Agents.Routing.Policy

  alias Arbiter.Agents.Routing
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace

  @impl true
  def choose(%Issue{} = bead, workspace, _ledger_snapshot) do
    default = Routing.default_choice(workspace)

    case rule_for(workspace, bead.priority) do
      nil -> default
      rule -> %{default | config: Map.merge(default.config, rule)}
    end
  end

  defp rule_for(nil, _priority), do: nil

  defp rule_for(%Workspace{config: config}, priority) when is_integer(priority) do
    case get_in(config || %{}, ["routing", "rules", priority_key(priority)]) do
      rule when is_map(rule) -> rule
      _ -> nil
    end
  end

  defp rule_for(_workspace, _priority), do: nil

  defp priority_key(p) when p in 0..4, do: "P#{p}"
  defp priority_key(_), do: nil
end
