defmodule ArbiterWeb.Api.RepoJSON do
  @moduledoc "Render functions for repo aggregates (see `RepoController`)."

  def index(%{repos: repos}) do
    %{data: Enum.map(repos, &data/1)}
  end

  def data(repo) do
    %{
      name: repo.name,
      path: repo.path,
      source: repo.source,
      polecats: repo.polecats,
      worktrees: repo.worktrees
    }
  end
end
