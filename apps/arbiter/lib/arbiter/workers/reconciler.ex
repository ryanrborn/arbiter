defmodule Arbiter.Workers.Reconciler do
  @moduledoc """
  Reconciles orphaned `:running` `Arbiter.Workers.Run` rows on boot.

  A worker GenServer is ephemeral: it writes a `:running` Run row on init and
  stamps the terminal status (`:completed` / `:failed`) when it stops. If the
  node dies between those two writes — a crash, a hard restart — the row is left
  `:running` forever. `arb prime` tracks live processes, so it correctly shows
  no active workers, but the durable history lies: it claims work is still in
  flight when the process that owned it is long gone.

  This module sweeps those orphans. A `:running` row whose `task_id` has no live
  worker registered under `Arbiter.Worker.Registry` is marked `:failed` with a
  `failure_reason` of `"server restarted"`. Run on application start (see
  `Arbiter.Application`) after the Repo and the Worker Registry are online.

  ## Single-instance gate

  Liveness is keyed off the LOCAL process registry, which is empty on a fresh
  boot — so this sweep is only correct on the *one* canonical instance per DB.
  A second instance booting against the same DB (e.g. an worker running
  `mix phx.server` / `iex -S mix` / `mix run` while the real server is up) has
  an empty registry too, so it would mistake the primary instance's live runs
  for orphans and fail them. The boot path therefore gates the sweep on
  `Arbiter.SingleInstance.primary?/0` (a session advisory lock) and passes the
  verdict as the `:primary?` option; a non-primary boot skips the sweep
  entirely and returns `{:ok, :skipped}`. See bd-9rouwh / bd-6k8519.

  The sweep is best-effort: a DB hiccup logs a warning and returns `{:error, _}`
  rather than crashing the supervision tree at boot.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Usage.Event
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.MergedPRFinalizerSupervisor
  alias Arbiter.Workflows.PRPatrolSupervisor
  alias Arbiter.Workflows.ReviewPatrolSupervisor

  # The failure_reason stamped onto reconciled orphans. Distinct, greppable,
  # and human-legible on the dashboard's "Completed Workers" view.
  @failure_reason "server restarted"

  @doc """
  Sweep `:running` Run rows with no live worker and mark them `:failed`.

  Returns `{:ok, count}` where `count` is the number of rows reconciled, or
  `{:error, reason}` if the read failed (in which case nothing was written).

  ## Options

    * `:primary?` — whether this instance is the canonical single instance and
      may sweep. Defaults to `true` (the mechanism is permissive on its own;
      the boot path supplies the real verdict from `Arbiter.SingleInstance`).
      When `false`, the sweep is skipped and `{:ok, :skipped}` is returned
      without touching any row — this is what keeps a transient/duplicate boot
      from failing the primary instance's live runs.
  """
  @spec reconcile_orphaned_runs(keyword()) ::
          {:ok, non_neg_integer() | :skipped} | {:error, term()}
  def reconcile_orphaned_runs(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      do_reconcile()
    else
      Logger.info(
        "Workers.Reconciler: not the primary instance; skipping orphan sweep " <>
          "(advisory lock held elsewhere)"
      )

      {:ok, :skipped}
    end
  end

  defp do_reconcile do
    orphans =
      Run
      |> Ash.Query.filter(status == :running)
      |> Ash.read!()
      |> Enum.reject(&live_worker?/1)

    reconciled = Enum.count(orphans, &mark_interrupted/1)

    if reconciled > 0 do
      Logger.info("Workers.Reconciler: marked #{reconciled} orphaned :running run(s) :failed")
    end

    {:ok, reconciled}
  rescue
    e ->
      Logger.warning("Workers.Reconciler: sweep failed: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  Re-establish monitoring for orphaned `:in_progress` Issues whose worker died
  on a restart but whose PR is still open (or which are review-only engagements),
  instead of merely escalating them.

  After a reboot the ephemeral worker/Watchdog that was following the PR no longer
  exists, so a bead parked in awaiting_review loses its active watcher: merge
  detection and review-feedback follow-up are dropped until a human notices. The
  patrol layer (`PRPatrol` + `MergedPRFinalizer`, or `ReviewPatrol` for review-only
  engagements) is exactly the durable, restart-surviving watcher for these beads.
  This sweep hands each orphaned open-PR bead back to that layer explicitly so:

    * `MergedPRFinalizer` finalizes the task when the PR merges (keys on `pr_ref`), and
    * `PRPatrol` re-drives review-feedback (CHANGES_REQUESTED / unresolved threads).

  Escalation is kept only as the fallback: a bead whose workspace has no patrol
  coverage (e.g. no hosted-forge merger configured) can't be auto-watched, so it
  still lands in the coordinator's mailbox rather than being silently dropped.

  Respects the `worker_live?` guard (C6): a bead that still has a live worker is
  left untouched — no duplicate watcher is established.

  Returns `{:ok, %{rewatched: non_neg_integer(), escalated: non_neg_integer()}}`,
  `{:ok, :skipped}` when not the primary instance, or `{:error, reason}`.

  ## Options

    * `:primary?` — same single-instance gate as `reconcile_orphaned_runs/1`.
      When `false`, skips and returns `{:ok, :skipped}`.
    * `:rewatch_fun` — 1-arity fun `(Issue.t() -> :ok | {:error, term()})` used to
      re-establish patrol coverage for a bead. Defaults to `&default_rewatch/1`
      (starts the real patrol supervisors for the bead's workspace). Injectable so
      tests can drive the re-watch/escalate branches without booting patrols.
  """
  @spec reconcile_open_pr_tasks(keyword()) ::
          {:ok, %{rewatched: non_neg_integer(), escalated: non_neg_integer()} | :skipped}
          | {:error, term()}
  def reconcile_open_pr_tasks(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      do_reconcile_open_pr_tasks(Keyword.get(opts, :rewatch_fun, &default_rewatch/1))
    else
      {:ok, :skipped}
    end
  end

  defp do_reconcile_open_pr_tasks(rewatch_fun) do
    stuck =
      Issue
      |> Ash.Query.filter(status == :in_progress)
      |> Ash.read!()
      |> Enum.reject(&live_worker_for_issue?/1)
      |> Enum.filter(&rewatchable?/1)

    {rewatched, escalated} =
      Enum.reduce(stuck, {0, 0}, fn issue, {rw, esc} ->
        case rewatch_fun.(issue) do
          :ok ->
            Logger.info(
              "Workers.Reconciler: re-established patrol watching for in_progress task " <>
                "#{issue.id} (PR #{issue.pr_ref}) — handed to patrol layer, not escalated"
            )

            {rw + 1, esc}

          {:error, reason} ->
            Logger.warning(
              "Workers.Reconciler: could not re-watch task #{issue.id} (PR #{issue.pr_ref}): " <>
                "#{inspect(reason)} — escalating"
            )

            if escalate_stuck_issue(issue, :open_pr), do: {rw, esc + 1}, else: {rw, esc}
        end
      end)

    if rewatched + escalated > 0 do
      Logger.info(
        "Workers.Reconciler: open-PR sweep — re-watched #{rewatched}, escalated #{escalated}"
      )
    end

    {:ok, %{rewatched: rewatched, escalated: escalated}}
  rescue
    e ->
      Logger.warning("Workers.Reconciler: open-PR task sweep failed: #{Exception.message(e)}")

      {:error, e}
  end

  @doc """
  Resume orphaned `:in_progress` Issues that were mid-flight (a `:running` /
  revising worker killed by the restart) but have **no** open PR yet — via the
  existing `bd-auma3z` resume path (`Arbiter.Worker.Dispatch.resume/2`), which
  re-attaches a fresh agent to the task's *preserved* worktree.

  Resume is delegated to `Dispatch.resume/2`, which already enforces the safety
  guards this sweep requires: it refuses a closed task, refuses when a worker is
  still active for the task (the `worker_live?` / C6 guard — no duplicate worker),
  and refuses (`{:error, :no_outpost}`) when the worktree was cleaned up. Any bead
  that cannot be safely resumed falls back to an escalation rather than being
  dropped.

  Open-PR / awaiting_review beads are intentionally **not** handled here — they
  belong to the patrol layer via `reconcile_open_pr_tasks/1`; resuming them would
  spawn a redundant worker to redo already-shipped work.

  Returns `{:ok, %{resumed: non_neg_integer(), escalated: non_neg_integer()}}`,
  `{:ok, :skipped}` when not the primary instance, or `{:error, reason}`.

  ## Options

    * `:primary?` — same single-instance gate as `reconcile_orphaned_runs/1`.
    * `:resume_fun` — 1-arity fun `(Issue.t() -> {:ok, term()} | {:error, term()})`
      used to resume a bead. Defaults to `&default_resume/1` (the real
      `Dispatch.resume/2`). Injectable so tests can exercise the resume/escalate
      branches without spawning a real worker.
  """
  @spec reconcile_resumable_tasks(keyword()) ::
          {:ok, %{resumed: non_neg_integer(), escalated: non_neg_integer()} | :skipped}
          | {:error, term()}
  def reconcile_resumable_tasks(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      do_reconcile_resumable_tasks(Keyword.get(opts, :resume_fun, &default_resume/1))
    else
      {:ok, :skipped}
    end
  end

  defp do_reconcile_resumable_tasks(resume_fun) do
    stuck =
      Issue
      |> Ash.Query.filter(status == :in_progress and is_nil(pr_ref))
      |> Ash.read!()
      |> Enum.reject(&live_worker_for_issue?/1)
      |> Enum.reject(&review_only?/1)

    {resumed, escalated} =
      Enum.reduce(stuck, {0, 0}, fn issue, {res, esc} ->
        case resume_fun.(issue) do
          {:ok, _result} ->
            Logger.info(
              "Workers.Reconciler: resumed mid-flight task #{issue.id} from its preserved worktree"
            )

            {res + 1, esc}

          {:error, reason} ->
            Logger.warning(
              "Workers.Reconciler: cannot safely resume task #{issue.id} " <>
                "(#{inspect(reason)}) — escalating"
            )

            if escalate_stuck_issue(issue, {:unresumable, reason}),
              do: {res, esc + 1},
              else: {res, esc}
        end
      end)

    if resumed + escalated > 0 do
      Logger.info("Workers.Reconciler: resume sweep — resumed #{resumed}, escalated #{escalated}")
    end

    {:ok, %{resumed: resumed, escalated: escalated}}
  rescue
    e ->
      Logger.warning("Workers.Reconciler: resumable task sweep failed: #{Exception.message(e)}")

      {:error, e}
  end

  # An orphaned in_progress bead is re-watchable (belongs to the patrol layer)
  # when it has an open PR of its own (pr_ref) or is a review-only engagement
  # (driven by ReviewPatrol via source_pr).
  defp rewatchable?(%Issue{} = issue), do: not is_nil(issue.pr_ref) or review_only?(issue)

  defp review_only?(%Issue{review_only: true}), do: true
  defp review_only?(%Issue{}), do: false

  defp live_worker_for_issue?(%Issue{id: task_id}), do: not is_nil(Worker.whereis(task_id))

  # Default re-watch: hand the bead back to the durable patrol layer for its
  # workspace. Review-only engagements go to ReviewPatrol; author-side open-PR
  # beads go to PRPatrol (review-feedback follow-up) + MergedPRFinalizer (merge
  # finalization). All supervisor starts are idempotent — an already-running
  # patrol reports `{:error, {:already_started, _}}`, which we treat as covered.
  # Returns `:ok` when at least one relevant patrol is established, otherwise
  # `{:error, reason}` so the caller escalates as the fallback.
  defp default_rewatch(%Issue{workspace_id: workspace_id} = issue) do
    case load_workspace(workspace_id) do
      {:ok, %Workspace{} = workspace} ->
        results =
          if review_only?(issue) do
            [ReviewPatrolSupervisor.start_patrol(workspace)]
          else
            [
              PRPatrolSupervisor.start_patrol(workspace),
              MergedPRFinalizerSupervisor.start_finalizer(workspace)
            ]
          end

        if Enum.any?(results, &patrol_established?/1),
          do: :ok,
          else: {:error, {:no_patrol_coverage, results}}

      {:error, reason} ->
        {:error, {:workspace_unavailable, reason}}
    end
  end

  defp load_workspace(nil), do: {:error, :no_workspace}

  defp load_workspace(workspace_id) when is_binary(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, workspace} -> {:ok, workspace}
      {:error, reason} -> {:error, reason}
    end
  end

  # A patrol is considered established either when we just started it or when it
  # was already running (idempotent start). `:skip` (no repos / unsupported
  # adapter) and any other error mean the workspace can't be watched.
  defp patrol_established?({:ok, _pid}), do: true
  defp patrol_established?({:error, {:already_started, _pid}}), do: true
  defp patrol_established?(_), do: false

  defp default_resume(%Issue{id: task_id}), do: Dispatch.resume(task_id)

  defp escalate_stuck_issue(%Issue{} = issue, reason) do
    %Issue{id: task_id, pr_ref: pr_ref, workspace_id: workspace_id} = issue
    {subject, body} = escalation_copy(task_id, pr_ref, reason)

    Message.send_mail(%{
      kind: :escalation,
      to_ref: Message.coordinator_ref(),
      from_ref: "system",
      workspace_id: workspace_id,
      directive_ref: task_id,
      subject: subject,
      body: body
    })

    true
  rescue
    e ->
      Logger.warning(
        "Workers.Reconciler: failed to escalate stuck task #{issue.id}: #{Exception.message(e)}"
      )

      false
  end

  defp escalation_copy(task_id, pr_ref, :open_pr) do
    subject = "#{task_id} stuck — PR ##{pr_ref} open but no live worker or patrol coverage"

    body =
      "Task #{task_id} has an open PR (#{pr_ref}) but no live worker, and its workspace has " <>
        "no patrol coverage to re-establish monitoring automatically.\n" <>
        "Action: verify the PR is ready to merge, then run `arb issue dispatch #{task_id}` to re-drive " <>
        "or manually merge and close the task."

    {subject, body}
  end

  defp escalation_copy(task_id, _pr_ref, {:unresumable, reason}) do
    subject = "#{task_id} stuck — mid-flight worker lost and cannot be safely resumed"

    body =
      "Task #{task_id} was in_progress with no live worker after a restart, and could not be " <>
        "auto-resumed (#{inspect(reason)} — e.g. the worktree was cleaned up or the repo is " <>
        "unresolvable).\n" <>
        "Action: inspect the task state, then run `arb issue dispatch #{task_id}` to re-drive from scratch."

    {subject, body}
  end

  # A run is live iff a worker GenServer is registered for its task_id. After a
  # boot the registry is empty, so every :running row is an orphan; mid-life this
  # guards against racing a worker that is legitimately still working.
  defp live_worker?(%Run{task_id: task_id}), do: not is_nil(Worker.whereis(task_id))

  # Returns true when the row was successfully reconciled (so the caller can
  # count it), false on a per-row write failure that we've logged and skipped.
  defp mark_interrupted(%Run{} = run) do
    attrs = %{
      status: :failed,
      completed_at: DateTime.utc_now(),
      failure_reason: @failure_reason
    }

    case Ash.update(run, attrs, action: :update) do
      {:ok, updated} ->
        # bd-au3xrq: a node that died mid-run left no usage row (the worker
        # never reached its own record_usage_event). If this run captured its
        # Claude session coordinates, reconcile the token ledger from the
        # on-disk session JSONL that survived the crash.
        maybe_backfill_usage_from_disk(updated)
        true

      {:error, reason} ->
        Logger.warning(
          "Workers.Reconciler: failed to reconcile run for task=#{run.task_id}: #{inspect(reason)}"
        )

        false
    end
  end

  # Best-effort on-disk usage backfill for a just-reconciled orphan. Only fires
  # when the run recorded a `session_id` + `config_dir` (Claude runs past their
  # `init` event) AND no `Arbiter.Usage.Event` already exists for the run — so a
  # run whose stdout path DID land a row is never double-counted. Cost stays nil
  # (the JSONL carries no dollar figure). Any failure logs and is swallowed:
  # backfilling the ledger must never break the boot-time sweep.
  #
  # `since: run.started_at` is load-bearing, not decoration: a session-level
  # resume (`Dispatch.resume_session/2`) opens a NEW run row but re-spawns with
  # `--resume <sid>`, and the CLI appends to the SAME <sid>.jsonl. Reading the
  # whole file would bill this run for every token the parent run already spent
  # (and `usage_event_exists?/1` can't catch it — it's keyed on this run's id).
  # The cutoff bounds the read to this run's own turns.
  defp maybe_backfill_usage_from_disk(%Run{session_id: sid, config_dir: cfg} = run)
       when is_binary(sid) and sid != "" and is_binary(cfg) and cfg != "" do
    if usage_event_exists?(run.id) do
      :ok
    else
      case ClaudeSessionFile.usage_for(cfg, sid, since: run.started_at) do
        {:ok, %{message_count: n} = totals} when n > 0 ->
          write_reconciled_usage(run, totals)

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning(
        "Workers.Reconciler: usage backfill raised for task=#{run.task_id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp maybe_backfill_usage_from_disk(%Run{}), do: :ok

  defp usage_event_exists?(run_id) do
    Event
    |> Ash.Query.filter(worker_run_id == ^run_id)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> Kernel.!=([])
  end

  defp write_reconciled_usage(%Run{} = run, totals) do
    step = if run.worker_type == :review, do: :review, else: :work

    attrs = %{
      task_id: run.task_id,
      workspace_id: run.workspace_id,
      repo: run.repo,
      step: step,
      model: run.model || totals.model,
      provider: "claude",
      tokens_in: totals.tokens_in,
      tokens_out: totals.tokens_out,
      cache_creation_tokens: totals.cache_creation_tokens,
      cache_read_tokens: totals.cache_read_tokens,
      cost_usd: nil,
      worker_run_id: run.id,
      session_id: run.session_id,
      occurred_at: DateTime.utc_now(),
      raw: %{
        "arb_usage_source" => %{
          "reconciled_from" => "session_jsonl",
          "via" => "reconciler",
          "message_count" => totals.message_count,
          "skipped_before_since" => totals.skipped_before_since
        }
      }
    }

    case Ash.create(Event, attrs) do
      {:ok, _ev} ->
        Logger.info(
          "Workers.Reconciler: reconciled usage from on-disk session JSONL for " <>
            "task=#{run.task_id} run=#{run.id} (#{totals.message_count} msgs, " <>
            "#{totals.tokens_in} in / #{totals.tokens_out} out)"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Workers.Reconciler: could not write reconciled usage for task=#{run.task_id}: " <>
            "#{inspect(reason)}"
        )

        :ok
    end
  end
end
