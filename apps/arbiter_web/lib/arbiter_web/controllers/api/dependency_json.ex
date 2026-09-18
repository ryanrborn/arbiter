defmodule ArbiterWeb.Api.DependencyJSON do
  @moduledoc "Render functions for Dependency resources."

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue

  def show(%{dependency: dep}), do: data(dep)

  @doc """
  Renders the `Arbiter.Tasks.Dependencies.list/1` shape: one row per edge,
  each carrying both endpoints' id/title/status/priority so a live edge is
  distinguishable from a closed↔closed one without a second lookup
  (bd-1defgu).
  """
  def index(%{dependencies: rows}) do
    %{data: Enum.map(rows, &edge_row/1)}
  end

  defp edge_row(%{edge: dep, from: from, to: to}) do
    dep
    |> data()
    |> Map.put(:from, endpoint(from))
    |> Map.put(:to, endpoint(to))
  end

  defp endpoint(%Issue{} = issue) do
    %{
      id: issue.id,
      title: issue.title,
      status: to_string_atom(issue.status),
      priority: issue.priority
    }
  end

  def data(%Dependency{} = dep) do
    %{
      id: dep.id,
      from_issue_id: dep.from_issue_id,
      to_issue_id: dep.to_issue_id,
      type: to_string_atom(dep.type),
      created_by: dep.created_by,
      notes: dep.notes,
      created_at: iso(dep.created_at),
      updated_at: iso(dep.updated_at)
    }
  end

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
