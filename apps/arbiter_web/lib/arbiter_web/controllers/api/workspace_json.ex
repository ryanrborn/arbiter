defmodule ArbiterWeb.Api.WorkspaceJSON do
  @moduledoc "Render functions for Workspace resources."

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Beads.Workspace

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
      # The *resolved* acolyte security posture (install default + this
      # domain's overrides) — single source of truth for `arb prime` and the
      # dashboard, so neither re-derives it from raw config.
      security_posture: ws |> SecurityPolicy.resolve() |> SecurityPolicy.summary(),
      created_at: iso(ws.created_at),
      updated_at: iso(ws.updated_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
