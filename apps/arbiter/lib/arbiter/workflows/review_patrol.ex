defmodule Arbiter.Workflows.ReviewPatrol do
  @moduledoc """
  Per-(workspace, repo) GenServer that polls **open review engagements** and
  drives their lifecycle. The reviewer-side mirror of `PRPatrol`: where PRPatrol
  watches PRs the fleet *authored* and files follow-up work, ReviewPatrol watches
  PRs the fleet is *reviewing* (long-lived `review_only` engagements) and keeps
  the engagement in step with the upstream PR.

  ## What is an "engagement"

  A review engagement is an `Issue` with `review_only == true` and a `source_pr`
  set — a long-lived task created when the fleet is asked to review someone
  else's PR (bd-cw3w9p made these tasks long-lived: the Driver / MergeQueue no
  longer auto-close them after the first verdict, so ReviewPatrol owns closure).

  ## Query / dedup

  Each tick selects `review_only == true and not is_nil(source_pr) and
  status != :closed`, scoped to the patrol's `workspace_id`. The `review_only`
  predicate is the hard boundary that keeps ReviewPatrol from colliding with
  PRPatrol's author-side follow-ups: those are filed with `review_only == false`
  (they take the normal implementation path), so they are never selected here.

  ## Per-engagement action

  For each engagement, `adapter.get(source_pr)`:

    * `:merged` or `:closed` → **terminate the engagement**: close the task via
      the `:close` action. Because the task is `review_only`, `SyncTracker`
      short-circuits and the close fires ZERO tracker writes (bd-6xaaam). The
      query already excludes `:closed` tasks, so re-ticking an already-terminated
      engagement is a no-op (idempotent).

    * `:open` with `last_reviewed_sha` **unset** → record the PR head SHA (first
      sighting). No review is dispatched here — the first pass is `arb review` at
      engagement-creation time.

    * `:open` with `last_reviewed_sha` **set** and `head_sha` **advanced** → a
      candidate for new-commit re-review, gated by the spam guards below (task D).

    * any adapter error → no-op for that engagement (logged); the tick still
      completes and bumps the counter so callers can see the patrol is alive.

  ## New-commit re-review (bd-f3fg22)

  When a PR head advances past `last_reviewed_sha`, ReviewPatrol re-reviews — but
  only under a stack of guards that keep it from spamming the PR:

    * **Automation mode** — the engagement's `review_automation` (task B) decides
      *whether* we re-review at all: `:auto` re-reviews automatically; `:flag`
      only surfaces the new commits as a mailbox flag. A bare SHA advance is not a
      trigger on its own.

    * **Relevance gate** — the new commits must touch a file we previously flagged
      (`posted_findings`). A push that touches only unrelated files is not our
      concern and does NOT trigger a re-review.

    * **Sticky approval** (bd-4po0nv) — once the operator identity holds a
      CURRENT approving review on the PR (`adapter.self_approved?/1`, the same
      optional capability the external-review dispatch guard uses, bd-7z5pi5),
      a push does NOT trigger a re-review unless it *invalidates* that
      approval. Invalidating means the new diff touches at least one file that
      is neither a doc file nor a test file with a substantive (non-
      formatting-only) change — see `invalidating_diff?/1`. A doc-only,
      test-only, formatting-only, or rebase/merge-only push (nothing
      substantive in the new diff) is declined: the decision is appended to
      the engagement's `notes` (so "approval is sticky" reads as a deliberate
      decision rather than ReviewPatrol going quiet) and `last_reviewed_sha`
      still advances, so the same push is never re-evaluated. Adapters without
      `self_approved?/1`, or a call that errors, fail OPEN — this gate never
      applies and behavior is unchanged from before this feature. Colleagues
      can still get a response after an approval stands via the author-reply
      path below (no new commits required).

    * **Debounce** — at most one re-review per configurable window
      (`config["review_patrol"]["debounce_ms"]`, then the `:review_patrol_debounce_ms`
      app env, default 5 min). A burst of pushes yields one re-review. We also wait
      for CI to *settle* (not pending/running) before firing.

    * **Review cap** — once `review_count` reaches a configurable ceiling
      (`config["review_patrol"]["max_reviews"]`, then the `:review_patrol_max_reviews`
      app env, default 3), ReviewPatrol stops re-reviewing the PR entirely (no diff
      fetch, no model spend) and instead raises ONE coordinator escalation the first
      time the cap is hit (`review_cap_escalated`), so a PR that keeps looping (e.g.
      a re-flagged phantom finding) is capped rather than accumulating reviews
      indefinitely (bd-ahvk03). `review_count` is a backstop only — sticky
      approval above is what stops *routine* re-review; the cap exists for the
      case where re-review keeps legitimately re-triggering (e.g. a recurring
      finding). The escalation is claimed atomically (`claim_review_cap_escalation/1`,
      a single `UPDATE ... WHERE review_cap_escalated = false`) rather than via
      a plain read-then-write, so it fires exactly once per trip even under
      concurrent evaluation of the same engagement (bd-4po0nv: a read-then-write
      race was observed to emit 7 identical escalations for one trip within ~3s).

    * **New-diff-only** — the re-review diffs `last_reviewed_sha..head_sha` (the
      adapter's compare endpoint), never the whole PR, so comments land only on the
      newly-pushed commits.

    * **Never re-post an unchanged finding** — new findings are de-duped against
      `posted_findings` by `{file, line, message}` before anything is posted.

  On a completed re-review we append the newly-posted findings to `posted_findings`
  and advance `last_reviewed_sha` to `head_sha` (and stamp `last_reviewed_at`).

  ## Author-reply handling (bd-8fg64x)

  When the head has NOT advanced (no new commits this tick), ReviewPatrol instead
  looks for **author replies** on the review threads we own. Using task E's
  reader (`list_open_review_threads/1` + `filter_to_our_threads/2`) it keeps only
  the threads WE participated in — identified by the fleet's own login
  (`config["review_patrol"]["our_login"]`) — and within those, the comments newer
  than `last_seen_comment_id` authored by the PR author. Comments by other
  reviewers (and our own) are ignored (decision 6).

  A new author reply is handled by the engagement's `review_automation` mode:

    * `:auto` — dispatch the distinct `ReviewReply` workflow (task F) to answer
      in-thread. A *code-change* discussion (new commits pushed) is handled by
      the re-review path above instead: the head-advanced branch runs first, so a
      push defers to task D rather than getting an in-thread reply.

    * `:flag` — post NOTHING to the PR; raise exactly ONE addressed coordinator
      escalation (`to_ref: "coordinator"`) with the PR link + reply snippet.

  Either way we advance `last_seen_comment_id` past the handled reply so it is
  processed (or escalated) exactly once, never per-tick.

  ## Hard invariant

  ReviewPatrol may only ever dispatch `review_only` sub-runs. It must NEVER call
  the Work / implementation path (`Arbiter.Worker.start/1` for a normal task). The
  re-review runs `Arbiter.Workflows.CodeReview` in `:adapter` mode through the
  `review_agent` model slot — read the diff, post inline comments, submit a single
  verdict — and posts nothing else.

  ## Lifecycle

  Not in `Application.children` directly — started per-(workspace, repo) by
  `Arbiter.Workflows.ReviewPatrolSupervisor`, gated by the same
  `:auto_start_refineries` flag PRPatrol uses. Registered in the SEPARATE
  `Arbiter.Workflows.ReviewPatrolRegistry` (never PRPatrol's).

  Test convenience: `tick/1` forces a synchronous patrol cycle without waiting
  for the next interval.

  ## Rate-limit circuit breaker (bd-1m8k7d)

  Every open engagement costs one `adapter.get/1` call per tick — with no
  guard, a workspace with many open engagements linearly scales forge traffic,
  and once the forge starts returning rate-limit errors, ReviewPatrol kept
  polling at full rate: the retry traffic itself sustained the outage (900
  failed calls in 7 minutes was observed against GitHub's secondary limit).

  `process_engagements_paced/5` now recognizes a rate-limited adapter error
  (a 429, or any error whose `kind` is `:rate_limited` — GitHub sets this for
  both primary quota and secondary/abuse 403s) and counts *consecutive*
  occurrences. Once the count reaches `rate_limit_trip_threshold/1`
  (`config["review_patrol"]["rate_limit_trip_threshold"]`, then
  `:review_patrol_rate_limit_trip_threshold` app env, default 3), the tick
  stops processing the REMAINING engagements immediately — bounding the
  request burst to the threshold regardless of how many engagements are open —
  and the whole patrol (every engagement in this workspace/repo) is paused
  until a computed `paused_until`:

    * When the triggering error carries `retry_after_ms` (from GitHub's
      `Retry-After` or `x-ratelimit-reset` header), that value is honored
      directly — we sleep until the forge itself says the limit clears,
      rather than re-probing.
    * Otherwise we fall back to an exponential backoff
      (`@rate_limit_base_backoff_ms * 2^(backoff_level - 1)`, capped at
      `@rate_limit_max_backoff_ms`) that grows on each successive trip and
      resets once a tick completes without tripping.

  While paused, `do_tick/1` short-circuits before resolving the adapter or
  reading a single engagement — zero forge calls, not even one per
  engagement — and logs (and escalates to the coordinator, exactly once per
  trip) the aggregate deferred count rather than a line per engagement per
  cycle. The pause is workspace/repo-scoped (this GenServer's own state),
  matching where the forge's rate limit itself is scoped: account-wide, not
  per-PR.
  """

  # `:transient` (not the default `:permanent`) so a patrol that self-terminates
  # because its repo has no open engagement left (bd-7tr11p) stays down — a
  # `:permanent` child would be restarted immediately by the DynamicSupervisor,
  # defeating the lazy-stop. A genuine crash still exits abnormally and restarts.
  use GenServer, restart: :transient

  alias Arbiter.Agents
  alias Arbiter.GitHub.Limiter
  alias Arbiter.Mergers.Github.RepoResolver
  alias Arbiter.Tasks.{Issue, RepoConfig}
  alias Arbiter.Worker.ReviewAutomation
  alias Arbiter.Workflows.{CodeReview, PatrolPacing, PatrolRepoScope, ReviewReply}
  alias Arbiter.{Mergers, Tasks.Workspace}
  require Ash.Query
  require Logger

  @default_interval_ms 60_000

  # Default debounce window: at most one new-commit re-review per 5 minutes per
  # engagement. Overridable per-workspace (config["review_patrol"]["debounce_ms"])
  # and via the :review_patrol_debounce_ms app env.
  @default_debounce_ms 5 * 60_000

  # Default review cap: after this many posted re-reviews on one engagement,
  # ReviewPatrol stops re-reviewing and escalates once instead of looping.
  # Overridable per-workspace (config["review_patrol"]["max_reviews"]) and via
  # the :review_patrol_max_reviews app env.
  @default_max_reviews 3

  # Pipeline statuses that mean CI has NOT settled yet — hold the re-review until
  # the next tick rather than reviewing a diff whose checks are still in flight.
  @unsettled_ci [:running, :pending]

  # Consecutive rate-limited `adapter.get/1` responses (within one tick) that
  # trip the circuit breaker (bd-1m8k7d). Overridable per-workspace
  # (config["review_patrol"]["rate_limit_trip_threshold"]) and via the
  # :review_patrol_rate_limit_trip_threshold app env.
  @default_rate_limit_trip_threshold 3

  # Fallback exponential backoff when the triggering error carries no
  # Retry-After / x-ratelimit-reset hint: base * 2^(backoff_level - 1),
  # capped at the max. Grows on each successive trip; resets to level 0 the
  # next time a tick completes without tripping.
  @rate_limit_base_backoff_ms 60_000
  @rate_limit_max_backoff_ms 30 * 60_000

  # Ceiling for the idle-tick backoff (bd-4brb2j): a repo with no open
  # engagements (or one where a tick produced no outcomes) for several
  # consecutive ticks stretches its cadence out to at most this, instead of
  # holding a fixed ~1/min poll forever. Distinct from the rate-limit circuit
  # breaker above, which backs off for a different reason (GitHub is actively
  # throttling us) and independently.
  @idle_backoff_ceiling_ms 15 * 60_000

  defstruct [
    :repo,
    :workspace_id,
    :workspace,
    :interval_ms,
    :timer_ref,
    ticks: 0,
    # Consecutive ticks in a row that produced zero outcomes (no engagements
    # open, or none needed action) — drives the idle backoff in
    # `schedule_next/1` (bd-4brb2j). Reset to 0 the moment a tick does
    # anything. Left untouched while the rate-limit circuit is open (a
    # separate, already-backed-off state).
    idle_ticks: 0,
    last_terminated: [],
    last_rereviewed: [],
    last_reported: [],
    last_flagged: [],
    last_replied: [],
    last_escalated: [],
    last_declined: [],
    last_tick_at: nil,
    # Workspace/repo-scoped rate-limit circuit breaker state (bd-1m8k7d):
    # %{paused_until: nil | DateTime.t(), backoff_level: non_neg_integer()}.
    # While paused_until is in the future, do_tick/1 makes zero forge calls.
    rate_limit: %{paused_until: nil, backoff_level: 0}
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
         last_terminated: state.last_terminated,
         last_rereviewed: state.last_rereviewed,
         last_reported: state.last_reported,
         last_flagged: state.last_flagged,
         last_replied: state.last_replied,
         last_escalated: state.last_escalated,
         last_declined: state.last_declined,
         last_tick_at: state.last_tick_at,
         rate_limit_paused_until: state.rate_limit.paused_until,
         idle_ticks: state.idle_ticks
       }, state}

  @impl true
  def handle_info(:tick, state) do
    # Lazy-stop gate (bd-7tr11p): re-check — with a cheap DB read, NOT a forge
    # call — whether this repo still has an open engagement to watch. When it
    # doesn't, terminate before touching GitHub, so an idle repo's patrol makes
    # zero background requests on the tick that reaps it. `:transient` restart
    # keeps it down; a crash still restarts (abnormal exit).
    if has_open_engagement?(state.workspace_id, state.repo) do
      new_state = do_tick(state) |> schedule_next()
      {:noreply, new_state}
    else
      Logger.info(
        "ReviewPatrol[#{state.repo}]: stopping — no open engagement left to watch " <>
          "(workspace #{state.workspace_id})"
      )

      {:stop, :normal, state}
    end
  end

  # Prompt lazy-stop nudge (bd-7tr11p): the PatrolLifecycle subscriber sends
  # this when a watched item in this workspace closes, so the patrol re-checks
  # and terminates immediately rather than waiting for its next (idle-backed-off)
  # scheduled tick. No forge call — pure DB re-check. When an engagement remains,
  # it's a no-op and the existing schedule is left untouched.
  def handle_info(:recheck, state) do
    if has_open_engagement?(state.workspace_id, state.repo) do
      {:noreply, state}
    else
      Logger.info(
        "ReviewPatrol[#{state.repo}]: stopping — last watched engagement closed " <>
          "(workspace #{state.workspace_id})"
      )

      {:stop, :normal, state}
    end
  end

  # ---- tick logic ----

  # Every forge call this tick makes is background (bd-3p5vqc): review polling
  # must yield to foreground work and never starve it. `with_priority/3` tags
  # the patrol process for the tick (and names it in the limiter report,
  # bd-7qgxf9); the GitHub clients honour that class at
  # their request seam (this runs synchronously in the patrol process).
  defp do_tick(state) do
    Limiter.with_priority(:background, :review_patrol, fn -> do_tick_body(state) end)
  end

  defp do_tick_body(state) do
    # Re-fetch the workspace on every tick so config changes take effect
    # immediately without a GenServer restart (mirrors PRPatrol).
    workspace =
      case Ash.get(Workspace, state.workspace_id) do
        {:ok, ws} -> ws
        _ -> nil
      end

    now = clock_now()

    if paused?(state.rate_limit, now) do
      # Circuit open: make ZERO forge calls (not even a first one) until the
      # pause elapses (bd-1m8k7d) — nothing to log per-tick beyond the one
      # aggregate line + escalation already emitted when the circuit tripped.
      %{
        state
        | ticks: state.ticks + 1,
          last_tick_at: now,
          workspace: workspace,
          last_terminated: [],
          last_rereviewed: [],
          last_reported: [],
          last_flagged: [],
          last_replied: [],
          last_escalated: [],
          last_declined: []
      }
    else
      {outcomes, rate_limit} =
        with %Workspace{} <- workspace,
             adapter when not is_nil(adapter) <- resolve_adapter(workspace),
             true <- function_exported?(adapter, :get, 1),
             :ok <- Mergers.prepare_with_repo(workspace, state.repo) do
          rig_name = rig_name_for_repo(workspace, state.repo)

          state.workspace_id
          |> open_engagements(state.repo)
          |> process_engagements_paced(adapter, workspace, rig_name, state.rate_limit)
        else
          # On any failure (missing workspace, unsupported adapter), no-op the
          # cycle but still bump the tick counter below so the patrol is observable.
          _ -> {[], state.rate_limit}
        end

      idle_ticks = if outcomes == [], do: state.idle_ticks + 1, else: 0

      Logger.debug(
        "ReviewPatrol[#{state.repo}]: tick outcomes=#{length(outcomes)} idle_ticks=#{idle_ticks}"
      )

      %{
        state
        | ticks: state.ticks + 1,
          last_tick_at: now,
          last_terminated: for({:terminated, id} <- outcomes, do: id),
          last_rereviewed: for({:rereviewed, id} <- outcomes, do: id),
          last_reported: for({:reported, id} <- outcomes, do: id),
          last_flagged: for({:flagged, id} <- outcomes, do: id),
          last_replied: for({:replied, id} <- outcomes, do: id),
          last_escalated: for({:escalated, id} <- outcomes, do: id),
          last_declined: for({:declined, id} <- outcomes, do: id),
          workspace: workspace,
          rate_limit: rate_limit,
          idle_ticks: idle_ticks
      }
    end
  end

  defp resolve_adapter(workspace) do
    adapter = Mergers.for_workspace(workspace)

    # Force the adapter module to load before the `function_exported?/3` guard
    # inspects it: the guard returns false for a not-yet-loaded module without
    # triggering a load, so under interactive code loading (`mix test`) it would
    # spuriously no-op the whole tick. Releases preload all modules, masking
    # this — but the guard must not depend on prior load order. See bd-1hn1qw.
    Code.ensure_loaded(adapter)
    adapter
  rescue
    ArgumentError -> nil
  end

  @doc """
  Whether `repo` (an `"owner/repo"` slug) has an open review engagement worth
  watching (bd-7tr11p). Pure DB read, no forge call: an engagement's repo is
  recoverable from its `source_pr` (embedded `owner/repo#N` for multi-repo, bare
  `#N` in a single-repo workspace where the sole repo is unambiguous — see
  `PatrolRepoScope`).

  The lazy-start gate: the supervisor starts a patrol only for repos where this
  is true, and a running patrol self-terminates once it flips false, so an idle
  repo costs zero background polling.
  """
  @spec has_open_engagement?(String.t(), String.t()) :: boolean()
  def has_open_engagement?(workspace_id, repo)
      when is_binary(workspace_id) and is_binary(repo) do
    workspace_id |> open_engagements(repo) |> Kernel.!=([])
  end

  # OPEN review engagements for a specific repo in this workspace: review_only
  # tasks with a linked source PR that are not yet closed. The `review_only ==
  # true` filter is what keeps this disjoint from PRPatrol's author-side
  # follow-ups (review_only == false), so the two patrols never act on each
  # other's tasks.
  #
  # The engagement set is scoped to `repo` (bd-7tr11p): the workspace-level query
  # is filtered down to engagements whose `source_pr` belongs to `repo`. This is
  # what makes per-repo lazy start/stop correct in a multi-repo workspace — a
  # patrol's watched set is exactly its own repo's engagements, so it can tell
  # when ITS last engagement closes. It also removes the prior redundancy where
  # every repo's patrol polled (and acted on) every other repo's engagements,
  # since a qualified `source_pr` self-routes at the adapter regardless of the
  # per-patrol repo override.
  defp open_engagements(workspace_id, repo) do
    Issue
    |> Ash.Query.filter(
      review_only == true and not is_nil(source_pr) and status != :closed and
        workspace_id == ^workspace_id
    )
    |> Ash.read!()
    |> Enum.filter(fn %Issue{source_pr: ref} -> PatrolRepoScope.ref_matches_repo?(ref, repo) end)
  rescue
    _ -> []
  end

  # Pace GitHub `get()` calls across a tick's engagements so a workspace with
  # many open engagements doesn't fire a burst of requests within the same
  # second and trip GitHub's secondary (abuse) rate limit (bd-1yva53). Every
  # engagement after the first waits a jittered delay first; the first fires
  # immediately so a single-engagement tick (the common case, and every
  # existing test) pays no delay at all.
  @pace_base_ms 300
  @pace_jitter_ms 200

  # Poll each engagement in order, pacing between calls, but stop firing new
  # `adapter.get/1` calls the moment `@rate_limit_trip_threshold` CONSECUTIVE
  # rate-limited responses are seen (bd-1m8k7d) — bounding the request burst
  # to the threshold regardless of how many engagements are still open. On
  # trip, the remaining (unprocessed) engagements are deferred and the whole
  # workspace/repo is paused; see `trip_circuit/4`. A run that completes
  # without tripping resets the circuit (any prior backoff level forgotten).
  defp process_engagements_paced(engagements, adapter, workspace, rig_name, rate_limit) do
    threshold = rate_limit_trip_threshold(workspace)
    total = length(engagements)

    {outcomes, _consecutive, tripped_at} =
      engagements
      |> Enum.with_index()
      |> Enum.reduce_while({[], 0, nil}, fn {engagement, index}, {outcomes, consecutive, _} ->
        if index > 0, do: pace_delay()

        result = fetch_pr_result(engagement, adapter)

        case rate_limit_signal(result) do
          {:rate_limited, retry_after_ms} ->
            consecutive = consecutive + 1

            if consecutive >= threshold do
              {:halt, {outcomes, consecutive, {index, retry_after_ms}}}
            else
              {:cont, {outcomes, consecutive, nil}}
            end

          :ok ->
            outcome = process_engagement_result(engagement, result, adapter, workspace, rig_name)
            {:cont, {[outcome | outcomes], 0, nil}}
        end
      end)

    outcomes = outcomes |> Enum.reverse() |> Enum.filter(& &1)

    case tripped_at do
      nil ->
        {outcomes, %{rate_limit | paused_until: nil, backoff_level: 0}}

      {index, retry_after_ms} ->
        deferred = total - (index + 1)
        {outcomes, trip_circuit(rate_limit, workspace, retry_after_ms, deferred)}
    end
  end

  defp pace_delay do
    ms = @pace_base_ms + :rand.uniform(@pace_jitter_ms)

    case Application.get_env(:arbiter, :review_patrol_pace_sleep_fun) do
      fun when is_function(fun, 1) -> fun.(ms)
      _ -> Process.sleep(ms)
    end
  end

  # ---- rate-limit circuit breaker (bd-1m8k7d) -----------------------------

  # `adapter.get/1` result → `{:rate_limited, retry_after_ms | nil}` when the
  # error is a forge rate limit (429, or any error whose `kind` is
  # `:rate_limited` — GitHub sets this for both primary-quota and
  # secondary/abuse 403s), else `:ok` (success, or any other error kind, which
  # is still logged/no-op'd per-engagement exactly as before). Duck-typed on
  # `:kind`/`:status`/`:retry_after_ms` so any adapter's error struct works,
  # not just GitHub's.
  defp rate_limit_signal({:error, reason}) when is_map(reason) do
    if Map.get(reason, :kind) == :rate_limited or Map.get(reason, :status) == 429 do
      {:rate_limited, Map.get(reason, :retry_after_ms)}
    else
      :ok
    end
  end

  defp rate_limit_signal(_result), do: :ok

  # The `adapter.get/1` call, skipped entirely when the engagement has no
  # usable source_pr — mirrors the guard the old `process_engagement/4` used
  # so an invalid ref never reaches the forge (and never counts toward the
  # rate-limit trip).
  defp fetch_pr_result(%Issue{source_pr: source_pr}, adapter)
       when is_binary(source_pr) and source_pr != "" do
    adapter.get(source_pr)
  end

  defp fetch_pr_result(_engagement, _adapter), do: {:ok, :skipped}

  # Trip the circuit: compute how long to pause (honoring the triggering
  # error's retry hint when present, else an exponential fallback that grows
  # on each successive trip), log ONE aggregate line (never one per
  # engagement), and raise ONE coordinator escalation. Best-effort — a
  # mailbox hiccup never breaks the tick.
  defp trip_circuit(rate_limit, workspace, retry_after_ms, deferred_count) do
    backoff_level = rate_limit.backoff_level + 1
    pause_ms = rate_limit_pause_ms(retry_after_ms, backoff_level)
    paused_until = DateTime.add(clock_now(), pause_ms, :millisecond)

    Logger.warning(
      "ReviewPatrol: workspace #{workspace_ref(workspace)} hit the rate-limit trip threshold; " <>
        "pausing ALL polling until #{DateTime.to_iso8601(paused_until)} " <>
        "(#{deferred_count} engagement(s) deferred this tick, retry_after=#{inspect(retry_after_ms)}ms)"
    )

    escalate_rate_limit(workspace, paused_until, deferred_count)

    %{rate_limit | paused_until: paused_until, backoff_level: backoff_level}
  end

  defp rate_limit_pause_ms(retry_after_ms, _backoff_level)
       when is_integer(retry_after_ms) and retry_after_ms > 0 do
    min(retry_after_ms, @rate_limit_max_backoff_ms)
  end

  defp rate_limit_pause_ms(_retry_after_ms, backoff_level) do
    min(
      @rate_limit_base_backoff_ms * Integer.pow(2, backoff_level - 1),
      @rate_limit_max_backoff_ms
    )
  end

  defp escalate_rate_limit(%Workspace{id: ws_id} = workspace, paused_until, deferred_count) do
    ref = "review_patrol_rate_limit:#{ws_id}"

    body =
      "ReviewPatrol hit a sustained forge rate limit polling workspace #{workspace_ref(workspace)} " <>
        "and is pausing ALL polling for this workspace until #{DateTime.to_iso8601(paused_until)} " <>
        "(#{deferred_count} open engagement(s) deferred this tick). No further requests will be " <>
        "made until then; the backoff grows automatically if the limit is still in effect once " <>
        "polling resumes."

    _ =
      safe(fn ->
        Arbiter.Messages.Message.send_mail(%{
          kind: :escalation,
          to_ref: Arbiter.Messages.Message.coordinator_ref(),
          from_ref: ref,
          workspace_id: ws_id,
          task_ref: ref,
          subject: "ReviewPatrol paused — forge rate limit",
          body: body
        })
      end)

    :ok
  end

  defp escalate_rate_limit(_workspace, _paused_until, _deferred_count), do: :ok

  defp workspace_ref(%Workspace{id: id, name: name}), do: "#{id} (#{name})"
  defp workspace_ref(_workspace), do: "?"

  defp paused?(%{paused_until: %DateTime{} = at}, now), do: DateTime.compare(now, at) == :lt
  defp paused?(_rate_limit, _now), do: false

  defp rate_limit_trip_threshold(%Workspace{config: config}) do
    case get_in(config || %{}, ["review_patrol", "rate_limit_trip_threshold"]) do
      n when is_integer(n) and n > 0 -> n
      _ -> app_rate_limit_trip_threshold()
    end
  end

  defp rate_limit_trip_threshold(_workspace), do: app_rate_limit_trip_threshold()

  defp app_rate_limit_trip_threshold,
    do:
      Application.get_env(
        :arbiter,
        :review_patrol_rate_limit_trip_threshold,
        @default_rate_limit_trip_threshold
      )

  # Overridable in tests (`Application.put_env(:arbiter, :review_patrol_clock_fun, fun)`)
  # so pause-window expiry can be exercised without a real sleep.
  defp clock_now do
    case Application.get_env(:arbiter, :review_patrol_clock_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> DateTime.utc_now()
    end
  end

  # Returns a tagged outcome for the tick's bookkeeping:
  #   {:terminated, id} — the source PR merged/closed and the engagement closed
  #   {:rereviewed, id} — a new-commit re-review was posted this tick
  #   {:reported, id}   — :report_only mode re-reviewed and reported proposed
  #                        comments to the coordinator (posted nothing)
  #   {:flagged, id}    — :flag mode surfaced new commits as a mailbox flag
  #   {:replied, id}    — :auto mode dispatched a reply to an author reply
  #   {:escalated, id}  — :flag mode escalated an author reply to the coordinator
  #   {:declined, id}   — sticky approval (bd-4po0nv): the operator identity
  #                        currently holds an approving review and the new push
  #                        was non-invalidating, so no re-review was conducted
  #   nil               — nothing actionable (first-sighting SHA record, no
  #                        advance, guard suppressed, no new replies, or an
  #                        adapter error)
  defp process_engagement_result(
         %Issue{source_pr: source_pr} = engagement,
         result,
         adapter,
         workspace,
         rig_name
       )
       when is_binary(source_pr) and source_pr != "" do
    case result do
      {:ok, %{status: status}} when status in [:merged, :closed] ->
        case terminate_engagement(engagement, status) do
          nil -> nil
          id -> {:terminated, id}
        end

      {:ok, %{status: :open} = pr} ->
        handle_open_pr(engagement, pr, adapter, workspace, rig_name)

      {:ok, _other} ->
        nil

      {:error, reason} ->
        Logger.info(
          "ReviewPatrol: get(#{source_pr}) failed for engagement #{engagement.id}: " <>
            inspect(reason)
        )

        nil
    end
  end

  defp process_engagement_result(_engagement, _result, _adapter, _workspace, _rig_name), do: nil

  # An open source PR. First sighting (last_reviewed_sha unset) → record the head
  # SHA and stop. If the head advanced, consider a new-commit re-review under the
  # spam guards (task D). Otherwise (head unchanged — no new commits this tick)
  # check our review threads for author replies to answer / escalate (task G).
  defp handle_open_pr(%Issue{last_reviewed_sha: nil} = engagement, pr, _adapter, _workspace, _rig) do
    maybe_record_head_sha(engagement, pr)
    nil
  end

  defp handle_open_pr(
         %Issue{last_reviewed_sha: last} = engagement,
         %{head_sha: head} = pr,
         adapter,
         workspace,
         rig_name
       )
       when is_binary(head) and head != "" and head != last do
    # The head advanced — new commits were pushed. This is the "fresh code change
    # discussion" case: defer to task D's re-review path rather than replying in
    # a thread. Author replies (if any) are picked up on a later tick once the
    # head settles (they remain newer than `last_seen_comment_id`).
    maybe_rereview(engagement, pr, adapter, workspace, rig_name)
  end

  # No new commits this tick (head unchanged, or head unknown/blank). Look for
  # new author replies on the review threads we own and handle them per the
  # engagement's automation mode.
  defp handle_open_pr(%Issue{} = engagement, pr, adapter, workspace, rig_name) do
    maybe_handle_author_replies(engagement, pr, adapter, workspace, rig_name)
  end

  # Close the engagement's task. review_only == true, so SyncTracker skips every
  # tracker write (bd-6xaaam): terminating an engagement never touches the
  # upstream PR / issue we don't own.
  defp terminate_engagement(%Issue{} = engagement, pr_status) do
    case Ash.update(engagement, %{reason: "source PR #{pr_status}"}, action: :close) do
      {:ok, _closed} ->
        Logger.info(
          "ReviewPatrol: terminated engagement #{engagement.id} (source PR #{engagement.source_pr} #{pr_status})"
        )

        engagement.id

      {:error, reason} ->
        Logger.warning(
          "ReviewPatrol: failed to terminate engagement #{engagement.id}: #{inspect(reason)}"
        )

        nil
    end
  end

  # Record the PR head SHA the first time we see the engagement (last_reviewed_sha
  # unset). Once set, this is a no-op here — new-commit re-review lands in task D.
  defp maybe_record_head_sha(%Issue{last_reviewed_sha: nil} = engagement, %{head_sha: sha})
       when is_binary(sha) and sha != "" do
    case Ash.update(engagement, %{last_reviewed_sha: sha}, action: :update) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ReviewPatrol: failed to record head SHA for engagement #{engagement.id}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp maybe_record_head_sha(_engagement, _pr), do: :ok

  # ---- new-commit re-review (bd-f3fg22) ----------------------------------

  # The head advanced past `last_reviewed_sha`. Apply the spam guards in order —
  # CI settle, debounce, fetch the new-diff-only, relevance gate — then act by
  # automation mode: `:auto` posts a re-review, `:flag` raises a mailbox flag.
  defp maybe_rereview(%Issue{} = engagement, pr, adapter, workspace, rig_name) do
    cond do
      not ci_settled?(pr) ->
        Logger.info(
          "ReviewPatrol: CI not settled (#{inspect(Map.get(pr, :pipeline))}) for engagement " <>
            "#{engagement.id}; deferring re-review"
        )

        nil

      debounced?(engagement, workspace) ->
        Logger.info(
          "ReviewPatrol: engagement #{engagement.id} inside debounce window; skipping re-review"
        )

        nil

      review_capped?(engagement, workspace) ->
        handle_review_cap(engagement, workspace)

      true ->
        gate_on_relevance(engagement, pr, adapter, workspace, rig_name)
    end
  end

  # ---- per-PR review cap (bd-ahvk03) -------------------------------------

  # The cap is checked BEFORE the new diff is even fetched, so a capped
  # engagement costs nothing beyond the (already-paid) adapter.get/1 call —
  # no diff fetch, no model spend.
  defp review_capped?(%Issue{review_count: count}, workspace) do
    (count || 0) >= max_reviews(workspace)
  end

  # First tick past the cap: raise exactly ONE coordinator escalation and mark
  # the engagement so it isn't re-escalated on every subsequent tick. Neither
  # `last_reviewed_sha` nor `review_count` advance — the engagement is simply
  # frozen until a human intervenes.
  #
  # The escalate-then-mark ordering used to be a plain read-then-write: two
  # ticks landing on the same capped engagement within the same window (e.g. a
  # crash-restart loop, or duplicate patrol processes) could both read
  # `review_cap_escalated: false` and both escalate before either write
  # committed — observed as 7 identical escalations for one trip within ~3s
  # (bd-4po0nv). `claim_review_cap_escalation/1` closes that window: it flips
  # the flag false->true via a single atomic `UPDATE ... WHERE` statement, so
  # only the caller that actually performs the flip proceeds to escalate.
  defp handle_review_cap(%Issue{review_cap_escalated: true} = _engagement, _workspace), do: nil

  defp handle_review_cap(%Issue{} = engagement, workspace) do
    if claim_review_cap_escalation(engagement) do
      escalate_review_cap(engagement, workspace)

      Logger.info(
        "ReviewPatrol: engagement #{engagement.id} hit the review cap " <>
          "(#{engagement.review_count} reviews); escalated and stopped re-reviewing"
      )

      {:escalated, engagement.id}
    else
      nil
    end
  end

  # Atomically claim the review-cap escalation for one engagement: a single
  # `UPDATE issues SET review_cap_escalated = true WHERE id = ? AND
  # review_cap_escalated = false` — so at most one caller can ever observe
  # `records != []` for a given trip, even when multiple callers evaluate the
  # same capped engagement concurrently.
  #
  # Goes straight to Ecto (`Repo.update_all/2`) rather than `Ash.bulk_update/4`:
  # the `:update` action carries a custom `Change` (status-guard logic) that
  # doesn't implement the atomic optimizer, so Ash's bulk update falls back to
  # a read-then-per-record-update strategy that reopens the exact race this
  # is closing. A single Ecto `UPDATE ... WHERE` bypasses action changes
  # entirely — safe here because the claim touches only this one boolean
  # bookkeeping column, nothing that other `:update` change logic guards.
  defp claim_review_cap_escalation(%Issue{id: id}) do
    import Ecto.Query

    # Schemaless query against the raw "issues" table — Ecto can't infer the
    # column's type without a schema, so `type/2` casts pin both sides to
    # :boolean explicitly (otherwise the driver has been observed persisting
    # the literal string "true" instead of a proper boolean).
    query =
      from(i in "issues",
        where: i.id == ^id and i.review_cap_escalated == type(^false, :boolean),
        update: [set: [review_cap_escalated: type(^true, :boolean)]]
      )

    {count, _} = Arbiter.Repo.update_all(query, [])
    count == 1
  rescue
    _ -> false
  end

  # Best-effort human-facing escalation when a PR hits the review cap. A
  # mailbox hiccup never breaks the tick.
  defp escalate_review_cap(%Issue{workspace_id: ws_id} = engagement, _workspace)
       when is_binary(ws_id) do
    body =
      "ReviewPatrol has posted #{engagement.review_count} re-review(s) on PR " <>
        "##{engagement.source_pr} and hit the configured review cap. No further " <>
        "automatic re-reviews will be posted; the PR likely needs human " <>
        "intervention (e.g. a recurring finding that keeps re-triggering)."

    _ =
      safe(fn ->
        Arbiter.Messages.Message.send_mail(%{
          kind: :escalation,
          to_ref: Arbiter.Messages.Message.coordinator_ref(),
          from_ref: engagement.id,
          workspace_id: ws_id,
          task_ref: engagement.id,
          subject: "PR ##{engagement.source_pr} hit the ReviewPatrol review cap",
          body: body
        })
      end)

    :ok
  end

  defp escalate_review_cap(_engagement, _workspace), do: :ok

  defp max_reviews(%Workspace{config: config}) do
    case get_in(config || %{}, ["review_patrol", "max_reviews"]) do
      n when is_integer(n) and n >= 0 -> n
      _ -> app_max_reviews()
    end
  end

  defp max_reviews(_workspace), do: app_max_reviews()

  defp app_max_reviews,
    do: Application.get_env(:arbiter, :review_patrol_max_reviews, @default_max_reviews)

  # Fetch the diff SINCE `last_reviewed_sha` (new-diff-only) and re-review only
  # when it touches a file we previously flagged. A push that touches only
  # unrelated files is not our concern and is skipped without advancing anything.
  defp gate_on_relevance(engagement, pr, adapter, workspace, rig_name) do
    opts = %{
      base: engagement.last_reviewed_sha,
      head: pr.head_sha,
      # Anchor inline comments to the new head commit (skips an extra PR fetch
      # in the adapter and pins each comment to the commit we're reviewing).
      commit_id: pr.head_sha,
      task: %{id: engagement.id, title: engagement.title}
    }

    case fetch_new_diff(adapter, engagement.source_pr, opts) do
      {:ok, diff} ->
        cond do
          not relevant?(engagement.posted_findings, diff) ->
            Logger.info(
              "ReviewPatrol: new commits on engagement #{engagement.id} touch no previously-" <>
                "flagged file; skipping re-review"
            )

            nil

          sticky_approval_blocks?(engagement, diff, adapter) ->
            decline_for_sticky_approval(engagement, pr.head_sha)

          true ->
            act_on_new_commits(engagement, pr.head_sha, adapter, workspace, opts, rig_name)
        end

      {:error, reason} ->
        Logger.info(
          "ReviewPatrol: could not fetch new diff for engagement #{engagement.id}: " <>
            inspect(reason)
        )

        nil
    end
  end

  # ---- sticky approval (bd-4po0nv) ---------------------------------------
  #
  # Once the operator identity holds a CURRENT approving review on the PR,
  # ReviewPatrol stops auto-re-reviewing on every push — a colleague iterating
  # on their own PR should not collect a fresh approval from us per commit.
  # Re-review resumes only when the new commits are *invalidating*: they alter
  # non-test, non-doc code (the heuristic below), or the diff is otherwise
  # substantive rather than pure reformatting. A doc-only, test-only,
  # formatting-only, or rebase/merge-only push (no substantive file in the new
  # diff) never trips this — it's declined and the decision is recorded on the
  # engagement so "approval is sticky" reads as a decision, not as ReviewPatrol
  # going quiet/broken.
  #
  # `self_approved?/1` is an OPTIONAL adapter capability (already used by the
  # external-review dispatch guard, bd-7z5pi5) that reports whether the
  # authenticated (fleet) identity currently holds an APPROVED verdict — dup
  # state, dismissals, and superseding CHANGES_REQUESTED reviews are already
  # resolved by the adapter. Adapters without it (or a call that errors) fail
  # OPEN here: sticky approval never applies, so behavior is unchanged from
  # before this feature for those adapters.
  defp sticky_approval_blocks?(%Issue{source_pr: source_pr}, diff, adapter) do
    operator_currently_approved?(adapter, source_pr) and not invalidating_diff?(diff)
  end

  defp operator_currently_approved?(adapter, source_pr) do
    if function_exported?(adapter, :self_approved?, 1) do
      case safe(fn -> adapter.self_approved?(source_pr) end) do
        {:ok, true} -> true
        _ -> false
      end
    else
      false
    end
  end

  # Advance the cursor (so the same push isn't re-evaluated every tick) and
  # append a note to the engagement recording the decision — "approval stands"
  # is a deliberate outcome, distinguishable from ReviewPatrol silently doing
  # nothing / being broken.
  defp decline_for_sticky_approval(%Issue{} = engagement, head) do
    note =
      "[#{DateTime.to_iso8601(now())}] ReviewPatrol: approval stands — new commits (head " <>
        "#{head}) were doc/test/formatting/rebase-only; declined to re-review (bd-4po0nv)."

    update_engagement(engagement, %{
      last_reviewed_sha: head,
      last_reviewed_at: now(),
      notes: append_note(engagement.notes, note)
    })

    Logger.info(
      "ReviewPatrol: engagement #{engagement.id} approval stands; declined re-review on " <>
        "non-invalidating push to #{head}"
    )

    {:declined, engagement.id}
  end

  defp append_note(nil, note), do: note
  defp append_note("", note), do: note
  defp append_note(existing, note) when is_binary(existing), do: existing <> "\n" <> note

  # Whether the new diff *invalidates* a standing approval: true when it
  # touches at least one file that is neither a doc file nor a test file with
  # a substantive (non-formatting-only) change. An empty diff (rebase/merge
  # with no content delta) has no such file, so it's never invalidating.
  defp invalidating_diff?(diff) when is_binary(diff) do
    diff
    |> diff_lines_by_file()
    |> Enum.any?(fn {file, lines} ->
      not doc_or_test_file?(file) and not formatting_only_lines?(lines)
    end)
  end

  defp invalidating_diff?(_diff), do: false

  # Group a unified diff's added/removed content lines by the file they belong
  # to. The "current file" switches on each `+++ b/…` header (which follows
  # `--- a/…` in every hunk), so this works regardless of whether a `diff
  # --git` header is present.
  defp diff_lines_by_file(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, fn line, {current_file, acc} ->
      cond do
        String.starts_with?(line, "+++ ") ->
          case file_from_diff_line(line) do
            [f] -> {f, Map.put_new(acc, f, [])}
            [] -> {nil, acc}
          end

        String.starts_with?(line, "--- ") ->
          {current_file, acc}

        is_binary(current_file) and content_line?(line) ->
          {current_file, Map.update(acc, current_file, [line], &[line | &1])}

        true ->
          {current_file, acc}
      end
    end)
    |> elem(1)
  end

  defp content_line?(line) do
    (String.starts_with?(line, "+") or String.starts_with?(line, "-")) and
      not String.starts_with?(line, "+++") and not String.starts_with?(line, "---")
  end

  @doc_path_regex ~r{(^|/)docs?/}i
  @doc_ext_regex ~r/\.(md|markdown|txt|rst|adoc)$/i
  @doc_name_regex ~r{(^|/)(README|CHANGELOG|LICENSE|CONTRIBUTING|NOTICE)(\.[^/]*)?$}i
  @test_path_regex ~r{(^|/)(tests?|specs?|__tests__)/}i
  @test_name_regex ~r/(_test\.\w+|_spec\.\w+|\.test\.\w+|\.spec\.\w+)$/i

  defp doc_or_test_file?(file) do
    doc_file?(file) or test_file?(file)
  end

  defp doc_file?(file) do
    Regex.match?(@doc_path_regex, file) or Regex.match?(@doc_ext_regex, file) or
      Regex.match?(@doc_name_regex, file)
  end

  defp test_file?(file) do
    Regex.match?(@test_path_regex, file) or Regex.match?(@test_name_regex, file)
  end

  # A file's change is formatting-only when its added and removed content
  # lines are the same multiset once whitespace-normalized — i.e. every line
  # that changed only had its whitespace rearranged, nothing semantic.
  defp formatting_only_lines?(lines) do
    {added, removed} =
      Enum.reduce(lines, {[], []}, fn line, {add, rem} ->
        cond do
          String.starts_with?(line, "+") ->
            {[normalize_ws(String.trim_leading(line, "+")) | add], rem}

          String.starts_with?(line, "-") ->
            {add, [normalize_ws(String.trim_leading(line, "-")) | rem]}

          true ->
            {add, rem}
        end
      end)

    Enum.sort(added) == Enum.sort(removed)
  end

  defp normalize_ws(s), do: s |> String.trim() |> String.replace(~r/\s+/, " ")

  defp act_on_new_commits(engagement, head, adapter, workspace, opts, rig_name) do
    case automation_mode(engagement, workspace, rig_name) do
      :auto -> run_rereview(engagement, head, adapter, workspace, opts)
      :report_only -> report_rereview(engagement, head, adapter, workspace, opts)
      # :off (bd-7opdaf) is a hard opt-out — never dispatch a reviewer, same
      # non-dispatching behavior as :flag (surface a flag, don't review).
      mode when mode in [:flag, :off] -> flag_new_commits(engagement, head, workspace)
    end
  end

  # Dispatch a `review_only` CodeReview sub-run in `:adapter` mode through the
  # `review_agent` model slot. Seeding `:review_agent` lets the re-review run on a
  # cheaper model than the first pass. The check runner is wrapped to drop any
  # finding we already posted (unchanged-finding de-dupe) BEFORE the workflow
  # posts inline comments. On success we persist the newly-posted findings and
  # advance `last_reviewed_sha`.
  defp run_rereview(%Issue{} = engagement, head, adapter, workspace, opts) do
    # `reviewer_for_workspace/1` selects the reviewer adapter; `prepare/2` seeds
    # its per-process model config so CodeReview's Claude session honors it.
    _reviewer = Agents.reviewer_for_workspace(workspace)
    :ok = Agents.prepare(workspace, :review_agent)

    prior_keys = prior_finding_keys(engagement.posted_findings)

    state = %{
      mode: :adapter,
      adapter: adapter,
      mr_ref: engagement.source_pr,
      workspace: workspace,
      adapter_opts: opts,
      check_runner: dedupe_runner(prior_keys),
      # bd-9rdwe4 (#1017 gap G5): a re-review never spawns through
      # `Arbiter.Worker` — this is its only prompt-persistence choke-point,
      # keyed on the engagement (an `Issue` row, not a Reviews.Record).
      review_record_id: engagement.id
    }

    case Arbiter.Workflow.run(CodeReview, state) do
      {:ok, final} ->
        posted = Map.get(final, :findings) || []
        persist_rereview(engagement, head, posted)

        Logger.info(
          "ReviewPatrol: re-reviewed engagement #{engagement.id} on #{head} " <>
            "(#{length(posted)} new finding(s))"
        )

        {:rereviewed, engagement.id}

      {:error, reason} ->
        Logger.warning(
          "ReviewPatrol: re-review workflow failed for engagement #{engagement.id}: " <>
            inspect(reason)
        )

        nil
    end
  end

  # `:report_only` automation mode (bd-36qzgx): run the full re-review of the new
  # diff but post NOTHING to the PR. Instead, surface the proposed comments +
  # recommended verdict to the coordinator mailbox so a human can greenlight what
  # posts. On success we persist the reported findings (so the relevance gate and
  # dedupe track them) and advance `last_reviewed_sha`.
  defp report_rereview(%Issue{} = engagement, head, adapter, workspace, opts) do
    _reviewer = Agents.reviewer_for_workspace(workspace)
    :ok = Agents.prepare(workspace, :review_agent)

    prior_keys = prior_finding_keys(engagement.posted_findings)

    state = %{
      mode: :adapter,
      adapter: adapter,
      mr_ref: engagement.source_pr,
      workspace: workspace,
      adapter_opts: opts,
      report_only: true,
      check_runner: dedupe_runner(prior_keys),
      # bd-9rdwe4 (#1017 gap G5): see the mirroring comment in run_rereview/5.
      review_record_id: engagement.id
    }

    case Arbiter.Workflow.run(CodeReview, state) do
      {:ok, final} ->
        findings = Map.get(final, :findings) || []
        proposed = Map.get(final, :proposed_comments) || []
        verdict = Map.get(final, :verdict)

        report_to_coordinator(engagement, head, proposed, verdict)
        persist_rereview(engagement, head, findings)

        Logger.info(
          "ReviewPatrol: report-only re-review of engagement #{engagement.id} on #{head} " <>
            "(#{length(proposed)} proposed, posted 0)"
        )

        {:reported, engagement.id}

      {:error, reason} ->
        Logger.warning(
          "ReviewPatrol: report-only re-review failed for engagement #{engagement.id}: " <>
            inspect(reason)
        )

        nil
    end
  end

  # Surface a report-only re-review's proposed comments to the coordinator.
  # Best-effort — a mailbox hiccup never breaks the tick.
  defp report_to_coordinator(%Issue{workspace_id: ws_id} = engagement, head, proposed, verdict)
       when is_binary(ws_id) do
    lines =
      proposed
      |> Enum.with_index()
      |> Enum.map(fn {c, i} ->
        file = c[:file] || c["file"] || "?"
        line = c[:line] || c["line"]
        loc = if line, do: "#{file}:#{line}", else: file
        body = c[:body] || c["body"] || ""
        "  [#{i}] #{loc}\n      #{body}"
      end)
      |> Enum.join("\n")

    body =
      "New commits (head #{head}) on PR #{engagement.source_pr} were re-reviewed in " <>
        "report-only mode — NOTHING was posted. Recommended verdict: #{verdict}.\n\n" <>
        "Proposed comments:\n" <> lines

    _ =
      safe(fn ->
        Arbiter.Messages.Message.send_mail(%{
          kind: :escalation,
          to_ref: Arbiter.Messages.Message.coordinator_ref(),
          from_ref: engagement.id,
          workspace_id: ws_id,
          task_ref: engagement.id,
          subject:
            "Report-only re-review: PR #{engagement.source_pr} — #{length(proposed)} proposed comment(s)",
          body: body
        })
      end)

    :ok
  end

  defp report_to_coordinator(_engagement, _head, _proposed, _verdict), do: :ok

  # `:flag` automation mode: surface the new commits as a durable mailbox flag
  # rather than re-reviewing, then advance the cursor so the same commits aren't
  # re-flagged. Best-effort — a mailbox hiccup never breaks the tick.
  defp flag_new_commits(%Issue{workspace_id: ws_id} = engagement, head, _workspace)
       when is_binary(ws_id) do
    _ =
      safe(fn ->
        Arbiter.Messages.Message.send_mail(%{
          kind: :flag,
          from_ref: engagement.id,
          to_ref: engagement.id,
          workspace_id: ws_id,
          task_ref: engagement.id,
          subject: "New commits on PR ##{engagement.source_pr} touch flagged areas",
          body:
            "ReviewPatrol detected new commits (head #{head}) on the source PR that touch a file " <>
              "this engagement previously flagged. Automation mode is :flag, so no automatic " <>
              "re-review was posted. Trigger a re-review manually if warranted."
        })
      end)

    advance_cursor(engagement, head)
    {:flagged, engagement.id}
  end

  defp flag_new_commits(engagement, head, _workspace) do
    advance_cursor(engagement, head)
    {:flagged, engagement.id}
  end

  # A check runner that runs the real CodeReview checks and then drops any finding
  # whose {file, line, message} we've already posted on this engagement.
  defp dedupe_runner(prior_keys) do
    fn diff, st ->
      case CodeReview.Checks.run(diff, st) do
        {:ok, findings} when is_list(findings) ->
          {:ok, Enum.reject(findings, &MapSet.member?(prior_keys, finding_key(&1)))}

        other ->
          other
      end
    end
  end

  defp persist_rereview(%Issue{} = engagement, head, posted) do
    merged = (engagement.posted_findings || []) ++ Enum.map(posted, &stored_finding/1)

    update_engagement(engagement, %{
      last_reviewed_sha: head,
      last_reviewed_at: now(),
      posted_findings: merged,
      review_count: (engagement.review_count || 0) + 1
    })
  end

  defp advance_cursor(%Issue{} = engagement, head) do
    update_engagement(engagement, %{
      last_reviewed_sha: head,
      last_reviewed_at: now()
    })
  end

  # Second precision: `store_action_inputs?` (paper_trail) serializes the update
  # inputs and rejects a microsecond datetime; the debounce window is in minutes,
  # so second resolution is more than enough.
  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp update_engagement(%Issue{} = engagement, attrs) do
    case Ash.update(engagement, attrs, action: :update) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ReviewPatrol: failed to update engagement #{engagement.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # ---- author-reply handling (phase 2, bd-8fg64x) ------------------------

  # Detect author replies newer than `last_seen_comment_id` on the review
  # threads WE own, then act per automation mode:
  #   :auto → dispatch the ReviewReply workflow (task F) to answer in-thread.
  #   :flag → post NOTHING; raise ONE coordinator escalation.
  # Either way, advance `last_seen_comment_id` past the handled reply so the
  # same reply isn't processed (or re-escalated) on the next tick.
  #
  # Needs `our_login` (config["review_patrol"]["our_login"]) to know which
  # threads are ours, and the PR author login (from the adapter's get/1) to tell
  # an author's reply apart from another reviewer's comment (decision 6). When
  # either is unavailable, we conservatively skip — never guessing.
  defp maybe_handle_author_replies(%Issue{} = engagement, pr, adapter, workspace, rig_name) do
    with our_login when is_binary(our_login) and our_login != "" <- our_login(workspace),
         pr_author when is_binary(pr_author) and pr_author != "" <- Map.get(pr, :author),
         true <- function_exported?(adapter, :list_open_review_threads, 1),
         {:ok, threads} when is_list(threads) <-
           adapter.list_open_review_threads(engagement.source_pr) do
      cursor = parse_comment_cursor(engagement.last_seen_comment_id)

      replies =
        threads
        |> filter_our_threads(adapter, our_login)
        |> new_author_replies(cursor, pr_author)

      case replies do
        [] -> nil
        _ -> act_on_author_replies(engagement, replies, adapter, workspace, rig_name)
      end
    else
      _ -> nil
    end
  end

  # Handle the new author replies for one engagement. We reply to / escalate on
  # the single most-recent reply (the current question) and advance the cursor
  # past ALL new replies in this batch — so a burst of replies yields exactly one
  # action and never re-fires.
  defp act_on_author_replies(%Issue{} = engagement, replies, adapter, workspace, rig_name) do
    {thread, comment} = Enum.max_by(replies, fn {_t, c} -> c[:id] end)
    max_id = replies |> Enum.map(fn {_t, c} -> c[:id] end) |> Enum.max()

    outcome =
      case automation_mode(engagement, workspace, rig_name) do
        :auto ->
          dispatch_reply(engagement, thread, comment, adapter, workspace)

        # report-only, flag, and off all post NOTHING to the PR — escalate the
        # reply to the coordinator and let a human decide (bd-36qzgx, bd-7opdaf).
        mode when mode in [:report_only, :flag, :off] ->
          escalate_reply(engagement, thread, comment, adapter)
      end

    # Advance the high-watermark cursor whether we replied, escalated, or the
    # dispatch failed: a failed reply is logged, and advancing keeps a broken
    # reply from re-dispatching (or re-escalating) every tick.
    advance_comment_cursor(engagement, max_id)
    outcome
  end

  # :auto — dispatch the distinct ReviewReply workflow (task F). It composes and
  # posts a threaded reply via the adapter; it runs review_only (no worktree, no
  # tracker writes), so the hard invariant holds.
  defp dispatch_reply(%Issue{} = engagement, thread, comment, adapter, workspace) do
    state = %{
      adapter: adapter,
      mr_ref: engagement.source_pr,
      thread: thread,
      comment_id: comment[:id],
      workspace: workspace,
      adapter_opts: %{}
    }

    case Arbiter.Workflow.run(ReviewReply, state) do
      {:ok, _final} ->
        Logger.info(
          "ReviewPatrol: replied to author on engagement #{engagement.id} " <>
            "(comment #{comment[:id]})"
        )

        {:replied, engagement.id}

      {:error, reason} ->
        Logger.warning(
          "ReviewPatrol: reply workflow failed for engagement #{engagement.id}: " <>
            inspect(reason)
        )

        nil
    end
  end

  # :flag — post NOTHING to the PR. Raise ONE addressed coordinator escalation
  # (to_ref "coordinator") so a human decides whether to reply or re-review. The
  # cursor advance in the caller dedupes: we escalate a given reply exactly once.
  defp escalate_reply(%Issue{workspace_id: ws_id} = engagement, thread, comment, adapter)
       when is_binary(ws_id) do
    author = comment[:author] || "author"
    link = safe_link(adapter, engagement.source_pr)

    body =
      [
        "PR ##{engagement.source_pr} (author @#{author}) replied on a review thread we own — " <>
          "needs a reply or re-review, awaiting direction.",
        link && "Link: #{link}",
        thread[:path] && "File: #{thread[:path]}",
        "Reply: #{comment_snippet(comment)}",
        "Automation mode is :flag, so ReviewPatrol posted NOTHING to the PR."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    _ =
      safe(fn ->
        Arbiter.Messages.Message.send_mail(%{
          kind: :escalation,
          to_ref: Arbiter.Messages.Message.coordinator_ref(),
          from_ref: engagement.id,
          workspace_id: ws_id,
          task_ref: engagement.id,
          subject: "PR ##{engagement.source_pr} (author @#{author}) replied — awaiting direction",
          body: body
        })
      end)

    {:escalated, engagement.id}
  end

  defp escalate_reply(%Issue{} = engagement, _thread, _comment, _adapter),
    do: {:escalated, engagement.id}

  # Keep only the threads we participated in, via task E's `filter_to_our_threads/2`
  # when the adapter exports it (Github). Fall back to the same participation test
  # inline for adapters that don't (so the gate degrades safely, never widens).
  defp filter_our_threads(threads, adapter, our_login) do
    if function_exported?(adapter, :filter_to_our_threads, 2) do
      adapter.filter_to_our_threads(threads, our_login)
    else
      Enum.filter(threads, fn t ->
        t[:author] == our_login or
          Enum.any?(Map.get(t, :comments) || [], &(&1[:author] == our_login))
      end)
    end
  end

  # The {thread, comment} pairs whose comment is (a) newer than the cursor and
  # (b) authored by the PR author. Comments by us or by other reviewers are
  # dropped — only the author's own replies count (decision 6).
  defp new_author_replies(threads, cursor, pr_author) do
    for thread <- threads,
        comment <- Map.get(thread, :comments) || [],
        is_integer(comment[:id]),
        comment[:id] > cursor,
        comment[:author] == pr_author do
      {thread, comment}
    end
  end

  # `last_seen_comment_id` is stored as a string (JSON-friendly); comment ids are
  # integers (GitHub databaseId). nil / unparseable → 0 (treat everything as new).
  defp parse_comment_cursor(nil), do: 0
  defp parse_comment_cursor(n) when is_integer(n), do: n

  defp parse_comment_cursor(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _rest} -> n
      :error -> 0
    end
  end

  defp parse_comment_cursor(_), do: 0

  defp advance_comment_cursor(%Issue{} = engagement, max_id) when is_integer(max_id) do
    update_engagement(engagement, %{last_seen_comment_id: Integer.to_string(max_id)})
  end

  defp advance_comment_cursor(_engagement, _max_id), do: :ok

  defp our_login(%Workspace{} = workspace), do: Workspace.review_patrol_our_login(workspace)
  defp our_login(_workspace), do: nil

  # Best-effort human-facing PR link for the escalation body; nil if the adapter
  # can't build one.
  defp safe_link(adapter, source_pr) do
    if function_exported?(adapter, :link_for, 1) do
      case safe(fn -> adapter.link_for(source_pr) end) do
        url when is_binary(url) and url != "" -> url
        _ -> nil
      end
    else
      nil
    end
  end

  @snippet_limit 280
  defp comment_snippet(%{} = comment) do
    case comment[:body] do
      body when is_binary(body) and body != "" ->
        trimmed = String.trim(body)

        if String.length(trimmed) > @snippet_limit,
          do: String.slice(trimmed, 0, @snippet_limit) <> "…",
          else: trimmed

      _ ->
        "(no text)"
    end
  end

  # ---- guards / helpers --------------------------------------------------

  # The engagement's automation stance (task B). Re-resolved from the workspace's
  # LIVE `review_automation.repo_overrides[rig_name]` on every tick (bd-3cpcw2):
  # a repo override is author-independent and is checked fresh — never just
  # trusted from `engagement.review_automation` — meaning a repo flipped to
  # `report_only`/`flag` immediately stops an in-flight engagement from
  # auto-posting, instead of only gating NEW dispatches. When no override
  # applies to this repo, we fall back to the mode captured at dispatch time
  # (the `auto_authors`/`default` resolution, which still needs the PR author
  # and isn't re-derived here). A missing/unresolvable value is treated
  # conservatively as `:flag` — matching `ReviewAutomation`'s default — so
  # ReviewPatrol never auto-posts against an engagement that was never opted
  # into automatic re-review.
  #
  # The live override and the stored (dispatch-time) mode can disagree in
  # either direction — e.g. a coordinator can dispatch `worker_review` with an
  # explicit hard `automation: "report_only"` override even on a repo whose
  # `repo_overrides` says `auto` (the explicit dispatch arg wins per
  # `Tools.guard_review_automation/3`), which is stored as `:report_only`
  # on the engagement. We must never let a *more permissive* live override
  # widen that back out to auto-posting — only a downgrade (more restrictive)
  # should take immediate effect. So we take the more restrictive of the two,
  # never the more permissive:
  #
  #   :auto        — re-review AND post to the PR.
  #   :report_only — re-review but post NOTHING; report proposed comments to the
  #                  coordinator to greenlight (infra default, bd-36qzgx).
  #   :flag        — do NOT review; surface new commits / replies as a flag.
  #   :off         — hard opt-out (bd-7opdaf): never dispatch a reviewer at
  #                  all. Same non-dispatching behavior as :flag, but ranked
  #                  MORE restrictive so a repo flipped to :off downgrades an
  #                  in-flight engagement immediately, exactly like the
  #                  existing report_only downgrade.
  defp automation_mode(%Issue{} = engagement, workspace, rig_name) do
    stored = stored_automation_mode(engagement)

    case ReviewAutomation.repo_override_mode(workspace_config(workspace), rig_name) do
      mode when mode in [:auto, :report_only, :flag, :off] -> most_restrictive(stored, mode)
      nil -> stored
    end
  end

  defp workspace_config(%Workspace{config: config}), do: config
  defp workspace_config(_workspace), do: nil

  defp stored_automation_mode(%Issue{review_automation: :auto}), do: :auto
  defp stored_automation_mode(%Issue{review_automation: :report_only}), do: :report_only
  defp stored_automation_mode(%Issue{review_automation: :off}), do: :off
  defp stored_automation_mode(_engagement), do: :flag

  # Pick whichever of the two modes posts/reviews less — never let a live
  # repo-override widen posting behavior beyond what was captured at dispatch.
  defp most_restrictive(a, b), do: Enum.max_by([a, b], &restriction_rank/1)

  defp restriction_rank(:auto), do: 0
  defp restriction_rank(:report_only), do: 1
  defp restriction_rank(:flag), do: 2
  defp restriction_rank(:off), do: 3

  @doc false
  # Reverse `repo` (the "owner/repo" string a patrol is started with, from
  # `ReviewPatrolSupervisor.patrol_repos/1`) back to the bare rig/repo-config
  # name that `review_automation.repo_overrides` is keyed by (bd-3cpcw2) — the
  # same identifier `worker_review`'s `args["repo"]` uses at dispatch time
  # (`Arbiter.Mcp.Tools.guard_review_automation/3`). Public (not just used by
  # this module's own ticks) so `ReviewPatrolSupervisor` can resolve the same
  # rig name to gate patrol startup on a repo's `:off`-mode override
  # (bd-4brb2j) without duplicating the repo_paths-remote-resolution logic.
  #
  # Single-repo workspaces: `merge.config.repo` IS that bare name directly.
  # Multi-repo workspaces: find the `repo_paths` entry whose git
  # remote resolves to this "owner/repo" and use its key.
  def rig_name_for_repo(%Workspace{config: config}, repo) when is_binary(repo) and repo != "" do
    config = config || %{}

    case get_in(config, ["merge", "config", "repo"]) do
      name when is_binary(name) and name != "" -> name
      _ -> rig_name_from_repo_paths(config, repo)
    end
  end

  def rig_name_for_repo(_workspace, _repo), do: nil

  defp rig_name_from_repo_paths(config, repo) do
    rig_map = Map.get(config, "repo_paths") || %{}

    Enum.find_value(rig_map, fn {rig_name, rig_config} ->
      with path when is_binary(path) <- RepoConfig.repo_path_from_config(rig_config),
           {:ok, {owner, r}} <- RepoResolver.from_remote(path),
           true <- "#{owner}/#{r}" == repo do
        rig_name
      else
        _ -> nil
      end
    end)
  rescue
    _ -> nil
  end

  # CI has "settled" when the head's pipeline is not actively running/pending, so
  # a re-review lands on a diff whose checks are done rather than firing on every
  # intermediate push. A nil pipeline (no checks / unknown) counts as settled.
  #
  # `:not_started` (bd-aeb9wv / #1189) is deliberately NOT in @unsettled_ci,
  # unlike the Watchdog's merge-gate (`Watchdog.ci_pending?/1`), even though
  # both read the same GitHub adapter signal. The two consumers have opposite
  # failure modes for treating zero-check-runs as "wait": the Watchdog hard-
  # fails the worker after `max_polls`, so it bounds the wait
  # (`@not_started_grace_polls`) before falling through. ReviewPatrol has no
  # such fallthrough here — `ci_settled?/1` only gates *when* a re-review
  # fires, and ReviewPatrol re-checks on its own poll interval regardless, so
  # treating `:not_started` as unsettled with no bound would mean a repo with
  # no CI configured at all never gets re-reviewed on new commits (the
  # pipeline never leaves `:not_started`). Counting it as settled matches the
  # pre-existing `nil` behavior: worst case a re-review lands slightly before
  # checks start, which is a stale-signal nuisance, not a merge-safety bug.
  defp ci_settled?(%{pipeline: status}) when status in @unsettled_ci, do: false
  defp ci_settled?(_pr), do: true

  # Debounce: suppress a re-review while now - last_reviewed_at is inside the
  # configured window. No prior review timestamp → not debounced.
  defp debounced?(%Issue{last_reviewed_at: nil}, _workspace), do: false

  defp debounced?(%Issue{last_reviewed_at: %DateTime{} = at}, workspace) do
    DateTime.diff(DateTime.utc_now(), at, :millisecond) < debounce_ms(workspace)
  end

  defp debounced?(_engagement, _workspace), do: false

  defp debounce_ms(%Workspace{config: config}) do
    case get_in(config || %{}, ["review_patrol", "debounce_ms"]) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> app_debounce_ms()
    end
  end

  defp debounce_ms(_workspace), do: app_debounce_ms()

  defp app_debounce_ms,
    do: Application.get_env(:arbiter, :review_patrol_debounce_ms, @default_debounce_ms)

  defp fetch_new_diff(adapter, source_pr, opts) do
    if function_exported?(adapter, :get_diff, 2) do
      adapter.get_diff(source_pr, opts)
    else
      {:error, :get_diff_unsupported}
    end
  end

  # A re-review is relevant only when the new diff touches a file we previously
  # flagged. Empty `posted_findings` → nothing flagged → never relevant (we don't
  # re-review a PR we've raised no findings on).
  defp relevant?(posted_findings, diff) do
    flagged =
      posted_findings
      |> List.wrap()
      |> Enum.map(&stored_field(&1, "file"))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> MapSet.new()

    not MapSet.disjoint?(flagged, changed_files(diff))
  end

  # The set of file paths a unified diff touches, read from its `--- a/…` and
  # `+++ b/…` headers (git prefixes stripped, `/dev/null` ignored).
  defp changed_files(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.flat_map(&file_from_diff_line/1)
    |> MapSet.new()
  end

  defp changed_files(_diff), do: MapSet.new()

  defp file_from_diff_line("+++ " <> rest), do: strip_diff_path(rest)
  defp file_from_diff_line("--- " <> rest), do: strip_diff_path(rest)
  defp file_from_diff_line(_line), do: []

  defp strip_diff_path(rest) do
    path =
      rest
      |> String.split("\t", parts: 2)
      |> List.first()
      |> to_string()
      |> String.trim()

    cond do
      path in ["/dev/null", ""] -> []
      String.starts_with?(path, "a/") -> [String.replace_prefix(path, "a/", "")]
      String.starts_with?(path, "b/") -> [String.replace_prefix(path, "b/", "")]
      true -> [path]
    end
  end

  # {file, line, message} identity of a fresh check finding (atom-keyed).
  defp finding_key(%{} = f), do: {f[:file], f[:line], f[:message]}

  # The same identity from findings we stored earlier (JSON round-trips to
  # string keys), as a MapSet for O(1) de-dupe lookup.
  defp prior_finding_keys(findings) do
    findings
    |> List.wrap()
    |> Enum.map(fn f ->
      {stored_field(f, "file"), stored_field(f, "line"), stored_field(f, "message")}
    end)
    |> MapSet.new()
  end

  # Normalize a fresh finding into the string-keyed shape we persist.
  defp stored_finding(%{} = f) do
    %{
      "file" => f[:file] || f["file"],
      "line" => f[:line] || f["line"],
      "message" => f[:message] || f["message"],
      "severity" => to_string(f[:severity] || f["severity"] || "")
    }
  end

  # Read a field from a stored finding tolerating either key form.
  defp stored_field(%{} = f, key) when is_binary(key),
    do: Map.get(f, key) || Map.get(f, String.to_existing_atom(key))

  defp stored_field(_f, _key), do: nil

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # Delay until the next tick: the idle-backed-off interval (bd-4brb2j — grows
  # with consecutive outcome-free ticks, capped at @idle_backoff_ceiling_ms),
  # then jittered +/- 15% so patrols started within milliseconds of each other
  # at boot drift apart instead of ticking in lockstep forever. Independent of
  # the rate-limit circuit breaker's own pause window (bd-1m8k7d), which
  # already suppresses forge calls while open regardless of this schedule.
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
