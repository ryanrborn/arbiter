defmodule ArbiterWeb.Api.WorkspaceJSON do
  @moduledoc "Render functions for Workspace resources."

  alias Arbiter.Agents
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Beads.Workspace

  def show(%{workspace: ws}), do: data(ws)

  def index(%{workspaces: workspaces}) do
    %{data: Enum.map(workspaces, &data/1)}
  end

  def data(%Workspace{} = ws) do
    adapter = Agents.for_workspace(ws)

    %{
      id: ws.id,
      name: ws.name,
      description: ws.description,
      prefix: ws.prefix,
      config: ws.config,
      # The *resolved* acolyte security posture (install default + this
      # domain's overrides) — single source of truth for `arb prime` and the
      # dashboard, so neither re-derives it from raw config.
      # `policy_enforced` reflects whether the active adapter honors the policy
      # contract (see Arbiter.Agents.Agent.security_enforced?/0). Adapters that
      # don't yet implement the security contract return false so the operator
      # knows the declared posture is not being enforced.
      security_posture:
        ws
        |> SecurityPolicy.resolve()
        |> SecurityPolicy.summary()
        |> Map.merge(%{
          "provider" => adapter.provider(),
          "policy_enforced" => security_enforced?(adapter)
        }),
      created_at: iso(ws.created_at),
      updated_at: iso(ws.updated_at)
    }
  end

  defp security_enforced?(adapter) do
    if function_exported?(adapter, :security_enforced?, 0) do
      adapter.security_enforced?()
    else
      false
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
