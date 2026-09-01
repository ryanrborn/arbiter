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
  (`effective_block_reason/1`). On an `auto_merge` lane the Watchdog tries to
  resolve the two mechanically-fixable reasons itself before escalating:

      :behind_base -> `adapter.update_branch/1` (update-branch), then re-poll.
                      A failed update (conflict introduced) falls through to
                      `:conflict` handling.
      :ci_failed   -> dispatch a fix-pass worker (briefed with the failing
                      check logs via `adapter.failing_check_logs/1`) to fix the
                      root cause and push, then re-poll.

  Each attempt increments a per-episode counter; after `max_auto_resolve_attempts`
  (default 2) the Watchdog stops retrying and escalates with the reason + attempt
  count, and lifts its poll ceiling (`max_polls`) to `:infinity` so it parks and
  keeps watching indefinitely instead of dying at the finite auto_merge ceiling —
  an out-of-band fix (e.g. a manual pipeline retry) that later makes the MR
  mergeable is picked back up on a later poll rather than being missed because
  the only process watching the MR already exited (bd-krg7ci). The lifted
  ceiling is restored once the block clears (`poll_count` resets with it), and
  the exhausted-retry escalation itself re-fires periodically (every
  `base_max_polls` polls) while parked, so a block that never resolves keeps
  paging the coordinator instead of going silent after the first page. The
  remaining reasons (`:conflict`, `:needs_approval`, `:draft`, `:blocked_other`)
  keep the Phase 1 behaviour: escalate once and park.

  ## Non-author-approval block (bd-c3lchp)

  A fleet-authored PR that is fully green but parked on a required *non-author*
  approval (the forge's branch protection requires a reviewer other than the
  author — which the fleet can never be, having authored the PR) is a special
  case the adapters report as `:needs_nonauthor_approval`. The auto_merge poll
  ceiling used to mark such a PR FAILED even though nothing was broken. The
  Watchdog now parks it: it escalates to a human reviewer **once** and lifts its poll
  ceiling to `:infinity`, handing off to indefinite watching so a later human
  approval auto-merges. No failed worker, on any forge.

  ## Auto-resuming an awaiting_review timeout (bd-8eheb6)

  Hitting `max_polls` on an `auto_merge` lane fails the worker with
  `{:awaiting_review_timeout, N}` — exit_status 0, worktree preserved, MR
  usually still mergeable. That is a *cleanly resumable* run, not a crash, and
  the coordinator's remedy has always been a plain `worker_resume`. So the
  Watchdog now does it itself: `handle_review_timeout/2` still registers the
  failure reason (the timeout is real and must stay visible), then calls
  `Arbiter.Workflows.MergeQueue.AutoResumeDispatcher` — swappable via the
  `:auto_resume_dispatcher` opt — instead of leaving a "failed but resumable"
  worker for a human to spot on the dashboard.

  The budget is bounded by `:max_auto_resumes` (default 3; workspace key
  `merge.max_awaiting_review_resumes`; `0` disables it and restores the old
  escalate-and-park behaviour). The attempt counter lives on the *worker's*
  `meta[:awaiting_review_resume_attempts]`, not in Watchdog state, because each
  auto-resume mints a brand-new worker *and* a brand-new Watchdog — a
  per-Watchdog counter would reset every round and the cap would never bind.
  `Arbiter.Worker.Dispatch` re-stamps it onto each resumed run.

  Once the budget is spent the coordinator gets an addressed escalation reading
  "auto-resume exhausted after N attempts", deliberately distinct from a
  first-time genuine failure. Non-timeout failures (`:mr_closed`, a real crash)
  are untouched — they escalate immediately, exactly as before.

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
  `Arbiter.Mergers.prepare_with_repo/2` in `init/1` (a no-op for `Direct`). The
  optional `:repo` opt lets a multi-GitLab-project workspace (see
  `Arbiter.Mergers.Gitlab.Config` moduledoc) resolve the project the watched
  MR actually lives in, instead of the workspace-wide default.
  """

  use GenServer

  require Logger

  alias Arbiter.Mergers
  alias Arbiter.Worker
  alias Arbiter.Worker.Registry, as: PRegistry

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

  # Consecutive `:not_started` polls (zero check-runs on the head SHA) the
  # Watchdog will defer auto-merge for before treating the pipeline as settled
  # and falling through to a merge attempt (bd-aeb9wv / #1189). Bounded, not
  # infinite: zero check-runs is ambiguous between "GitHub hasn't created the
  # check-suite yet" (the #1188 race — resolves within a poll or two) and "no
  # CI is configured for this repo at all" (never resolves). Treating
  # `:not_started` the same as genuine `:running`/`:pending` forever would
  # make every no-CI auto-merge lane time out at `max_polls` and hard-fail the
  # worker. 5 polls at the default 60s interval is ~5 minutes — orders of
  # magnitude more than the 1s gap in the incident report, while still bounded
  # for repos that will never produce a check-run.
  @not_started_grace_polls 5

  # Consecutive auto-resolve attempts (#354, Phase 2a) before the Watchdog stops
  # mechanically resolving a block and escalates to the coordinator with the
  # reason + attempt count. Override via opt `:max_auto_resolve_attempts` or
  # workspace config["merge"]["max_auto_resolve_attempts"].
  @default_max_auto_resolve_attempts 2

  # The default dispatcher the Watchdog uses to spawn a fix-pass worker for a
  # :ci_failed block. Swappable via the `:fix_pass_dispatcher` opt (tests stub it).
  @default_fix_pass_dispatcher Arbiter.Workflows.MergeQueue.FixPassDispatcher

  # Consecutive safe_merge failures before the Watchdog pages the coordinator with a
  # stall notification (bd-6gxosc). The Watchdog keeps retrying after notifying;
  # the counter resets on a successful merge so a future stall re-notifies.
  @default_merge_fail_notify_threshold 3

  # Registry suffix the fix-pass worker registers under — MUST match
  # `FixPassDispatcher.registry_suffix/0` so we can detect an in-flight fix pass.
  @fix_pass_registry_suffix ":fixpass"

  # Registry suffix the Watchdog itself registers under, so an external caller
  # (CLI / MCP tool / dashboard) can find the Watchdog for a task by task_id
  # alone and message it directly — needed for `retry_auto_resolve/1` (bd-bspakl).
  @watchdog_registry_suffix ":watchdog"
  # Bounded rebase attempts before the Watchdog gives up auto-resolving a
  # `:conflict` block and escalates to the coordinator (#354, Phase 2b). Each
  # attempt is one dispatched rebase-resolve worker; if two consecutive passes
  # don't clear the conflict it is almost certainly semantic and needs a human.
  @default_max_conflict_attempts 2

  # Bounded auto-resumes of an `{:awaiting_review_timeout, _}` failure before the
  # Watchdog stops self-healing and pages the coordinator (bd-8eheb6). Override
  # via opt `:max_auto_resumes` or workspace
  # config["merge"]["max_awaiting_review_resumes"]. 0 disables auto-resume and
  # restores the pre-bd-8eheb6 "escalate + park failed" behaviour.
  @default_max_auto_resumes 3

  # The dispatcher the Watchdog uses to auto-resume an awaiting_review timeout
  # (and to page the coordinator once the budget is spent). Swappable via the
  # `:auto_resume_dispatcher` opt (tests stub it).
  @default_auto_resume_dispatcher Arbiter.Workflows.MergeQueue.AutoResumeDispatcher

  # The resolver that dispatches a rebase-resolve worker against the task's
  # existing worktree. Injectable via the `:conflict_resolver` opt (tests pass a
  # stub). The default is the same module the MergeQueue uses, so the Watchdog-
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
          | {:max_auto_resumes, non_neg_integer()}
          | {:auto_resume_dispatcher, module()}
          | {:merge_fail_notify_threshold, pos_integer()}

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
    task_id = Keyword.fetch!(opts, :task_id)
    GenServer.start_link(__MODULE__, opts, name: registry_name(task_id))
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
          :conflict
          | :behind_base
          | :ci_failed
          | :needs_approval
          | :needs_nonauthor_approval
          | :draft
          | :blocked_other

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

  The arity-1 form is the state-less surface (the dashboard / LiveViews): it can
  only read what the forge itself reports. The poll loop uses
  `effective_block_reason/2`, which additionally knows whether the ReviewGate
  already approved in-process — see there.
  """
  @spec effective_block_reason(map()) :: block_reason() | nil
  def effective_block_reason(result),
    do: effective_block_reason(%{via_review_gate: false}, result)

  @doc """
  `effective_block_reason/1`, but aware of an in-process ReviewGate approval —
  the form the poll loop routes on (bd-23y19q / #1176).

  The approval gate above is computed from `classify/1`, i.e. the forge's *own*
  PR/MR review state. When the ReviewGate approved in-process, hosted-forge
  adapters never see that approval on the PR itself, so `classify/1` returns
  `:pending` forever and the arity-1 gate returns `nil` on every poll — which
  made the entire block-handling surface (`:ci_failed` → fix-pass worker,
  `:behind_base` → update-branch, the exhaustion escalation) dead code for
  exactly the population ReviewGate drives. Live consequence: PR #1173
  auto-merged four seconds after its APPROVE verdict with a `mix test` check
  that had been concluded FAILURE for three minutes, because nothing on that
  lane could see the `:ci_failed` block.

  So this mirrors `effective_outcome/2`'s existing override: gate the reason on
  the *effective* outcome rather than the raw `classify/1`. Terminal statuses
  (`:merged` / `:closed`) still short-circuit to `nil` — they're facts about the
  MR, not approval-state interpretation.
  """
  @spec effective_block_reason(map(), map()) :: block_reason() | nil
  def effective_block_reason(state, result) when is_map(state) and is_map(result) do
    case effective_outcome(state, result) do
      :approved -> block_reason(result)
      _ -> nil
    end
  end

  def effective_block_reason(_state, _result), do: nil

  @doc """
  Look up the Watchdog registered for `task_id`, or `nil` if none is running.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(task_id) when is_binary(task_id),
    do: PRegistry.whereis(task_id <> @watchdog_registry_suffix)

  @doc """
  Re-arm one more auto-resolve attempt for a task parked indefinitely after
  exhausting `max_auto_resolve_attempts` on a `:ci_failed` block (bd-bspakl).

  Once exhausted, `handle_block/3` never calls `auto_resolve/3` again on its
  own — by design, so a structurally-broken PR can't burn cost forever. This
  is the supported external trigger for a human to say "try once more": it
  bumps this episode's budget by exactly one attempt and immediately re-polls,
  which re-invokes the ordinary `resolve_ci_failed/2` path (dispatching a
  fresh fix-pass worker) if the block is still `:ci_failed`, or picks up
  whatever the MR's current state actually is otherwise.

  No cap on how many times a human calls this — they're presumably watching
  and will notice non-convergence — but it is never called automatically; the
  Watchdog itself only ever re-arms via this explicit external call.

  Only bumps the budget for *this* block episode: the configured ceiling
  (`base_max_auto_resolve_attempts`) is restored once the episode clears, so
  a later, unrelated block on the same lane doesn't inherit the bump.

  Returns:
    * `:ok` — re-armed; a poll will pick it up on the already-pending
      schedule (within `interval_ms`).
    * `{:error, :not_found}` — no Watchdog is registered for `task_id`.
    * `{:error, :not_parked_on_ci_failed}` — the Watchdog isn't parked on an
      exhausted `:ci_failed` block (e.g. still running, or parked for a
      different reason), so there is nothing to re-arm.
  """
  @spec retry_auto_resolve(String.t()) ::
          :ok | {:error, :not_found | :not_parked_on_ci_failed}
  def retry_auto_resolve(task_id) when is_binary(task_id) do
    case whereis(task_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :retry_auto_resolve, 1_000)
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Read-only lookup of the reason a task's Watchdog is currently parked on
  (e.g. `:ci_failed`), or `nil` if it isn't parked or no Watchdog is running
  for `task_id`.

  This is the authoritative signal for whether `retry_auto_resolve/1` would
  accept a re-arm — unlike `effective_block_reason/1`, which infers from the
  forge's own approval state and can't see a ReviewGate-driven park (bd-bspakl).
  """
  @spec parked_on(String.t()) :: block_reason() | nil
  def parked_on(task_id) when is_binary(task_id) do
    case whereis(task_id) do
      nil -> nil
      pid -> GenServer.call(pid, :parked_on, 1_000)
    end
  catch
    :exit, _ -> nil
  end

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
        Mergers.prepare_with_repo(workspace, Keyword.get(opts, :repo))

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
        max_auto_resumes = resolve_max_auto_resumes(opts, workspace)

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
          # The configured ceiling as passed at start (before any indefinite-park
          # lift). Restored into `max_polls` once a block episode clears, and used
          # as the re-escalation cadence while parked (bd-krg7ci) — see
          # `maybe_escalate_unresolved/2` and the `nil`-reason recovery branch.
          base_max_polls: Keyword.get(opts, :max_polls, default_max_polls),
          poll_count: 0,
          watch_pipeline: watch_pipeline,
          last_pipeline: nil,
          # The last merge-block reason we escalated, so a blocked merge is
          # surfaced once per reason rather than on every poll (#354, Phase 1).
          last_block_reason: nil,
          # The reason a genuine indefinite park is in effect, set alongside
          # `max_polls: :infinity` by `handle_nonauthor_approval/2` and the
          # exhausted-retry branch of `handle_block/3`, and cleared only once
          # that specific episode is confirmed resolved (bd-krg7ci round 4).
          # Unlike `last_block_reason` — which the adapters can transiently stop
          # emitting for reasons unrelated to the park actually clearing (CI
          # going red/running collapses `:needs_nonauthor_approval` to `nil`;
          # an approval dismissal collapses any approval-gated reason to `nil`)
          # — `park_reason` only clears on a poll that shows the PR genuinely
          # approved and unblocked, so a signal lapse can't revoke a park that's
          # still needed. See `do_maybe_escalate_merge_block/2`.
          park_reason: nil,
          # Consecutive auto-resolve attempts for the current block episode
          # (#354, Phase 2a). Reset to 0 when the block clears. After
          # `max_auto_resolve_attempts` the Watchdog escalates instead of retrying.
          auto_resolve_attempts: 0,
          max_auto_resolve_attempts: max_auto_resolve_attempts,
          # The configured ceiling as passed at start, mirroring `base_max_polls`.
          # `retry_auto_resolve/1` bumps `max_auto_resolve_attempts` for the
          # current block episode only; this is restored into it once the
          # episode clears so the bump doesn't leak into a later, unrelated
          # block (bd-bspakl).
          base_max_auto_resolve_attempts: max_auto_resolve_attempts,
          fix_pass_dispatcher: fix_pass_dispatcher,
          # Latches the exhausted-retry escalation so it fires once per block
          # episode rather than on every subsequent poll (#354, Phase 2a). While
          # parked indefinitely (max_polls lifted to :infinity) the latch is
          # periodically cleared — see `last_escalated_poll` — so a block that
          # never resolves keeps paging instead of going silent forever.
          unresolved_escalated: false,
          # poll_count at which `unresolved_escalated` was last set. While parked
          # indefinitely, re-escalate every `base_max_polls` polls so a stuck MR
          # keeps surfacing to the coordinator instead of polling silently
          # forever after the one-time page (bd-krg7ci).
          last_escalated_poll: 0,
          # Fired once when an approved MR is parked without auto-merge, so the
          # external tracker moves to its "approved, awaiting merge" status
          # (e.g. Jira VR -> Pending Merge) instead of every poll. (bd-c4cfuv)
          pending_merge_synced: false,
          # Fired once when an approved + mergeable MR is parked on an
          # auto_merge:false lane, so the coordinator inbox is paged that the PR
          # is ready for a manual merge decision instead of parking silently
          # forever. Debounced like `pending_merge_synced`. (bd-b4pwxa)
          approved_merge_notified: false,
          # Auto-resolve of an approved `:conflict` block (#354, Phase 2b).
          #   auto_resolve_conflict  — master switch (workspace-tunable).
          #   conflict_resolver      — module that dispatches the rebase worker.
          #   max_conflict_attempts  — bounded rebase passes before escalation.
          #   conflict_attempts      — passes dispatched for the current conflict.
          #   conflict_resolving     — a resolver worker is in flight right now.
          #   conflict_resolver_pid  — that resolver worker's pid. We poll its
          #                            terminal status to detect completion: the
          #                            resolver worker does NOT exit when its
          #                            worker finishes (it lingers :completed/
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
          conflict_escalated: false,
          # Bounded self-healing of `{:awaiting_review_timeout, _}` (bd-8eheb6).
          #   max_auto_resumes        — auto-resume budget for this task; 0 = off.
          #   auto_resume_dispatcher  — module that re-attaches the worker and,
          #                             once the budget is spent, pages the
          #                             coordinator. The attempt counter itself
          #                             lives on the WORKER's meta
          #                             (`:awaiting_review_resume_attempts`), not
          #                             here: each auto-resume mints a brand-new
          #                             worker + Watchdog, so a per-Watchdog
          #                             counter would reset to 0 every round and
          #                             the cap would never bind.
          max_auto_resumes: max_auto_resumes,
          auto_resume_dispatcher:
            Keyword.get(opts, :auto_resume_dispatcher, @default_auto_resume_dispatcher),
          # Consecutive safe_merge failures (bd-6gxosc). Resets to 0 on success;
          # a notification fires once when the count first hits the threshold, then
          # is suppressed until the counter resets and re-hits the threshold.
          merge_fail_count: 0,
          merge_fail_notify_threshold:
            Keyword.get(opts, :merge_fail_notify_threshold, @default_merge_fail_notify_threshold),
          merge_stall_notified: false,
          last_merge_stall_poll: 0,
          # Consecutive `:not_started` polls for the current approval episode
          # (bd-aeb9wv / #1189). Resets whenever the pipeline reports anything
          # other than `:not_started`. Once it reaches `@not_started_grace_polls`,
          # the Watchdog stops deferring and falls through to a merge attempt —
          # see `apply_outcome(:approved, result, %{auto_merge: true})`.
          not_started_polls: 0
        }

        Process.monitor(worker_pid)
        schedule(self(), Keyword.get(opts, :initial_delay_ms, 0))
        {:ok, state}
    end
  end

  defp registry_name(task_id), do: PRegistry.via_tuple(task_id <> @watchdog_registry_suffix)

  @impl true
  def handle_call(:retry_auto_resolve, _from, %{park_reason: :ci_failed} = state) do
    Logger.warning(
      "Worker.Watchdog: manual auto-resolve re-arm for task=#{state.task_id} " <>
        "mr=#{state.mr_ref} (was #{state.auto_resolve_attempts}/#{state.max_auto_resolve_attempts} attempts)"
    )

    state = %{
      state
      | max_auto_resolve_attempts: state.max_auto_resolve_attempts + 1,
        unresolved_escalated: false,
        last_escalated_poll: state.poll_count
    }

    # Deliberately not scheduling an immediate poll here: a `:poll` timer is
    # already pending from the last `reschedule/1` (there is no timer ref
    # tracked in state, so we can't cancel-and-replace it), and firing a
    # second one starts a permanent, independent poll chain that never merges
    # back — each re-arm would multiply the effective poll rate. The already-
    # pending timer picks this up within `interval_ms`, which a human re-arm
    # can tolerate.
    {:reply, :ok, state}
  end

  def handle_call(:retry_auto_resolve, _from, state) do
    {:reply, {:error, :not_parked_on_ci_failed}, state}
  end

  @impl true
  def handle_call(:parked_on, _from, state) do
    {:reply, state.park_reason, state}
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
    sync_tracker_merged(state)
    safe(fn -> Worker.complete(state.worker_pid, :merged) end)

    {:stop, :normal,
     %{state | merge_fail_count: 0, merge_stall_notified: false, last_merge_stall_poll: 0}}
  end

  defp apply_outcome(:closed, _result, state) do
    Logger.info("Worker.Watchdog: MR #{state.mr_ref} closed for task=#{state.task_id}")
    safe(fn -> Worker.fail(state.worker_pid, {:mr_closed, state.mr_ref}) end)
    {:stop, :normal, state}
  end

  defp apply_outcome(:approved, result, %{auto_merge: true} = state) do
    cond do
      # `:not_started` (zero check-runs on the head SHA) is ambiguous between
      # "check-suite not created yet" and "no CI on this repo at all" — defer,
      # but only for a bounded number of polls (bd-aeb9wv / #1189). Once the
      # grace is exhausted, fall out of this branch entirely (not into the
      # `ci_pending?` branch below, which no longer matches `:not_started`) so
      # a no-CI repo still becomes mergeable instead of hard-failing at
      # `max_polls`. See `@not_started_grace_polls`.
      Map.get(result, :pipeline) == :not_started and
          state.not_started_polls + 1 < @not_started_grace_polls ->
        state = %{state | not_started_polls: state.not_started_polls + 1}

        Logger.info(
          "Worker.Watchdog: deferring auto-merge for task=#{state.task_id} " <>
            "mr=#{state.mr_ref}; no check-runs yet for head SHA " <>
            "(#{state.not_started_polls}/#{@not_started_grace_polls} grace polls), " <>
            "will retry next poll"
        )

        reschedule(state)

      ci_pending?(result) ->
        Logger.info(
          "Worker.Watchdog: deferring auto-merge for task=#{state.task_id} " <>
            "mr=#{state.mr_ref}; pipeline still #{inspect(Map.get(result, :pipeline))}, " <>
            "will retry next poll"
        )

        reschedule(%{state | not_started_polls: 0})

      # CI reported, and it reported *failure*. "Not pending" is not "safe to
      # merge": before bd-23y19q this branch didn't exist, so a settled `:failed`
      # pipeline fell straight through to the merge — PR #1173 merged four
      # seconds after its ReviewGate APPROVE with a `mix test` check that had
      # been concluded FAILURE for three minutes. Never merge on red.
      #
      # This is the last-resort guard, not the resolution path: a red pipeline
      # normally surfaces as a `:ci_failed` block, and `handle_block/3` gets
      # there first — dispatching a bounded fix-pass worker and escalating once
      # the retries are exhausted (that block is now visible on ReviewGate lanes
      # too, via `effective_block_reason/2`). This branch only catches the case
      # where the adapter surfaces the red pipeline without a block reason, so
      # we stay parked and keep polling rather than merging.
      ci_failed?(result) ->
        Logger.warning(
          "Worker.Watchdog: refusing auto-merge for task=#{state.task_id} " <>
            "mr=#{state.mr_ref}; pipeline concluded :failed, staying parked"
        )

        reschedule(%{state | not_started_polls: 0})

      true ->
        do_apply_approved_auto_merge(%{state | not_started_polls: 0})
    end
  end

  defp apply_outcome(:approved, result, %{auto_merge: false} = state) do
    # Approved but auto_merge is off: the review passed yet the fleet will not
    # merge — a human decides. Two once-latched side effects, then keep polling
    # for the human merge (the next poll that sees :merged completes):
    #
    #   * `sync_tracker_pending_merge` moves the external tracker to its parked-
    #     but-approved status (Jira VR -> Pending Merge). (bd-c4cfuv)
    #   * `notify_awaiting_manual_merge` pages the coordinator INBOX that the PR
    #     is ready for a manual merge decision. Without this, an approved+done
    #     PR on an auto_merge:false lane parked *silently* — nothing was ever
    #     written to the coordinator inbox, so a ready-to-merge PR could sit
    #     indefinitely until someone happened to poll `arb worker list`.
    #     auto_merge:false must mean "ask a human", not "say nothing". (bd-b4pwxa)
    state = maybe_sync_pending_merge(state)
    state = maybe_notify_awaiting_manual_merge(state, result)
    reschedule(state)
  end

  defp apply_outcome(:pending, _result, state), do: reschedule(state)

  # CI still running/queued for the approved MR's head commit — attempting the
  # merge right now would just fail against the forge's own not-yet-mergeable
  # check (bd-cnytw3). `block_reason/1` deliberately collapses this in-progress
  # state to `nil` (correctly — it's not a genuine block to escalate on), so it
  # can't tell "genuinely mergeable" apart from "CI in flight"; the raw
  # `:pipeline` signal both adapters already expose can. `:pending` here means
  # genuinely queued/in-flight on both adapters — each adapter maps its own
  # *settled*-but-non-success states (GitHub neutral/skipped/stale check runs,
  # GitLab skipped/manual pipelines) to `:neutral` instead, so they fall
  # through to a real merge attempt rather than deferring forever.
  #
  # `:not_started` (bd-aeb9wv / #1189) is deliberately NOT in this list. The
  # GitHub adapter's check-runs API returned zero results for the head SHA —
  # PR #1188 merged 6s after its ReviewGate APPROVE, one second *before* its
  # check-suite was even created, so `ci_pending?/1` had nothing to classify
  # and the merge went through on an unstarted pipeline. But zero check-runs
  # is genuinely ambiguous: it's the same response GitHub gives for "no CI
  # configured on this repo/commit at all" as for "check-suite not created
  # yet". Putting `:not_started` in this set would make it identical to
  # `:running`/`:pending` — deferred *forever*, since nothing ever moves a
  # no-CI repo's pipeline out of `:not_started`. Instead `apply_outcome/3`
  # handles `:not_started` itself, ahead of this check, deferring for only
  # `@not_started_grace_polls` polls before falling through to a merge
  # attempt — bounded waiting for the ambiguous case, not permanent blocking.
  def ci_pending?(result), do: Map.get(result, :pipeline) in [:running, :pending]

  @doc """
  CI has *concluded*, and it failed. The strict complement of `ci_pending?/1`
  for the merge decision: the two must never be conflated under "not pending"
  (bd-23y19q / #1176). `:neutral` is deliberately excluded — both adapters map
  their settled-but-non-success states (GitHub neutral/skipped/stale check runs,
  GitLab skipped/manual pipelines) there, and those are not failures.
  """
  @spec ci_failed?(map()) :: boolean()
  def ci_failed?(result), do: Map.get(result, :pipeline) == :failed

  defp do_apply_approved_auto_merge(state) do
    case safe_merge(state) do
      :ok ->
        Logger.info(
          "Worker.Watchdog: auto-merged approved MR #{state.mr_ref} for task=#{state.task_id}"
        )

        sync_tracker_merged(state)
        safe(fn -> Worker.complete(state.worker_pid, :merged) end)
        {:stop, :normal, state}

      {:error, reason} ->
        # Merge failed (race, branch conflict, transient). Stay parked and let
        # the next poll re-attempt rather than failing the task outright.
        fail_count = state.merge_fail_count + 1

        Logger.warning(
          "Worker.Watchdog: auto-merge failed for task=#{state.task_id} mr=#{state.mr_ref}: #{inspect(reason)}; will retry (consecutive failure #{fail_count})"
        )

        state = %{state | merge_fail_count: fail_count}

        should_notify =
          (fail_count >= state.merge_fail_notify_threshold and not state.merge_stall_notified) or
            (state.merge_stall_notified and
               state.poll_count - state.last_merge_stall_poll >= escalation_cadence(state))

        state =
          if should_notify do
            Logger.warning(
              "Worker.Watchdog: paging coordinator for auto-merge stall " <>
                "(fail_count=#{fail_count}) task=#{state.task_id} mr=#{state.mr_ref}"
            )

            safe(fn ->
              Arbiter.Messages.CoordinatorNotifier.auto_merge_stalled(
                snapshot(state),
                state.mr_ref,
                fail_count,
                reason
              )
            end)

            # The coordinator has been paged — this is no longer the silent
            # "should auto-merge quickly or something's broken" case the ordinary
            # ceiling guards against. Lift it to an indefinite park-and-watch so
            # a manual pipeline retry or other out-of-band fix that later makes
            # the MR mergeable is picked back up instead of the worker dying at
            # the finite ceiling first (bd-krg7ci).
            #
            # Re-page every `base_max_polls` polls instead of latching silent
            # forever after the first page — mirrors `maybe_escalate_unresolved/2`
            # below, which fixed the identical permanent-silence gap on the block
            # path (bd-krg7ci round 2).
            %{
              state
              | merge_stall_notified: true,
                max_polls: :infinity,
                last_merge_stall_poll: state.poll_count
            }
          else
            state
          end

        reschedule(state)
    end
  end

  # Sync the external tracker to its parked-but-approved status exactly once per
  # Watchdog episode (bd-c4cfuv).
  defp maybe_sync_pending_merge(%{pending_merge_synced: true} = state), do: state

  defp maybe_sync_pending_merge(state) do
    sync_tracker_pending_merge(state)
    %{state | pending_merge_synced: true}
  end

  # Page the coordinator inbox once that an approved PR on an auto_merge:false
  # lane is ready for a manual merge (bd-b4pwxa). Skip when a block is
  # outstanding: `merge_blocked/3` already escalates those, and this message is
  # specifically "approved + mergeable + nothing left but the human merge".
  #
  # `effective_block_reason/1 != nil` covers an *approved* PR with a genuine
  # block (handled by `handle_block/3`); the raw `:needs_nonauthor_approval`
  # covers the fleet-authored-PR case (handled by `handle_nonauthor_approval/2`),
  # which classifies as pending on the forge yet still routes here via
  # `effective_outcome/2`. Both already page the coordinator, so suppress the
  # duplicate here. Self-latched on `approved_merge_notified` so it fires once.
  defp maybe_notify_awaiting_manual_merge(%{approved_merge_notified: true} = state, _result),
    do: state

  defp maybe_notify_awaiting_manual_merge(state, result) do
    if awaiting_manual_merge?(state, result) do
      safe(fn ->
        Arbiter.Messages.CoordinatorNotifier.approved_awaiting_merge(
          snapshot(state),
          state.mr_ref,
          state.via_review_gate
        )
      end)

      %{state | approved_merge_notified: true}
    else
      state
    end
  end

  defp awaiting_manual_merge?(state, result) do
    effective_block_reason(state, result) == nil and
      block_reason(result) != :needs_nonauthor_approval
  end

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

  # Fire the merged tracker hook. Best-effort + loud-on-failure inside
  # `Arbiter.Trackers.Sync`; an unreadable task just skips.
  defp sync_tracker_merged(state) do
    with {:ok, task} <- Ash.get(Arbiter.Tasks.Issue, state.task_id) do
      Arbiter.Trackers.Sync.lifecycle(task, :merged)
    end

    :ok
  rescue
    e ->
      Logger.debug(
        "Worker.Watchdog: merged tracker sync raised for task=#{state.task_id}: #{Exception.message(e)}"
      )

      :ok
  end

  # ---- internals ----------------------------------------------------------

  defp record_status(state, result) do
    safe(fn ->
      Worker.record_merger_status(state.worker_pid, result)
    end)
  end

  # When watch_pipeline is enabled, escalate to the coordinator on the first poll
  # that reports a failed pipeline. Stay parked — a human may force-merge or
  # rerun. Only escalates once per failure sequence (tracks last_pipeline to
  # suppress repeated alerts on consecutive :failed polls).
  defp maybe_escalate_pipeline(%{watch_pipeline: false} = state, _result), do: state

  defp maybe_escalate_pipeline(state, result) do
    current_pipeline = Map.get(result, :pipeline)

    if current_pipeline == :failed and state.last_pipeline != :failed do
      Logger.warning(
        "Worker.Watchdog: CI pipeline failed for task=#{state.task_id} mr=#{state.mr_ref}; " <>
          "escalating to coordinator, staying parked"
      )

      safe(fn ->
        snap =
          case safe_snapshot(state.worker_pid) do
            %{} = s -> s
            _ -> %{task_id: state.task_id, workspace_id: nil}
          end

        Arbiter.Messages.CoordinatorNotifier.pipeline_failed(snap, state.mr_ref)
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
  # Phase 2b owns `:conflict`: when auto-resolve is enabled the Watchdog rebases
  # rather than paging on a conflict, and only escalates after the bounded
  # retries are exhausted (see `maybe_auto_resolve_conflict/2`). So skip the
  # generic page here for `:conflict` — the other reasons still escalate.
  # A fleet-authored PR blocked only on a required *non-author* approval can
  # never auto-merge on its own: the fleet authored it, and the forge's branch
  # protection / approval rules require a *different* reviewer the fleet can't
  # supply (it cannot approve its own PR). The 30-poll auto_merge ceiling used to
  # mark this FAILED (`{:awaiting_review_timeout, 30}`) even on a fully-green PR
  # (bd-c3lchp / lt-4kjaoe). Park it instead: summon a human reviewer once and
  # hand off to indefinite watching, so a later human approval auto-merges.
  #
  # This applies to both non-gate PRs (awaiting any reviewer) and ReviewGate PRs
  # (gate approved in-process but the forge's branch protection still requires a
  # non-author forge-level review). The coordinator reviewer submits that forge
  # approval, then signals MergeQueue (bd-bs3z04); once the forge reflects it,
  # the next poll sees :approved and auto-merges. Without this guard a
  # via_review_gate Watchdog would exhaust 30 polls trying safe_merge against a
  # forge-blocked PR and then fail the worker. (bd-bs3z04)
  #
  # Read from the *raw* block_reason rather than `effective_block_reason/1`: this
  # block is meaningful *before* approval (it is precisely *why* no approval has
  # landed), whereas the approval gate deliberately suppresses pre-approval
  # blocks. The adapters (`Github` / `Gitlab`) only emit this reason for the
  # narrow case — green, no changes requested, blocked solely on a required
  # review the author can't satisfy — so an ordinary "awaiting first review" PR
  # still flows through the normal pending path.
  defp maybe_escalate_merge_block(state, result) do
    if block_reason(result) == :needs_nonauthor_approval do
      handle_nonauthor_approval(state, result)
    else
      route_merge_block(state, result)
    end
  end

  # Summon a human reviewer once (debounced on `last_block_reason`) and convert
  # the lane to indefinite park-and-watch by lifting `max_polls` to `:infinity`,
  # so `reschedule/1`'s auto_merge ceiling can never fail this worker. The worker
  # stays at `:awaiting_review`; whenever the human approval lands, the ongoing
  # poll sees `:approved` and auto-merges (or, on a manual lane, a human merges).
  defp handle_nonauthor_approval(state, result) do
    state = debounce_escalate_block(state, :needs_nonauthor_approval)

    apply_outcome(
      effective_outcome(state, result),
      result,
      %{state | max_polls: :infinity, park_reason: :needs_nonauthor_approval}
    )
  end

  defp route_merge_block(%{auto_resolve_conflict: true} = state, result) do
    case effective_block_reason(state, result) do
      :conflict -> reschedule(state)
      _ -> do_maybe_escalate_merge_block(state, result)
    end
  end

  defp route_merge_block(state, result), do: do_maybe_escalate_merge_block(state, result)

  defp do_maybe_escalate_merge_block(state, result) do
    case effective_block_reason(state, result) do
      nil ->
        # The block cleared. Besides resetting the per-episode latches, restore
        # the configured poll ceiling *if a block episode was actually parked
        # AND that specific park is confirmed resolved*: `handle_block/3` and
        # `handle_nonauthor_approval/2` set `max_polls: :infinity` together with
        # `park_reason` while parked, and leaving that lift in place after the
        # episode resolves would make the worker immortal for the rest of its
        # life instead of just for that one episode (bd-krg7ci).
        #
        # Gated on `state.park_reason != nil` (i.e. a genuine indefinite park is
        # in effect) AND the *current* poll showing the PR genuinely approved
        # with no raw block reason. Deliberately NOT gated on
        # `effective_block_reason(result) == nil` alone (that's merely the guard
        # of the enclosing `case` and is satisfied by *any* unapproved PR, since
        # `effective_block_reason/1` suppresses pre-approval blocks) — doing so
        # let a signal lapse masquerade as resolution and revoke a park that was
        # still needed (bd-krg7ci round 4):
        #
        #   * `:needs_nonauthor_approval` park — the adapters only emit this
        #     narrow reason while CI is green; as soon as CI goes red
        #     (`github.ex`, `gitlab.ex`) or starts running (`gitlab.ex` maps
        #     `ci_still_running`/`ci_must_pass` to `nil`), the reason vanishes
        #     even though the PR is still unapproved, which used to restore the
        #     finite ceiling and let the ordinary auto_merge timeout fail the
        #     worker out from under a PR still awaiting the same human.
        #   * exhausted-block park (e.g. `:ci_failed`) — dismissing the PR's
        #     approval (standard branch-protection behavior on a new commit
        #     push) also collapses `effective_block_reason/1` to `nil` even
        #     though the underlying block was never actually resolved.
        #
        # Requiring `classify(result) == :approved and block_reason(result) ==
        # nil` on the poll that clears the park means only a poll that shows the
        # PR genuinely mergeable — not just "the gated reason isn't visible right
        # now" — can revoke it. A lane that repeatedly enters and clears a
        # *bounded* block (e.g. `:behind_base`/`:ci_failed` resolving within
        # `max_auto_resolve_attempts`, which never sets `park_reason`) still
        # never trips this branch, so the finite ceiling stays monotonic for
        # those flapping episodes too (bd-krg7ci round 2).
        #
        # Deliberately raw `classify/1` here, not the ReviewGate-aware
        # `effective_block_reason/2` / `effective_outcome/2` (bd-23y19q): on a
        # gate lane the effective outcome is *always* `:approved`, which would
        # collapse this condition to "no raw block reason right now" — precisely
        # the signal lapse round 4 closed (GitLab maps an in-flight pipeline's
        # reason to `nil`). Keeping it raw means a gate lane simply never
        # revokes a park, which is the safe direction: the worker keeps watching
        # and merges the moment the block genuinely clears.
        #
        # This still excludes the separate auto-merge-failure stall park
        # (`do_apply_approved_auto_merge/1`), which lifts `max_polls` to
        # `:infinity` without ever touching `park_reason` — `park_reason` stays
        # `nil` there, so this branch doesn't fire and that lift remains
        # unconditional for the rest of the episode.
        #
        # `poll_count` resets alongside the restored cap because it's monotonic
        # across the worker's life — restoring a finite cap without resetting the
        # count would trip the ceiling on the very next poll.
        #
        # Also clear the merge-stall latches (`merge_stall_notified`,
        # `merge_fail_count`, `last_merge_stall_poll`) here. They can be stale
        # from an *earlier* part of the same episode: the coordinator's own
        # response to a stall page can forge-approve the MR, which surfaces a
        # real block (e.g. `:behind_base`) that then clears and hits this
        # branch. Left stale, `last_merge_stall_poll` sits above the reset
        # `poll_count`, so `poll_count - last_merge_stall_poll` in
        # `do_apply_approved_auto_merge/1` goes negative and can never reach the
        # re-notify cadence again — silently disarming the stall park and
        # reproducing the exact incident this whole fix targets (bd-krg7ci
        # round 3). Mirrors what the `:merged` clause already does on success.
        state =
          if state.park_reason != nil and classify(result) == :approved and
               block_reason(result) == nil do
            %{
              state
              | max_polls: state.base_max_polls,
                poll_count: 0,
                last_escalated_poll: 0,
                merge_stall_notified: false,
                merge_fail_count: 0,
                last_merge_stall_poll: 0,
                park_reason: nil
            }
          else
            state
          end

        state = %{
          state
          | last_block_reason: nil,
            auto_resolve_attempts: 0,
            max_auto_resolve_attempts: state.base_max_auto_resolve_attempts,
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
      # Lift max_polls to :infinity (mirrors handle_nonauthor_approval below):
      # the coordinator has now been paged, so this is no longer the silent
      # "should auto-merge quickly or something's broken" case the ordinary
      # ceiling guards against — it's an indefinite park-and-watch for an
      # out-of-band fix (e.g. a manual pipeline retry). Without this, the
      # shared poll_count kept climbing across the auto-resolve attempts and
      # eventually tripped the ordinary ceiling anyway, failing the worker and
      # killing the only process still watching the MR (bd-krg7ci).
      state.auto_resolve_attempts >= state.max_auto_resolve_attempts ->
        state = maybe_escalate_unresolved(state, reason)

        reschedule(%{
          state
          | last_block_reason: reason,
            max_polls: :infinity,
            park_reason: reason
        })

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
      Arbiter.Messages.CoordinatorNotifier.merge_blocked(snapshot(state), state.mr_ref, reason)
    end)

    %{state | last_block_reason: reason}
  end

  # The two mechanically auto-resolvable block reasons (#354, Phase 2a).
  defp auto_resolvable?(:behind_base), do: true
  defp auto_resolvable?(:ci_failed), do: true
  defp auto_resolvable?(_), do: false

  # :behind_base needs the adapter to support `update_branch/1`; :ci_failed is
  # resolved by dispatching a fix-pass worker (adapter-agnostic — the failing
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
          Arbiter.Messages.CoordinatorNotifier.merge_blocked(
            snapshot(state),
            state.mr_ref,
            :conflict
          )
        end)

        reschedule(%{state | last_block_reason: :conflict, auto_resolve_attempts: attempts})
    end
  end

  # :ci_failed — dispatch a fix-pass worker (briefed with the failing check
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
        "Worker.Watchdog: auto-resolving :ci_failed via fix-pass worker for " <>
          "task=#{state.task_id} mr=#{state.mr_ref} (attempt #{attempts}, " <>
          "#{length(checks)} failing check(s))"
      )

      _ = dispatch_fix_pass(state, checks)
      _ = result

      reschedule(%{state | last_block_reason: :ci_failed, auto_resolve_attempts: attempts})
    end
  end

  # True when a fix-pass worker for this task is still working (registered under
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

  # Re-page periodically while parked instead of latching silent forever: once
  # `unresolved_escalated` is set, only skip re-escalating until `poll_count`
  # has advanced `escalation_cadence/1` polls past the last page. This keeps a
  # block that never resolves loudly visible — the indefinite park added by
  # `handle_block/3` must not turn a one-time page into permanent silence
  # (bd-krg7ci).
  defp maybe_escalate_unresolved(%{unresolved_escalated: true} = state, reason) do
    if state.poll_count - state.last_escalated_poll >= escalation_cadence(state) do
      escalate_unresolved_block(state, reason)
      %{state | last_escalated_poll: state.poll_count}
    else
      state
    end
  end

  defp maybe_escalate_unresolved(state, reason) do
    escalate_unresolved_block(state, reason)
    %{state | unresolved_escalated: true, last_escalated_poll: state.poll_count}
  end

  # The cadence (in polls) at which a parked lane re-pages the coordinator
  # (`maybe_escalate_unresolved/2`, `do_apply_approved_auto_merge/1`). Normally
  # the configured ceiling itself, but a lane can have `base_max_polls:
  # :infinity` (`Arbiter.Tasks.Workspace.watchdog_max_polls/1` accepts the
  # string `"infinity"`) — falling back to the ordinary auto_merge default
  # there keeps such a lane from parking indefinitely *and* paging exactly
  # once, which is the same permanent-silence shape this whole fix targets,
  # just reachable via config rather than an auto-resolve exhaustion
  # (bd-krg7ci round 3).
  defp escalation_cadence(%{base_max_polls: n}) when is_integer(n), do: n
  defp escalation_cadence(_state), do: @default_max_polls_auto

  defp escalate_unresolved_block(state, reason) do
    Logger.warning(
      "Worker.Watchdog: auto-resolve exhausted (#{reason}, " <>
        "#{state.auto_resolve_attempts} attempt(s)) for task=#{state.task_id} " <>
        "mr=#{state.mr_ref}; escalating to coordinator"
    )

    safe(fn ->
      Arbiter.Messages.CoordinatorNotifier.merge_block_unresolved(
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
  # isolation but no longer applying cleanly on the moved base — the Watchdog
  # dispatches a short-lived rebase-resolve worker against the task's existing
  # worktree instead of parking and paging a human. The worker rebases,
  # resolves honoring the task intent, runs tests, and force-pushes; the next
  # poll then re-attempts the merge.
  #
  # Bounded: a resolver runs asynchronously and the Watchdog monitors it, so it
  # never spawns a second while one is in flight. After `max_conflict_attempts`
  # passes that don't clear the conflict it escalates once (attempt count +
  # context) and stays parked. A cleared conflict resets the counter so a future
  # conflict starts fresh. This supersedes the manual stop → direction → resume
  # → rebase flow and hardens the one-shot #122 resolver with bounded retries.
  defp maybe_auto_resolve_conflict(%{auto_resolve_conflict: false} = state, _result), do: state

  defp maybe_auto_resolve_conflict(state, result) do
    case effective_block_reason(state, result) do
      :conflict -> drive_conflict_resolution(state)
      _ -> reset_conflict_state(state)
    end
  end

  # A resolver worker is in flight. The resolver is an `Arbiter.Worker`
  # GenServer that does NOT exit when its rebase worker finishes — it lingers
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
          "Worker.Watchdog: dispatched conflict-resolve worker " <>
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
          "Worker.Watchdog: could not dispatch conflict-resolve worker for " <>
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

  # Has the in-flight resolver worker finished its rebase pass? The resolver is
  # an `Arbiter.Worker` that lingers in a terminal status (:completed/:failed)
  # after its worker exits — it is only torn down on task :close — so "finished"
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
  # polls, escalate to the coordinator and either:
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
        "#{cap} polls without a terminal outcome; failing (see the next line for " <>
        "whether it was auto-resumed or escalated)"
    )

    handle_review_timeout(state, cap)
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

  # bd-8eheb6 / #1287. An awaiting_review timeout on an auto_merge lane is a
  # *distinct* failure: exit_status 0, worktree preserved, MR usually mergeable
  # — the run is cleanly resumable, and the coordinator's remedy has always been
  # a plain `worker_resume`. So do it here instead of parking a "failed but
  # resumable" worker that only a `worker_failed` event or the dashboard's
  # active-worker count would ever surface.
  #
  # The worker is failed either way: the run really did time out and
  # worker_show/the event feed must keep saying so (and `Dispatch.resume`
  # requires the prior worker to be in a terminal state before it re-attaches).
  # What changes is what happens next — a bounded auto-resume, or, once that
  # budget is spent, an escalation that names the spent budget explicitly.
  defp handle_review_timeout(state, cap) do
    snap = snapshot(state)
    attempts = awaiting_review_resume_attempts(snap)

    safe(fn -> Worker.fail(state.worker_pid, {:awaiting_review_timeout, cap}) end)

    if attempts < state.max_auto_resumes do
      auto_resume(state, attempts + 1)
    else
      escalate_auto_resume_give_up(state, snap, attempts, :budget_exhausted)
    end
  end

  # One auto-resume round. On success the task is healing, so we deliberately do
  # NOT page the coordinator — that is the whole point. A resume that can't run
  # (typically `:no_outpost`: the worktree was cleaned up, so there is nothing to
  # re-attach to) is not self-healing, so it falls back to the escalation path
  # rather than dropping the task on the floor.
  defp auto_resume(state, attempt) do
    args = %{
      task_id: state.task_id,
      attempt: attempt,
      workspace_id: workspace_id(state),
      mr_ref: state.mr_ref
    }

    case safe_resume(state, args) do
      {:ok, _} ->
        Logger.warning(
          "Worker.Watchdog: task=#{state.task_id} mr=#{state.mr_ref} timed out at " <>
            ":awaiting_review; auto-resumed (attempt #{attempt}/#{state.max_auto_resumes})"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Worker.Watchdog: task=#{state.task_id} mr=#{state.mr_ref} auto-resume " <>
            "attempt #{attempt} failed (#{inspect(reason)}); escalating instead"
        )

        escalate_auto_resume_give_up(
          state,
          snapshot(state),
          attempt - 1,
          {:resume_failed, reason}
        )
    end
  end

  defp safe_resume(state, args) do
    state.auto_resume_dispatcher.resume(args)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Budget spent (or auto-resume off / unable to run): page the coordinator the
  # way this always did, PLUS an addressed mailbox escalation that names the
  # attempt count and why we stopped, so "we already tried resuming N times"
  # doesn't have to be re-derived from `worker_show`.
  defp escalate_auto_resume_give_up(state, snap, attempts, reason) do
    Logger.warning(
      "Worker.Watchdog: task=#{state.task_id} mr=#{state.mr_ref} not auto-resumed " <>
        "(#{inspect(reason)}, #{attempts}/#{state.max_auto_resumes} attempts used); " <>
        "escalating to the coordinator"
    )

    escalate_watchdog(state)

    safe(fn ->
      state.auto_resume_dispatcher.escalate_exhausted(
        state.task_id,
        Map.get(snap, :workspace_id) || workspace_id(state),
        state.mr_ref,
        attempts,
        reason
      )
    end)

    :ok
  end

  # How many times this task has ALREADY been auto-resumed out of an
  # awaiting_review timeout. Carried on the worker's `meta` and re-stamped onto
  # each resumed run by `Arbiter.Worker.Dispatch` (see `maybe_put_resume_meta/2`).
  # No Watchdog survives an auto-resume round — a fresh worker mints a fresh
  # Watchdog — but the counter has to survive all of them, so the worker's meta
  # is where it lives.
  defp awaiting_review_resume_attempts(%{meta: %{} = meta}) do
    case Map.get(meta, :awaiting_review_resume_attempts) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp awaiting_review_resume_attempts(_), do: 0

  # Auto-resume budget. Opt wins; else workspace config
  # (`merge.max_awaiting_review_resumes`); else the module default. 0 is a valid
  # value (auto-resume off), so `>= 0` rather than `> 0`.
  defp resolve_max_auto_resumes(opts, workspace) do
    case Keyword.get(opts, :max_auto_resumes) do
      n when is_integer(n) and n >= 0 -> n
      _ -> max_auto_resumes_from_workspace(workspace)
    end
  end

  defp max_auto_resumes_from_workspace(%Arbiter.Tasks.Workspace{config: %{} = config}) do
    case get_in(config, ["merge", "max_awaiting_review_resumes"]) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_max_auto_resumes
    end
  end

  defp max_auto_resumes_from_workspace(_), do: @default_max_auto_resumes

  defp escalate_watchdog(state) do
    snap =
      case safe_snapshot(state.worker_pid) do
        %{} = s -> s
        _ -> %{task_id: state.task_id, workspace_id: nil}
      end

    safe(fn ->
      Arbiter.Messages.CoordinatorNotifier.awaiting_review_stuck(snap, state.mr_ref)
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

  # Best-effort fetch of the failing-check briefing for the fix-pass worker. An
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
