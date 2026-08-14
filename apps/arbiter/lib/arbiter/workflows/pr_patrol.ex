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

      A thread whose LAST comment was posted by us (`Workspace.pr_patrol_our_login/1`,
      falling back to `config["review_patrol"]["our_login"]`) is excluded from
      this count even while still unresolved (bd-45x4yo) — otherwise a thread
      the follow-up protocol forbids resolving (a wrong finding on a bot
      thread, or any human-reviewer thread, which is NEVER auto-resolved)
      stays "unresolved" forever and gets re-filed as an identical follow-up
      on every tick. A new comment from anyone else after ours makes the
      thread actionable again.

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

  # `:transient` (not the default `:permanent`) so a patrol that self-terminates
  # because its repo has no watched work (bd-7tr11p) stays down — a `:permanent`
  # child would be restarted immediately by the DynamicSupervisor, defeating the
  # whole lazy-stop. A genuine crash still exits abnormally and is restarted.
  use GenServer, restart: :transient

  alias Arbiter.GitHub.Limiter
  alias Arbiter.Tasks.Issue
  alias Arbiter.{Mergers, Tasks.Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workflows.{CIFailureFollowUp, PatrolPacing, PatrolRepoScope, ReviewThreadFollowUp}
  require Ash.Query
  require Logger

  @default_interval_ms 60_000

  # Cap the exponential dispatch-failure backoff so a permanently-broken repo
  # eventually retries about once an hour instead of never (bd-49ajyt).
  @max_backoff_ms 60 * 60_000

  # Ceiling for the idle-tick backoff (bd-4brb2j): a repo with no actionable
  # PR for several consecutive ticks stretches its cadence out to at most this,
  # instead of holding a fixed ~1/min poll forever regardless of activity.
  @idle_backoff_ceiling_ms 15 * 60_000

  # A PR stuck in a persistent dispatch-failure streak re-escalates at most
  # this often, so a condition that outlives the original escalation (missed
  # notification, new failure mode) doesn't stay silent forever (bd-dtpjlf).
  @re_escalate_after_ms 60 * 60_000

  defstruct [
    :repo,
    :workspace_id,
    :workspace,
    :interval_ms,
    :timer_ref,
    ticks: 0,
    last_dispatched: %{},
    last_tick_at: nil,
    # Consecutive ticks in a row that found zero actionable PRs — drives the
    # idle backoff in `schedule_next/1` (bd-4brb2j). Reset to 0 the moment a
    # tick dispatches (or would have dispatched, see `maybe_dispatch/3`).
    idle_ticks: 0,
    # PR number => %{count: n, retry_at: DateTime, escalated_at: DateTime | nil}
    # — tracks consecutive follow-up dispatch failures per PR so a persistent
    # failure escalates and then exponential-backs-off, instead of re-filing +
    # re-escalating every tick (bd-49ajyt). `escalated_at` is set ONLY when the
    # coordinator message actually persisted (bd-dtpjlf) — a failed escalation
    # write leaves it as it was, so the very next failure retries the
    # escalation instead of being silently suppressed as "already escalated".
    # Cleared as soon as a dispatch succeeds.
    dispatch_failures: %{},
    # How often (ms) a still-failing PR may re-escalate even after a prior
    # escalation persisted (bd-dtpjlf) — test-only override; production
    # defaults to @re_escalate_after_ms.
    re_escalate_after_ms: @re_escalate_after_ms,
    # Test-only escape hatch merged into the Dispatch.dispatch/2 opts (e.g.
    # `claude_command:` to avoid spawning a real `claude` subprocess).
    # Production never sets this — it always defaults to [].
    dispatch_opts: [],
    # Test-only escape hatch replacing the coordinator-escalation write
    # (defaults to `Message.send_mail/1`). Lets tests simulate the write
    # failing — e.g. a transient DB/PubSub error — so the "only suppress on a
    # persisted escalation" logic (bd-dtpjlf) can be exercised without
    # corrupting a real Ash changeset. Production never sets this.
    escalate_send_fun: nil
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

  @doc """
  Whether `repo` (an `"owner/repo"` slug) has an open fleet-authored PR worth
  watching (bd-7tr11p) — an open `Issue` in the workspace whose `pr_ref` the
  MergeQueue stamped when it opened the PR. Pure DB read, no forge call: the
  repo a task's PR belongs to is recoverable from the `pr_ref` shape (embedded
  `owner/repo#N` for multi-repo, bare `#N` in a single-repo workspace where the
  sole repo is unambiguous — see `PatrolRepoScope`).

  This is the lazy-start gate: the supervisor starts a patrol only for repos
  where this is true, and a running patrol self-terminates once it flips false,
  so an idle repo costs zero background polling.
  """
  @spec has_open_authored_pr?(String.t(), String.t()) :: boolean()
  def has_open_authored_pr?(workspace_id, repo)
      when is_binary(workspace_id) and is_binary(repo) do
    Issue
    |> Ash.Query.filter(
      status != :closed and not is_nil(pr_ref) and workspace_id == ^workspace_id
    )
    |> Ash.read!()
    |> Enum.any?(fn %Issue{pr_ref: ref} -> PatrolRepoScope.ref_matches_repo?(ref, repo) end)
  rescue
    _ -> false
  end

  # ---- GenServer callbacks ----

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    dispatch_opts = Keyword.get(opts, :dispatch_opts, [])
    re_escalate_after_ms = Keyword.get(opts, :re_escalate_after_ms, @re_escalate_after_ms)
    escalate_send_fun = Keyword.get(opts, :escalate_send_fun, &Message.send_mail/1)

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
      dispatch_opts: dispatch_opts,
      re_escalate_after_ms: re_escalate_after_ms,
      escalate_send_fun: escalate_send_fun
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
         last_tick_at: state.last_tick_at,
         idle_ticks: state.idle_ticks
       }, state}

  @impl true
  def handle_info(:tick, state) do
    # Lazy-stop gate (bd-7tr11p): re-check — with a cheap DB read, NOT a forge
    # call — whether this repo still has a fleet-authored PR to watch. When it
    # doesn't, terminate before touching GitHub, so an idle repo's patrol makes
    # zero background requests on the tick that reaps it. `:transient` restart
    # keeps it down. A crash still restarts (abnormal exit).
    if has_open_authored_pr?(state.workspace_id, state.repo) do
      new_state = do_tick(state) |> schedule_next()
      {:noreply, new_state}
    else
      Logger.info(
        "PRPatrol[#{state.repo}]: stopping — no open fleet-authored PR left to watch " <>
          "(workspace #{state.workspace_id})"
      )

      {:stop, :normal, state}
    end
  end

  # Prompt lazy-stop nudge (bd-7tr11p): the PatrolLifecycle subscriber sends
  # this when a watched item in this workspace closes, so the patrol re-checks
  # and terminates immediately rather than waiting for its next (idle-backed-off)
  # scheduled tick. No forge call — pure DB re-check. When work remains, it's a
  # no-op and the existing schedule is left untouched.
  def handle_info(:recheck, state) do
    if has_open_authored_pr?(state.workspace_id, state.repo) do
      {:noreply, state}
    else
      Logger.info(
        "PRPatrol[#{state.repo}]: stopping — last watched item closed " <>
          "(workspace #{state.workspace_id})"
      )

      {:stop, :normal, state}
    end
  end

  # ---- tick logic ----

  # All GitHub traffic this tick issues is background (bd-3p5vqc): the forge
  # polling here must yield to — and never starve — foreground work like a
  # deploy or a PR merge. `with_priority/2` tags the current process for the
  # duration of the tick; the GitHub clients read that ambient class at their
  # request seam. Runs synchronously in the patrol process, so the tag applies.
  defp do_tick(state) do
    Limiter.with_priority(:background, fn -> do_tick_body(state) end)
  end

  defp do_tick_body(state) do
    # Re-fetch the workspace on every tick so config changes (author_logins,
    # merge settings, etc.) take effect immediately without a GenServer restart.
    workspace =
      case Ash.get(Workspace, state.workspace_id) do
        {:ok, ws} -> ws
        _ -> nil
      end

    # Thread state through each PR so per-PR dispatch-failure backoff records
    # (bd-49ajyt) accumulate across the tick and survive into the next one.
    # Also thread a `dispatched?` flag so the idle-backoff streak (bd-4brb2j)
    # only resets when a PR was genuinely actionable this tick.
    {dispatched_state, mr_count, dispatched_count} =
      with %Workspace{} <- workspace,
           adapter when not is_nil(adapter) <- resolve_adapter(workspace),
           true <- function_exported?(adapter, :list_open, 0),
           :ok <- Mergers.prepare_with_repo(workspace, state.repo),
           {:ok, mrs} <- adapter.list_open() do
        base_state = %{state | workspace: workspace}

        # Cheap, DB-only / in-memory gate FIRST (bd-4brb2j): a PR that's backing
        # off, filtered out by the author allowlist, or already has an open
        # follow-up (the steady-state case) needs no forge signal check at all.
        # Only the survivors enter the batched request below — so a steady-state
        # tick where every open PR already has a follow-up filed issues ZERO
        # GraphQL requests, preserving the inter-sweep-trickle→0 win.
        candidates = Enum.filter(mrs, &dispatch_candidate?(&1, base_state))

        # bd-3byp1n: fetch every candidate's three trigger signals in ONE batched
        # forge request, replacing the ~3 calls per PR. Any candidate the batch
        # couldn't resolve (a partial GraphQL failure) or that a non-batch adapter
        # can't cover is simply absent from the map, and actionable_reason/3 falls
        # back to the per-PR path for it.
        signals_by_ref = batch_signals(adapter, candidates)

        {new_state, dispatched_count} =
          Enum.reduce(candidates, {base_state, 0}, fn mr, {acc, n} ->
            case maybe_dispatch(mr, acc, adapter, Map.get(signals_by_ref, mr.ref)) do
              {new_acc, true} -> {new_acc, n + 1}
              {new_acc, false} -> {new_acc, n}
            end
          end)

        {new_state, length(mrs), dispatched_count}
      else
        # On any failure (missing workspace, unsupported adapter, API error),
        # still bump the tick counter so callers can detect the patrol is alive.
        _ -> {%{state | workspace: workspace}, 0, 0}
      end

    idle_ticks = if dispatched_count > 0, do: 0, else: dispatched_state.idle_ticks + 1

    Logger.debug(
      "PRPatrol[#{state.repo}]: tick open_prs=#{mr_count} dispatched=#{dispatched_count} " <>
        "idle_ticks=#{idle_ticks}"
    )

    %{
      dispatched_state
      | ticks: dispatched_state.ticks + 1,
        last_tick_at: DateTime.utc_now(),
        workspace: workspace,
        idle_ticks: idle_ticks
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

  # The cheap, DB-only / in-memory gate deciding whether a PR is even worth a
  # forge signal check this tick. `backing_off?/2`, `author_allowed?/2`, and
  # `deduped?/2` cost no GitHub call, and are run BEFORE the batched signal
  # request (bd-4brb2j): a PR that's backing off, filtered out by the author
  # allowlist, or already has an open follow-up needs no signal check. Previously
  # `deduped?/2` ran LAST, so once a follow-up was already filed for a PR, every
  # subsequent tick still paid the full signal check before discovering there was
  # nothing to do — for every open PR in the repo, every ~60s, forever. That
  # steady per-tick cost is the "inter-sweep trickle" from bd-4brb2j's incident
  # report. Gating here means a PR that already has an open follow-up (the common
  # steady-state case) never enters the batched request at all — so a fully
  # deduped sweep makes zero signal requests.
  defp dispatch_candidate?(%{number: pr_number} = mr, state) do
    not backing_off?(pr_number, state) and
      author_allowed?(mr, state.workspace) and
      not deduped?(pr_number, state.workspace_id)
  end

  # One batched forge request for every candidate's trigger signals (bd-3byp1n),
  # via the adapter's optional `batch_pr_signals/1`. Returns a `%{ref =>
  # pr_signals}` map; a ref absent from it — no batch surface (e.g. `Direct`),
  # empty candidate list (no request made), a total failure, or a per-PR partial
  # failure — falls back to the per-PR path in `actionable_reason/3`. Never
  # raises: a batch error degrades to per-PR, it does not crash the tick.
  defp batch_signals(_adapter, []), do: %{}

  defp batch_signals(adapter, candidates) do
    if function_exported?(adapter, :batch_pr_signals, 1) do
      refs = Enum.map(candidates, & &1.ref)

      case adapter.batch_pr_signals(refs) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    else
      %{}
    end
  end

  # A candidate that passed `dispatch_candidate?/2`: decide if it's actionable —
  # from the pre-fetched batched `signals` when present, else the per-PR fallback
  # path — and dispatch a follow-up if so. Returns `{state, dispatched?}`.
  defp maybe_dispatch(%{ref: mr_ref, number: pr_number} = mr, state, adapter, signals) do
    case actionable_reason(
           adapter,
           mr_ref,
           signals,
           Workspace.pr_patrol_our_login(state.workspace)
         ) do
      {reason, extra_protocol} when is_binary(reason) ->
        task = create_follow_up(mr, state, reason, extra_protocol)
        {dispatch_follow_up(task, pr_number, state), true}

      _ ->
        {state, false}
    end
  end

  # Route the follow-up through the full Dispatch.dispatch/2 pipeline — the
  # same one manual `worker_dispatch` uses — instead of a bare `Worker.start`,
  # which only registers an idle GenServer with no worktree and no subprocess
  # (bd-bi5pn0). A follow-up whose dispatch fails is closed immediately (rather
  # than left open as a zombie `:idle` registration) so `deduped?/2` naturally
  # frees the PR for a retry on the next patrol tick, and an escalation is sent
  # to the coordinator so a persistently-failing repo/quota/worktree condition
  # doesn't retry silently forever. A quota hold is NOT a failure: it means
  # Dispatch.dispatch/2 already enqueued the intent in DispatchQueue for
  # automatic re-drain, and closing the task here would make that later
  # re-dispatch fail at ensure_not_closed.
  defp dispatch_follow_up(task, pr_number, state) do
    # bd-6v2my2: no `provision_worktree: true` override — `:task`'s default
    # (skip branch provisioning) is exactly right here. The worker still gets
    # a real repo checkout to run `gh`/`git` from: `Dispatch.resolve_agent_cwd/3`
    # falls back to a DETACHED inspect checkout (no branch at all) for any
    # `:task` whose worktree was skipped, which is what makes `gh pr checkout
    # <source_pr>` (onto the ORIGINAL PR's branch — see the branch-policy note
    # this description carries) safe to run there: nothing Arbiter provisioned
    # is a branch of its own to begin with.
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
  # escalations on verus-client#3282). Now the failure is recorded per PR:
  # `backing_off?/2` parks the PR for an exponentially-growing window before
  # the next retry, and escalation is gated on whether the coordinator message
  # actually PERSISTED (bd-dtpjlf) — not merely on whether this is the first
  # failure of a streak. A failed escalation write leaves `escalated_at`
  # untouched, so the very next dispatch failure retries it instead of being
  # silently swallowed forever behind "already escalated". Once an escalation
  # does persist, a still-failing PR re-escalates at most every
  # `re_escalate_after_ms`, so a condition that outlives the original message
  # (missed notification, new failure mode) doesn't stay silent indefinitely.
  defp record_dispatch_failure(task, pr_number, state, reason) do
    prior = Map.get(state.dispatch_failures, pr_number)
    count = if prior, do: prior.count + 1, else: 1
    prior_escalated_at = prior && Map.get(prior, :escalated_at)

    due_for_escalation? =
      is_nil(prior_escalated_at) or
        DateTime.diff(DateTime.utc_now(), prior_escalated_at, :millisecond) >=
          state.re_escalate_after_ms

    {escalated_at, escalated_this_time?} =
      if due_for_escalation? do
        case escalate_dispatch_failure(task, state, reason) do
          :ok -> {DateTime.utc_now(), true}
          :error -> {prior_escalated_at, false}
        end
      else
        {prior_escalated_at, false}
      end

    Logger.warning(
      "PRPatrol: dispatch failed for follow-up #{task.id} (PR #{task.source_pr}): " <>
        inspect(reason) <>
        " — closing" <>
        cond do
          escalated_this_time? -> " and escalating"
          due_for_escalation? -> " (escalation failed to persist — will retry next failure)"
          true -> " (backing off, already escalated)"
        end
    )

    Ash.update(
      task,
      %{reason: "PRPatrol dispatch failed: #{inspect(reason)}", close_upstream: false},
      action: :close
    )

    retry_at =
      DateTime.add(DateTime.utc_now(), backoff_ms(count, state.interval_ms), :millisecond)

    %{
      state
      | dispatch_failures:
          Map.put(state.dispatch_failures, pr_number, %{
            count: count,
            retry_at: retry_at,
            escalated_at: escalated_at
          })
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
    base =
      if is_integer(interval_ms) and interval_ms > 0, do: interval_ms, else: @default_interval_ms

    min(base * Integer.pow(2, count - 1), @max_backoff_ms)
  end

  # Returns `:ok` only when the coordinator message actually persisted, `:error`
  # otherwise (bd-dtpjlf) — the caller (`record_dispatch_failure/4`) uses this
  # to decide whether the "already escalated" suppression may kick in. Both a
  # `{:error, _}` return from the write AND a raised exception/exit are loud
  # (`Logger.error`, not `Logger.debug`) — the whole prior incident was this
  # failure mode being invisible.
  defp escalate_dispatch_failure(task, state, reason) do
    attrs = %{
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
    }

    send_fun = state.escalate_send_fun || (&Message.send_mail/1)

    case send_fun.(attrs) do
      {:ok, _message} ->
        :ok

      {:error, error} ->
        Logger.error(
          "PRPatrol.escalate_dispatch_failure/3: coordinator escalation for PR " <>
            "##{task.source_pr} failed to persist: #{inspect(error)}"
        )

        :error
    end
  rescue
    e ->
      Logger.error(
        "PRPatrol.escalate_dispatch_failure/3 raised for PR ##{task.source_pr}: " <>
          Exception.message(e)
      )

      :error
  catch
    :exit, reason ->
      Logger.error(
        "PRPatrol.escalate_dispatch_failure/3 exited for PR ##{task.source_pr}: #{inspect(reason)}"
      )

      :error
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
  #
  # `signals` is the pre-fetched batched `t:Merger.pr_signals/0` for this PR
  # (bd-3byp1n) when the sweep's one batched request covered it, or `nil` to fall
  # back to the per-PR adapter calls. Either source resolves to bit-for-bit the
  # same trigger decision — the batched decomposition reuses the adapter's own
  # per-PR extractors — so the priority order and semantics are unchanged.
  #
  # `our_login` (`Workspace.pr_patrol_our_login/1`) excludes threads we've
  # already answered from the unresolved-thread count (bd-45x4yo) — see
  # `reject_answered_threads/2`.
  defp actionable_reason(adapter, mr_ref, signals, our_login) do
    cond do
      changes_requested_signal?(adapter, mr_ref, signals) ->
        {"at least one review with state=CHANGES_REQUESTED", ""}

      (n = open_review_thread_count(adapter, mr_ref, signals, our_login)) > 0 ->
        {"#{n} unresolved review thread(s) / inline review comment(s)", ""}

      (names = required_check_failure_names(adapter, mr_ref, signals)) != [] ->
        {"#{length(names)} required check(s) failing: #{Enum.join(names, ", ")}",
         CIFailureFollowUp.instructions(names)}

      true ->
        nil
    end
  end

  # CHANGES_REQUESTED: from the batched signals when present, else the per-PR
  # `list_review_feedback/1` fallback.
  defp changes_requested_signal?(_adapter, _mr_ref, %{changes_requested: cr})
       when is_boolean(cr),
       do: cr

  defp changes_requested_signal?(adapter, mr_ref, _no_batch),
    do: changes_requested?(adapter, mr_ref)

  defp changes_requested?(adapter, mr_ref) do
    case adapter.list_review_feedback(mr_ref) do
      {:ok, %{changes_requested: true}} -> true
      _ -> false
    end
  end

  # Count of unresolved review threads that still need a response: from the
  # batched signals when present, else the per-PR `list_open_review_threads/1`
  # fallback. Threads we've already answered (`reject_answered_threads/2`) are
  # excluded regardless of source.
  defp open_review_thread_count(_adapter, _mr_ref, %{review_threads: threads}, our_login)
       when is_list(threads),
       do: threads |> reject_answered_threads(our_login) |> length()

  defp open_review_thread_count(adapter, mr_ref, _no_batch, our_login),
    do: open_review_thread_count(adapter, mr_ref, our_login)

  # The count of unresolved review threads, via the adapter's optional
  # `list_open_review_threads/1` primitive. Adapters without a thread surface
  # (e.g. Direct) don't export it — treat that as zero.
  defp open_review_thread_count(adapter, mr_ref, our_login) do
    if function_exported?(adapter, :list_open_review_threads, 1) do
      case adapter.list_open_review_threads(mr_ref) do
        {:ok, threads} when is_list(threads) ->
          threads |> reject_answered_threads(our_login) |> length()

        _ ->
          0
      end
    else
      0
    end
  end

  # bd-45x4yo: drop threads where WE had the last word. The follow-up
  # protocol has one branch (a wrong finding on a bot thread) that requires
  # replying + escalating WITHOUT resolving the thread, and another rule
  # that's unconditional for human threads ("do NOT resolve"). Either way,
  # "unresolved" then stays true forever even though the thread has already
  # been answered — and PRPatrol's only trigger condition is "unresolved
  # thread exists", so it re-files the identical follow-up every tick. A
  # thread whose most recent comment is ours is done, independent of resolve
  # state; only a genuinely NEW comment after ours (a human pushing back, a
  # bot re-flagging) should make it actionable again.
  #
  # `our_login` is `nil` when unconfigured (no `pr_patrol.our_login` and no
  # `review_patrol.our_login` fallback) — we can't tell our own replies apart
  # from anyone else's, so conservatively treat every unresolved thread as
  # still open (the pre-fix behaviour).
  defp reject_answered_threads(threads, our_login)
       when is_binary(our_login) and our_login != "" do
    Enum.reject(threads, &answered_by_us?(&1, our_login))
  end

  defp reject_answered_threads(threads, _our_login), do: threads

  defp answered_by_us?(thread, our_login) do
    case Map.get(thread, :comments) do
      [_ | _] = comments -> List.last(comments)[:author] == our_login
      _ -> false
    end
  end

  # Names of settled, REQUIRED failing checks: from the batched signals when
  # present, else the per-PR `list_required_check_failures/1` fallback.
  defp required_check_failure_names(_adapter, _mr_ref, %{required_check_failures: checks})
       when is_list(checks),
       do: Enum.map(checks, & &1.name)

  defp required_check_failure_names(adapter, mr_ref, _no_batch),
    do: required_check_failure_names(adapter, mr_ref)

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
  # worker registered `:idle` and never advanced is a zombie (bd-bi5pn0 — the
  # pre-Dispatch.dispatch/2 bare Worker.start bug, or any future dispatch
  # crash between registration and `maybe_start_claude/4` advancing it off
  # `:idle`). A healthy dispatch always makes that advance synchronously,
  # within the SAME `Dispatch.dispatch/2` call that registered the worker —
  # so a worker still `:idle` when a LATER PRPatrol tick observes it can only
  # be one that crashed before advancing, never a normal in-progress run. Left
  # unfiltered, that zombie would permanently blackhole every future PRPatrol
  # trigger on the PR (lt-c9td4r) since it never transitions to :closed on its
  # own.
  defp still_blocking?(%Issue{} = issue) do
    case Worker.whereis(issue.id) do
      nil -> true
      pid when is_pid(pid) -> not zombie_idle?(pid)
    end
  end

  # bd-6v2my2: every follow-up is now `:task` (not :feature/reviewable), so
  # `meta.worktree_path` is nil for every HEALTHY run too, not just a zombie
  # — Dispatch skips branch-worktree provisioning for `:task` by design (its
  # cwd, when it has one, is a detached inspect checkout, never tracked in
  # meta). `:idle` alone is therefore the load-bearing zombie signal here (see
  # `still_blocking?/1`'s reasoning above) — this was already true for plain
  # research/ops `:task` directives before this fix, so no behavior changes,
  # just the discriminator that now matters for every follow-up too.
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
        # bd-6v2my2: :task, NOT a reviewable type. A follow-up's deliverable is
        # replies + resolves against the ORIGINAL PR's review threads — it has
        # no code deliverable of its own. A reviewable type would provision a
        # fresh worktree/branch that `dispatch_follow_up/3`'s
        # `Dispatch.dispatch/2` call turns into a brand-new PR on completion
        # (via the MergeQueue), and its commit gate would fail a run that
        # posts replies/resolves but pushes no commit — exactly the
        # lt-divfvo -> verus_server#3682 duplicate-PR incident. `:task`
        # completes via the notes gate instead: no commit gate, no PR, no
        # merge, and no branch worktree at all — the worker still gets a real
        # (detached, branch-free) repo checkout to run `gh`/`git` from via
        # `Dispatch.resolve_agent_cwd/3`'s existing `:task` fallback. See the
        # branch-policy note this description carries, folded in by
        # `Arbiter.Worker.Dispatch.task_prompt/2` via `source_pr`.
        issue_type: :task,
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

  # Delay until the next tick: the idle-backed-off interval (bd-4brb2j — grows
  # with consecutive idle ticks, capped at @idle_backoff_ceiling_ms), then
  # jittered +/- 15% so N patrols started within milliseconds of each other at
  # boot (18 patrols in ~22ms was the incident's synchronous restart burst)
  # drift apart instead of ticking in lockstep forever.
  defp schedule_next(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    delay =
      state.idle_ticks
      |> PatrolPacing.idle_backoff_ms(state.interval_ms, @idle_backoff_ceiling_ms)
      |> PatrolPacing.jitter()

    ref = Process.send_after(self(), :tick, delay)
    %{state | timer_ref: ref}
  end
end
