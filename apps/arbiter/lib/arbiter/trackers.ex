defmodule Arbiter.Trackers do
  @moduledoc """
  Entry point for external-tracker calls.

  Reads `issue.tracker_type`, resolves the adapter, and delegates. Callers
  should generally use this module rather than reaching into a specific
  adapter — keeps adapter-resolution centralized so per-bead overrides and
  workspace defaults behave consistently.

  ## Resolution rule

  `issue.tracker_type` is an atom in `[:none, :jira, :shortcut, :linear, :github]`. It is
  populated by `Arbiter.Beads.Issue.Changes.InheritTrackerType` from the
  workspace's `config["tracker"]["type"]` at create-time, unless explicitly
  overridden by the caller.

  See `docs/decision-doc.md` section 8.
  """

  alias Arbiter.Beads.Issue
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
  Returns the adapter module for the given bead.

  Raises if the bead's `tracker_type` has no adapter registered (i.e. it's a
  type the codebase knows about but hasn't shipped yet — Jira/Linear/GitHub
  before their phases). Callers that want to handle that gracefully should
  pattern-match on `Issue.tracker_types/0` against `adapters/0`.
  """
  @spec for_bead(Issue.t()) :: adapter
  def for_bead(%Issue{tracker_type: type}), do: for_type(type)

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
  @spec prepare(Issue.t(), Arbiter.Beads.Workspace.t() | nil) :: :ok
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
  def fetch(%Issue{tracker_ref: ref} = issue), do: for_bead(issue).fetch(ref)

  @spec transition(Issue.t(), Tracker.status()) :: :ok | {:error, term()}
  def transition(%Issue{tracker_ref: ref} = issue, status),
    do: for_bead(issue).transition(ref, status)

  @spec update_fields(Issue.t(), map()) :: :ok | {:error, term()}
  def update_fields(%Issue{tracker_ref: ref} = issue, fields),
    do: for_bead(issue).update_fields(ref, fields)

  @spec link_for(Issue.t()) :: String.t()
  def link_for(%Issue{tracker_ref: ref} = issue), do: for_bead(issue).link_for(ref)

  @spec list_transitions(Issue.t()) :: {:ok, [Tracker.status()]} | {:error, term()}
  def list_transitions(%Issue{tracker_ref: ref} = issue),
    do: for_bead(issue).list_transitions(ref)

  @doc """
  Create an upstream item in `type`'s tracker for the given bead-domain attrs.

  Unlike the other wrappers, there's no `Issue` to dispatch from yet —
  callers (the `Issue.create` after-transaction hook, the CLI `claim` flow if
  ever inverted) pass the tracker type explicitly. Workspace is used to seed
  the per-process adapter config exactly like `prepare/2`; pass `nil` to fall
  back to `Application.get_env/3` defaults.
  """
  @spec create(atom(), Arbiter.Beads.Workspace.t() | nil, Tracker.create_attrs()) ::
          {:ok, Tracker.ref()} | {:error, term()}
  def create(type, workspace, attrs) when is_atom(type) and is_map(attrs) do
    prepare_type(type, workspace)
    for_type(type).create(attrs)
  end

  defp prepare_type(:github, workspace), do: GitHub.Config.put_active(workspace)
  defp prepare_type(:jira, workspace), do: Jira.Config.put_active(workspace)
  defp prepare_type(:shortcut, workspace), do: Shortcut.Config.put_active(workspace)
  defp prepare_type(_, _), do: :ok
end
