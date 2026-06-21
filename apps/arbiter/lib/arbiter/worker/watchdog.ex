defmodule Arbiter.Worker.Watchdog do
  @moduledoc """
  Watchdog process for a worker parked at `:awaiting_review`.

  When an worker finishes its work it opens a merge request and the paired
  `Arbiter.Worker` transitions `:running -> :awaiting_review`, spawning one
  Watchdog. The Watchdog polls `Arbiter.Mergers.get/1` on an interval and drives
  the worker to its terminal state based on the MR's fate:

      MR merged           -> Worker.complete(:merged)
      MR approved         -> (auto_merge) Mergers.merge/1 then complete(:merged)
                          -> (manual)     stay parked; a human merges, next
                                          poll sees :merged, then complete
      MR closed/rejected  -> Worker.fail({:mr_closed, ref})

  One Watchdog supervises one worker. It is started under
  `Arbiter.Worker.WatchdogSupervisor` (a `DynamicSupervisor`, `restart:
  :temporary`) and monitors the worker: if the worker dies, the Watchdog
  stops.

  ## Approval detection lives in one function

  `classify/1` maps a `Mergers.get/1` result map to one of `:merged |
  :approved | :closed | :pending`. It is the *single* decision surface — the
  poll loop and any future push trigger both route through it.

  ## Auto-resolving blocked merges (#354, Phase 2a)

  An *approved* PR that still can't merge carries a `block_reason`
  (`effective_block_reason/1`). On an `auto_merge` lane the Warden tries to
  resolve the two mechanically-fixable reasons itself before escalating:

      :behind_base -> `adapter.update_branch/1` (update-branch), then re-poll.
                      A failed update (conflict introduced) falls through to
                      `:conflict` handling.
      :ci_failed   -> dispatch a fix-pass acolyte (briefed with the failing
                      check logs via `adapter.failing_check_logs/1`) to fix the
                      root cause and push, then re-poll.

  Each attempt increments a per-episode counter; after `max_auto_resolve_attempts`
  (default 2) the Warden stops retrying and escalates with the reason + attempt
  count. The remaining reasons (`:conflict`, `:needs_approval`, `:draft`,
  `:blocked_other`) keep the Phase 1 behaviour: escalate once and park.

  ### Webhook upgrade (design only — not implemented here)

  Polling is the shipped mechanism. A future push path would add
  `POST /webhooks/gitlab` and `POST /webhooks/github` controllers that, on a
  merge-request event, look up the Watchdog for the affected `mr_ref` and send
  it `{:mr_event, get_result}`. Because `classify/1` already encapsulates the
  approval logic, the webhook handler reuses it verbatim and the poll interval
  becomes a slow safety-net backstop rather than the primary trigger. No state
  machine changes are required to make that swap — only a new inbound message
  that calls the same `apply_outcome/2` path the poll uses.

  ## Adapter config

  Hosted-forge adapters (GitLab) resolve host/project/token from the process
  dictionary. The Watchdog runs in its own process, so it seeds that config via
  `Arbiter.Mergers.prepare/1` in `init/1` (a no-op for `Direct`).
  """

  use GenServer

  require Logger

  alias Arbiter.Mergers
  alias Arbiter.Worker

  @default_interval_ms 60_000
  # Watchdog ceiling on consecutive :pending polls before we escalate and stop.
  #
  # auto_merge ON (CI/forge merges): 30 polls × 60s = 30 min. If auto-merge
  # hasn't fired after that long, something is broken — fail loudly (bd-66ey1o).
  #
  # auto_merge OFF (human-merge lanes): :infinity — a human reviewer may take
  # hours or overnight. Failing the worker after 30 min was a false negative
  # (bd-akr4il, VR-17739). The Watchdog polls indefinitely until the MR is
  # merged or closed. Override via workspace config["merge"]["watchdog_max_polls"].
  @default_max_polls_auto 30
  @default_max_polls_manual :infinity

  # Consecutive auto-resolve attempts (#354, Phase 2a) before the Warden stops
  # mechanically resolving a block and escalates to the coordinator with the
  # reason + attempt count. Override via opt `:max_auto_resolve_attempts` or
  # workspace config["merge"]["max_auto_resolve_attempts"].
  @default_max_auto_resolve_attempts 2

  # The default dispatcher the Warden uses to spawn a fix-pass acolyte for a
  # :ci_failed block. Swappable via the `:fix_pass_dispatcher` opt (tests stub it).
  @default_fix_pass_dispatcher Arbiter.Workflows.MergeQueue.FixPassDispatcher

  # Registry suffix the fix-pass worker registers under — MUST match
  # `FixPassDispatcher.registry_suffix/0` so we can detect an in-flight fix pass.
  @fix_pass_registry_suffix ":fixpass"
  # Bounded rebase attempts before the Warden gives up auto-resolving a
  # `:conflict` block and escalates to the coordinator (#354, Phase 2b). Each
  # attempt is one dispatched rebase-resolve acolyte; if two consecutive passes
  # don't clear the conflict it is almost certainly semantic and needs a human.
  @default_max_conflict_attempts 2

  # The resolver that dispatches a rebase-resolve acolyte against the task's
  # existing worktree. Injectable via the `:conflict_resolver` opt (tests pass a
  # stub). The default is the same module the MergeQueue uses, so the Warden-
  # driven Phase 2b flow and the legacy #122 MergeQueue path share one resolver.
  @default_conflict_resolver Arbiter.Workflows.MergeQueue.ConflictResolver

  @type opt ::
          {:task_id, String.t()}
          | {:worker, pid() | String.t()}
          | {:mr_ref, String.t()}
          | {:adapter, module()}
          | {:workspace, Arbiter.Tasks.Workspace.t() | nil}
          | {:auto_merge, boolean()}
          | {:via_review_gate, boolean()}
          | {:interval_ms, non_neg_integer()}
          | {:initial_delay_ms, non_neg_integer()}
          | {:max_polls, non_neg_integer()}
          | {:watch_pipeline, boolean()}
          | {:max_auto_resolve_attempts, non_neg_integer()}
          | {:fix_pass_dispatcher, module()}
          | {:auto_resolve_conflict, boolean()}
          | {:max_conflict_attempts, pos_integer()}
          | {:conflict_resolver, module()}

  @type opts :: [opt()]

  # ---- public API ---------------------------------------------------------

  @doc """
  Start a Watchdog under `Arbiter.Worker.WatchdogSupervisor`.

  Required opts: `:task_id`, `:worker` (pid or task_id), `:mr_ref`,
  `:adapter`. Optional:

    * `:workspace`
    * `:auto_merge` (default `false`)
    * `:via_review_gate` (default `false`) — when true, the ReviewGate gate has
      already approved this MR; the Watchdog treats every non-terminal poll as
      `:approved` and forces auto-merge, so the merge fires on the first poll
      without waiting for a hosted-forge approval the gate never posts.
    * `:interval_ms` (default `#{@default_interval_ms}`)
    * `:initial_delay_ms` (default `0` — poll once promptly, then on the interval)
    * `:max_polls` — consecutive `:pending` polls before the Watchdog escalates.
      Default is `#{@default_max_polls_auto}` when `auto_merge: true` (fail
      loudly — auto-merge should fire quickly) and `:infinity` when
      `auto_merge: false` (human-merge lanes; a human may take overnight or
      longer, so the Watchdog parks rather than hard-fails). When a finite cap is
      reached on a manual lane the worker is **left parked** in
      `:awaiting_review` and the Watchdog stops polling — it is NOT failed.
      Pass `:infinity` to disable the watchdog entirely.
  """
  @spec start(opts()) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(Arbiter.Worker.WatchdogSupervisor, {__MODULE__, opts})
  end

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "Default poll interval in milliseconds."
  @spec default_interval_ms() :: pos_integer()
  def default_interval_ms, do: @default_interval_ms

  @doc """
  Default watchdog cap for `auto_merge: true` lanes (30 polls).
  For `auto_merge: false` lanes the default is `:infinity`.
  """
  @spec default_max_polls_auto() :: pos_integer()
  def default_max_polls_auto, do: @default_max_polls_auto

  @doc "Default watchdog cap for `auto_merge: false` (manual-merge) lanes."
  @spec default_max_polls_manual() :: :infinity
  def default_max_polls_manual, do: @default_max_polls_manual

  @doc "Default bounded rebase attempts before a `:conflict` block escalates (Phase 2b)."
  @spec default_max_conflict_attempts() :: pos_integer()
  def default_max_conflict_attempts, do: @default_max_conflict_attempts

  @doc """
  Classify a `Arbiter.Mergers.get/1` result map into an approval outcome.

  This is the single approval-detection decision point — see the moduledoc's
  webhook note. `:merged` wins over `:approved` (a merged MR may also report
  `approved: true`); `:closed` is terminal-fail; everything else is `:pending`.
  """
  @spec classify(map()) :: :merged | :approved | :closed | :pending
  def classify(%{status: :merged}), do: :merged
  def classify(%{status: :closed}), do: :closed
  def classify(%{approved: true}), do: :approved
  def classify(_), do: :pending

  @typedoc """
  Why an open MR can't merge, as classified by the merger adapter
  (`Arbiter.Mergers.get/1`). `nil` when the MR is mergeable or already terminal.
  """
  @type block_reason ::
          :conflict | :behind_base | :ci_failed | :needs_approval | :draft | :blocked_other

  @doc """
  Read the merge-block reason a `Arbiter.Mergers.get/1` result carries, or `nil`
  when the MR is mergeable (or the adapter reports no reason). The adapters
  (`Arbiter.Mergers.Github` / `Arbiter.Mergers.Gitlab`) classify the reason from
  PR/MR state; this is the single extraction surface the poll loop and the
  dashboard both read (#354, Phase 1).
  """
  @spec block_reason(map()) :: block_reason() | nil
  def block_reason(result) when is_map(result), do: Map.get(result, :block_reason)
  def block_reason(_), do: nil

  @doc """
  The merge-block reason to *act on* — the adapter's `block_reason/1`, but only
  once the MR is **approved** (`classify/1 == :approved`). `nil` otherwise.

  The Watchdog polls throughout the ordinary pre-approval review window, and a
  not-yet-approved PR routinely classifies as "blocked": GitHub reports
  `mergeable_state == "blocked"` for an open PR merely awaiting its required
  review, and GitLab reports `not_approved` / in-progress merge statuses. Those
  are the *normal* review state, not a merge failure — the directive's silent-park
  problem is specifically an **approved** PR that still cannot merge (#354).

  So escalation and the dashboard both route through this gate, not raw
  `block_reason/1`: only an approved-but-unmergeable PR is treated as blocked.
  This also keeps the escalation debounce honest — a reason can never latch
  during the pre-approval window and suppress a later, genuine post-approval
  re-block, because the gate returns `nil` until approval lands.
  """
  @spec effective_block_reason(map()) :: block_reason() | nil
  def effective_block_reason(result) when is_map(result) do
    case classify(result) do
      :approved -> block_reason(result)
      _ -> nil
    end
  end

  def effective_block_reason(_), do: nil

  # ---- GenServer ----------------------------------------------------------

  @impl true
  def init(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    adapter = Keyword.fetch!(opts, :adapter)
    mr_ref = Keyword.fetch!(opts, :mr_ref)

    worker_pid =
      case Keyword.fetch!(opts, :worker) do
        pid when is_pid(pid) -> pid
        ref when is_binary(ref) -> Worker.whereis(ref)
      end

    cond do
      not is_pid(worker_pid) ->
        # Nothing to watch — the worker is already gone.
        :ignore

      true ->
        workspace = Keyword.get(opts, :workspace)
        Mergers.prepare(workspace)

        via_review_gate = Keyword.get(opts, :via_review_gate, false)
        # A ReviewGate-approved MR has no pending hosted-forge approval to wait
        # for, so auto_merge is implicit. Honor any explicit override (for
        # tests) but default to true when the gate has approved.
        auto_merge = Keyword.get(opts, :auto_merge, via_review_gate)

        default_max_polls =
          if auto_merge, do: @default_max_polls_auto, else: @default_max_polls_manual

        watch_pipeline =
          case Keyword.get(opts, :watch_pipeline) do
            flag when is_boolean(flag) -> flag
            _ -> watch_pipeline_from_workspace(workspace)
          end

        max_auto_resolve_attempts =
          Keyword.get(opts, :max_auto_resolve_attempts) ||
            max_auto_resolve_from_workspace(workspace) ||
            @default_max_auto_resolve_attempts

        fix_pass_dispatcher =
          Keyword.get(opts, :fix_pass_dispatcher, @default_fix_pass_dispatcher)

        auto_resolve_conflict = resolve_auto_resolve_conflict(opts, workspace)
        max_conflict_attempts = resolve_max_conflict_attempts(opts, workspace)

        state = %{
          task_id: task_id,
          worker_pid: worker_pid,
          mr_ref: mr_ref,
          adapter: adapter,
          workspace: workspace,
          auto_merge: auto_merge,
          via_review_gate: via_review_gate,
          interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
          max_polls: Keyword.get(opts, :max_polls, default_max_polls),
          poll_count: 0,
          watch_pipeline: watch_pipeline,
          last_pipeline: nil,
          # The last merge-block reason we escalated, so a blocked merge is
          # surfaced once per reason rather than on every poll (#354, Phase 1).
          last_block_reason: nil,
          # Consecutive auto-resolve attempts for the current block episode
          # (#354, Phase 2a). Reset to 0 when the block clears. After
          # `max_auto_resolve_attempts` the Warden escalates instead of retrying.
          auto_resolve_attempts: 0,
          max_auto_resolve_attempts: max_auto_resolve_attempts,
          fix_pass_dispatcher: fix_pass_dispatcher,
          # Latches the exhausted-retry escalation so it fires once per block
          # episode rather than on every subsequent poll (#354, Phase 2a).
          unresolved_escalated: false,
          # Fired once when an approved MR is parked without auto-merge, so the
          # external tracker moves to its "approved, awaiting merge" status
          # (e.g. Jira VR -> Pending Merge) instead of every poll. (bd-c4cfuv)
          pending_merge_synced: false,
          # Auto-resolve of an approved `:conflict` block (#354, Phase 2b).
          #   auto_resolve_conflict  — master switch (workspace-tunable).
          #   conflict_resolver      — module that dispatches the rebase acolyte.
          #   max_conflict_attempts  — bounded rebase passes before escalation.
          #   conflict_attempts      — passes dispatched for the current conflict.
          #   conflict_resolving     — a resolver acolyte is in flight right now.
          #   conflict_resolver_pid  — that resolver worker's pid. We poll its
          #                            terminal status to detect completion: the
          #                            resolver worker does NOT exit when its
          #                            acolyte finishes (it lingers :completed/
          #                            :failed until task :close), so a `:DOWN`
          #                            monitor never fires on a normal finish.
          #   conflict_branch        — branch label (for the exhaustion escalation).
          #   conflict_escalated     — exhaustion already paged; stay parked, don't spam.
          auto_resolve_conflict: auto_resolve_conflict,
          conflict_resolver: Keyword.get(opts, :conflict_resolver, @default_conflict_resolver),
          max_conflict_attempts: max_conflict_attempts,
          conflict_attempts: 0,
          conflict_resolving: false,
          conflict_resolver_pid: nil,
          conflict_branch: nil,
          conflict_escalated: false
        }

        Process.monitor(worker_pid)
        schedule(self(), Keyword.get(opts, :initial_delay_ms, 0))
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case safe_get(state) do
      {:ok, result} when is_map(result) ->
        record_status(state, result)
        state = maybe_escalate_pipeline(state, result)
        state = maybe_auto_resolve_conflict(state, result)
        maybe_escalate_merge_block(state, result)

      {:error, reason} ->
        Logger.debug(
          "Worker.Watchdog: get/1 error for task=#{state.task_id} mr=#{state.mr_ref}: #{inspect(reason)}"
        )

        reschedule(state)
    end
  end

  # Worker died — nothing left to watch.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{worker_pid: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The ReviewGate gate approves in-process — hosted-forge adapters never see
  # that approval on the PR/MR itself, so `classify/1` would forever return
  # `:pending`. When the worker told us the gate already approved, treat any
  # non-terminal status as `:approved` so the auto-merge path fires on the
  # first poll. `:merged` / `:closed` still win because they're terminal facts
  # about the MR itself, not approval-state interpretation.
  defp effective_outcome(%{via_review_gate: true} = _state, result) do
    case classify(result) do
      :pending -> :approved
      other -> other
    end
  end

  defp effective_outcome(_state, result), do: classify(result)

  # ---- outcome handling ---------------------------------------------------
  #
  # The poll loop and any future webhook trigger both funnel through
  # apply_outcome/3, so the approval semantics stay in one place.

  defp apply_outcome(:merged, _result, state) do
    Logger.info("Worker.Watchdog: MR #{state.mr_ref} merged for task=#{state.task_id}")
    safe(fn -> Worker.complete(state.worker_pid, :merged) end)
    {:stop, :normal, state}
  end

  defp apply_outcome(:closed, _result, state) do
    Logger.info("Worker.Watchdog: MR #{state.mr_ref} closed for task=#{state.task_id}")
    safe(fn -> Worker.fail(state.worker_pid, {:mr_closed, state.mr_ref}) end)
    {:stop, :normal, state}
  end

  defp apply_outcome(:approved, _result, %{auto_merge: true} = state) do
    case safe_merge(state) do
      :ok ->
        Logger.info(
          "Worker.Watchdog: auto-merged approved MR #{state.mr_ref} for task=#{state.task_id}"
        )

        safe(fn -> Worker.complete(state.worker_pid, :merged) end)
        {:stop, :normal, state}

      {:error, reason} ->
        # Merge failed (race, branch conflict, transient). Stay parked and let
        # the next poll re-attempt rather than failing the task outright.
        Logger.warning(
          "Worker.Watchdog: auto-merge failed for task=#{state.task_id} mr=#{state.mr_ref}: #{inspect(reason)}; will retry"
        )

        reschedule(state)
    end
  end

  defp apply_outcome(:approved, _result, %{pending_merge_synced: false} = state) do
    # Approved but auto_merge is off: the review passed yet we can't merge yet
    # (other releases in-flight). Move the external tracker to its parked-but-
    # approved status (Jira VR -> Pending Merge) once, then keep polling for a
    # human merge. (bd-c4cfuv)
    sync_tracker_pending_merge(state)
    reschedule(%{state | pending_merge_synced: true})
  end

  defp apply_outcome(:approved, _result, state) do
    # Already synced to Pending Merge; just keep polling. The next poll that
    # sees :merged will complete.
    reschedule(state)
  end

  defp apply_outcome(:pending, _result, state), do: reschedule(state)

  # Fire the approved-but-parked tracker hook. Best-effort + loud-on-failure
  # inside `Arbiter.Trackers.Sync`; an unreadable task just skips.
  defp sync_tracker_pending_merge(state) do
    with {:ok, task} <- Ash.get(Arbiter.Tasks.Issue, state.task_id) do
      Arbiter.Trackers.Sync.lifecycle(task, :approved_unmerged)
    end

    :ok
  rescue
    e ->
      Logger.debug(
        "Worker.Watchdog: pending-merge tracker sync raised for task=#{state.task_id}: #{Exception.message(e)}"
      )

      :ok
  end

  # ---- internals ----------------------------------------------------------

  defp record_status(state, result) do
    safe(fn ->
      Worker.record_merger_status(state.worker_pid, result)
    end)
  end

  # When watch_pipeline is enabled, escalate to the Admiral on the first poll
  # that reports a failed pipeline. Stay parked — a human may force-merge or
  # rerun. Only escalates once per failure sequence (tracks last_pipeline to
  # suppress repeated alerts on consecutive :failed polls).
  defp maybe_escalate_pipeline(%{watch_pipeline: false} = state, _result), do: state

  defp maybe_escalate_pipeline(state, result) do
    current_pipeline = Map.get(result, :pipeline)

    if current_pipeline == :failed and state.last_pipeline != :failed do
      Logger.warning(
        "Worker.Watchdog: CI pipeline failed for task=#{state.task_id} mr=#{state.mr_ref}; " <>
          "escalating to Admiral, staying parked"
      )

      safe(fn ->
        snap =
          case safe_snapshot(state.worker_pid) do
            %{} = s -> s
            _ -> %{task_id: state.task_id, workspace_id: nil}
          end

        Arbiter.Messages.AdmiralNotifier.pipeline_failed(snap, state.mr_ref)
      end)
    end

    %{state | last_pipeline: current_pipeline}
  end

  # Route the poll result on its (approval-gated) merge-block reason (#354).
  #
  #   * no block        → reset the block latch + auto-resolve counter, run the
  #                       normal merged/approved/closed/pending outcome.
  #   * a block reason   → `handle_block/3` either auto-resolves it (Phase 2a),
  #                       escalates it (Phase 1 reasons / exhausted retries), or
  #                       both, then re-polls.
  #
  # Gated on approval (`effective_block_reason/1`): only an *approved* PR that
  # cannot merge escalates, so the ordinary pre-approval review window never
  # fires a spurious "merge blocked" alert.
  #
  # Debounced on `last_block_reason`: a given reason escalates once when it first
  # appears (or changes), not on every poll. A cleared block (reason `nil`, e.g.
  # the branch caught up, the MR merged, or approval has not landed yet) resets
  # the latch so a later re-block re-escalates. Best-effort — a notifier failure
  # must not disrupt the poll loop.
  # Phase 2b owns `:conflict`: when auto-resolve is enabled the Warden rebases
  # rather than paging on a conflict, and only escalates after the bounded
  # retries are exhausted (see `maybe_auto_resolve_conflict/2`). So skip the
  # generic page here for `:conflict` — the other reasons still escalate.
  defp maybe_escalate_merge_block(%{auto_resolve_conflict: true} = state, result) do
    case effective_block_reason(result) do
      :conflict -> reschedule(state)
      _ -> do_maybe_escalate_merge_block(state, result)
    end
  end

  defp maybe_escalate_merge_block(state, result), do: do_maybe_escalate_merge_block(state, result)

  defp do_maybe_escalate_merge_block(state, result) do
    case effective_block_reason(result) do
      nil ->
        state = %{
          state
          | last_block_reason: nil,
            auto_resolve_attempts: 0,
            unresolved_escalated: false
        }

        apply_outcome(effective_outcome(state, result), result, state)

      reason ->
        handle_block(reason, result, state)
    end
  end

  # Auto-resolution only runs on auto_merge lanes — the autonomous merge path
  # (#354, Phase 2a). On a human-merge lane (auto_merge: false) a person is
  # driving the merge, so we keep the Phase 1 behaviour: escalate the block once
  # and let the normal parked-but-approved flow continue.
  defp handle_block(reason, result, %{auto_merge: false} = state) do
    state = debounce_escalate_block(state, reason)
    apply_outcome(effective_outcome(state, result), result, state)
  end

  defp handle_block(reason, result, state) do
    cond do
      # Not mechanically resolvable here (:conflict → Phase 2b, :needs_approval /
      # :draft / :blocked_other → human), or the adapter can't perform the
      # resolution: fall back to the Phase 1 debounced escalation + normal outcome.
      not (auto_resolvable?(reason) and adapter_supports?(state, reason)) ->
        state = debounce_escalate_block(state, reason)
        apply_outcome(effective_outcome(state, result), result, state)

      # Bounded retries exhausted: escalate (once) with the reason + attempt
      # count and park — stop auto-resolving so a human / Phase 2b takes over.
      state.auto_resolve_attempts >= state.max_auto_resolve_attempts ->
        state = maybe_escalate_unresolved(state, reason)
        reschedule(%{state | last_block_reason: reason})

      true ->
        auto_resolve(reason, result, state)
    end
  end

  # The Phase 1 debounced escalation: a given block reason escalates once when it
  # first appears (or changes), not on every poll. Best-effort.
  defp debounce_escalate_block(%{last_block_reason: reason} = state, reason), do: state

  defp debounce_escalate_block(state, reason) do
    Logger.warning(
      "Worker.Watchdog: merge blocked (#{reason}) for task=#{state.task_id} " <>
        "mr=#{state.mr_ref}; escalating to coordinator"
    )

    safe(fn ->
      Arbiter.Messages.AdmiralNotifier.merge_blocked(snapshot(state), state.mr_ref, reason)
    end)

    %{state | last_block_reason: reason}
  end

  # The two mechanically auto-resolvable block reasons (#354, Phase 2a).
  defp auto_resolvable?(:behind_base), do: true
  defp auto_resolvable?(:ci_failed), do: true
  defp auto_resolvable?(_), do: false

  # :behind_base needs the adapter to support `update_branch/1`; :ci_failed is
  # resolved by dispatching a fix-pass acolyte (adapter-agnostic — the failing
  # check logs are best-effort).
  defp adapter_supports?(%{adapter: adapter}, :behind_base),
    do: function_exported?(adapter, :update_branch, 1)

  defp adapter_supports?(_state, :ci_failed), do: true
  defp adapter_supports?(_state, _reason), do: false

  defp auto_resolve(:behind_base, _result, state), do: resolve_behind_base(state)
  defp auto_resolve(:ci_failed, result, state), do: resolve_ci_failed(result, state)

  # :behind_base — run update-branch (mechanical, no agent) and re-poll. On
  # failure (update-branch would conflict) fall through to :conflict handling.
  defp resolve_behind_base(state) do
    attempts = state.auto_resolve_attempts + 1

    Logger.info(
      "Worker.Watchdog: auto-resolving :behind_base via update-branch for " <>
        "task=#{state.task_id} mr=#{state.mr_ref} (attempt #{attempts})"
    )

    case safe_update_branch(state) do
      :ok ->
        reschedule(%{state | last_block_reason: :behind_base, auto_resolve_attempts: attempts})

      {:error, reason} ->
        Logger.warning(
          "Worker.Watchdog: update-branch failed for task=#{state.task_id} " <>
            "mr=#{state.mr_ref}: #{inspect(reason)}; falling through to :conflict"
        )

        # update-branch introduced (or hit) a conflict — escalate as :conflict so
        # a human / the Phase 2b rebase agent takes over, and park.
        safe(fn ->
          Arbiter.Messages.AdmiralNotifier.merge_blocked(snapshot(state), state.mr_ref, :conflict)
        end)

        reschedule(%{state | last_block_reason: :conflict, auto_resolve_attempts: attempts})
    end
  end

  # :ci_failed — dispatch a fix-pass acolyte (briefed with the failing check
  # logs) to fix the root cause and push, then re-poll. Only one fix pass runs at
  # a time: while a prior one is still working we wait rather than spawning a
  # second, so the attempt counter tracks *completed* fix passes.
  defp resolve_ci_failed(result, state) do
    if fix_pass_active?(state) do
      reschedule(%{state | last_block_reason: :ci_failed})
    else
      attempts = state.auto_resolve_attempts + 1
      checks = safe_failing_checks(state)

      Logger.info(
        "Worker.Watchdog: auto-resolving :ci_failed via fix-pass acolyte for " <>
          "task=#{state.task_id} mr=#{state.mr_ref} (attempt #{attempts}, " <>
          "#{length(checks)} failing check(s))"
      )

      _ = dispatch_fix_pass(state, checks)
      _ = result

      reschedule(%{state | last_block_reason: :ci_failed, auto_resolve_attempts: attempts})
    end
  end

  # True when a fix-pass acolyte for this task is still working (registered under
  # the `:fixpass` suffix and not yet terminal).
  defp fix_pass_active?(state) do
    case Worker.whereis(state.task_id <> @fix_pass_registry_suffix) do
      nil -> false
      pid -> safe_worker_status(pid) not in [:failed, :completed, nil]
    end
  end

  defp dispatch_fix_pass(state, checks) do
    args = %{
      task_id: state.task_id,
      workspace_id: workspace_id(state),
      pr_ref: state.mr_ref,
      checks: checks
    }

    safe(fn -> state.fix_pass_dispatcher.dispatch(args) end)
  end

  defp maybe_escalate_unresolved(%{unresolved_escalated: true} = state, _reason), do: state

  defp maybe_escalate_unresolved(state, reason) do
    escalate_unresolved_block(state, reason)
    %{state | unresolved_escalated: true}
  end

  defp escalate_unresolved_block(state, reason) do
    Logger.warning(
      "Worker.Watchdog: auto-resolve exhausted (#{reason}, " <>
        "#{state.auto_resolve_attempts} attempt(s)) for task=#{state.task_id} " <>
        "mr=#{state.mr_ref}; escalating to coordinator"
    )

    safe(fn ->
      Arbiter.Messages.AdmiralNotifier.merge_block_unresolved(
        snapshot(state),
        state.mr_ref,
        reason,
        state.auto_resolve_attempts
      )
    end)
  end

  defp max_auto_resolve_from_workspace(%Arbiter.Tasks.Workspace{config: %{} = config}) do
    case get_in(config, ["merge", "max_auto_resolve_attempts"]) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp max_auto_resolve_from_workspace(_), do: nil
  # Auto-resolve an approved-but-conflicting PR (#354, Phase 2b). When the
  # merger reports a `:conflict` block on an *approved* PR — mergeable in
  # isolation but no longer applying cleanly on the moved base — the Warden
  # dispatches a short-lived rebase-resolve acolyte against the task's existing
  # worktree instead of parking and paging a human. The acolyte rebases,
  # resolves honoring the task intent, runs tests, and force-pushes; the next
  # poll then re-attempts the merge.
  #
  # Bounded: a resolver runs asynchronously and the Warden monitors it, so it
  # never spawns a second while one is in flight. After `max_conflict_attempts`
  # passes that don't clear the conflict it escalates once (attempt count +
  # context) and stays parked. A cleared conflict resets the counter so a future
  # conflict starts fresh. This supersedes the manual stop → direction → resume
  # → rebase flow and hardens the one-shot #122 resolver with bounded retries.
  defp maybe_auto_resolve_conflict(%{auto_resolve_conflict: false} = state, _result), do: state

  defp maybe_auto_resolve_conflict(state, result) do
    case effective_block_reason(result) do
      :conflict -> drive_conflict_resolution(state)
      _ -> reset_conflict_state(state)
    end
  end

  # A resolver acolyte is in flight. The resolver is an `Arbiter.Worker`
  # GenServer that does NOT exit when its rebase acolyte finishes — it lingers
  # in a terminal status (:completed/:failed) until task :close — so we drive
  # completion off the worker's status on each poll rather than a process
  # `:DOWN` that only fires on an abnormal crash (#354 review). While the
  # resolver is still live we wait; once its pass has finished we tear it down
  # (freeing its `:conflict` registry slot) and re-evaluate — dispatching the
  # next bounded attempt or escalating.
  defp drive_conflict_resolution(%{conflict_resolving: true} = state) do
    if resolver_finished?(state) do
      state |> teardown_resolver() |> drive_conflict_resolution()
    else
      state
    end
  end

  # Retries already exhausted and escalated — stay parked, don't re-page.
  defp drive_conflict_resolution(%{conflict_escalated: true} = state), do: state

  # Bounded retries spent: escalate once with the attempt count, then stop.
  defp drive_conflict_resolution(%{conflict_attempts: n, max_conflict_attempts: cap} = state)
       when n >= cap do
    escalate_conflict_exhausted(state, nil)
    %{state | conflict_escalated: true}
  end

  defp drive_conflict_resolution(state), do: spawn_conflict_resolver(state)

  defp spawn_conflict_resolver(state) do
    args = %{
      task_id: state.task_id,
      workspace_id: workspace_id(state),
      pr_ref: state.mr_ref
    }

    case safe_resolve(state.conflict_resolver, args) do
      {:ok, info} ->
        pid = Map.get(info, :worker_pid)
        attempt = state.conflict_attempts + 1

        Logger.info(
          "Worker.Watchdog: dispatched conflict-resolve acolyte " <>
            "(attempt #{attempt}/#{state.max_conflict_attempts}) for " <>
            "task=#{state.task_id} mr=#{state.mr_ref}"
        )

        %{
          state
          | conflict_attempts: attempt,
            conflict_resolving: is_pid(pid),
            conflict_resolver_pid: if(is_pid(pid), do: pid, else: nil),
            conflict_branch: Map.get(info, :branch) || state.conflict_branch
        }

      {:error, reason} ->
        Logger.warning(
          "Worker.Watchdog: could not dispatch conflict-resolve acolyte for " <>
            "task=#{state.task_id} mr=#{state.mr_ref}: #{inspect(reason)}; escalating"
        )

        escalate_conflict_exhausted(
          %{state | conflict_attempts: max(state.conflict_attempts, 1)},
          reason
        )

        %{state | conflict_escalated: true}
    end
  end

  # Conflict cleared (or never present): tear down any lingering resolver worker
  # and reset the retry counter + escalation latch so a *future* conflict on this
  # PR starts fresh.
  defp reset_conflict_state(
         %{
           conflict_resolver_pid: nil,
           conflict_resolving: false,
           conflict_attempts: 0,
           conflict_escalated: false
         } = state
       ),
       do: state

  defp reset_conflict_state(state),
    do: %{teardown_resolver(state) | conflict_attempts: 0, conflict_escalated: false}

  # Has the in-flight resolver acolyte finished its rebase pass? The resolver is
  # an `Arbiter.Worker` that lingers in a terminal status (:completed/:failed)
  # after its acolyte exits — it is only torn down on task :close — so "finished"
  # means the worker reports a terminal status (or its process is already gone).
  # This replaces the `:DOWN` monitor, which never fired on a normal completion
  # and left `conflict_resolving` latched true forever (#354 review).
  defp resolver_finished?(%{conflict_resolver_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      case safe_snapshot(pid) do
        %{status: status} -> status in [:completed, :failed]
        _ -> true
      end
    else
      true
    end
  end

  defp resolver_finished?(_), do: true

  # Tear down a finished resolver worker. It lingers in a terminal status holding
  # its `task_id <> ":conflict"` registry slot until task :close; stopping it
  # here frees that slot so the next bounded attempt's `Worker.start` doesn't
  # collide (`:resolver_already_running`). `Worker.stop` unregisters
  # synchronously in the worker's `terminate/2`. Best-effort — a dead/unstoppable
  # pid just clears the in-flight flag.
  defp teardown_resolver(%{conflict_resolver_pid: pid} = state) do
    if is_pid(pid), do: safe(fn -> Worker.stop(pid) end)
    %{state | conflict_resolving: false, conflict_resolver_pid: nil}
  end

  # Page the coordinator that auto-resolution gave up, with the attempt count and
  # conflict context. Routes through the resolver's `escalate_unresolved/4` (the
  # same channel #122 uses), falling back to the default resolver when an
  # injected one doesn't implement the optional callback. Best-effort.
  defp escalate_conflict_exhausted(state, extra) do
    branch = state.conflict_branch || state.mr_ref || "(unknown branch)"

    reason =
      "auto-resolve exhausted after #{state.conflict_attempts} rebase attempt(s)" <>
        if(extra, do: " (#{inspect_short(extra)})", else: "") <>
        "; manual rebase + push required"

    Logger.warning(
      "Worker.Watchdog: conflict auto-resolve exhausted for task=#{state.task_id} " <>
        "mr=#{state.mr_ref} after #{state.conflict_attempts} attempt(s); escalating to coordinator"
    )

    case workspace_id(state) do
      ws_id when is_binary(ws_id) ->
        resolver = state.conflict_resolver

        target =
          if function_exported?(resolver, :escalate_unresolved, 4),
            do: resolver,
            else: @default_conflict_resolver

        safe(fn -> target.escalate_unresolved(state.task_id, ws_id, branch, reason) end)

      _ ->
        # No workspace_id → the escalation mailbox has no workspace to address, so
        # `escalate_unresolved/4` would silently no-op (the original review's Low
        # finding). Surface the give-up loudly instead of letting it vanish, so an
        # operator still sees that auto-resolve gave up and a manual rebase is
        # required.
        Logger.error(
          "Worker.Watchdog: conflict auto-resolve exhausted for task=#{state.task_id} " <>
            "mr=#{state.mr_ref} but workspace_id is nil — cannot page the coordinator; " <>
            "MANUAL rebase + push required (#{reason})"
        )
    end
  end

  defp safe_resolve(resolver, args) do
    case resolver.resolve(args) do
      {:ok, info} when is_map(info) -> {:ok, info}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_return, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp workspace_id(%{workspace: %{id: id}}) when is_binary(id), do: id
  defp workspace_id(_), do: nil

  defp inspect_short(reason) when is_binary(reason), do: reason
  defp inspect_short(reason), do: reason |> inspect() |> String.slice(0, 200)

  # Master switch for Phase 2b auto-resolve. Opt wins; else workspace config
  # (`merge.auto_resolve_conflict`, default on); else on.
  defp resolve_auto_resolve_conflict(opts, workspace) do
    case Keyword.get(opts, :auto_resolve_conflict) do
      flag when is_boolean(flag) -> flag
      _ -> auto_resolve_from_workspace(workspace)
    end
  end

  defp auto_resolve_from_workspace(%Arbiter.Tasks.Workspace{config: %{} = config}) do
    get_in(config, ["merge", "auto_resolve_conflict"]) != false
  end

  defp auto_resolve_from_workspace(_), do: true

  # Bounded rebase attempts. Opt wins; else workspace config
  # (`merge.max_conflict_attempts`); else the module default.
  defp resolve_max_conflict_attempts(opts, workspace) do
    case Keyword.get(opts, :max_conflict_attempts) do
      n when is_integer(n) and n > 0 -> n
      _ -> max_conflict_attempts_from_workspace(workspace)
    end
  end

  defp max_conflict_attempts_from_workspace(%Arbiter.Tasks.Workspace{config: %{} = config}) do
    case get_in(config, ["merge", "max_conflict_attempts"]) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_conflict_attempts
    end
  end

  defp max_conflict_attempts_from_workspace(_), do: @default_max_conflict_attempts

  defp watch_pipeline_from_workspace(nil), do: false

  defp watch_pipeline_from_workspace(%Arbiter.Tasks.Workspace{} = ws),
    do: Arbiter.Tasks.Workspace.watch_pipeline?(ws)

  defp watch_pipeline_from_workspace(_), do: false

  # Watchdog: bd-66ey1o / bd-akr4il. After `:max_polls` consecutive non-terminal
  # polls, escalate to the Admiral and either:
  #   - auto_merge ON  → fail the worker (auto-merge should fire quickly; a 30-
  #                       min timeout means something is broken on the forge side)
  #   - auto_merge OFF → park the worker (a human reviewer may take overnight or
  #                       longer; failing here was a false negative — VR-17739).
  #                       The Watchdog stops polling to free resources, and the
  #                       worker stays in :awaiting_review so a boot-resume or
  #                       webhook can re-attach it later.
  # Pass `max_polls: :infinity` to disable.
  defp reschedule(%{max_polls: cap, poll_count: count, auto_merge: true} = state)
       when is_integer(cap) and cap > 0 and count + 1 >= cap do
    Logger.warning(
      "Worker.Watchdog: task=#{state.task_id} mr=#{state.mr_ref} exceeded " <>
        "#{cap} polls without a terminal outcome; escalating + failing"
    )

    escalate_watchdog(state)
    safe(fn -> Worker.fail(state.worker_pid, {:awaiting_review_timeout, cap}) end)
    {:stop, :normal, %{state | poll_count: count + 1}}
  end

  defp reschedule(%{max_polls: cap, poll_count: count, auto_merge: false} = state)
       when is_integer(cap) and cap > 0 and count + 1 >= cap do
    Logger.warning(
      "Worker.Watchdog: task=#{state.task_id} mr=#{state.mr_ref} exceeded " <>
        "#{cap} polls on a manual-merge lane; parking (worker stays :awaiting_review)"
    )

    escalate_watchdog(state)
    {:stop, :normal, %{state | poll_count: count + 1}}
  end

  defp reschedule(state) do
    schedule(self(), state.interval_ms)
    {:noreply, %{state | poll_count: state.poll_count + 1}}
  end

  defp escalate_watchdog(state) do
    snap =
      case safe_snapshot(state.worker_pid) do
        %{} = s -> s
        _ -> %{task_id: state.task_id, workspace_id: nil}
      end

    safe(fn ->
      Arbiter.Messages.AdmiralNotifier.awaiting_review_stuck(snap, state.mr_ref)
    end)
  end

  defp safe_snapshot(pid) do
    Worker.state(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # The worker snapshot the notifiers read, with a workspace-derived fallback so
  # an escalation can still be addressed (Message.workspace_id is required) when
  # the worker process can't be reached.
  defp snapshot(state) do
    case safe_snapshot(state.worker_pid) do
      %{} = s -> s
      _ -> %{task_id: state.task_id, workspace_id: workspace_id(state)}
    end
  end

  defp safe_worker_status(pid) do
    case Worker.state(pid) do
      %{status: status} -> status
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_update_branch(%{adapter: adapter, mr_ref: mr_ref}) do
    case adapter.update_branch(mr_ref) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_return, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Best-effort fetch of the failing-check briefing for the fix-pass acolyte. An
  # adapter that doesn't expose check logs, or any error, yields an empty list —
  # the fix pass still dispatches, just without log context.
  defp safe_failing_checks(%{adapter: adapter, mr_ref: mr_ref}) do
    if function_exported?(adapter, :failing_check_logs, 1) do
      case adapter.failing_check_logs(mr_ref) do
        {:ok, checks} when is_list(checks) -> checks
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp schedule(pid, ms) when is_integer(ms) and ms >= 0 do
    Process.send_after(pid, :poll, ms)
  end

  defp safe_get(%{adapter: adapter, mr_ref: mr_ref}) do
    adapter.get(mr_ref)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe_merge(%{adapter: adapter, mr_ref: mr_ref}) do
    case adapter.merge(mr_ref) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_return, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
