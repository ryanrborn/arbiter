defmodule Arbiter.Mergers do
  @moduledoc """
  Entry point for merge-strategy calls.

  Reads a workspace's `config["merge"]["strategy"]`, resolves the adapter, and
  hands back the module. Callers should generally resolve through this module
  rather than referencing a specific adapter directly — keeps adapter
  resolution centralized so workspace defaults behave consistently.

  Mirrors `Arbiter.Trackers`. The `Direct`, `GitLab`, and `GitHub` adapters all ship now.

  ## Resolution rule

  The strategy is an atom resolved from the workspace via
  `Arbiter.Tasks.Workspace.merger_strategy/1` (which reads
  `config["merge"]["strategy"]`, falling back to `:direct`).
  """

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Mergers.{Direct, Github, Gitlab}

  @type adapter :: module()

  @adapters %{
    direct: Direct,
    gitlab: Gitlab,
    github: Github
  }

  @doc """
  Returns the adapter module for the given workspace.

  Resolves `Workspace.merger_strategy/1` and looks it up in `adapters/0`.
  """
  @spec for_workspace(Workspace.t()) :: adapter
  def for_workspace(%Workspace{} = workspace),
    do: for_strategy(Workspace.merger_strategy(workspace))

  @doc """
  Returns the adapter module for a merger strategy atom.

  Raises if the strategy has no adapter registered (i.e. a strategy the
  codebase knows about but hasn't shipped yet).
  """
  @spec for_strategy(atom()) :: adapter
  def for_strategy(strategy) when is_atom(strategy) do
    case Map.fetch(@adapters, strategy) do
      {:ok, mod} ->
        mod

      :error ->
        raise ArgumentError,
              "no merger adapter registered for #{inspect(strategy)} " <>
                "(registered: #{inspect(Map.keys(@adapters))})"
    end
  end

  @doc "Returns the map of strategy → adapter module."
  @spec adapters() :: %{atom() => adapter}
  def adapters, do: @adapters

  @doc """
  Prepare the current process to make adapter calls for `workspace`.

  Some adapters resolve their backend config from the process dictionary
  (the `GitLab` and `GitHub` adapters read host/owner/repo/token via
  `Arbiter.Mergers.Gitlab.Config` / `Arbiter.Mergers.Github.Config`, exactly
  as `Arbiter.Trackers.Jira` does). A long-lived poller such as
  `Arbiter.Worker.Watchdog` runs in its own process, so it must seed that
  config before calling `get/1` or `merge/1`.

  This keeps the adapter-specific coupling in one place: callers
  (`Arbiter.Worker`, `Arbiter.Worker.Watchdog`) just call `prepare/1` and stay
  adapter-agnostic. A no-op for adapters that carry no per-process config
  (e.g. `Direct`) and for a `nil` workspace.
  """
  @spec prepare(Workspace.t() | nil) :: :ok
  def prepare(nil), do: :ok

  def prepare(%Workspace{} = workspace) do
    case Workspace.merger_strategy(workspace) do
      :gitlab -> Arbiter.Mergers.Gitlab.Config.put_active(workspace)
      :github -> Arbiter.Mergers.Github.Config.put_active(workspace)
      _ -> :ok
    end

    :ok
  end

  @doc """
  Like `prepare/1`, but also overrides the per-process `owner`/`repo` from an
  explicit `"owner/repo"` slug.

  Used by `Arbiter.Workflows.PRPatrol` so each per-repo patrol instance seeds
  `list_open/0` with the correct repo, even when the workspace's merge config
  omits `repo` (multi-repo workspace shape where repo is derived per-rig from
  the rig's git remote at open time).

  Callers that run in single-repo workspaces or already have the repo set in
  the workspace config can still use `prepare/1` — or pass `nil` as `repo` to
  this function, which falls back to `prepare/1` with no override.
  """
  @spec prepare_with_repo(Workspace.t() | nil, String.t() | nil) :: :ok
  def prepare_with_repo(workspace, nil), do: prepare(workspace)
  def prepare_with_repo(nil, _repo), do: :ok

  def prepare_with_repo(%Workspace{} = workspace, repo) when is_binary(repo) and repo != "" do
    :ok = prepare(workspace)

    if Workspace.merger_strategy(workspace) == :github do
      Arbiter.Mergers.Github.Config.override_repo(repo)
    end

    :ok
  end
end
