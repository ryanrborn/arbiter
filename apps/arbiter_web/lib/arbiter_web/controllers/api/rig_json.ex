defmodule ArbiterWeb.Api.RigJSON do
  @moduledoc "Render functions for rig aggregates (see `RigController`)."

  def index(%{rigs: rigs}) do
    %{data: Enum.map(rigs, &data/1)}
  end

  def data(rig) do
    %{
      name: rig.name,
      path: rig.path,
      source: rig.source,
      polecats: rig.polecats,
      worktrees: rig.worktrees
    }
  end
end
