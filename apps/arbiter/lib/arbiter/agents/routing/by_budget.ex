defmodule Arbiter.Agents.Routing.ByBudget do
  @moduledoc """
  Routing policy: route by some base policy (`:by_priority` by default,
  `:by_difficulty` when `routing.base_policy = "by_difficulty"`), then
  apply a daily-USD ceiling. When the ledger snapshot says today's spend
  has crossed `workspace.config["routing"]["budget_usd_per_day"]`,
  degrade the chosen tier one step:

    * Abstract tiers (from `:by_difficulty`): `premium → standard → economy`
      on the `"model_tier"` key.
    * Legacy concrete-model configs (from `:by_priority`):
      `opus → sonnet → haiku` on the `"model"` key.

  The two degradations are independent: a chosen config with both
  `"model"` and `"model_tier"` set has both degraded. A config with
  neither set is passed through unchanged (the CLI default isn't
  something we second-guess).

  The ledger snapshot is supplied by the caller as a map; this policy
  reads `:cost_usd_today` (a float). When the snapshot has no usage data
  (the default `%{}`), the policy behaves exactly like its base policy
  — so a workspace can opt in before the ledger has data to drive it
  without the policy doing anything surprising.

  Stage-D-ready (`docs/agent-harness-design.md` §4.4): the policy ships
  here so the seam is present, but it's only *useful* once the ledger
  is queried into a snapshot on every dispatch — that integration is
  intentionally out of scope for this bead.
  """

  @behaviour Arbiter.Agents.Routing.Policy

  alias Arbiter.Agents.Routing.ByDifficulty
  alias Arbiter.Agents.Routing.ByPriority
  alias Arbiter.Beads.Workspace

  @model_degrade %{
    "opus" => "sonnet",
    "sonnet" => "haiku",
    "haiku" => "haiku"
  }

  @tier_degrade %{
    "premium" => "standard",
    "standard" => "economy",
    "economy" => "economy"
  }

  @impl true
  def choose(bead, workspace, ledger_snapshot) do
    base = base_policy(workspace).choose(bead, workspace, ledger_snapshot)

    case over_budget?(workspace, ledger_snapshot) do
      false -> base
      true -> degrade(base)
    end
  end

  # Pick the underlying policy. Defaults to `:by_priority` to preserve
  # today's behavior; opt in to `:by_difficulty` by setting
  # `routing.base_policy = "by_difficulty"` on the workspace.
  defp base_policy(nil), do: ByPriority

  defp base_policy(%Workspace{config: config}) do
    case get_in(config || %{}, ["routing", "base_policy"]) do
      "by_difficulty" -> ByDifficulty
      _ -> ByPriority
    end
  end

  defp over_budget?(nil, _snapshot), do: false

  defp over_budget?(%Workspace{config: config}, snapshot) do
    budget = get_in(config || %{}, ["routing", "budget_usd_per_day"])
    spend = Map.get(snapshot, :cost_usd_today) || Map.get(snapshot, "cost_usd_today")

    is_number(budget) and is_number(spend) and spend >= budget
  end

  defp degrade(%{config: config} = choice) do
    degraded =
      config
      |> maybe_degrade("model_tier", @tier_degrade)
      |> maybe_degrade("model", @model_degrade)

    %{choice | config: degraded}
  end

  defp maybe_degrade(config, key, table) do
    case Map.get(config, key) do
      v when is_binary(v) ->
        Map.put(config, key, Map.get(table, v, v))

      _ ->
        config
    end
  end
end
