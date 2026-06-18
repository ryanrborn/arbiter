defmodule ArbiterWeb.Api.RigController do
  @moduledoc """
  REST endpoint for rigs — the repo/project keys polecats operate on.

  Routes:

    * `GET /api/rigs` — :index

  A "rig" is a named repository checkout. Rigs are discovered from three
  sources, mirroring `ArbiterWeb.DashboardLive.refresh_rigs/1`:

    * each workspace's `config["rig_paths"]` map,
    * the application-env `:arbiter, :rig_paths` fallback (`source: "(app)"`),
    * any rig name a live polecat is running against that isn't configured
      anywhere (`source: "(unconfigured)"`).

  For each rig the response carries the number of active polecats and the
  number of git worktrees resident at its path.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Beads.RigConfig
  alias Arbiter.Beads.Workspace
  alias Arbiter.Polecat
  alias Arbiter.Polecat.Worktree

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, _params) do
    render(conn, :index, rigs: list_rigs())
  end

  # ---- rig aggregation (mirrors DashboardLive.refresh_rigs/1) ----

  defp list_rigs do
    workspaces = load_workspaces()

    paths_by_rig = collect_rig_paths(workspaces)
    polecats_by_rig = group_polecats_by_rig()

    paths_by_rig
    |> Map.merge(rigs_from_polecats(polecats_by_rig, paths_by_rig))
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
        polecats: Map.get(polecats_by_rig, name, 0),
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

  # Build {rig_name => %{path:, source:}} from every workspace's
  # config["rig_paths"] plus the application-env fallback. Workspace
  # entries win over app-env when names collide.
  defp collect_rig_paths(workspaces) do
    app_paths =
      :arbiter
      |> Application.get_env(:rig_paths, %{})
      |> Map.new(fn {name, raw} ->
        {name, %{path: RigConfig.rig_path_from_config(raw), source: "(app)"}}
      end)

    Enum.reduce(workspaces, app_paths, fn ws, acc ->
      ws_rig_paths =
        case ws.config do
          %{"rig_paths" => paths} when is_map(paths) -> paths
          _ -> %{}
        end

      Enum.reduce(ws_rig_paths, acc, fn {name, raw}, acc ->
        Map.put(acc, name, %{path: RigConfig.rig_path_from_config(raw), source: ws.name})
      end)
    end)
  end

  defp group_polecats_by_rig do
    try do
      Polecat.list_children()
    rescue
      _ -> []
    end
    |> Enum.reduce(%{}, fn p, acc ->
      rig = p.rig || "(none)"
      Map.update(acc, rig, 1, &(&1 + 1))
    end)
  end

  # A polecat can be running against a rig name that isn't in any
  # `rig_paths` config (default-rig "unknown", a typo, or an inherited
  # legacy value). Surface those as well.
  defp rigs_from_polecats(polecats_by_rig, configured) do
    polecats_by_rig
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
