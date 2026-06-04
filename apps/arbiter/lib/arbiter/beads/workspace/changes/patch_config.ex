defmodule Arbiter.Beads.Workspace.Changes.PatchConfig do
  @moduledoc """
  Computes the new `config` for the `:patch_config` action.

  Read-modify-write: starts from the workspace's existing `config`, then
    1. removes each dotted path in `unset_paths`,
    2. deep-merges `patch` into the result (maps recurse; scalars / lists
       overwrite),

  and writes the result back to the `config` attribute. `ValidateConfig`
  runs as a follow-up change so the merged result is validated, not the
  partial patch.

  Deep-merge semantics:

    * `deep_merge(%{a: 1, b: %{x: 1}}, %{b: %{y: 2}, c: 3})` →
      `%{a: 1, b: %{x: 1, y: 2}, c: 3}` (sibling keys preserved).
    * Non-map values overwrite (so a list replaces a list — not appended).
    * `nil` values in the patch overwrite (use `unset_paths` to drop a key).
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    existing =
      case changeset.data do
        %{config: %{} = c} -> c
        _ -> %{}
      end

    patch = Changeset.get_argument(changeset, :patch) || %{}
    unset_paths = Changeset.get_argument(changeset, :unset_paths) || []

    cond do
      not is_map(patch) ->
        Changeset.add_error(changeset, field: :patch, message: "must be a map")

      not is_list(unset_paths) ->
        Changeset.add_error(changeset, field: :unset_paths, message: "must be a list of strings")

      true ->
        new_config =
          existing
          |> apply_unsets(unset_paths)
          |> deep_merge(patch)

        Changeset.force_change_attribute(changeset, :config, new_config)
    end
  end

  @doc """
  Deep-merge two maps. Maps recurse; everything else (scalars, lists, structs)
  is overwritten by the patch value.
  """
  @spec deep_merge(map(), map()) :: map()
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r ->
      if is_map(l) and is_map(r) and not is_struct(l) and not is_struct(r) do
        deep_merge(l, r)
      else
        r
      end
    end)
  end

  @doc """
  Remove each dotted path from `config`. A dotted path traverses nested maps;
  missing intermediate keys are a no-op (so unsetting an absent key is safe).
  Empty maps left behind after a leaf removal are kept (callers can decide
  whether to also prune empties).
  """
  @spec apply_unsets(map(), [String.t()]) :: map()
  def apply_unsets(config, paths) when is_map(config) and is_list(paths) do
    Enum.reduce(paths, config, fn path, acc -> drop_path(acc, split_path(path)) end)
  end

  defp split_path(path) when is_binary(path) do
    path |> String.split(".") |> Enum.reject(&(&1 == ""))
  end

  defp drop_path(map, []), do: map

  defp drop_path(map, [key]) when is_map(map), do: Map.delete(map, key)

  defp drop_path(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      %{} = sub -> Map.put(map, key, drop_path(sub, rest))
      _ -> map
    end
  end

  defp drop_path(other, _), do: other
end
