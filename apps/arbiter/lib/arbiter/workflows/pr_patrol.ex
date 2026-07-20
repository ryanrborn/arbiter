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

    * The PR has at least one **settled, REQUIRED** failing check, via the
      adapter's `list_required_check_failures/1` primitive (bd-ayetel). This
      catches an approved-but-BLOCKED PR whose CI failed silently — no review
      signal fires because nobody requested changes, so without this the PR
      just sits there. Scoped to required checks only (an optional/
      informational check failing must not page anyone) and to settled
      failures only (a required check still running is not yet a failure —
      firing on it would flap every poll until it completes).

  All three signals are read through the provider-agnostic
  `Arbiter.Mergers.Merger` adapter: PRPatrol never sees GitHub GraphQL or
  GitLab discussion shapes, only the normalized `changes_requested` boolean,
  `t:Arbiter.Mergers.Merger.review_thread/0` list, and
  `t:Arbiter.Mergers.Merger.failing_check/0` list. An adapter without a given
  surface (e.g. `Direct`) simply doesn't implement the corresponding
  optional callback; PRPatrol guards each with `function_exported?/3` and
  treats absence as "nothing to report" for that signal.

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
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workflows.{CIFailureFollowUp, ReviewThreadFollowUp}
  require Ash.Query
  require Logger

  @default_interval_ms 60_000

  # Cap the exponential dispatch-failure backoff so a permanently-broken repo
  # eventually retries about once an hour instead of never (bd-49ajyt).
  @max_backoff_ms 60 * 60_000

  defstruct [
    :repo,
    :workspace_id,
    :workspace,
    :interval_ms,
    :timer_ref,
    ticks: 0,
    last_dispatched: %{},
    last_tick_at: nil,
    # PR number => %{count: n, retry_at: DateTime} — tracks consecutive
    # follow-up dispatch failures per PR so a persistent failure escalates
    # ONCE and then exponential-backs-off, instead of re-filing + re-escalating
    # every tick (bd-49ajyt). Cleared as soon as a dispatch succeeds.
    dispatch_failures: %{},
    # Test-only escape hatch merged into the Dispatch.dispatch/2 opts (e.g.
    # `claude_command:` to avoid spawning a real `claude` subprocess).
    # Production never sets this — it always defaults to [].
    dispatch_opts: []
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
    dispatch_opts = Keyword.get(opts, :dispatch_opts, [])

    workspace =
      case Ash.get(Workspace, workspace_id) do
        {:ok, ws} -> ws
        _ -> nil
      end

    state = %__MODULE__{
      repo: repo,
      workspace_id: workspace_id,
      workspace: workspace,
      interval_ms: interval_ms,
      dispatch_opts: dispatch_opts
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

    # Thread state through each PR so per-PR dispatch-failure backoff records
    # (bd-49ajyt) accumulate across the tick and survive into the next one.
    dispatched_state =
      with %Workspace{} <- workspace,
           adapter when not is_nil(adapter) <- resolve_adapter(workspace),
           true <- function_exported?(adapter, :list_open, 0),
           :ok <- Mergers.prepare_with_repo(workspace, state.repo),
           {:ok, mrs} <- adapter.list_open() do
        Enum.reduce(mrs, %{state | workspace: workspace}, fn mr, acc ->
          maybe_dispatch(mr, acc, adapter)
        end)
      else
        # On any failure (missing workspace, unsupported adapter, API error),
        # still bump the tick counter so callers can detect the patrol is alive.
        _ -> %{state | workspace: workspace}
      end

    %{
      dispatched_state
      | ticks: dispatched_state.ticks + 1,
        last_tick_at: DateTime.utc_now(),
        workspace: workspace
    }
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

  # Returns the (possibly updated) patrol state. `backing_off?/2` short-circuits
  # before any forge calls so a PR whose dispatch keeps failing is parked for
  # the backoff window instead of re-filed every tick (bd-49ajyt).
  defp maybe_dispatch(%{ref: mr_ref, number: pr_number} = mr, state, adapter) do
    with false <- backing_off?(pr_number, state),
         true <- author_allowed?(mr, state.workspace),
         {reason, extra_protocol} when is_binary(reason) <- actionable_reason(adapter, mr_ref),
         false <- deduped?(pr_number, state.workspace_id) do
      task = create_follow_up(mr, state, reason, extra_protocol)
      dispatch_follow_up(task, pr_number, state)
    else
      _ -> state
    end
  end

  # Route the follow-up through the full Dispatch.dispatch/2 pipeline — the
  # same one manual `worker_dispatch` uses — instead of a bare `Worker.start`,
  # which only registers an idle GenServer with no worktree and no subprocess
  # (bd-bi5pn0). A follow-up whose dispatch fails is closed immediately (rather
  # than left open as a zombie `:idle` registration) so `deduped?/2` naturally
  # frees the PR for a retry on the next patrol tick, and an escalation is sent
  # to the Admiral so a persistently-failing repo/quota/worktree condition
  # doesn't retry silently forever. A quota hold is NOT a failure: it means
  # Dispatch.dispatch/2 already enqueued the intent in DispatchQueue for
  # automatic re-drain, and closing the task here would make that later
  # re-dispatch fail at ensure_not_closed.
  defp dispatch_follow_up(task, pr_number, state) do
    opts = Keyword.merge([repo: state.repo, start_claude: true], state.dispatch_opts)

    case Dispatch.dispatch(task.id, opts) do
      {:ok, _result} ->
        clear_dispatch_failure(pr_number, state)

      {:error, {:quota_held, _task_id}} ->
        clear_dispatch_failure(pr_number, state)

      {:error, reason} ->
        record_dispatch_failure(task, pr_number, state, reason)
    end
  end

  # A follow-up whose dispatch fails is closed immediately (rather than left as
  # a zombie `:idle` registration). Previously that also freed `deduped?/2` for
  # an immediate refile on the very next tick — a persistent failure therefore
  # re-filed + re-escalated once a minute forever (bd-49ajyt spammed ~25
  # escalations on verus-client#3282). Now the failure is recorded per PR: we
  # escalate only on the FIRST failure of a streak, and `backing_off?/2` parks
  # the PR for an exponentially-growing window before the next retry.
  defp record_dispatch_failure(task, pr_number, state, reason) do
    prior = Map.get(state.dispatch_failures, pr_number)
    count = if prior, do: prior.count + 1, else: 1

    Logger.warning(
      "PRPatrol: dispatch failed for follow-up #{task.id} (PR #{task.source_pr}): " <>
        inspect(reason) <> " — closing" <>
        if(count == 1, do: " and escalating", else: " (backing off, already escalated)")
    )

    if count == 1, do: escalate_dispatch_failure(task, state, reason)

    Ash.update(task, %{reason: "PRPatrol dispatch failed: #{inspect(reason)}"}, action: :close)

    retry_at = DateTime.add(DateTime.utc_now(), backoff_ms(count, state.interval_ms), :millisecond)

    %{
      state
      | dispatch_failures:
          Map.put(state.dispatch_failures, pr_number, %{count: count, retry_at: retry_at})
    }
  end

  defp clear_dispatch_failure(pr_number, state) do
    %{state | dispatch_failures: Map.delete(state.dispatch_failures, pr_number)}
  end

  # True while a PR is inside its post-failure backoff window: the follow-up
  # dispatch failed and the next retry is still in the future. Once the window
  # elapses the PR is eligible for one more retry attempt.
  defp backing_off?(pr_number, state) do
    case Map.get(state.dispatch_failures, pr_number) do
      %{retry_at: %DateTime{} = retry_at} ->
        DateTime.compare(DateTime.utc_now(), retry_at) == :lt

      _ ->
        false
    end
  end

  # Exponential backoff: interval, 2×interval, 4×interval, … capped at
  # @max_backoff_ms. `count` is the consecutive-failure count (>= 1).
  defp backoff_ms(count, interval_ms) do
    base = if is_integer(interval_ms) and interval_ms > 0, do: interval_ms, else: @default_interval_ms
    min(base * Integer.pow(2, count - 1), @max_backoff_ms)
  end

  defp escalate_dispatch_failure(task, state, reason) do
    Message.send_mail(%{
      kind: :escalation,
      to_ref: Message.coordinator_ref(),
      from_ref: task.id,
      workspace_id: state.workspace_id,
      directive_ref: task.id,
      subject: "PRPatrol follow-up dispatch failed for PR ##{task.source_pr}",
      body:
        "PRPatrol auto-filed a follow-up for #{state.repo} PR ##{task.source_pr}, but " <>
          "Dispatch.dispatch/2 failed: #{inspect(reason)}. The follow-up task has been " <>
          "closed so the next patrol tick can retry filing it."
    })
  rescue
    e -> Logger.debug("PRPatrol.escalate_dispatch_failure/3 swallowed: #{Exception.message(e)}")
  catch
    :exit, _ -> :ok
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

  # The reply/resolve/pushback protocol text (bd-76ydsu), folded into the
  # follow-up Issue's description so the dispatched worker doesn't just push
  # a fix silently. Policy flags default to a nil workspace's defaults
  # (resolve bots, leave humans) so a follow-up filed before the workspace
  # loads still carries a sane instruction.
  defp follow_up_protocol(%Workspace{} = workspace) do
    ReviewThreadFollowUp.instructions(%{
      resolve_bot_threads: Workspace.pr_patrol_resolve_bot_threads?(workspace),
      resolve_human_threads: Workspace.pr_patrol_resolve_human_threads?(workspace)
    })
  end

  defp follow_up_protocol(_), do: ReviewThreadFollowUp.instructions(%{})

  # The trigger reason this PR is actionable for (a human-readable string folded
  # into the follow-up task), or nil when nothing needs attention.
  # CHANGES_REQUESTED takes priority; then any unresolved review thread /
  # inline comment; then a settled required-check failure (bd-ayetel) — CI
  # failing silently on an otherwise-clean, approved PR.
  defp actionable_reason(adapter, mr_ref) do
    cond do
      changes_requested?(adapter, mr_ref) ->
        {"at least one review with state=CHANGES_REQUESTED", ""}

      (n = open_review_thread_count(adapter, mr_ref)) > 0 ->
        {"#{n} unresolved review thread(s) / inline review comment(s)", ""}

      (names = required_check_failure_names(adapter, mr_ref)) != [] ->
        {"#{length(names)} required check(s) failing: #{Enum.join(names, ", ")}",
         CIFailureFollowUp.instructions(names)}

      true ->
        nil
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

  # The names of settled, REQUIRED failing checks on this PR, via the
  # adapter's optional `list_required_check_failures/1` primitive (bd-ayetel).
  # Adapters without a required-check surface (e.g. `Direct`) don't export
  # it — treat that as no failures. A transport/API error also yields no
  # failures rather than raising: a patrol tick must not crash the GenServer
  # on a flaky forge API call, and the next tick will re-check anyway.
  defp required_check_failure_names(adapter, mr_ref) do
    if function_exported?(adapter, :list_required_check_failures, 1) do
      case adapter.list_required_check_failures(mr_ref) do
        {:ok, checks} when is_list(checks) -> Enum.map(checks, & &1.name)
        _ -> []
      end
    else
      []
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
    |> Enum.any?(&still_blocking?/1)
  end

  # A non-closed follow-up normally blocks dedup — but a follow-up whose
  # worker registered `:idle` and never provisioned a worktree is a zombie
  # (bd-bi5pn0 — the pre-Dispatch.dispatch/2 bare Worker.start bug, or any
  # future dispatch crash between registration and worktree provisioning).
  # Dispatch.dispatch/2 always provisions the worktree before starting the
  # worker for a reviewable follow-up, so a live worker with no
  # `meta.worktree_path` can only mean a zombie registration, never a normal
  # in-progress run. Left unfiltered, that zombie would permanently blackhole
  # every future PRPatrol trigger on the PR (lt-c9td4r) since it never
  # transitions to :closed on its own.
  defp still_blocking?(%Issue{} = issue) do
    case Worker.whereis(issue.id) do
      nil -> true
      pid when is_pid(pid) -> not zombie_idle?(pid)
    end
  end

  defp zombie_idle?(pid) do
    case Worker.state(pid) do
      %{status: :idle, meta: meta} -> is_nil(meta) or is_nil(Map.get(meta, :worktree_path))
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp create_follow_up(%{number: number, title: title, url: url}, state, reason, extra_protocol) do
    issue_title = "PR ##{number}: #{title} needs follow-up"

    description =
      """
      Auto-filed by PRPatrol against #{state.repo}.

      Trigger: #{reason}.

      Original PR: #{url}

      #{follow_up_protocol(state.workspace)}
      #{extra_protocol}
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
