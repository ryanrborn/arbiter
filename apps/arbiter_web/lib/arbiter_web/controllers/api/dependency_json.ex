defmodule ArbiterWeb.Api.DependencyJSON do
  @moduledoc "Render functions for Dependency resources."

  alias Arbiter.Tasks.Dependency

  def show(%{dependency: dep}), do: data(dep)

  def index(%{dependencies: deps}) do
    %{data: Enum.map(deps, &data/1)}
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
