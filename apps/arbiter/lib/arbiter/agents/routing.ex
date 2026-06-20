defmodule Arbiter.Agents.Routing do
  @moduledoc """
  Routing dispatcher: resolves `workspace.config["routing"]["policy"]` to a
  `Arbiter.Agents.Routing.Policy` implementation and delegates `choose/3`.

  Mirrors the trackers / mergers / agents dispatcher shape. Today's
  policies:

    * `:static` (default) — always return the workspace's `agent` config.
    * `:by_priority` — map `task.priority` to a rule under
      `routing.rules["P0".."P4"]`, falling back to the workspace default.
    * `:by_difficulty` — map `task.difficulty` to abstract
      `{model_tier, thinking}` under `routing.rules["D0".."D4"]`, falling
      back to a default mapping. Provider-agnostic: each adapter resolves
      the tier + thinking abstractions to its own knobs.
    * `:by_budget` — `:by_priority` (or `:by_difficulty`, see the
      `routing.base_policy` option) until the ledger says the workspace
      has blown its daily budget; then degrade one tier (premium →
      standard → economy, or Opus → Sonnet → Haiku for legacy
      concrete-model configs).
    * `:round_robin` — cycle through `routing.adapters` per dispatch.

  Only `:static`, `:by_priority`, and `:by_difficulty` are exercised on
  the worker dispatch path today; `:by_budget` and `:round_robin` ship as
  seams. `Arbiter.Agents.Routing.choose/3` returns the same
  `%{type:, config:}` shape regardless of which policy is active.
  """

  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.Routing.{ByBudget, ByDifficulty, ByPriority, Policy, RoundRobin, Static}
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @policies %{
    static: Static,
    by_priority: ByPriority,
    by_difficulty: ByDifficulty,
    by_budget: ByBudget,
    round_robin: RoundRobin
  }

  @valid_policies ~w(static by_priority by_difficulty by_budget round_robin)

  @doc """
  Choose an agent for `task`. `:ledger_snapshot` is reserved for
  policies that read usage data (`:by_budget`); the default policies
  ignore it.
  """
  @spec choose(Issue.t(), Workspace.t() | nil, Policy.ledger_snapshot()) :: Policy.choice()
  def choose(%Issue{} = task, workspace, ledger_snapshot \\ %{}) do
    workspace
    |> policy_for_workspace()
    |> apply(:choose, [task, workspace, ledger_snapshot])
  end

  @doc """
  Returns the policy module for the given workspace, resolved from
  `config["routing"]["policy"]`. Defaults to `Static` when unset or
  malformed.
  """
  @spec policy_for_workspace(Workspace.t() | nil) :: module()
  def policy_for_workspace(nil), do: Static

  def policy_for_workspace(%Workspace{config: config}) do
    case get_in(config || %{}, ["routing", "policy"]) do
      p when p in @valid_policies -> Map.fetch!(@policies, String.to_atom(p))
      _ -> Static
    end
  end

  @doc "Returns the map of policy atom → module."
  @spec policies() :: %{atom() => module()}
  def policies, do: @policies

  @doc "Valid routing policy strings (for workspace-config validation)."
  @spec valid_policies() :: [String.t()]
  def valid_policies, do: @valid_policies

  @doc """
  Default choice — the workspace's worker-agent config, with no per-task
  override applied. Policies fall back to this when they have no rule
  for a task.
  """
  @spec default_choice(Workspace.t() | nil) :: Policy.choice()
  def default_choice(nil), do: %{type: :claude, config: %{}}

  def default_choice(%Workspace{config: config}) do
    raw = get_in(config || %{}, ["agent"]) || %{}

    %{
      type: agent_type_atom(raw),
      config: raw["config"] || %{}
    }
  end

  @doc false
  def agent_type_atom(%{"type" => t}) when is_binary(t) do
    try do
      String.to_existing_atom(t)
    rescue
      ArgumentError -> :claude
    end
  end

  def agent_type_atom(%{"type" => list}) when is_list(list) do
    list
    |> Enum.map(&safe_to_atom/1)
    |> Enum.reject(&is_nil/1)
    |> ProviderPool.pick() || :claude
  end

  def agent_type_atom(_), do: :claude

  defp safe_to_atom(t) when is_binary(t) do
    String.to_existing_atom(t)
  rescue
    ArgumentError -> nil
  end

  defp safe_to_atom(_), do: nil
end
