defmodule Arbiter.Agents.Routing.ByBudget do
  @moduledoc """
  Routing policy: `:by_priority`, but with a daily-USD ceiling. When the
  ledger snapshot says today's spend has crossed
  `workspace.config["routing"]["budget_usd_per_day"]`, degrade the chosen
  model one tier (`"opus" → "sonnet" → "haiku"`).

  The ledger snapshot is supplied by the caller as a map; this policy
  reads `:cost_usd_today` (a float). When the snapshot has no usage data
  (the default `%{}`), the policy behaves exactly like `:by_priority` —
  so a workspace can opt into the policy before the ledger has data to
  drive it without the policy doing anything surprising.

  Stage-D-ready (`docs/agent-harness-design.md` §4.4): the policy ships
  here so the seam is present, but it's only *useful* once the ledger
  is queried into a snapshot on every dispatch — that integration is
  intentionally out of scope for this bead.
  """

  @behaviour Arbiter.Agents.Routing.Policy

  alias Arbiter.Agents.Routing.ByPriority
  alias Arbiter.Beads.Workspace

  @tier_degrade %{
    "opus" => "sonnet",
    "sonnet" => "haiku",
    "haiku" => "haiku"
  }

  @impl true
  def choose(bead, workspace, ledger_snapshot) do
    base = ByPriority.choose(bead, workspace, ledger_snapshot)

    case over_budget?(workspace, ledger_snapshot) do
      false -> base
      true -> degrade(base)
    end
  end

  defp over_budget?(nil, _snapshot), do: false

  defp over_budget?(%Workspace{config: config}, snapshot) do
    budget = get_in(config || %{}, ["routing", "budget_usd_per_day"])
    spend = Map.get(snapshot, :cost_usd_today) || Map.get(snapshot, "cost_usd_today")

    is_number(budget) and is_number(spend) and spend >= budget
  end

  defp degrade(%{config: config} = choice) do
    case Map.get(config, "model") do
      model when is_binary(model) ->
        %{choice | config: Map.put(config, "model", Map.get(@tier_degrade, model, model))}

      _ ->
        # No explicit model on the choice → nothing to degrade. The CLI default
        # is whatever Claude Code picks; we don't try to second-guess it.
        choice
    end
  end
end
