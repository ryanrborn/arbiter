defmodule Arbiter.Polecat.TargetBranch do
  @moduledoc """
  Single source of truth for a bead's **integration branch** — the branch its
  worktree is cut from AND the base its PR/MR merges into. These two must never
  diverge, or a worktree cut from `integration/dolphin` would open a PR against
  `main`, producing a wrong diff and spurious conflicts (bd-b6rzoc).

  Both `Arbiter.Polecat.Dispatch` (which provisions the worktree) and
  `Arbiter.Workflows.MergeQueue` (which opens the PR) call `resolve/2`, so the
  worktree base and the PR base are computed by the *same* chain from the *same*
  inputs.

  ## Resolution order

    1. `:base_branch` opt — an explicit, top-priority override. The escape hatch
       for callers (and tests) that know better than any config. `Dispatch` exposes
       this as its `:base_branch` opt.
    2. Bead's own `:target_branch` field — the per-bead override.
    3. Per-rig default in workspace config — the `rig_paths` map entry can be a
       string (the path) or a `{"path" => ..., "target_branch" => ...}` map for
       an integration branch shared by every bead worked in that rig. Requires
       the caller to pass the resolved `:rig`.
    4. `:workspace_base` opt — a queue-level base. The `MergeQueue` passes its
       explicitly-configured `state.base` here so it sits *below* the per-bead
       and per-rig config rather than short-circuiting them. nil when unset.
    5. Workspace merge config (`workspace.config["merge"]["base"]`).
    6. `"main"` — the default integration branch.

  Steps 2, 3 and 5 read the bead and its workspace; steps 1 and 4 come purely
  from `opts`. The per-bead/per-rig config therefore always wins over a queue's
  blanket base, which is what keeps the worktree base and the PR base in sync.
  """

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.RigConfig
  alias Arbiter.Beads.Workspace

  @type opt ::
          {:base_branch, String.t() | nil}
          | {:rig, String.t() | nil}
          | {:workspace_base, String.t() | nil}
  @type opts :: [opt]

  @doc """
  Resolve the integration branch for `bead`. See the moduledoc for the chain.

  `opts`:

    * `:base_branch` — explicit top-priority override (nil to skip).
    * `:rig` — the resolved rig name, used to look up the per-rig default.
    * `:workspace_base` — a queue-level base that sits below bead/rig config.
  """
  @spec resolve(Issue.t(), opts) :: String.t()
  def resolve(%Issue{} = bead, opts \\ []) do
    Keyword.get(opts, :base_branch) ||
      bead_target_branch(bead) ||
      workspace_rig_target(bead, Keyword.get(opts, :rig)) ||
      Keyword.get(opts, :workspace_base) ||
      workspace_base_branch(bead) ||
      "main"
  end

  defp bead_target_branch(%Issue{target_branch: t}) when is_binary(t) and t != "", do: t
  defp bead_target_branch(_), do: nil

  defp workspace_rig_target(_bead, nil), do: nil

  defp workspace_rig_target(%Issue{workspace_id: nil}, _rig), do: nil

  defp workspace_rig_target(%Issue{workspace_id: ws_id}, rig) when is_binary(rig) do
    case load_workspace_config(ws_id) do
      %{} = config -> rig_target_from_config(get_in(config, ["rig_paths", rig]))
      _ -> nil
    end
  end

  defp rig_target_from_config(raw), do: RigConfig.rig_target_from_config(raw)

  defp workspace_base_branch(%Issue{workspace_id: nil}), do: nil

  defp workspace_base_branch(%Issue{workspace_id: ws_id}) do
    case load_workspace_config(ws_id) do
      %{} = config ->
        case get_in(config, ["merge", "base"]) do
          base when is_binary(base) and base != "" -> base
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp load_workspace_config(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{config: %{} = config}} -> config
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
