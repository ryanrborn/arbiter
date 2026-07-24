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
      indefinitely (bd-ahvk03).

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
  """

  use GenServer

  alias Arbiter.Agents
  alias Arbiter.Mergers.Github.RepoResolver
  alias Arbiter.Tasks.{Issue, RepoConfig}
  alias Arbiter.Worker.ReviewAutomation
  alias Arbiter.Workflows.{CodeReview, ReviewReply}
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

  defstruct [
    :repo,
    :workspace_id,
    :workspace,
    :interval_ms,
    :timer_ref,
    ticks: 0,
    last_terminated: [],
    last_rereviewed: [],
    last_reported: [],
    last_flagged: [],
    last_replied: [],
    last_escalated: [],
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
         last_terminated: state.last_terminated,
         last_rereviewed: state.last_rereviewed,
         last_reported: state.last_reported,
         last_flagged: state.last_flagged,
         last_replied: state.last_replied,
         last_escalated: state.last_escalated,
         last_tick_at: state.last_tick_at
       }, state}

  @impl true
  def handle_info(:tick, state) do
    new_state = do_tick(state) |> schedule_next()
    {:noreply, new_state}
  end

  # ---- tick logic ----

  defp do_tick(state) do
    # Re-fetch the workspace on every tick so config changes take effect
    # immediately without a GenServer restart (mirrors PRPatrol).
    workspace =
      case Ash.get(Workspace, state.workspace_id) do
        {:ok, ws} -> ws
        _ -> nil
      end

    outcomes =
      with %Workspace{} <- workspace,
           adapter when not is_nil(adapter) <- resolve_adapter(workspace),
           true <- function_exported?(adapter, :get, 1),
           :ok <- Mergers.prepare_with_repo(workspace, state.repo) do
        rig_name = rig_name_for_repo(workspace, state.repo)

        state.workspace_id
        |> open_engagements()
        |> process_engagements_paced(adapter, workspace, rig_name)
      else
        # On any failure (missing workspace, unsupported adapter), no-op the
        # cycle but still bump the tick counter below so the patrol is observable.
        _ -> []
      end

    %{
      state
      | ticks: state.ticks + 1,
        last_tick_at: DateTime.utc_now(),
        last_terminated: for({:terminated, id} <- outcomes, do: id),
        last_rereviewed: for({:rereviewed, id} <- outcomes, do: id),
        last_reported: for({:reported, id} <- outcomes, do: id),
        last_flagged: for({:flagged, id} <- outcomes, do: id),
        last_replied: for({:replied, id} <- outcomes, do: id),
        last_escalated: for({:escalated, id} <- outcomes, do: id),
        workspace: workspace
    }
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

  # OPEN review engagements for this workspace: review_only tasks with a linked
  # source PR that are not yet closed. The `review_only == true` filter is what
  # keeps this disjoint from PRPatrol's author-side follow-ups (review_only ==
  # false), so the two patrols never act on each other's tasks.
  defp open_engagements(workspace_id) do
    Issue
    |> Ash.Query.filter(
      review_only == true and not is_nil(source_pr) and status != :closed and
        workspace_id == ^workspace_id
    )
    |> Ash.read!()
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

  defp process_engagements_paced(engagements, adapter, workspace, rig_name) do
    engagements
    |> Enum.with_index()
    |> Enum.map(fn {engagement, index} ->
      if index > 0, do: pace_delay()
      process_engagement(engagement, adapter, workspace, rig_name)
    end)
    |> Enum.filter(& &1)
  end

  defp pace_delay do
    ms = @pace_base_ms + :rand.uniform(@pace_jitter_ms)

    case Application.get_env(:arbiter, :review_patrol_pace_sleep_fun) do
      fun when is_function(fun, 1) -> fun.(ms)
      _ -> Process.sleep(ms)
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
  #   nil               — nothing actionable (first-sighting SHA record, no
  #                        advance, guard suppressed, no new replies, or an
  #                        adapter error)
  defp process_engagement(
         %Issue{source_pr: source_pr} = engagement,
         adapter,
         workspace,
         rig_name
       )
       when is_binary(source_pr) and source_pr != "" do
    case adapter.get(source_pr) do
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

  defp process_engagement(_engagement, _adapter, _workspace, _rig_name), do: nil

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
  defp handle_review_cap(%Issue{review_cap_escalated: true} = _engagement, _workspace), do: nil

  defp handle_review_cap(%Issue{} = engagement, workspace) do
    escalate_review_cap(engagement, workspace)
    update_engagement(engagement, %{review_cap_escalated: true})

    Logger.info(
      "ReviewPatrol: engagement #{engagement.id} hit the review cap " <>
        "(#{engagement.review_count} reviews); escalated and stopped re-reviewing"
    )

    {:escalated, engagement.id}
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
          directive_ref: engagement.id,
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
        if relevant?(engagement.posted_findings, diff) do
          act_on_new_commits(engagement, pr.head_sha, adapter, workspace, opts, rig_name)
        else
          Logger.info(
            "ReviewPatrol: new commits on engagement #{engagement.id} touch no previously-" <>
              "flagged file; skipping re-review"
          )

          nil
        end

      {:error, reason} ->
        Logger.info(
          "ReviewPatrol: could not fetch new diff for engagement #{engagement.id}: " <>
            inspect(reason)
        )

        nil
    end
  end

  defp act_on_new_commits(engagement, head, adapter, workspace, opts, rig_name) do
    case automation_mode(engagement, workspace, rig_name) do
      :auto -> run_rereview(engagement, head, adapter, workspace, opts)
      :report_only -> report_rereview(engagement, head, adapter, workspace, opts)
      :flag -> flag_new_commits(engagement, head, workspace)
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
      check_runner: dedupe_runner(prior_keys)
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
      check_runner: dedupe_runner(prior_keys)
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
          directive_ref: engagement.id,
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
          directive_ref: engagement.id,
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

        # report-only and flag both post NOTHING to the PR — escalate the reply
        # to the coordinator and let a human decide (bd-36qzgx).
        mode when mode in [:report_only, :flag] ->
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
          directive_ref: engagement.id,
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
  # `Tools.resolve_review_automation_mode/2`), which is stored as `:report_only`
  # on the engagement. We must never let a *more permissive* live override
  # widen that back out to auto-posting — only a downgrade (more restrictive)
  # should take immediate effect. So we take the more restrictive of the two,
  # never the more permissive:
  #
  #   :auto        — re-review AND post to the PR.
  #   :report_only — re-review but post NOTHING; report proposed comments to the
  #                  coordinator to greenlight (infra default, bd-36qzgx).
  #   :flag        — do NOT review; surface new commits / replies as a flag.
  defp automation_mode(%Issue{} = engagement, workspace, rig_name) do
    stored = stored_automation_mode(engagement)

    case ReviewAutomation.repo_override_mode(workspace_config(workspace), rig_name) do
      mode when mode in [:auto, :report_only, :flag] -> most_restrictive(stored, mode)
      nil -> stored
    end
  end

  defp workspace_config(%Workspace{config: config}), do: config
  defp workspace_config(_workspace), do: nil

  defp stored_automation_mode(%Issue{review_automation: :auto}), do: :auto
  defp stored_automation_mode(%Issue{review_automation: :report_only}), do: :report_only
  defp stored_automation_mode(_engagement), do: :flag

  # Pick whichever of the two modes posts/reviews less — never let a live
  # repo-override widen posting behavior beyond what was captured at dispatch.
  defp most_restrictive(a, b), do: Enum.max_by([a, b], &restriction_rank/1)

  defp restriction_rank(:auto), do: 0
  defp restriction_rank(:report_only), do: 1
  defp restriction_rank(:flag), do: 2

  # Reverse `state.repo` (the "owner/repo" string this patrol was started with,
  # from `ReviewPatrolSupervisor.patrol_repos/1`) back to the bare rig/repo-config
  # name that `review_automation.repo_overrides` is keyed by (bd-3cpcw2) — the
  # same identifier `worker_review`'s `args["repo"]` uses at dispatch time
  # (`Arbiter.Mcp.Tools.resolve_review_automation_mode/2`).
  #
  # Single-repo workspaces: `merge.config.repo` IS that bare name directly.
  # Multi-repo workspaces: find the `repo_paths`/`rig_paths` entry whose git
  # remote resolves to this "owner/repo" and use its key.
  defp rig_name_for_repo(%Workspace{config: config}, repo) when is_binary(repo) and repo != "" do
    config = config || %{}

    case get_in(config, ["merge", "config", "repo"]) do
      name when is_binary(name) and name != "" -> name
      _ -> rig_name_from_rig_paths(config, repo)
    end
  end

  defp rig_name_for_repo(_workspace, _repo), do: nil

  defp rig_name_from_rig_paths(config, repo) do
    rig_map = Map.get(config, "repo_paths") || Map.get(config, "rig_paths") || %{}

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

  defp schedule_next(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :tick, state.interval_ms)
    %{state | timer_ref: ref}
  end
end
