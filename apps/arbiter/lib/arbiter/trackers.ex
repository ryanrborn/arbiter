defmodule Arbiter.Trackers do
  @moduledoc """
  Entry point for external-tracker calls.

  Reads `issue.tracker_type`, resolves the adapter, and delegates. Callers
  should generally use this module rather than reaching into a specific
  adapter — keeps adapter-resolution centralized so per-task overrides and
  workspace defaults behave consistently.

  ## Resolution rule

  `issue.tracker_type` is an atom in `[:none, :jira, :shortcut, :linear, :github]`. It is
  populated by `Arbiter.Tasks.Issue.Changes.InheritTrackerType` from the
  workspace's `config["tracker"]["type"]` at create-time, unless explicitly
  overridden by the caller.

  See `docs/decision-doc.md` section 8.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Trackers.{GitHub, Jira, None, Shortcut, Tracker}

  @type adapter :: module()

  @adapters %{
    none: None,
    jira: Jira,
    shortcut: Shortcut,
    github: GitHub
    # :linear wired up in Phase 5
  }

  @doc """
  Returns the adapter module for the given task.

  Raises if the task's `tracker_type` has no adapter registered (i.e. it's a
  type the codebase knows about but hasn't shipped yet — Jira/Linear/GitHub
  before their phases). Callers that want to handle that gracefully should
  pattern-match on `Issue.tracker_types/0` against `adapters/0`.
  """
  @spec for_task(Issue.t()) :: adapter
  def for_task(%Issue{tracker_type: type}), do: for_type(type)

  @spec for_type(atom()) :: adapter
  def for_type(type) when is_atom(type) do
    case Map.fetch(@adapters, type) do
      {:ok, mod} ->
        mod

      :error ->
        raise ArgumentError,
              "no tracker adapter registered for #{inspect(type)} " <>
                "(registered: #{inspect(Map.keys(@adapters))})"
    end
  end

  @doc "Returns the map of tracker_type → adapter module."
  @spec adapters() :: %{atom() => adapter}
  def adapters, do: @adapters

  @doc """
  Prepare the current process to make adapter calls for `issue` against
  `workspace`.

  The tracker adapters resolve their backend config (owner/repo/credentials for
  GitHub, host/project for Jira, …) from the process dictionary via their
  `Config.put_active/1`. A long-lived process — or an Ash action running outside
  any request lifecycle, such as `:close` from the CLI — must seed that config
  before calling `transition/2`. This keeps the adapter-specific coupling in one
  place; callers stay tracker-agnostic.

  Dispatch is on the *issue's* `tracker_type` (the adapter that will be used),
  while the config payload comes from the *workspace*. A `nil` workspace clears
  the per-process config, letting the adapter fall back to its
  `Application.get_env/3` default. A no-op for `:none`. Mirrors
  `Arbiter.Mergers.prepare/1`.
  """
  @spec prepare(Issue.t(), Arbiter.Tasks.Workspace.t() | nil) :: :ok
  def prepare(%Issue{tracker_type: type}, workspace) do
    case type do
      :github -> GitHub.Config.put_active(workspace)
      :jira -> Jira.Config.put_active(workspace)
      :shortcut -> Shortcut.Config.put_active(workspace)
      _ -> :ok
    end

    :ok
  end

  # ---- Delegating wrappers ----
  # Thin pass-throughs so callers don't need to manually resolve+invoke.

  @spec fetch(Issue.t()) :: {:ok, map()} | {:error, term()}
  def fetch(%Issue{tracker_ref: ref} = issue), do: for_task(issue).fetch(ref)

  @spec transition(Issue.t(), Tracker.status()) :: :ok | {:error, term()}
  def transition(%Issue{tracker_ref: ref} = issue, status),
    do: for_task(issue).transition(ref, status)

  @spec update_fields(Issue.t(), map()) :: :ok | {:error, term()}
  def update_fields(%Issue{tracker_ref: ref} = issue, fields),
    do: for_task(issue).update_fields(ref, fields)

  @spec link_for(Issue.t()) :: String.t()
  def link_for(%Issue{tracker_ref: ref} = issue), do: for_task(issue).link_for(ref)

  @doc """
  Attach a remote link (typically the implementing PR/MR) to the task's
  tracked item so the ticket references the code.

  Resolves the adapter from the task's `tracker_type` and dispatches to its
  optional `add_remote_link/3`. Adapters that don't implement it — or tasks
  with no `tracker_ref` — return `{:error, :not_supported}`, which callers
  treat as "nothing to link" rather than a hard failure. Callers must have
  seeded the adapter's per-process config first (see `prepare/2`).
  """
  @spec add_remote_link(Issue.t(), String.t(), String.t()) ::
          :ok | {:error, :not_supported} | {:error, term()}
  def add_remote_link(%Issue{tracker_ref: ref} = issue, url, title)
      when is_binary(url) and is_binary(title) do
    cond do
      not is_binary(ref) or ref == "" ->
        {:error, :not_supported}

      true ->
        adapter = for_task(issue)

        if function_exported?(adapter, :add_remote_link, 3) do
          adapter.add_remote_link(ref, url, title)
        else
          {:error, :not_supported}
        end
    end
  end

  @doc """
  Post a comment on the task's tracked item (typically the PR URL at PR-open).

  Resolves the adapter from the task's `tracker_type` and dispatches to its
  optional `add_comment/2`. Adapters that don't implement it — or tasks with no
  `tracker_ref` — return `{:error, :not_supported}`, which callers treat as
  "nothing to comment" rather than a hard failure. Callers must have seeded the
  adapter's per-process config first (see `prepare/2`).
  """
  @spec add_comment(Issue.t(), String.t()) ::
          :ok | {:error, :not_supported} | {:error, term()}
  def add_comment(%Issue{tracker_ref: ref} = issue, body) when is_binary(body) do
    cond do
      not is_binary(ref) or ref == "" ->
        {:error, :not_supported}

      true ->
        adapter = for_task(issue)

        if function_exported?(adapter, :add_comment, 2) do
          adapter.add_comment(ref, body)
        else
          {:error, :not_supported}
        end
    end
  end

  @spec list_transitions(Issue.t()) :: {:ok, [Tracker.status()]} | {:error, term()}
  def list_transitions(%Issue{tracker_ref: ref} = issue),
    do: for_task(issue).list_transitions(ref)

  @doc """
  Lists open items from the workspace's configured tracker — used by
  `arb list --tracker` to surface upstream backlog alongside local tasks.

  Resolves the adapter from `workspace.config["tracker"]["type"]`, seeds the
  adapter's per-process config (same dance as `prepare/2`), and delegates.
  Adapters that don't have a notion of a backlog return
  `{:error, :not_supported}`, which callers should treat as "render local
  tasks only" rather than a hard failure.
  """
  @spec list_open(Arbiter.Tasks.Workspace.t(), keyword()) ::
          {:ok, [Tracker.summary()]} | {:error, :not_supported} | {:error, term()}
  def list_open(%Arbiter.Tasks.Workspace{} = workspace, opts \\ []) do
    type = workspace_tracker_type(workspace)
    adapter = adapter_for_workspace_type(type)

    with_workspace(type, workspace, fn -> adapter.list_open(opts) end)
  end

  @doc """
  Create a new upstream issue in the workspace's configured tracker.

  Used by the `Issue.create` after-transaction hook so `arb create` can mirror
  a new task into the workspace's tracker. Resolves the adapter from
  `workspace.config["tracker"]["type"]`, seeds the adapter's per-process
  config (same dance as `prepare/2`), and dispatches to `create/1`. Workspaces
  without a tracker (`type == :none`) or whose tracker doesn't support
  outbound create return `{:error, :not_supported}` and callers should treat
  that as "skip — local-only task".
  """
  @spec create_for_workspace(Arbiter.Tasks.Workspace.t(), Tracker.create_attrs()) ::
          {:ok, Tracker.ref()} | {:error, :not_supported} | {:error, term()}
  def create_for_workspace(%Arbiter.Tasks.Workspace{} = workspace, attrs) when is_map(attrs) do
    type = workspace_tracker_type(workspace)
    adapter = adapter_for_workspace_type(type)

    with_workspace(type, workspace, fn -> adapter.create(attrs) end)
  end

  @doc """
  Returns a human-clickable URL for a tracker ref in the context of the given workspace.

  Resolves the adapter from `workspace.config["tracker"]["type"]`, seeds the
  adapter's per-process config, and delegates to `link_for/1`. Used by the
  `--ticket-only` path so callers can print the URL without a local task.
  """
  @spec link_for_workspace(Arbiter.Tasks.Workspace.t(), Tracker.ref()) :: String.t()
  def link_for_workspace(%Arbiter.Tasks.Workspace{} = workspace, ref) when is_binary(ref) do
    type = workspace_tracker_type(workspace)
    adapter = adapter_for_workspace_type(type)

    with_workspace(type, workspace, fn -> adapter.link_for(ref) end)
  end

  @doc """
  Returns the tracker type atom for a workspace's configured tracker.

  Exposed so callers (e.g. the ticket-only controller) can check whether a
  workspace has a real tracker before attempting an outbound create.
  """
  @spec workspace_type(Arbiter.Tasks.Workspace.t()) :: atom()
  def workspace_type(%Arbiter.Tasks.Workspace{} = workspace),
    do: workspace_tracker_type(workspace)

  @doc """
  Searches open issues in the workspace's configured tracker for issues whose
  title matches `title` (case-insensitive exact match).

  Used by `arb create` to detect upstream duplicates before creating a new
  task. Adapters that do not implement `search_by_title/1` — or workspaces
  without a tracker — return `{:error, :not_supported}`, which callers should
  treat as "skip check".
  """
  @spec search_by_title_for_workspace(Arbiter.Tasks.Workspace.t(), String.t()) ::
          {:ok, [map()]} | {:error, :not_supported} | {:error, term()}
  def search_by_title_for_workspace(%Arbiter.Tasks.Workspace{} = workspace, title)
      when is_binary(title) do
    type = workspace_tracker_type(workspace)
    adapter = adapter_for_workspace_type(type)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :search_by_title, 1) do
      with_workspace(type, workspace, fn -> adapter.search_by_title(title) end)
    else
      {:error, :not_supported}
    end
  end

  @doc """
  Returns the adapter module for the workspace's configured tracker.

  Falls back to `None` for unknown types (e.g. `:linear` before its adapter
  lands), mirroring `adapter_for_workspace_type/1`.
  """
  @spec for_workspace(Arbiter.Tasks.Workspace.t()) :: adapter
  def for_workspace(%Arbiter.Tasks.Workspace{} = workspace),
    do: adapter_for_workspace_type(workspace_tracker_type(workspace))

  @doc """
  Seed the per-process adapter config for `workspace`, run `fun`, and restore
  the previous state. The `type` arg lets callers avoid re-computing the
  tracker type when they already have it.

  Mirrors the adapter-specific `with_workspace/2` helpers — callers that want
  to stay tracker-agnostic use this instead of reaching into a specific adapter.
  """
  @spec with_workspace(atom(), Arbiter.Tasks.Workspace.t(), (-> result)) :: result
        when result: any()
  def with_workspace(type, workspace, fun), do: do_with_workspace(type, workspace, fun)

  defp workspace_tracker_type(%Arbiter.Tasks.Workspace{config: config}) do
    case get_in(config || %{}, ["tracker", "type"]) do
      type when is_binary(type) ->
        try do
          String.to_existing_atom(type)
        rescue
          ArgumentError -> :none
        end

      _ ->
        :none
    end
  end

  # Unlike for_task/1, the workspace-tracker-type may name an adapter we don't
  # have shipped (e.g. `:linear`). Fall back to None rather than raising —
  # the caller is asking us to list, and "no backend yet" is naturally
  # :not_supported (which is what None returns).
  defp adapter_for_workspace_type(type) do
    case Map.fetch(@adapters, type) do
      {:ok, adapter} -> adapter
      :error -> None
    end
  end

  defp do_with_workspace(:github, workspace, fun), do: GitHub.with_workspace(workspace, fun)
  defp do_with_workspace(:jira, workspace, fun), do: Jira.with_workspace(workspace, fun)
  defp do_with_workspace(:shortcut, workspace, fun), do: Shortcut.with_workspace(workspace, fun)
  defp do_with_workspace(_, _workspace, fun), do: fun.()
end
