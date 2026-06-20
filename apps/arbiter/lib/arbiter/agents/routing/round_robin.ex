defmodule Arbiter.Agents.Routing.RoundRobin do
  @moduledoc """
  Routing policy: cycle through an ordered list of agent configs per
  dispatch. Useful for A/B between two adapters once a second adapter
  ships — until then, every entry in the list is a Claude config, so
  this policy effectively rotates model tiers.

  Reads `workspace.config["routing"]["adapters"]` — a list of partial
  agent-config maps. Each entry is merged on top of
  `config["agent"]["config"]` and used in turn. With no list configured
  (or an empty list), this policy falls back to the workspace default —
  same as `:static`.

  ## Rotation state

  The rotation counter is **per-workspace, in-memory** (an Agents
  registry handled at dispatch). For simplicity in Phase B, we use a
  process-dictionary counter keyed on the workspace id. Cross-process
  consistency (and persistence) lands when there's a real reason to
  spend the complexity — until then, "we cycle within a single
  scheduler process" is enough.
  """

  @behaviour Arbiter.Agents.Routing.Policy

  alias Arbiter.Agents.Routing
  alias Arbiter.Tasks.Workspace

  @impl true
  def choose(_task, workspace, _ledger_snapshot) do
    default = Routing.default_choice(workspace)

    case adapters_for(workspace) do
      [] -> default
      list -> %{default | config: Map.merge(default.config, pick_next(workspace, list))}
    end
  end

  defp adapters_for(nil), do: []

  defp adapters_for(%Workspace{config: config}) do
    case get_in(config || %{}, ["routing", "adapters"]) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  defp pick_next(workspace, list) do
    key = {__MODULE__, :rotation, workspace_id(workspace)}
    idx = Process.get(key, 0)
    chosen = Enum.at(list, rem(idx, length(list)))
    Process.put(key, idx + 1)
    chosen
  end

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(_), do: :anonymous
end
