defmodule GtElixirWeb.Api.ConvoyJSON do
  @moduledoc "Render functions for Convoy resources."

  alias GtElixir.Beads.Convoy

  @doc """
  Renders a single convoy with member-id list (requires `memberships` to be loaded).

  The progress map is included when aggregates are loaded.
  """
  def show(%{convoy: convoy}), do: data(convoy)

  def index(%{convoys: convoys}) do
    %{data: Enum.map(convoys, &data/1)}
  end

  def data(%Convoy{} = c) do
    base = %{
      id: c.id,
      title: c.title,
      status: to_string_atom(c.status),
      lifecycle: to_string_atom(c.lifecycle),
      workspace_id: c.workspace_id,
      closed_at: iso(c.closed_at),
      closed_reason: c.closed_reason,
      created_at: iso(c.created_at),
      updated_at: iso(c.updated_at),
      member_ids: member_ids(c)
    }

    base
    |> maybe_put(:total_issues, c.total_issues)
    |> maybe_put(:closed_issues, c.closed_issues)
  end

  defp member_ids(%{memberships: %Ash.NotLoaded{}}), do: nil

  defp member_ids(%{memberships: memberships}) when is_list(memberships) do
    Enum.map(memberships, & &1.issue_id)
  end

  defp member_ids(_), do: nil

  defp maybe_put(map, _key, %Ash.NotLoaded{}), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
