defmodule Arbiter.Workflows.PRPatrol do
  @moduledoc """
  Per-repo GenServer that polls open PRs and dispatches follow-up workers
  when reviews need attention. Replaces the Go GT `mol-pr-feedback-patrol`
  cron loop.

  ## Triggers

  A PR is considered "actionable" when any of these is true:

    * Any review on the PR has `state == "CHANGES_REQUESTED"`
      (highest-priority signal), via `list_review_feedback/1`.

    * The PR has at least one **unresolved review thread / inline review
      comment**, via the adapter's `list_open_review_threads/1` primitive
      (bd-823q7e). This catches a `COMMENTED` review that leaves inline
      comments without requesting changes — e.g. an automated reviewer — which
      the CHANGES_REQUESTED signal alone misses.

  Both signals are read through the provider-agnostic `Arbiter.Mergers.Merger`
  adapter: PRPatrol never sees GitHub GraphQL or GitLab discussion shapes, only
  the normalized `changes_requested` boolean and `t:Arbiter.Mergers.Merger.review_thread/0`
  list. An adapter without a thread surface (e.g. `Direct`) simply doesn't
  implement `list_open_review_threads/1`; PRPatrol guards with
  `function_exported?/3` and treats its absence as "no open review feedback".

  Future triggers (deferred to a follow-up task):

    * `statusCheckRollup` contains FAILURE — needs the GraphQL API or a
      separate `check-runs` fetch keyed off the PR head SHA.

  ## Dedup

  Each follow-up task records the PR it was filed against in the dedicated
  `source_pr` field (`to_string(pr_number)`), scoped to the patrol's workspace.
  Before dispatching, PRPatrol queries `Issue` for open tasks with that
  combination — if one exists, the PR has already been handled this cycle.

  `source_pr` is deliberately NOT `tracker_ref`: `tracker_ref` is the field
  `Arbiter.Trackers.Sync` treats as a writable tracker item to push task
  lifecycle status onto, and a PR number is not a workable tracker issue —
  transitioning a *merged PR* on dispatch fails with `Validation Failed` and
  escalates (bd-ci2jl2). A follow-up therefore carries `tracker_type: :none`
  (no lifecycle write-back) and links its source PR via `source_pr` instead.

  ## Lifecycle

  Not in `Application.children`. Started manually per-workspace:

      Arbiter.Workflows.PRPatrol.start_link(
        repo: "leo-technologies-llc/verus_server",
        workspace_id: ws.id,
        interval_ms: 60_000
      )

  Test convenience: `tick/1` forces a synchronous patrol cycle without
  waiting for the next interval.
  """

  use GenServer

  alias Arbiter.Tasks.Issue
  alias Arbiter.{Mergers, Tasks.Workspace}
  alias Arbiter.Worker
  require Ash.Query

  @default_interval_ms 60_000

  defstruct [
    :repo,
    :workspace_id,
    :workspace,
    :interval_ms,
    :timer_ref,
    ticks: 0,
    last_dispatched: %{},
    last_tick_at: nil
  ]

  # ---- public API ----

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Synchronously force a patrol cycle. Returns :ok after the cycle completes."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "Snapshot of internal state."
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  # ---- GenServer callbacks ----

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    workspace =
      case Ash.get(Workspace, workspace_id) do
        {:ok, ws} -> ws
        _ -> nil
      end

    state = %__MODULE__{
      repo: repo,
      workspace_id: workspace_id,
      workspace: workspace,
      interval_ms: interval_ms
    }

    {:ok, schedule_next(state)}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    new_state = do_tick(state)
    {:reply, :ok, new_state}
  end

  def handle_call(:state, _from, state),
    do:
      {:reply,
       %{
         repo: state.repo,
         workspace_id: state.workspace_id,
         interval_ms: state.interval_ms,
         ticks: state.ticks,
         last_dispatched: state.last_dispatched,
         last_tick_at: state.last_tick_at
       }, state}

  @impl true
  def handle_info(:tick, state) do
    new_state = do_tick(state) |> schedule_next()
    {:noreply, new_state}
  end

  # ---- tick logic ----

  defp do_tick(state) do
    # Re-fetch the workspace on every tick so config changes (author_logins,
    # merge settings, etc.) take effect immediately without a GenServer restart.
    workspace =
      case Ash.get(Workspace, state.workspace_id) do
        {:ok, ws} -> ws
        _ -> nil
      end

    result =
      with %Workspace{} <- workspace,
           adapter when not is_nil(adapter) <- resolve_adapter(workspace),
           true <- function_exported?(adapter, :list_open, 0),
           :ok <- Mergers.prepare_with_repo(workspace, state.repo),
           {:ok, mrs} <- adapter.list_open() do
        Enum.each(mrs, &maybe_dispatch(&1, %{state | workspace: workspace}, adapter))
        :ok
      else
        # On any failure (missing workspace, unsupported adapter, API error),
        # still bump the tick counter so callers can detect the patrol is alive.
        _ -> :noop
      end

    _ = result
    %{state | ticks: state.ticks + 1, last_tick_at: DateTime.utc_now(), workspace: workspace}
  end

  defp resolve_adapter(workspace) do
    adapter = Mergers.for_workspace(workspace)

    # Force the adapter module to load before any `function_exported?/3` guard
    # inspects it (`:list_open` in `do_tick/1`, `:list_open_review_threads` in
    # `open_review_thread_count/2`). `function_exported?/3` returns false for a
    # module that has not been loaded yet and does NOT trigger loading — so under
    # interactive code loading (as in `mix test`) the guard would spuriously fail
    # whenever no prior call had loaded the adapter, no-op the whole tick, and
    # dispatch nothing. Releases run in embedded mode (all modules preloaded),
    # which masks this, but the guard must not depend on prior load order.
    # See bd-1hn1qw.
    Code.ensure_loaded(adapter)
    adapter
  rescue
    ArgumentError -> nil
  end

  defp maybe_dispatch(%{ref: mr_ref, number: pr_number} = mr, state, adapter) do
    with true <- author_allowed?(mr, state.workspace),
         reason when is_binary(reason) <- actionable_reason(adapter, mr_ref),
         false <- deduped?(pr_number, state.workspace_id) do
      task = create_follow_up(mr, state, reason)
      _ = Worker.start(task_id: task.id, repo: state.repo, workspace_id: state.workspace_id)
      :ok
    else
      _ -> :noop
    end
  end

  # When the workspace sets `config["pr_patrol"]["author_logins"]`, only patrol
  # PRs authored by one of those logins — so a workspace can scope PRPatrol to
  # its operator's own PRs instead of every open PR in the repo. An empty/unset
  # allowlist patrols all PRs (the backward-compatible default). When an
  # allowlist IS set but the MR carries no resolvable author, the PR is skipped
  # (fail-closed: better to under-patrol than to file follow-ups we can't
  # attribute to an allowed author).
  defp author_allowed?(mr, %Workspace{} = workspace) do
    case Workspace.pr_patrol_author_logins(workspace) do
      [] -> true
      logins -> Map.get(mr, :author) in logins
    end
  end

  defp author_allowed?(_mr, _workspace), do: true

  # The trigger reason this PR is actionable for (a human-readable string folded
  # into the follow-up task), or nil when nothing needs attention. CHANGES_REQUESTED
  # takes priority; otherwise any unresolved review thread / inline comment fires.
  defp actionable_reason(adapter, mr_ref) do
    cond do
      changes_requested?(adapter, mr_ref) ->
        "at least one review with state=CHANGES_REQUESTED"

      true ->
        case open_review_thread_count(adapter, mr_ref) do
          n when n > 0 ->
            "#{n} unresolved review thread(s) / inline review comment(s)"

          _ ->
            nil
        end
    end
  end

  defp changes_requested?(adapter, mr_ref) do
    case adapter.list_review_feedback(mr_ref) do
      {:ok, %{changes_requested: true}} -> true
      _ -> false
    end
  end

  # The count of unresolved review threads, via the adapter's optional
  # `list_open_review_threads/1` primitive. Adapters without a thread surface
  # (e.g. Direct) don't export it — treat that as zero.
  defp open_review_thread_count(adapter, mr_ref) do
    if function_exported?(adapter, :list_open_review_threads, 1) do
      case adapter.list_open_review_threads(mr_ref) do
        {:ok, threads} when is_list(threads) -> length(threads)
        _ -> 0
      end
    else
      0
    end
  end

  defp deduped?(pr_number, workspace_id) do
    ref = to_string(pr_number)

    # Match either the current format (source_pr) or the legacy format that used
    # tracker_type: :github + tracker_ref: <pr#> before source_pr was introduced.
    # Without the legacy arm, old-format follow-ups are invisible to dedup and a
    # duplicate gets filed on the next patrol tick (bd-5g6rw4).
    Issue
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and
        status != :closed and
        (source_pr == ^ref or (tracker_type == :github and tracker_ref == ^ref))
    )
    |> Ash.read!()
    |> Enum.any?()
  end

  defp create_follow_up(%{number: number, title: title, url: url}, state, reason) do
    issue_title = "PR ##{number}: #{title} needs follow-up"

    description =
      """
      Auto-filed by PRPatrol against #{state.repo}.

      Trigger: #{reason}.

      Original PR: #{url}
      """

    {:ok, task} =
      Ash.create(Issue, %{
        title: issue_title,
        description: description,
        # A reviewable type (NOT :task): a follow-up addresses PR review
        # feedback with a real code change, so it must take the normal
        # worktree → commit → review → PR path. `:task` would skip worktree
        # provisioning (dispatch.ex) and dispatch would 500 with
        # :missing_worktree (bd-ci2jl2). The fresh worktree is cut from the
        # repo's default branch, which is correct for a follow-up to a PR
        # whose own branch was cleaned up on merge.
        issue_type: :feature,
        priority: 2,
        # No tracker lifecycle write-back: a PR number is not a workable
        # tracker issue (transitioning a merged PR on dispatch fails with
        # Validation Failed). The source PR is linked via `source_pr` for
        # dedup instead — see the module's Dedup section (bd-ci2jl2).
        tracker_type: :none,
        source_pr: to_string(number),
        workspace_id: state.workspace_id
      })

    task
  end

  defp schedule_next(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :tick, state.interval_ms)
    %{state | timer_ref: ref}
  end
end
