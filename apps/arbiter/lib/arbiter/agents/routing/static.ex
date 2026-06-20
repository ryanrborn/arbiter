defmodule Arbiter.Agents.Routing.Static do
  @moduledoc """
  Static routing policy — always returns the workspace's default agent
  config from `config["agent"]`. This is the default policy; preserves
  today's behavior for workspaces that haven't opted into per-task
  routing.
  """

  @behaviour Arbiter.Agents.Routing.Policy

  alias Arbiter.Agents.Routing

  @impl true
  def choose(_task, workspace, _ledger_snapshot), do: Routing.default_choice(workspace)
end
