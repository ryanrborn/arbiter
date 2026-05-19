defmodule GtElixirWeb.Api.WorkspaceJSON do
  @moduledoc "Render functions for Workspace resources."

  alias GtElixir.Beads.Workspace

  def show(%{workspace: ws}), do: data(ws)

  def index(%{workspaces: workspaces}) do
    %{data: Enum.map(workspaces, &data/1)}
  end

  def data(%Workspace{} = ws) do
    %{
      id: ws.id,
      name: ws.name,
      description: ws.description,
      prefix: ws.prefix,
      config: ws.config,
      created_at: iso(ws.created_at),
      updated_at: iso(ws.updated_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
