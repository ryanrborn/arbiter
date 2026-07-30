defmodule Arbiter.Workflows.PatrolLifecycle do
  @moduledoc """
  Subscribes to the `"tasks"` PubSub topic and starts/stops patrols on demand so
  they exist only while their repo has something to watch (bd-7tr11p).

  This is the event-driven half of lazy patrolling. The boot enumeration
  (`PRPatrolSupervisor.start_for_existing_workspaces/0` /
  `ReviewPatrolSupervisor.start_for_existing_workspaces/0`) starts patrols for
  repos that already have committed work; this subscriber keeps them in step
  afterwards, without a server restart:

    * A **new fleet PR** (a task whose `pr_ref` the MergeQueue just stamped) or a
      **new review engagement** (`review_only` task with a `source_pr`) starts
      its repo's patrol.

    * When such an item **closes**, the workspace's patrols are nudged to
      re-check; the one whose last watched item just closed self-terminates.

  ## Why the start path does not re-read the database

  The `:created` / `:updated` lifecycle broadcasts fire inside the action's
  transaction (before commit). A gate that re-read the DB from this separate
  process could race that commit and miss the very item that triggered the
  event. Instead the start path treats the event as proof that watched work
  exists and calls the supervisor's `ensure_started/2`, which resolves the repo
  from the item's ref (no DB read) and starts that repo's patrol optimistically.
  The patrol's own tick/`:recheck` guards (which run well after commit) reconcile
  anything that turns out to be spurious. The **stop** path keys off `:closed`,
  which fires post-commit, so `recheck_all/1`'s DB read sees the closed state.

  Inert unless patrols are configured to auto-start (`auto_start?/0`, off in
  test): it only subscribes when enabled, so it is harmless in the test suite
  while the app's own instance is present in the tree.
  """

  use GenServer

  require Logger

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workflows.{PRPatrolSupervisor, ReviewPatrolSupervisor}

  @topic "tasks"

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled?, PRPatrolSupervisor.auto_start?())
    if enabled?, do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @topic)
    {:ok, %{enabled?: enabled?}}
  end

  @impl true
  def handle_info({:task_lifecycle, event, %Issue{} = issue}, %{enabled?: true} = state) do
    react(event, issue)
    {:noreply, state}
  rescue
    # Never let a lifecycle reaction crash the subscriber — losing the
    # subscription would silently stop all on-demand patrol starts.
    e ->
      Logger.warning("PatrolLifecycle: reaction to #{event} failed: #{Exception.message(e)}")
      {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Classify an issue by the kind of patrol it is watched work for:

    * `:fleet_pr` — a fleet-authored PR (a task carrying a `pr_ref`),
    * `:engagement` — a review engagement (`review_only` with a `source_pr`),
    * `:ignore` — anything else (including a PRPatrol follow-up, which carries a
      `source_pr` but is not `review_only` and has no `pr_ref` of its own).

  `pr_ref` is checked first: a task that has opened its own PR is a fleet PR
  regardless of anything else.
  """
  @spec classify(Issue.t()) :: :fleet_pr | :engagement | :ignore
  def classify(%Issue{pr_ref: ref}) when is_binary(ref) and ref != "", do: :fleet_pr

  def classify(%Issue{review_only: true, source_pr: ref}) when is_binary(ref) and ref != "",
    do: :engagement

  def classify(%Issue{}), do: :ignore

  # ---- internals ----

  defp react(event, issue) do
    case classify(issue) do
      :ignore -> :ok
      kind -> apply_event(kind, event, issue)
    end
  end

  # Open-ish events on an OPEN item start the repo's patrol; a close nudges the
  # workspace's patrols to re-check (the idle one reaps itself). The `status !=
  # :closed` guard matters because a closed fleet-PR task keeps its `pr_ref` (and
  # a closed engagement its `source_pr`), so a later `:updated` on it — e.g. a
  # notes edit — would otherwise resurrect a patrol for a repo whose work is
  # already gone. Other events are no-ops.
  defp apply_event(kind, event, %Issue{status: status} = issue)
       when event in [:created, :updated, :reopened] and status != :closed do
    case load_workspace(issue.workspace_id) do
      %Workspace{} = ws -> ensure_started(kind, ws, ref_for(kind, issue))
      nil -> :ok
    end
  end

  defp apply_event(:fleet_pr, :closed, issue),
    do: PRPatrolSupervisor.recheck_all(issue.workspace_id)

  defp apply_event(:engagement, :closed, issue),
    do: ReviewPatrolSupervisor.recheck_all(issue.workspace_id)

  defp apply_event(_kind, _event, _issue), do: :ok

  defp ensure_started(_kind, _ws, nil), do: :ok
  defp ensure_started(:fleet_pr, ws, ref), do: PRPatrolSupervisor.ensure_started(ws, ref)
  defp ensure_started(:engagement, ws, ref), do: ReviewPatrolSupervisor.ensure_started(ws, ref)

  defp ref_for(:fleet_pr, %Issue{pr_ref: ref}), do: ref
  defp ref_for(:engagement, %Issue{source_pr: ref}), do: ref

  defp load_workspace(workspace_id) when is_binary(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  defp load_workspace(_), do: nil
end
