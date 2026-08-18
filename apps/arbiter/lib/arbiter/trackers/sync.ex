defmodule Arbiter.Trackers.Sync do
  @moduledoc """
  Loud, escalation-raising orchestration for external-tracker lifecycle sync.

  Two entry points, both tracker-agnostic:

    * `lifecycle/3` — drive a richer lifecycle moment that isn't a task status
      change (PR opened, review approved-but-parked). It seeds the adapter
      config from the task's workspace, transitions the external item toward
      the mapped target status (multi-hop path-finding lives in the adapter),
      and — for `:pr_opened` — attaches the PR as a comment + remote link.

    * `notify_failure/3` — the shared failure surface. The original incident
      (VR-17911 never auto-transitioned) was invisible because tracker errors
      were silently swallowed. This logs loudly **and** raises an
      escalation so a `status_map` / workflow mismatch can't hide.

  ## Benign vs. loud

  Not every non-`:ok` is a problem. A tracker that simply doesn't model a given
  lifecycle event (e.g. GitHub has no "In Code Review") returns
  `:status_unmapped` / `:transition_not_found` / `:not_supported` — we skip
  quietly. A *mapped* status that can't be reached (`:no_transition_path`) or a
  real wire failure (auth, 5xx, network) is loud + escalation. See `loud?/1`.

  ## Already-at-target-state recovery

  A `:validation_failed` from the tracker is normally loud, but it can be a
  benign race: e.g. GitHub auto-closes an issue via a `Closes #N` keyword
  between Arbiter's pre-flight GET (which saw "open") and the subsequent PATCH.
  `do_transition/2` re-fetches the upstream item after a `validation_failed` and
  suppresses the escalation if the item is already at the desired state — the
  transition was a no-op, not a real failure.

  ## Idempotency of the retried call (bd-1wplms)

  Only `:rate_limited` failures are retried (see `do_transition/3`), and only
  the status-transition call itself — `Trackers.transition/2`. That call is
  safe to repeat for every adapter: each one reads the upstream item's current
  state first and only issues a write if it isn't already there (GitHub/GitLab
  compare `state` + label; Jira walks the live workflow graph from the item's
  actual current status; Shortcut checks `completed`). A rate-limited response
  means GitHub/GitLab/Jira rejected the request before applying it, so retrying
  a request that never took effect cannot double-apply — and if a prior
  attempt's write *did* land despite our client not observing the response,
  the next attempt's read sees the target state and no-ops rather than
  re-issuing the write.

  `Trackers.update_fields/2` (the gated-field push in
  `ensure_gated_fields_pushed/2`) is a plain "set these fields to these
  values" PUT/PATCH — repeating it with the same values is a no-op, so it
  would also be safe to retry, though it currently is not (see below).

  The one non-idempotent write in this module, `add_comment/2` (posting the
  `:pr_opened` PR-link comment), is deliberately **outside** the retry loop:
  `comment_pr/2` calls it directly, not through `do_transition/3`, so a
  rate-limited comment post fails (or escalates) once rather than risking a
  duplicate comment on retry.
  """

  require Logger

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Trackers
  alias Arbiter.Trackers.Jira

  @doc """
  Drive a lifecycle event for the task's external tracker. Best-effort and
  always returns `:ok` — failures are logged + escalated, never raised, so the
  caller's own lifecycle is never disrupted.

  Recognised `opts`:
    * `:pr_url` — the PR/MR URL, used for the `:pr_opened` comment + remote link.
    * `:pr_title` — optional label for the remote link (defaults from `:pr_url`).
  """
  @spec lifecycle(Issue.t(), atom(), keyword()) :: :ok
  def lifecycle(%Issue{} = issue, event, opts \\ []) when is_atom(event) do
    cond do
      issue.tracker_type == :none -> :ok
      blank?(issue.tracker_ref) -> :ok
      true -> do_lifecycle(issue, event, opts)
    end
  rescue
    e ->
      Logger.warning(
        "Trackers.Sync: error on #{event} for task=#{issue.id}: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning("Trackers.Sync: exit on #{event} for task=#{issue.id}: #{inspect(reason)}")
      :ok
  end

  defp do_lifecycle(issue, event, opts) do
    Trackers.prepare(issue, load_workspace(issue.workspace_id))

    transition_event(issue, event)

    if event == :pr_opened, do: attach_pr_artifacts(issue, opts)

    :ok
  end

  @doc """
  Transition the task's external item toward the status mapped from `event`,
  surfacing any genuine failure loudly (log + escalation). Returns `:ok` on
  success or a benign skip, `{:error, reason}` only after escalating a loud
  failure (so callers that care can react; most ignore it).

  Used by `lifecycle/3` and by `Arbiter.Tasks.Issue.Changes.SyncTracker` for
  the core status-change path so the swallow-on-error behaviour is gone from
  both.
  """
  @spec transition_event(Issue.t(), atom()) :: :ok | {:error, term()}
  def transition_event(%Issue{} = issue, event) when is_atom(event) do
    case ensure_gated_fields_pushed(issue, event) do
      :ok ->
        do_transition(issue, event)

      {:error, reason} ->
        # Either a required field has no produced value (escalate naming it) or
        # pushing the produced values failed on the wire. Both are loud, and we
        # do NOT attempt the transition the provider would reject anyway.
        notify_failure(issue, event, reason)
        {:error, reason}
    end
  end

  # Bounded retries with backoff for a rate-limited tracker (bd-2wilou): a
  # transient 403/429 used to be treated as a genuine failure and escalated
  # immediately, stranding the transition (a `closed` transition dropped this
  # way is exactly how tasks accumulate open upstream issues after the local
  # close already succeeded). Honors the adapter's `retry_after_ms` (GitHub's
  # `Retry-After` / `x-ratelimit-reset`) when present, else falls back to
  # exponential backoff. Only `:rate_limited` gets this treatment — every
  # other error kind still fails (or escalates) on the first attempt.
  @max_rate_limit_retries 3
  @base_rate_limit_backoff_ms 1_000
  @max_rate_limit_backoff_ms 30_000

  defp do_transition(issue, event), do: do_transition(issue, event, 0, monotonic_ms())

  defp do_transition(issue, event, attempt, start_ms) do
    case Trackers.transition(issue, event) do
      :ok ->
        :ok

      {:error, %{kind: :rate_limited} = reason} when attempt < @max_rate_limit_retries ->
        wait_ms = rate_limit_wait_ms(reason, attempt)

        Logger.warning(
          "Trackers.Sync: rate-limited syncing task=#{issue.id} tracker=#{issue.tracker_type} " <>
            "on #{event} (attempt #{attempt + 1}/#{@max_rate_limit_retries}) — " <>
            "retrying in #{wait_ms}ms: #{describe(reason)}"
        )

        sleep(wait_ms)
        do_transition(issue, event, attempt + 1, start_ms)

      {:error, %{kind: :validation_failed} = reason} ->
        # A validation_failed can be a race: e.g. GitHub auto-closed the issue via a
        # `Closes #N` keyword between our GET (which saw "open") and our PATCH. The
        # tracker rejects the redundant transition, but the desired end-state is already
        # reached. Re-fetch to confirm before escalating.
        if already_at_target?(issue, event) do
          Logger.debug(
            "Trackers.Sync: #{event} for task=#{issue.id} " <>
              "tracker=#{issue.tracker_type} ref=#{issue.tracker_ref} — " <>
              "upstream already at target state (benign no-op)"
          )

          :ok
        else
          notify_failure(issue, event, reason)
          {:error, reason}
        end

      {:error, reason} ->
        if loud?(reason) do
          # Reaches here for a `:rate_limited` error once retries are exhausted
          # too — `loud?/1` treats it like any other non-benign kind, so it
          # still escalates (deduplicated) rather than dropping silently.
          # Annotate with how many attempts were made and over what window so
          # the escalation body can say "we tried and GitHub kept refusing"
          # rather than "we gave up instantly" (acceptance criterion).
          reason = annotate_retry_exhausted(reason, attempt, start_ms)
          notify_failure(issue, event, reason)
          {:error, reason}
        else
          Logger.debug(
            "Trackers.Sync: #{event} not modelled by tracker=#{issue.tracker_type} " <>
              "for task=#{issue.id} (#{describe(reason)}) — skipping"
          )

          :ok
        end
    end
  end

  # Prefer the adapter's own retry hint (GitHub's `Retry-After` or
  # `x-ratelimit-reset`, surfaced as `retry_after_ms`); fall back to
  # exponential backoff with jitter when the adapter didn't supply one.
  defp rate_limit_wait_ms(reason, attempt) do
    case Map.get(reason, :retry_after_ms) do
      ms when is_integer(ms) and ms > 0 -> min(ms, @max_rate_limit_backoff_ms)
      _ -> backoff_ms(attempt)
    end
  end

  defp backoff_ms(attempt) do
    base = @base_rate_limit_backoff_ms * Integer.pow(2, attempt)
    jitter = :rand.uniform(div(base, 4) + 1)
    min(base + jitter, @max_rate_limit_backoff_ms)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  # Only a rate_limited reason carries retry history (every other kind fails
  # on the first attempt, so "1 attempt over ~0ms" would be noise). `attempt`
  # is the 0-indexed retry count reached, so the total tries made is
  # `attempt + 1`.
  defp annotate_retry_exhausted(%{kind: :rate_limited} = reason, attempt, start_ms) do
    base = if is_struct(reason), do: Map.from_struct(reason), else: reason

    Map.merge(base, %{
      retry_attempts: attempt + 1,
      retry_elapsed_ms: monotonic_ms() - start_ms
    })
  end

  defp annotate_retry_exhausted(reason, _attempt, _start_ms), do: reason

  # Overridable in tests (`Application.put_env(:arbiter, :tracker_sync_retry_sleep_fun, fun)`)
  # so rate-limit backoff never actually blocks the test suite.
  defp sleep(ms) do
    case Application.get_env(:arbiter, :tracker_sync_retry_sleep_fun) do
      fun when is_function(fun, 1) -> fun.(ms)
      _ -> Process.sleep(ms)
    end
  end

  # Fetch the upstream item and check whether it's already at the desired state
  # for `event`. Returns false on fetch failure so genuine unreachable-tracker
  # errors still escalate.
  defp already_at_target?(issue, event) do
    case Trackers.fetch(issue) do
      {:ok, raw} -> upstream_at_target?(issue.tracker_type, event, raw)
      {:error, _} -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp upstream_at_target?(:github, :closed, %{"state" => "closed"}), do: true
  defp upstream_at_target?(:gitlab, :closed, %{"state" => "closed"}), do: true

  # Jira supports the recovery check for any mapped event (not just
  # :closed) — e.g. :merged rejected because the ticket already advanced
  # past the target status. See `Jira.at_or_past_target?/2`.
  defp upstream_at_target?(:jira, event, raw), do: Jira.at_or_past_target?(raw, event)

  defp upstream_at_target?(:shortcut, :closed, %{"completed" => true}), do: true
  defp upstream_at_target?(_, _, _), do: false

  # Push the task's produced field values into the transition's gating fields
  # BEFORE the transition is attempted. The adapter (not this layer) decides
  # which fields gate the transition — see `Tracker.gating_fields/2` — so this
  # stays provider-agnostic: Jira's `field_ids` today, any future tracker via
  # its own adapter.
  #
  #   * No gate (`{:ok, []}`) → nothing to push, proceed to transition.
  #   * A required field with no produced value on the task → `{:error, ...}`
  #     naming the exact field (escalated by the caller).
  #   * All required fields have produced values → push them, then transition.
  #
  # A benign adapter reason (e.g. `:status_unmapped` — the tracker doesn't model
  # this event, so there's no transition to gate) is treated as "no gate"; the
  # transition path then skips it quietly.
  defp ensure_gated_fields_pushed(issue, event) do
    case Trackers.gating_fields(issue, event) do
      {:ok, []} ->
        :ok

      {:ok, fields} ->
        push_resolved_fields(issue, fields)

      {:error, reason} ->
        if loud?(reason), do: {:error, reason}, else: :ok
    end
  end

  defp push_resolved_fields(issue, fields) do
    {present, missing} =
      Enum.split_with(fields, fn f -> not blank?(field_value(issue, f)) end)

    cond do
      missing != [] ->
        {:error, missing_fields_reason(missing)}

      present == [] ->
        :ok

      true ->
        values = Map.new(present, fn f -> {f.key, field_value(issue, f)} end)

        case Trackers.update_fields(issue, values) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Returns the value to push for a gating field. Prefers the adapter's
  # pre-resolved `:value` (e.g. a Jira fix-version name resolved from workspace
  # config) over the task's produced value, so adapters can inject config-driven
  # scalars without coupling this layer to tracker internals.
  defp field_value(issue, f) do
    case Map.get(f, :value) do
      v when not is_nil(v) -> v
      _ -> produced_value(issue, f.key)
    end
  end

  # The task carries the worker-produced values under task-domain keys
  # (`:qa_notes`, `:deployment_notes`, `:description`, ...). A gating field with
  # no task-domain key (`nil`) has no produced value by definition.
  defp produced_value(_issue, nil), do: nil
  defp produced_value(issue, key) when is_atom(key), do: Map.get(issue, key)

  defp missing_fields_reason(missing) do
    names = missing |> Enum.map(& &1.name) |> Enum.uniq()

    %{
      kind: :gated_fields_missing,
      missing_fields: names,
      message:
        "the tracker gates this transition on field(s) the task hasn't produced: " <>
          "#{Enum.join(names, ", ")}. Produce the value(s) on the task " <>
          "(e.g. qa_notes / deployment_notes) and re-run the sync"
    }
  end

  # ETS table for deduplicating tracker-sync escalations across processes.
  # Entries are {task_id, event} → monotonic_ms. Initialized lazily on first use.
  @failure_dedup_table :tracker_sync_failure_dedup
  # One escalation per (task, event) per 5-minute window — covers concurrent
  # callers (Watchdog + MergeQueue, MergedPRFinalizer ticks) firing on the same
  # merge without spamming the coordinator mailbox.
  @failure_dedup_ttl_ms 300_000

  @doc """
  Log loudly and raise an escalation for a tracker-sync failure. The
  single place a swallowed-error regression would have to get past.

  Escalations are deduplicated: at most **one** escalation is raised per
  `(task_id, event)` pair within a #{div(@failure_dedup_ttl_ms, 60_000)}-minute
  window. Subsequent calls still log at `:error` level (for visibility) but
  suppress the coordinator mailbox message, preventing escalation-spam when multiple
  callers (Watchdog, MergeQueue, MergedPRFinalizer) fire the same failure in
  quick succession on a single merge.
  """
  @spec notify_failure(Issue.t(), atom(), term()) :: :ok
  def notify_failure(%Issue{} = issue, event, reason) do
    Logger.error(
      "Trackers.Sync: FAILED to sync task=#{issue.id} tracker=#{issue.tracker_type} " <>
        "ref=#{issue.tracker_ref} on #{event}: #{describe(reason)} — raising escalation. " <>
        log_hint(reason)
    )

    if failure_dedup_seen?(issue.id, event) do
      Logger.debug(
        "Trackers.Sync: suppressing duplicate escalation for task=#{issue.id} " <>
          "event=#{event} (same failure already escalated within " <>
          "#{div(@failure_dedup_ttl_ms, 1000)}s)"
      )
    else
      failure_dedup_record(issue.id, event)

      CoordinatorNotifier.tracker_sync_failed(
        %{
          task_id: issue.id,
          workspace_id: issue.workspace_id,
          tracker_type: issue.tracker_type,
          tracker_ref: issue.tracker_ref
        },
        event,
        reason
      )
    end

    :ok
  end

  defp failure_dedup_seen?(task_id, event) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@failure_dedup_table, {task_id, event}) do
      [{_, ts}] when now - ts < @failure_dedup_ttl_ms -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp failure_dedup_record(task_id, event) do
    ensure_failure_dedup_table()
    now = System.monotonic_time(:millisecond)
    :ets.insert(@failure_dedup_table, {{task_id, event}, now})
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_failure_dedup_table do
    :ets.new(@failure_dedup_table, [:set, :public, :named_table])
  catch
    :error, _ -> :ok
  end

  # ---- PR-open artifacts ---------------------------------------------------

  # PR-open: comment the PR URL onto the ticket and attach it as a remote link.
  # Both are tracker-agnostic (adapters that don't support them return
  # `:not_supported`, which we skip). A genuine wire failure is loud.
  defp attach_pr_artifacts(issue, opts) do
    case Keyword.get(opts, :pr_url) do
      url when is_binary(url) and url != "" ->
        title = Keyword.get(opts, :pr_title) || "PR for #{issue.id}"
        comment_pr(issue, url)
        link_pr(issue, url, title)

      _ ->
        :ok
    end
  end

  defp comment_pr(issue, url) do
    body = "Arbiter opened a pull request for this ticket: #{url}"

    case Trackers.add_comment(issue, body) do
      :ok ->
        :ok

      {:error, :not_supported} ->
        :ok

      {:error, reason} ->
        if loud?(reason), do: notify_failure(issue, :pr_comment, reason), else: :ok
    end
  end

  defp link_pr(issue, url, title) do
    case Trackers.add_remote_link(issue, url, title) do
      :ok ->
        :ok

      {:error, :not_supported} ->
        :ok

      {:error, reason} ->
        if loud?(reason), do: notify_failure(issue, :pr_remote_link, reason), else: :ok
    end
  end

  # ---- classification ------------------------------------------------------

  @benign_kinds ~w(status_unmapped transition_not_found not_supported config_missing)a

  @doc false
  # A failure worth an escalation vs. a benign "this tracker doesn't model it" skip.
  def loud?(:not_supported), do: false
  def loud?(%{kind: kind}) when kind in @benign_kinds, do: false
  def loud?(_), do: true

  defp describe(%{message: msg, kind: kind}) when is_binary(msg),
    do: "#{msg} (#{kind})"

  defp describe(reason), do: inspect(reason)

  # The describe/1 message already names the missing field and the remedy for a
  # gated-fields failure, so don't append the (misleading) status_map hint.
  defp log_hint(%{kind: :gated_fields_missing}), do: ""

  # Provider's real error is already in the describe/1 output; appending the
  # config hint here would be actively misleading.
  defp log_hint(%{kind: :validation_failed}), do: ""
  defp log_hint(%{kind: :unauthenticated}), do: ""
  defp log_hint(%{kind: :forbidden}), do: ""
  defp log_hint(%{kind: :server_error}), do: ""
  defp log_hint(%{kind: :network}), do: ""

  # This escalates only after `@max_rate_limit_retries` retries with backoff
  # were already exhausted (see `do_transition/3`) — a status_map hint would
  # be actively misleading here. `retry_attempts`/`retry_elapsed_ms` are set
  # by `annotate_retry_exhausted/3` so the log line (like the escalation body)
  # distinguishes "we tried and GitHub kept refusing" from "we gave up
  # instantly".
  defp log_hint(%{kind: :rate_limited, retry_attempts: attempts, retry_elapsed_ms: elapsed_ms})
       when is_integer(attempts) and is_integer(elapsed_ms) do
    "Retried #{attempts} time(s) over #{format_elapsed(elapsed_ms)} honoring the tracker's " <>
      "Retry-After/backoff, but the rate limit never cleared — check the workspace's remaining quota."
  end

  defp log_hint(%{kind: :rate_limited}),
    do:
      "The tracker's rate limit did not clear within the retry budget — check the workspace's remaining quota."

  # No path through the graph IS a config-mismatch — keep the hint.
  defp log_hint(%{kind: :no_transition_path}),
    do: "Reconcile the workspace status_map / transition_graph with the tracker workflow."

  defp log_hint(_reason),
    do: "Reconcile the workspace status_map / transition_graph with the tracker workflow."

  defp format_elapsed(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp load_workspace(nil), do: nil

  defp load_workspace(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
