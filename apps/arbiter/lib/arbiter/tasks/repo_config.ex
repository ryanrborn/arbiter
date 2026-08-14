defmodule Arbiter.Tasks.RepoConfig do
  @moduledoc """
  Normalizers for `repo_paths` config entries.

  A `repo_paths` value may be either a bare string path or a map that carries
  an optional `target_branch` alongside the path:

      "server" => "/home/rborn/dev/leotech/server"
      "server" => %{"path" => "/home/rborn/dev/leotech/server", "target_branch" => "integration/dolphin"}

  Callers should use these functions instead of pattern-matching directly so
  both forms are handled consistently.
  """

  @doc "Returns the filesystem path from a repo_paths entry, or nil."
  def repo_path_from_config(p) when is_binary(p) and p != "", do: p
  def repo_path_from_config(%{"path" => p}) when is_binary(p) and p != "", do: p
  def repo_path_from_config(_), do: nil

  @doc "Returns the target_branch from a repo_paths entry, or nil."
  def repo_target_from_config(%{"target_branch" => t}) when is_binary(t) and t != "", do: t
  def repo_target_from_config(_), do: nil

  @doc """
  Normalizes a repo key/slug for loose comparison: lowercased with every `_`
  turned into `-`. A GitHub org may use underscores in an actual repo name
  (`verus_server`) while a `repo_paths` entry was registered with the more
  common hyphenated convention (`verus-server`, or vice versa) — this lets
  callers match the two without requiring the registered key to be an exact
  byte-for-byte match of the forge slug.
  """
  def normalize_slug(s) when is_binary(s), do: s |> String.downcase() |> String.replace("_", "-")
  def normalize_slug(_), do: nil

  @doc """
  Looks up `repo`'s raw entry in a `repo_paths`-shaped map.

  Three passes, in order:

    1. Exact key match.
    2. Normalized match (see `normalize_slug/1`) so a differently-separated
       key (`verus_server` vs `verus-server`) still resolves.
    3. If `repo` is a forge-qualified slug (`<org>/<repo>`), the same two
       passes against just its trailing segment — `repo_paths` is keyed by
       bare rig name, but callers like PRPatrol only have the slug on hand
       (bd-c5f0n5).

  Returns `nil` if `map` isn't a map, or the repo isn't registered.
  """
  def find_entry(map, repo) when is_map(map) and is_binary(repo) do
    case Map.get(map, repo) do
      nil ->
        target = normalize_slug(repo)

        Enum.find_value(map, fn {k, v} -> if normalize_slug(k) == target, do: v end) ||
          find_entry_by_slug_suffix(map, repo)

      raw ->
        raw
    end
  end

  def find_entry(_map, _repo), do: nil

  defp find_entry_by_slug_suffix(map, repo) do
    case String.split(repo, "/") do
      [_owner, name] when name != "" -> find_entry(map, name)
      _ -> nil
    end
  end

  @doc """
  Looks up `repo`'s filesystem path in a `repo_paths`-shaped map. See
  `find_entry/2` for the matching rules. Returns `nil` if `map`
  isn't a map, or the repo isn't registered.
  """
  def find_path(map, repo) do
    map |> find_entry(repo) |> repo_path_from_config()
  end
end
