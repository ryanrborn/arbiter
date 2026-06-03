defmodule Arbiter.Agents.Routing do
  @moduledoc """
  Routing dispatcher: resolves `workspace.config["routing"]["policy"]` to a
  `Arbiter.Agents.Routing.Policy` implementation and delegates `choose/3`.

  Mirrors the trackers / mergers / agents dispatcher shape. Today's
  policies:

    * `:static` (default) — always return the workspace's `agent` config.
    * `:by_priority` — map `bead.priority` to a rule under
      `routing.rules["P0".."P4"]`, falling back to the workspace default.
    * `:by_budget` — `:by_priority` until the ledger says the workspace has
      blown its daily budget; then degrade one tier (Opus → Sonnet → Haiku).
    * `:round_robin` — cycle through `routing.adapters` per dispatch.

  Only `:static` and `:by_priority` are usefully exercised today (the
  other two need ledger data + a second adapter to balance between).
  All four ship as the seam; `Arbiter.Agents.Routing.choose/3` returns the
  same `%{type:, config:}` shape regardless of which policy is active.
  """

  alias Arbiter.Agents.Routing.{ByBudget, ByPriority, Policy, RoundRobin, Static}
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace

  @policies %{
    static: Static,
    by_priority: ByPriority,
    by_budget: ByBudget,
    round_robin: RoundRobin
  }

  @valid_policies ~w(static by_priority by_budget round_robin)

  @doc """
  Choose an agent for `bead`. `:ledger_snapshot` is reserved for
  policies that read usage data (`:by_budget`); the default policies
  ignore it.
  """
  @spec choose(Issue.t(), Workspace.t() | nil, Policy.ledger_snapshot()) :: Policy.choice()
  def choose(%Issue{} = bead, workspace, ledger_snapshot \\ %{}) do
    workspace
    |> policy_for_workspace()
    |> apply(:choose, [bead, workspace, ledger_snapshot])
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
  Default choice — the workspace's worker-agent config, with no per-bead
  override applied. Policies fall back to this when they have no rule
  for a bead.
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

  def agent_type_atom(_), do: :claude
end
