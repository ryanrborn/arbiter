defmodule Arbiter.Beads.RigConfig do
  @moduledoc """
  Normalizers for `rig_paths` config entries.

  A `rig_paths` value may be either a bare string path or a map that carries
  an optional `target_branch` alongside the path:

      "server" => "/home/rborn/dev/leotech/server"
      "server" => %{"path" => "/home/rborn/dev/leotech/server", "target_branch" => "integration/dolphin"}

  Callers should use these functions instead of pattern-matching directly so
  both forms are handled consistently.
  """

  @doc "Returns the filesystem path from a rig_paths entry, or nil."
  def rig_path_from_config(p) when is_binary(p) and p != "", do: p
  def rig_path_from_config(%{"path" => p}) when is_binary(p) and p != "", do: p
  def rig_path_from_config(_), do: nil

  @doc "Returns the target_branch from a rig_paths entry, or nil."
  def rig_target_from_config(%{"target_branch" => t}) when is_binary(t) and t != "", do: t
  def rig_target_from_config(_), do: nil
end
