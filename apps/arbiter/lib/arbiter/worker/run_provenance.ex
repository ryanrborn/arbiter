defmodule Arbiter.Worker.RunProvenance do
  @moduledoc """
  Pure helpers that turn dispatch-time state into the provenance fields
  recorded on `Arbiter.Workers.Run` (bd-dzz6ly): the effective post-layering
  skill set, the workspace's standing_orders digest, and which routing policy
  is configured. Called from both `Arbiter.Worker.Dispatch` (the main worker
  spawn) and `Arbiter.Worker.ReviewGate` (reviewer/implementer workers) so
  every agent type reports through the same shape.
  """

  alias Arbiter.Agents.Routing
  alias Arbiter.StandingOrders
  alias Arbiter.Tasks.Workspace

  @doc """
  Turn an `Arbiter.Skills.Selection.resolve/1` result (`[%{skill:, activation:}]`)
  into the `{"name", "activation_mode", "skill_version"}` triples recorded in
  `resolved_skills`. `activation_mode` here is the resolved per-dispatch
  activation (workspace/repo/task override, or the skill's own default) — NOT
  necessarily the skill's stored `activation_mode`, since that's what actually
  governed this run. `skill_version` is the skill's `updated_at` (ISO 8601):
  skills have no incrementing version counter, but `updated_at` changes on
  every write, which is enough to tell "same body" from "different body"
  across two runs.
  """
  @spec skills([%{skill: Arbiter.Skills.Skill.t(), activation: atom()}]) :: [map()]
  def skills(resolved) when is_list(resolved) do
    Enum.map(resolved, fn %{skill: skill, activation: activation} ->
      %{
        "name" => skill.name,
        "activation_mode" => Atom.to_string(activation),
        "skill_version" => skill_version(skill)
      }
    end)
  end

  def skills(_), do: []

  defp skill_version(%{updated_at: %DateTime{} = dt}), do: DateTime.to_iso8601(dt)
  defp skill_version(_), do: nil

  @doc """
  SHA-256 hex digest of the workspace's effective `standing_orders` text, or
  `nil` when unset/empty. A list is joined with newlines before hashing so
  reordering or adding an entry changes the digest; a bare string is hashed
  as-is.
  """
  @spec standing_orders_digest(Workspace.t() | nil) :: String.t() | nil
  def standing_orders_digest(%Workspace{config: config}) do
    case get_in(config || %{}, ["standing_orders"]) do
      nil -> nil
      [] -> nil
      "" -> nil
      orders -> orders |> canonical_text() |> sha256_hex()
    end
  end

  def standing_orders_digest(_), do: nil

  defp canonical_text(orders) when is_list(orders),
    do: Enum.map_join(orders, "\n", &StandingOrders.canonical_text/1)

  defp canonical_text(text) when is_binary(text), do: text
  defp canonical_text(other), do: inspect(other)

  defp sha256_hex(text) do
    :sha256
    |> :crypto.hash(text)
    |> Base.encode16(case: :lower)
  end

  @doc """
  The routing policy string for provenance — `workspace.config["routing"]["policy"]`
  resolved through `Arbiter.Agents.Routing.policy_for_workspace/1` and mapped
  back to its config string ("static" when unset/invalid/nil workspace,
  mirroring the dispatcher's own fallback).
  """
  @spec routing_policy_string(Workspace.t() | nil) :: String.t()
  def routing_policy_string(workspace) do
    policy_module = Routing.policy_for_workspace(workspace)

    Routing.policies()
    |> Enum.find_value("static", fn {atom, mod} ->
      if mod == policy_module, do: Atom.to_string(atom)
    end)
  end
end
