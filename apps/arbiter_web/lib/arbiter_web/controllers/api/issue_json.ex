defmodule ArbiterWeb.Api.IssueJSON do
  @moduledoc """
  Render functions for Issue resources.

  Atoms are emitted as strings; timestamps as ISO8601.
  """

  alias Arbiter.Beads.Issue

  @doc "Renders a single issue."
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
      assignee: issue.assignee,
      tracker_type: to_string_atom(issue.tracker_type),
      tracker_ref: issue.tracker_ref,
      workspace_id: issue.workspace_id,
      closed_at: iso(issue.closed_at),
      created_at: iso(issue.created_at),
      updated_at: iso(issue.updated_at)
    }
  end

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
