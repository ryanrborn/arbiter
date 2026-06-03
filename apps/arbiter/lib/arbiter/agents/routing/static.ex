defmodule Arbiter.Agents.Routing.Static do
  @moduledoc """
  Static routing policy — always returns the workspace's default agent
  config from `config["agent"]`. This is the default policy; preserves
  today's behavior for workspaces that haven't opted into per-bead
  routing.
  """

  @behaviour Arbiter.Agents.Routing.Policy

  alias Arbiter.Agents.Routing

  @impl true
  def choose(_bead, workspace, _ledger_snapshot), do: Routing.default_choice(workspace)
end
