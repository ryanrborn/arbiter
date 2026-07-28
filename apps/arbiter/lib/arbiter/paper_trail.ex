defmodule Arbiter.PaperTrail do
  @moduledoc """
  Helpers for the `AshPaperTrail`-versioned resources (`Issue`, `Skill`,
  `Workspace`).

  ## Actor attribution

  `ash_paper_trail`'s `belongs_to_actor` DSL requires the actor to be an Ash
  *resource* (it stores a foreign key to a `User`-like row). arbiter has no such
  resource — a write originates from an MCP `Arbiter.MCP.Scope` (a coordinator
  or a worker bound to one task), the `arb` CLI, or the dashboard. So instead of
  a relationship we record a **stable string label** for the actor and let
  `paper_trail`'s `attributes_as_attributes` snapshot it onto every version row
  (see `Arbiter.Skills.Skill` / `Arbiter.Tasks.Workspace`).

  `actor_label/1` normalises whatever the caller threads through as the Ash
  `actor:` option into that label:

    * a coordinator scope → `"coordinator"`
    * a worker scope → `"worker:<task_id>"`
    * a bare string (e.g. `"cli"`, `"dashboard"`) → itself
    * `nil` → `nil` (an unattributed write, e.g. a seed or a legacy caller)
  """

  alias Arbiter.MCP.Scope

  @doc """
  Normalise an Ash `actor` term into a stable string label for a version row.
  """
  @spec actor_label(term()) :: String.t() | nil
  def actor_label(%Scope{tier: :coordinator}), do: "coordinator"

  def actor_label(%Scope{tier: :worker, task_id: task_id}) when is_binary(task_id),
    do: "worker:#{task_id}"

  def actor_label(%Scope{tier: tier}) when is_atom(tier), do: Atom.to_string(tier)
  def actor_label(label) when is_binary(label), do: label
  def actor_label(nil), do: nil
  def actor_label(other), do: inspect(other)
end
