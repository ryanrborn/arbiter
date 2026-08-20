defmodule ArbiterCli.Cmd.Workspace.Resolver do
  @moduledoc """
  Resolves a `--workspace` option (or the default) to a full workspace map,
  and locates a repo's entry under `config.repo_paths` — shared by the
  `standing-order` and `secret` verb groups of `arb workspace`.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  @spec resolve_workspace!(map() | String.t() | nil) :: map()
  def resolve_workspace!(%{} = ws) when is_map_key(ws, "id"), do: ws

  def resolve_workspace!(nil) do
    case Workspace.resolve() do
      {:ok, ws} -> ws
      {:error, msg} -> Output.die(msg)
    end
  end

  def resolve_workspace!(name) when is_binary(name) do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} ->
        case Enum.find(list, &(&1["name"] == name)) do
          nil -> Output.die("no workspace named #{inspect(name)}")
          ws -> ws
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  # Finds `repo`'s entry under `config.repo_paths`, matching loosely the way
  # `Arbiter.Tasks.RepoConfig` does server-side (exact key, then normalized
  # `_`/`-` match). Returns `{repo_paths_key, matched_entry_key,
  # entry_or_nil}` — `repo_paths_key` is which top-level key to patch back
  # into, and `matched_entry_key` is the literal key already used in config
  # (so a normalized-match write lands on the existing entry instead of
  # creating a sibling).
  @spec resolve_repo(map(), String.t()) :: {String.t(), String.t(), map() | String.t() | nil}
  def resolve_repo(ws, repo) do
    repo_paths_key = "repo_paths"

    map =
      case get_in(ws, ["config", "repo_paths"]) do
        m when is_map(m) -> m
        _ -> %{}
      end

    case Map.fetch(map, repo) do
      {:ok, entry} ->
        {repo_paths_key, repo, entry}

      :error ->
        target = normalize_repo_slug(repo)

        case Enum.find(map, fn {k, _v} -> normalize_repo_slug(k) == target end) do
          {k, entry} -> {repo_paths_key, k, entry}
          nil -> {repo_paths_key, repo, nil}
        end
    end
  end

  defp normalize_repo_slug(s), do: s |> String.downcase() |> String.replace("_", "-")
end
