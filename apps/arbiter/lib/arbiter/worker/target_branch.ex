defmodule Arbiter.Worker.TargetBranch do
  @moduledoc """
  Single source of truth for a task's **integration branch** — the branch its
  worktree is cut from AND the base its PR/MR merges into. These two must never
  diverge, or a worktree cut from `integration/dolphin` would open a PR against
  `main`, producing a wrong diff and spurious conflicts (bd-b6rzoc).

  Both `Arbiter.Worker.Dispatch` (which provisions the worktree) and
  `Arbiter.Workflows.MergeQueue` (which opens the PR) call `resolve/2`, so the
  worktree base and the PR base are computed by the *same* chain from the *same*
  inputs.

  ## Resolution order

    1. `:base_branch` opt — an explicit, top-priority override. The escape hatch
       for callers (and tests) that know better than any config. `Dispatch` exposes
       this as its `:base_branch` opt.
    2. Task's own `:target_branch` field — the per-task override.
    3. Per-repo default in workspace config — the `repo_paths` map entry can be a
       string (the path) or a `{"path" => ..., "target_branch" => ...}` map for
       an integration branch shared by every task worked in that repo. Requires
       the caller to pass the resolved `:repo`.
    4. `:workspace_base` opt — a queue-level base. The `MergeQueue` passes its
       explicitly-configured `state.base` here so it sits *below* the per-task
       and per-repo config rather than short-circuiting them. nil when unset.
    5. Workspace merge config (`workspace.config["merge"]["base"]`).
    6. `"main"` — the default integration branch.

  Steps 2, 3 and 5 read the task and its workspace; steps 1 and 4 come purely
  from `opts`. The per-task/per-repo config therefore always wins over a queue's
  blanket base, which is what keeps the worktree base and the PR base in sync.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace

  @type opt ::
          {:base_branch, String.t() | nil}
          | {:repo, String.t() | nil}
          | {:workspace_base, String.t() | nil}
  @type opts :: [opt]

  @doc """
  Resolve the integration branch for `task`. See the moduledoc for the chain.

  `opts`:

    * `:base_branch` — explicit top-priority override (nil to skip).
    * `:repo` — the resolved repo name, used to look up the per-repo default.
    * `:workspace_base` — a queue-level base that sits below task/repo config.
  """
  @spec resolve(Issue.t(), opts) :: String.t()
  def resolve(%Issue{} = task, opts \\ []) do
    Keyword.get(opts, :base_branch) ||
      task_target_branch(task) ||
      workspace_repo_target(task, Keyword.get(opts, :repo)) ||
      Keyword.get(opts, :workspace_base) ||
      workspace_base_branch(task) ||
      "main"
  end

  defp task_target_branch(%Issue{target_branch: t}) when is_binary(t) and t != "", do: t
  defp task_target_branch(_), do: nil

  defp workspace_repo_target(_task, nil), do: nil

  defp workspace_repo_target(%Issue{workspace_id: nil}, _repo), do: nil

  defp workspace_repo_target(%Issue{workspace_id: ws_id}, repo) when is_binary(repo) do
    case load_workspace_config(ws_id) do
      %{} = config ->
        repo_target_from_config(
          get_in(config, ["repo_paths", repo]) || get_in(config, ["rig_paths", repo])
        )

      _ ->
        nil
    end
  end

  defp repo_target_from_config(raw), do: RepoConfig.repo_target_from_config(raw)

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
