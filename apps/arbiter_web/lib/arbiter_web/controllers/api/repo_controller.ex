defmodule ArbiterWeb.Api.RepoController do
  @moduledoc """
  REST endpoint for repos — the repo/project keys workers operate on.

  Routes:

    * `GET /api/repos` — :index

  A "repo" is a named repository checkout. Repos are discovered from three
  sources, mirroring `ArbiterWeb.DashboardLive.refresh_repos/1`:

    * each workspace's `config["repo_paths"]` map (with compat fallback to `config["rig_paths"]`),
    * the application-env `:arbiter, :repo_paths` fallback (`source: "(app)"`),
    * any repo name a live worker is running against that isn't configured
      anywhere (`source: "(unconfigured)"`).

  For each repo the response carries the number of active workers and the
  number of git worktrees resident at its path.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Beads.RepoConfig
  alias Arbiter.Beads.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.Worktree

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, _params) do
    render(conn, :index, repos: list_repos())
  end

  # ---- repo aggregation (mirrors DashboardLive.refresh_repos/1) ----

  defp list_repos do
    workspaces = load_workspaces()

    paths_by_repo = collect_repo_paths(workspaces)
    workers_by_repo = group_workers_by_repo()

    paths_by_repo
    |> Map.merge(repos_from_workers(workers_by_repo, paths_by_repo))
    |> Enum.map(fn {name, entry} ->
      path = entry.path

      worktree_count =
        case path do
          nil -> 0
          p when is_binary(p) -> safe_worktree_count(p)
        end

      %{
        name: name,
        path: path,
        source: entry.source,
        workers: Map.get(workers_by_repo, name, 0),
        worktrees: worktree_count
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp load_workspaces do
    Ash.read!(Workspace)
  rescue
    _ -> []
  end

  # Build {repo_name => %{path:, source:}} from every workspace's
  # config["repo_paths"] (with compat fallback to config["rig_paths"]) plus
  # the application-env fallback. Workspace entries win over app-env when names collide.
  defp collect_repo_paths(workspaces) do
    app_paths =
      :arbiter
      |> Application.get_env(:repo_paths, %{})
      |> Map.new(fn {name, raw} ->
        {name, %{path: RepoConfig.repo_path_from_config(raw), source: "(app)"}}
      end)

    Enum.reduce(workspaces, app_paths, fn ws, acc ->
      ws_repo_paths =
        case ws.config do
          %{"repo_paths" => paths} when is_map(paths) -> paths
          %{"rig_paths" => paths} when is_map(paths) -> paths
          _ -> %{}
        end

      Enum.reduce(ws_repo_paths, acc, fn {name, raw}, acc ->
        Map.put(acc, name, %{path: RepoConfig.repo_path_from_config(raw), source: ws.name})
      end)
    end)
  end

  defp group_workers_by_repo do
    try do
      Worker.list_children()
    rescue
      _ -> []
    end
    |> Enum.reduce(%{}, fn p, acc ->
      repo = p.repo || "(none)"
      Map.update(acc, repo, 1, &(&1 + 1))
    end)
  end

  # A worker can be running against a repo name that isn't in any
  # `repo_paths` config (default-repo "unknown", a typo, or an inherited
  # legacy value). Surface those as well.
  defp repos_from_workers(workers_by_repo, configured) do
    workers_by_repo
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(configured, &1))
    |> Map.new(fn name -> {name, %{path: nil, source: "(unconfigured)"}} end)
  end

  defp safe_worktree_count(path) do
    Worktree.list(path) |> length()
  rescue
    _ -> 0
  end
end
