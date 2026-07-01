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

    * **New-diff-only** — the re-review diffs `last_reviewed_sha..head_sha` (the
      adapter's compare endpoint), never the whole PR, so comments land only on the
      newly-pushed commits.

    * **Never re-post an unchanged finding** — new findings are de-duped against
      `posted_findings` by `{file, line, message}` before anything is posted.

  On a completed re-review we append the newly-posted findings to `posted_findings`
  and advance `last_reviewed_sha` to `head_sha` (and stamp `last_reviewed_at`).

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
  alias Arbiter.Tasks.Issue
  alias Arbiter.Workflows.CodeReview
  alias Arbiter.{Mergers, Tasks.Workspace}
  require Ash.Query
  require Logger

  @default_interval_ms 60_000

  # Default debounce window: at most one new-commit re-review per 5 minutes per
  # engagement. Overridable per-workspace (config["review_patrol"]["debounce_ms"])
  # and via the :review_patrol_debounce_ms app env.
  @default_debounce_ms 5 * 60_000

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
    last_flagged: [],
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
         last_flagged: state.last_flagged,
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
        state.workspace_id
        |> open_engagements()
        |> Enum.map(&process_engagement(&1, adapter, workspace))
        |> Enum.filter(& &1)
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
        last_flagged: for({:flagged, id} <- outcomes, do: id),
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

  # Returns a tagged outcome for the tick's bookkeeping:
  #   {:terminated, id} — the source PR merged/closed and the engagement closed
  #   {:rereviewed, id} — a new-commit re-review was posted this tick
  #   nil               — nothing actionable (first-sighting SHA record, no
  #                        advance, guard suppressed, or an adapter error)
  defp process_engagement(%Issue{source_pr: source_pr} = engagement, adapter, workspace)
       when is_binary(source_pr) and source_pr != "" do
    case adapter.get(source_pr) do
      {:ok, %{status: status}} when status in [:merged, :closed] ->
        case terminate_engagement(engagement, status) do
          nil -> nil
          id -> {:terminated, id}
        end

      {:ok, %{status: :open} = pr} ->
        handle_open_pr(engagement, pr, adapter, workspace)

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

  defp process_engagement(_engagement, _adapter, _workspace), do: nil

  # An open source PR. First sighting (last_reviewed_sha unset) → record the head
  # SHA and stop. Otherwise, if the head advanced, consider a new-commit
  # re-review under the spam guards; a head that hasn't moved is a no-op.
  defp handle_open_pr(%Issue{last_reviewed_sha: nil} = engagement, pr, _adapter, _workspace) do
    maybe_record_head_sha(engagement, pr)
    nil
  end

  defp handle_open_pr(
         %Issue{last_reviewed_sha: last} = engagement,
         %{head_sha: head} = pr,
         adapter,
         workspace
       )
       when is_binary(head) and head != "" and head != last do
    maybe_rereview(engagement, pr, adapter, workspace)
  end

  defp handle_open_pr(_engagement, _pr, _adapter, _workspace), do: nil

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
  defp maybe_rereview(%Issue{} = engagement, pr, adapter, workspace) do
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

      true ->
        gate_on_relevance(engagement, pr, adapter, workspace)
    end
  end

  # Fetch the diff SINCE `last_reviewed_sha` (new-diff-only) and re-review only
  # when it touches a file we previously flagged. A push that touches only
  # unrelated files is not our concern and is skipped without advancing anything.
  defp gate_on_relevance(engagement, pr, adapter, workspace) do
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
          act_on_new_commits(engagement, pr.head_sha, adapter, workspace, opts)
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

  defp act_on_new_commits(engagement, head, adapter, workspace, opts) do
    case automation_mode(engagement) do
      :auto -> run_rereview(engagement, head, adapter, workspace, opts)
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
      posted_findings: merged
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

  # ---- guards / helpers --------------------------------------------------

  # The engagement's automation stance (task B), persisted at dispatch. A missing
  # value is treated conservatively as `:flag` — matching `ReviewAutomation`'s
  # default — so ReviewPatrol never auto-posts against an engagement that was
  # never opted into automatic re-review.
  defp automation_mode(%Issue{review_automation: :auto}), do: :auto
  defp automation_mode(_engagement), do: :flag

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
