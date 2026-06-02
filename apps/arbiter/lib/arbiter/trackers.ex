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
end
