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

  alias Arbiter.Mergers.{Direct, Github, Gitlab}
  alias Arbiter.Tasks.Workspace

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
  Returns a human-clickable URL for a PR/MR ref in the context of the given workspace.

  Resolves the merger adapter from `workspace.config["merge"]["strategy"]`, seeds
  the adapter's per-process config, and delegates to `link_for/1`. Mirrors
  `Arbiter.Trackers.link_for_workspace/2`.

  Returns an empty string when the strategy is `:direct` (no remote web UI) or
  when `mr_ref` is nil/blank.
  """
  @spec link_for_workspace(Workspace.t() | nil, String.t() | nil) :: String.t()
  def link_for_workspace(nil, _mr_ref), do: ""
  def link_for_workspace(_workspace, nil), do: ""
  def link_for_workspace(_workspace, ""), do: ""

  def link_for_workspace(%Workspace{} = workspace, mr_ref) when is_binary(mr_ref) do
    adapter = for_workspace(workspace)

    case Workspace.merger_strategy(workspace) do
      :github -> Github.with_workspace(workspace, fn -> adapter.link_for(mr_ref) end)
      :gitlab -> Gitlab.with_workspace(workspace, fn -> adapter.link_for(mr_ref) end)
      _ -> adapter.link_for(mr_ref)
    end
  end

  @doc """
  Like `prepare/1`, but also overrides the per-process merger config with a
  repo-specific one, using `repo` (the workspace's `repo_paths` key, e.g.
  `"tonic_device"`) to look up the override.

  For `:github`, overrides `owner`/`repo` from an explicit `"owner/repo"`
  slug — used by `Arbiter.Workflows.PRPatrol` so each per-repo patrol
  instance seeds `list_open/0` with the correct repo, even when the
  workspace's merge config omits `repo` (multi-repo workspace shape where
  repo is derived per-repo from that repo's git remote at open time).

  For `:gitlab`, overrides `project_id` (and any other merge-config key) from
  `config["merge"]["config"]["repos"][repo]` — used when a workspace's repos
  map to different GitLab projects (see `Arbiter.Mergers.Gitlab.Config`
  moduledoc), so the right project is targeted instead of the
  workspace-wide default.

  Callers that run in single-repo / single-GitLab-project workspaces or
  already have the repo set in the workspace config can still use
  `prepare/1` — or pass `nil` as `repo` to this function, which falls back
  to `prepare/1` with no override.
  """
  @spec prepare_with_repo(Workspace.t() | nil, String.t() | nil) :: :ok
  def prepare_with_repo(workspace, nil), do: prepare(workspace)
  def prepare_with_repo(nil, _repo), do: :ok

  def prepare_with_repo(%Workspace{} = workspace, repo) when is_binary(repo) and repo != "" do
    :ok = prepare(workspace)

    case Workspace.merger_strategy(workspace) do
      :github -> Arbiter.Mergers.Github.Config.override_repo(repo)
      :gitlab -> Arbiter.Mergers.Gitlab.Config.override_repo(workspace, repo)
      _ -> :ok
    end

    :ok
  end

  @doc """
  Calls `adapter.open/4`, retrying when the failure is a 409/422 "an open
  PR/MR already exists for this branch" (bd-636thc).

  `Github.open/4` and `Gitlab.open/4` are each already idempotent on their
  own: a look-before-create check, and (on a 409/422) a single reactive
  fallback lookup that adopts the existing open PR/MR instead of failing
  (bd-8rrn9t / bd-8iad6a). That single-shot lookup can still transiently miss
  a PR that is genuinely open — e.g. right after a burst of review-related
  API traffic — exhausting the adapter's own retry and bubbling a raw
  "already exists" error up to the caller even though the PR is sitting
  right there.

  This wraps a bounded retry *around the whole `open/4` call* (not just the
  lookup inside it), giving the adoption lookup another shot end to end.
  Every caller that can open an MR for a task's own branch (`Worker.safe_open/5`
  and `MergeQueue.open_mr_for/4`) routes through this so none of them bypass
  the adoption logic the other already benefits from.

  Any other error (an unrelated 422, a network failure, …) returns
  immediately on the first attempt — this only retries the specific
  "already exists" case.

  bd-28l6im: the original budget (3 attempts, flat 200ms) still let three
  finalize runs strand in one afternoon (bd-8cn795, bd-7opdaf, bd-2wilou) —
  the GitHub-listing miss window this retries around can outlast ~400ms. The
  cost of retrying longer (a few extra seconds, only on a confirmed
  already-open error) is negligible next to the cost of a false failure
  (stranding approved, mergeable work for a human to merge by hand), so the
  default budget backs off exponentially up to ~8.5s total instead of bailing
  after under half a second.
  """
  @default_open_retry_attempts 6
  @default_open_retry_base_delay_ms 300
  @default_open_retry_max_delay_ms 4_000

  @spec open_with_retry(adapter, String.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def open_with_retry(adapter, branch, title, description, opts, retry_opts \\ [])
      when is_atom(adapter) and is_binary(branch) and is_map(opts) do
    attempts = Keyword.get(retry_opts, :attempts, @default_open_retry_attempts)
    base_delay_ms = Keyword.get(retry_opts, :delay_ms, @default_open_retry_base_delay_ms)
    max_delay_ms = Keyword.get(retry_opts, :max_delay_ms, @default_open_retry_max_delay_ms)

    do_open_with_retry(adapter, branch, title, description, opts, attempts, 0, %{
      base_delay_ms: base_delay_ms,
      max_delay_ms: max_delay_ms
    })
  end

  defp do_open_with_retry(adapter, branch, title, description, opts, attempts, attempt, backoff) do
    case adapter.open(branch, title, description, opts) do
      {:ok, mr_ref} = ok when is_binary(mr_ref) ->
        ok

      {:error, reason} = err ->
        if attempts > 1 and already_open_error?(reason) do
          Process.sleep(backoff_delay_ms(attempt, backoff))

          do_open_with_retry(
            adapter,
            branch,
            title,
            description,
            opts,
            attempts - 1,
            attempt + 1,
            backoff
          )
        else
          err
        end

      other ->
        other
    end
  end

  # Exponential backoff (base * 2^attempt), capped at max_delay_ms so a large
  # attempt budget doesn't degenerate into an unbounded wait on later tries.
  defp backoff_delay_ms(attempt, %{base_delay_ms: base, max_delay_ms: max}) do
    min(base * Integer.pow(2, attempt), max)
  end

  @doc """
  Whether `reason` — an adapter error struct returned by `open/4` — represents
  "an open PR/MR already exists for this branch", GitHub's and GitLab's
  phrasing for the same 409/422 condition. Used to decide whether a failed
  `open/4` call is worth retrying (see `open_with_retry/6`).
  """
  @spec already_open_error?(term()) :: boolean()
  def already_open_error?(%{status: status, raw: raw}) when status in [409, 422] do
    already_open_message?(raw)
  end

  def already_open_error?(_), do: false

  defp already_open_message?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, &already_open_message?/1)
  end

  defp already_open_message?(%{"message" => messages}) when is_list(messages) do
    Enum.any?(messages, &already_open_message?/1)
  end

  defp already_open_message?(%{"message" => msg}) when is_binary(msg) do
    already_open_message?(msg)
  end

  defp already_open_message?(msg) when is_binary(msg) do
    String.contains?(String.downcase(msg), "already exists")
  end

  defp already_open_message?(_), do: false
end
