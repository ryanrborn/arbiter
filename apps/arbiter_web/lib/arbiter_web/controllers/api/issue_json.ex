defmodule ArbiterWeb.Api.IssueJSON do
  @moduledoc """
  Render functions for Issue resources.

  Atoms are emitted as strings; timestamps as ISO8601.
  """

  alias Arbiter.Tasks.Issue

  @doc "Renders a single issue."
  def show(%{issue: issue, warnings: warnings}) when warnings != [],
    do: Map.put(data(issue), :warnings, warnings)

  # bd-3j4ch4: the single-issue read carries a cost estimate (or an explicit
  # null — "no estimate yet" has to be distinguishable from "$0").
  # bd-18vl9q: and the epic cost rollup, null for a non-epic issue.
  def show(%{issue: issue, estimate: estimate, epic_rollup: epic_rollup}) do
    issue
    |> data()
    |> Map.put(:estimate, estimate)
    |> Map.put(:epic_rollup, epic_rollup)
  end

  def show(%{issue: issue}), do: data(issue)

  @doc "Renders a list of issues wrapped under :data."
  def index(%{issues: issues}) do
    %{data: Enum.map(issues, &data/1)}
  end

  def data(%Issue{} = issue) do
    %{
      id: issue.id,
      title: issue.title,
      description: issue.description,
      acceptance: issue.acceptance,
      notes: issue.notes,
      qa_notes: issue.qa_notes,
      deployment_notes: issue.deployment_notes,
      status: to_string_atom(issue.status),
      priority: issue.priority,
      difficulty: issue.difficulty,
      issue_type: to_string_atom(issue.issue_type),
      auto_close: issue.auto_close,
      verify_after_deploy: issue.verify_after_deploy,
      awaiting_verification_at: iso(issue.awaiting_verification_at),
      verification_outcome: to_string_atom(issue.verification_outcome),
      verification_evidence: issue.verification_evidence,
      # bd-9zuvbh: the ReviewGate park. Present (and null) on every issue so a
      # consumer can tell "not parked" from "this API predates the field".
      review_park_reason: issue.review_park_reason,
      review_parked_at: iso(issue.review_parked_at),
      assignee: issue.assignee,
      tracker_type: to_string_atom(issue.tracker_type),
      tracker_ref: issue.tracker_ref,
      pr_ref: issue.pr_ref,
      pr_body: issue.pr_body,
      target_branch: issue.target_branch,
      repo: issue.repo,
      workspace_id: issue.workspace_id,
      refined: issue.refined,
      acceptance_waived: issue.acceptance_waived,
      closed_at: iso(issue.closed_at),
      created_at: iso(issue.created_at),
      updated_at: iso(issue.updated_at)
    }
    |> maybe_put(:child_total, issue.child_total)
    |> maybe_put(:child_closed, issue.child_closed)
  end

  # Child-progress rollup is included only when the calcs are loaded (the show
  # endpoint loads them); index keeps them unloaded so the field is omitted.
  defp maybe_put(map, _key, %Ash.NotLoaded{}), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
