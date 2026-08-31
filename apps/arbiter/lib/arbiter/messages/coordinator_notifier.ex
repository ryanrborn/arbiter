defmodule Arbiter.Messages.CoordinatorNotifier do
  @moduledoc """
  Auto-posts coordinator notifications on worker (worker) lifecycle events, so
  the coordinator is informed without workers having to send messages by hand.

  Wired into `Arbiter.Worker`'s terminal/await transitions. Each event maps to
  a durable `:notification` `Arbiter.Messages.Message` — the broadcast kind that
  feeds the coordinator's dashboard (`to_ref` nil, never "consumed"):

  | Event                | Body                                                       |
  |----------------------|------------------------------------------------------------|
  | completed            | `<title> completed in <duration>`                          |
  | failed               | `<title> failed after <duration> — exit code <N>`          |
  | awaiting_review      | `<title> opened MR <mr_ref> — awaiting review`             |
  | awaiting_review_stuck| `<title> stuck at awaiting_review (MR <mr_ref>) — escalated` |

  Directive-closed events are intentionally **not** posted — too noisy.

  ## ReviewGate non-convergence is not a crash (bd-3wgdie)

  A `:failed` worker whose `meta[:failure_reason]` is `:review_gate_rejected`
  or `:review_gate_inconclusive` gets distinct wording instead of the generic
  `failed after <duration> — exit code <N>` template: e.g. `<title> escalated
  — ReviewGate did not converge after 2 round(s) — …`. The worker completed
  its work and exited 0 — it lost a review argument, not a crash — and the
  generic template previously read as a dead worker, burying a real
  human-judgement-needed escalation for 66 hours (see the bd-3wgdie
  writeup). ReviewGate also mails an addressed `:escalation` (`to_ref:
  "coordinator"`) with the full transcript via `Arbiter.Worker`'s
  `escalate_review_gate/3` — this broadcast `:notification` is a second,
  lower-friction surface (dashboard feed) carrying the same distinction.

  ## Actionable escalations (`worker_stopped`, `preflight_failed`)

  A dead/stopped worker (token exhaustion, crash, external kill, auth expiry)
  or a failed pre-flight auth probe is not just dashboard noise — it needs the
  operator to *act* (re-authenticate, top up credits, re-dispatch). Those go out as
  addressed `:escalation` **mailbox** messages (`to_ref: "coordinator"`,
  `task_ref: <task>`) so they land in `arb inbox` rather than scrolling off
  the broadcast feed. The classified cause + remediation
  (`Arbiter.Worker.StopReason`) is baked into the subject/body. See bd-awi4nw.

  ## Reconciliation with the task spec

  The originating task (bd-25ftl0) imagined dedicated `:completion` / `:failure`
  kinds and a `to="coordinator"` / `task_ref=task_id` shape. The Message
  resource that actually shipped (bd-bduz2k) settled on a leaner taxonomy:
  broadcast `:notification`s (the coordinator feed) vs. addressed mailbox kinds.
  We honour the realised design — every lifecycle auto-post is a
  `:notification` with `from_ref` set to the directive's task id; the
  completed/failed/awaiting distinction lives in the subject + body.

  ## Configuration

  Gated per-workspace by `workspace.config["coordinator_notifications"]`
  (default `true`). Set it to `false` on high-volume workspaces to silence the
  auto-posts. Workspaces configured before the vernacular rename (bd-2bsahq)
  may still carry the legacy `"admiral_notifications"` key — it is read as a
  fallback when the new key is absent, so existing opt-outs keep working.

  ## Failure handling

  Every entry point is best-effort: a missing workspace, a DB hiccup, or a
  payload bug is swallowed (with a debug breadcrumb) so notification work never
  disrupts the worker lifecycle. Mirrors the contract of
  `Arbiter.Worker.broadcast_lifecycle/2`.
  """

  require Logger

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Worker.StopReason

  @config_key "coordinator_notifications"
  @legacy_config_key "admiral_notifications"

  # How long a merge-block escalation stays "recent enough" to suppress a repeat
  # even after the coordinator has cleared it (bd-brwx7w). The primary dedupe is
  # "an identical page is still uncleared"; this is the second gate, so that a
  # `clear_all` on a block the fleet structurally cannot resolve
  # (`:needs_nonauthor_approval`) does not immediately re-open the once-a-minute
  # flood. Override with `config :arbiter, :merge_block_escalation_cooldown_ms`.
  @default_block_escalation_cooldown_ms :timer.hours(6)

  # The merge-block reasons that mean "a human reviewer has not approved yet".
  # The forge forbids the fleet approving its own PR, so these can only clear
  # out-of-band — they are one dedupe family and the only ones that earn the
  # post-clear cooldown. See `block_family/1` and `fleet_unresolvable?/1`.
  @approval_block_reasons [:needs_approval, :needs_nonauthor_approval]

  @typedoc """
  The subset of an `Arbiter.Worker` snapshot this module reads. Passing the
  full snapshot map is fine — extra keys are ignored.
  """
  @type snapshot :: %{
          required(:task_id) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:repo) => String.t() | nil,
          optional(:started_at) => DateTime.t() | nil,
          optional(:meta) => map() | nil
        }

  @doc "Post the `:completed` lifecycle notification. Best-effort, returns `:ok`."
  @spec completed(snapshot()) :: :ok
  def completed(snapshot), do: post(:completed, snapshot)

  @doc "Post the `:failed` lifecycle notification. Best-effort, returns `:ok`."
  @spec failed(snapshot()) :: :ok
  def failed(snapshot), do: post(:failed, snapshot)

  @doc "Post the `:awaiting_review` lifecycle notification. Best-effort, returns `:ok`."
  @spec awaiting_review(snapshot()) :: :ok
  def awaiting_review(snapshot), do: post(:awaiting_review, snapshot)

  @doc """
  Post a `:pipeline_failed` notification. Best-effort, returns `:ok`. Fired by
  `Arbiter.Worker.Watchdog` when a CI pipeline fails and `watch_pipeline` is
  enabled. The task is NOT failed — a human may force-merge or rerun.
  """
  @spec pipeline_failed(snapshot(), String.t() | nil) :: :ok
  def pipeline_failed(snapshot, mr_ref \\ nil) do
    snapshot =
      case mr_ref do
        nil ->
          snapshot

        ref when is_binary(ref) ->
          meta = Map.put(Map.get(snapshot, :meta, %{}) || %{}, :mr_ref, ref)
          Map.put(snapshot, :meta, meta)
      end

    post(:pipeline_failed, snapshot)
  end

  @doc """
  Post the `:awaiting_review_stuck` watchdog notification. Best-effort, returns
  `:ok`. Fired by `Arbiter.Worker.Watchdog` when a worker has been parked at
  `:awaiting_review` past its poll cap without a terminal MR outcome — so a
  silent hang surfaces to the operator instead of waiting forever (bd-66ey1o).
  """
  @spec awaiting_review_stuck(snapshot(), String.t() | nil) :: :ok
  def awaiting_review_stuck(snapshot, mr_ref \\ nil) do
    snapshot =
      case mr_ref do
        nil ->
          snapshot

        ref when is_binary(ref) ->
          meta = Map.put(Map.get(snapshot, :meta, %{}) || %{}, :mr_ref, ref)
          Map.put(snapshot, :meta, meta)
      end

    post(:awaiting_review_stuck, snapshot)
  end

  @doc """
  Escalate a stopped/dead worker to the coordinator (bd-awi4nw).

  Unlike the lifecycle `:notification`s above, this is an addressed
  `:escalation` **mailbox** message (`to_ref: "coordinator"`) so it surfaces in
  `arb inbox` as an actionable item. The `Arbiter.Worker.StopReason` carries
  the classified cause + remediation; the subject names the task + cause and
  the body spells out the repo, last activity, exit code, and fix. Best-effort,
  returns `:ok`.
  """
  @spec worker_stopped(snapshot(), StopReason.t()) :: :ok
  def worker_stopped(snapshot, %StopReason{} = reason),
    do: escalate(:worker_stopped, snapshot, reason)

  @doc """
  Escalate a failed pre-flight auth probe to the coordinator (bd-awi4nw).

  Fired by `Arbiter.Worker.Dispatch` when the agent CLI fails its cheap
  token-validity probe *before* any worker is dispatched — so a wave of spawns
  that would all 401 is refused up front and the operator is told to
  re-authenticate. Same addressed `:escalation` shape as `worker_stopped/2`.
  Best-effort, returns `:ok`.
  """
  @spec preflight_failed(snapshot(), StopReason.t()) :: :ok
  def preflight_failed(snapshot, %StopReason{} = reason),
    do: escalate(:preflight_failed, snapshot, reason)

  @doc """
  Escalate a post-`start_worker` dispatch failure to the coordinator (bd-bi5pn0).

  Fired by `Arbiter.Worker.Dispatch` when a step AFTER `start_worker/3` fails
  (e.g. a transient network/VPN outage during the agent subprocess spawn, or
  a workflow-machine attach failure) — the worker it just registered `:idle`
  is failed rather than left as a silent zombie registration. Same addressed
  `:escalation` shape as `worker_stopped/2` / `preflight_failed/2`.
  Best-effort, returns `:ok`.
  """
  @spec spawn_failed(snapshot(), StopReason.t()) :: :ok
  def spawn_failed(snapshot, %StopReason{} = reason),
    do: escalate(:spawn_failed, snapshot, reason)

  @doc """
  Escalate a proactively-detected credential expiry to the coordinator (bd-5wchp1).

  Fired by `Arbiter.Agents.CredentialWatchdog` when a periodic liveness probe
  detects that credentials are expired *before* any worker has been dispatched
  or failed. Unlike `worker_stopped/2` and `preflight_failed/2`, this has no
  associated task — it names the adapter that failed instead.

  `snapshot` must contain `:workspace_id`; `adapter` is the module whose probe
  failed. Same addressed `:escalation` shape as the other escalations.
  Best-effort, returns `:ok`.
  """
  @spec credential_expired(%{workspace_id: String.t()}, module(), StopReason.t()) :: :ok
  def credential_expired(%{workspace_id: ws_id} = snapshot, adapter, %StopReason{} = reason)
      when is_binary(ws_id) and is_atom(adapter) do
    snapshot_with_adapter = Map.put(snapshot, :adapter, adapter)
    escalate(:credential_expired, snapshot_with_adapter, reason)
  end

  def credential_expired(_snapshot, _adapter, _reason), do: :ok

  @doc """
  Escalate a failed external-tracker sync to the coordinator (bd-c4cfuv).

  Fired by `Arbiter.Trackers.Sync` / `Arbiter.Tasks.Issue.Changes.SyncTracker`
  when a lifecycle transition (dispatch → In Progress, PR-open → In Code Review,
  merge → Done, …) can't be resolved or fails on the wire. The original
  incident (VR-17911) was invisible precisely because such failures were
  swallowed; this surfaces a `status_map`/workflow mismatch as an actionable
  inbox item instead. Best-effort, returns `:ok`.

  `snapshot` carries `:task_id` + `:workspace_id` (and optionally
  `:tracker_type` / `:tracker_ref`); `event` is the lifecycle atom; `reason` is
  the adapter's error term.
  """
  @spec tracker_sync_failed(map(), atom(), term()) :: :ok
  def tracker_sync_failed(snapshot, event, reason) do
    escalate_event("tracker_sync_failed/3", snapshot, fn task_id ->
      tracker = Map.get(snapshot, :tracker_type)
      ref = Map.get(snapshot, :tracker_ref)

      subject = "#{task_id} tracker sync failed — #{event}"

      body =
        [
          "Failed to sync #{title_for(task_id)} to its external tracker on the " <>
            "`#{event}` lifecycle event.",
          tracker && "Tracker: #{tracker}#{ref && " #{ref}"}",
          "Error: #{describe_reason(reason)}",
          sync_hint(reason)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  @doc """
  Escalate a stalled auto-merge to the coordinator (bd-6gxosc).

  Fired by `Arbiter.Worker.Watchdog` after N consecutive `safe_merge` failures on
  an approved PR — the merge keeps failing (race, transient forge error, unknown
  `mergeable_state`) but the Watchdog keeps retrying silently. After the threshold
  is hit, this surfaces the stall as an actionable `:escalation` mailbox item so
  the coordinator can intervene if needed. The Watchdog continues retrying; it does
  NOT stop. `attempts` is the total consecutive failure count; `reason` is the
  last error from the merger adapter. Best-effort, returns `:ok`.
  """
  @spec auto_merge_stalled(map(), String.t() | nil, non_neg_integer(), term()) :: :ok
  def auto_merge_stalled(snapshot, mr_ref, attempts, reason) do
    escalate_event("auto_merge_stalled/4", snapshot, fn task_id ->
      subject = "#{task_id} auto-merge stalled (#{attempts} consecutive failures)"

      body =
        [
          "#{title_for(task_id)} is approved but auto-merge has failed #{attempts} consecutive time(s).",
          mr_ref && "PR/MR: #{mr_ref}",
          "Last error: #{describe_reason(reason)}",
          "The Watchdog is still retrying — you can wait for it to resolve (e.g. once " <>
            "the forge finishes computing `mergeable_state`) or merge manually. " <>
            "No action is required if the next poll succeeds."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  @doc """
  Escalate a blocked merge to the coordinator (#354, Phase 1).

  Fired by `Arbiter.Worker.Watchdog` when an approved/parked PR can't merge and
  the merger adapter has classified *why* (`:conflict`, `:behind_base`,
  `:ci_failed`, `:needs_approval`, `:needs_nonauthor_approval`, `:draft`,
  `:blocked_other`). Unlike the
  broadcast lifecycle notifications, this is an addressed `:escalation` **mailbox**
  message (`to_ref: "coordinator"`) so it lands in `arb inbox` as an actionable item
  — the whole point of Phase 1 is that a blocked merge never parks silently.

  `snapshot` carries `:task_id` + `:workspace_id`; `mr_ref` is the PR/MR ref (may
  be `nil`); `reason` is the block-reason atom. Best-effort, returns `:ok`.

  ## Deduped and backed off (bd-brwx7w)

  A block reason the fleet cannot resolve on its own — `:needs_nonauthor_approval`
  above all, where the forge forbids the author approving their own PR — is
  re-detected on *every* poll, forever. Each poller used to hold its own
  in-memory latch, so two pollers watching one PR paged the coordinator roughly
  once a minute indefinitely, drowning the mailbox and tripping event-stream
  watchers' rate cutoffs.

  The latch now lives in the message table, which every poller and every restart
  shares. A page is suppressed when an identical escalation for this
  `(workspace, task, reason-family)` is **still uncleared**, or when one was
  raised inside the cooldown window (`@default_block_escalation_cooldown_ms`).
  `:needs_approval` and `:needs_nonauthor_approval` share one family — they are
  two spellings of "waiting on a human reviewer", and alternating between them
  is exactly what defeated the old per-reason latch. A genuinely *different*
  block (a conflict appearing on top of a missing approval) is a different
  family and still pages immediately.
  """
  @spec merge_blocked(map(), String.t() | nil, atom()) :: :ok
  def merge_blocked(snapshot, mr_ref, reason) do
    escalate_event("merge_blocked/3", snapshot, fn task_id ->
      ws_id = snapshot.workspace_id

      if duplicate_block_escalation?(ws_id, task_id, reason) do
        Logger.debug(
          "CoordinatorNotifier.merge_blocked/3 suppressed duplicate escalation " <>
            "task=#{task_id} reason=#{reason} (bd-brwx7w)"
        )

        :skip
      else
        subject = block_subject(task_id, reason)

        body =
          [
            "#{title_for(task_id)} cannot merge: #{block_label(reason)}.",
            mr_ref && "PR/MR: #{mr_ref}",
            "Reason: #{reason}",
            "Remediation: #{block_remediation(reason, auto_merge?(ws_id))}",
            "The Watchdog detected this on its merge poll and parked the PR rather " <>
              "than failing it — resolve the block (or force-merge) and the next " <>
              "poll will pick it up.",
            "This escalation is raised once per block episode — it will not repeat " <>
              "while it is outstanding in the inbox."
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        {subject, body}
      end
    end)
  end

  @doc """
  Escalate a quota-overage spend crossing to the coordinator (bd-7cd38f).

  Fired by `Arbiter.Workflows.DispatchQueue` in `:continue` mode when the
  workspace's windowed overage spend crosses a multiple of its
  `overage_alert_usd` threshold. Same addressed `:escalation` **mailbox** shape
  as `merge_blocked/3` so it lands in `arb inbox` as an actionable item — but
  this is informational: dispatch does NOT stop, the operator decides whether to
  switch back to `:throttle` or top up. Debounced upstream (one per crossing).

  `snapshot` carries `:workspace_id` (and optionally `:task_id`); `spend_usd` is
  the windowed overage spend; `threshold_usd` is the configured alert threshold.
  Best-effort, returns `:ok`.
  """
  @spec overage_alert(map(), number(), number()) :: :ok
  def overage_alert(snapshot, spend_usd, threshold_usd) do
    escalate_event(
      "overage_alert/3",
      snapshot,
      [task_ref: Map.get(snapshot, :task_id)],
      fn _task_id ->
        ws_id = snapshot.workspace_id

        subject =
          "quota overage spend crossed $#{fmt_usd(threshold_usd)} — #{fmt_usd(spend_usd)} so far"

        body =
          [
            "This workspace is dispatching past the Anthropic plan cap in `:continue` " <>
              "mode and has now spent about $#{fmt_usd(spend_usd)} in paid overage this " <>
              "5h window — crossing the $#{fmt_usd(threshold_usd)} alert threshold.",
            "Dispatch has NOT stopped. This is an informational alert (cap + alert, " <>
              "not auto-stop): switch this workspace to `:throttle`, raise " <>
              "`quota.overage_alert_usd`, or let it ride — your call.",
            "Workspace: #{ws_id}"
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        {subject, body}
      end
    )
  end

  defp fmt_usd(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  @doc """
  Escalate a card that Autopilot cannot get out of Ready (bd-a40f4q).

  Fired by `Arbiter.Board.Autopilot` when a promoted card's dispatch keeps
  returning the same error shape. `Arbiter.Worker.Dispatch.resolve_repo_for_dispatch/2`
  can fail with `:ambiguous_repo`, `:no_repo_configured` or `:repo_not_found` —
  none of those self-heal by retrying, so Autopilot escalates the first time
  it sees one. Any other dispatch error gets an Autopilot-owned retry budget
  first, in case it is transient (a quota gate, a network blip); the
  escalation only fires once that budget is exhausted. Same addressed
  `:escalation` **mailbox** shape as the other escalations here.

  Dedupe lives in `Arbiter.Board.Autopilot`'s own process state (an
  `escalated?` latch per card, cleared on the next successful dispatch or when
  the error shape changes) rather than the message table: a card either keeps
  failing the same way, in which case one page is enough, or the error
  changes, in which case a fresh page is exactly right.

  `snapshot` carries `:task_id` + `:workspace_id`; `reason` is the raw
  dispatch error term; `attempts` is the consecutive-failure count. Best-effort,
  returns `:ok`.
  """
  @spec dispatch_stuck(map(), term(), pos_integer()) :: :ok
  def dispatch_stuck(snapshot, reason, attempts) do
    escalate_event("dispatch_stuck/3", snapshot, fn task_id ->
      subject = "#{task_id} dispatch stuck (#{attempts}× #{dispatch_stuck_label(reason)})"

      body =
        [
          "Autopilot has tried to dispatch #{title_for(task_id)} #{attempts} consecutive " <>
            "time(s) and gotten the same error every time: #{dispatch_stuck_label(reason)}.",
          "The card is still in Ready and Autopilot keeps reconsidering it every tick, but " <>
            "it will not succeed on its own: #{dispatch_stuck_action(reason)}",
          "This escalation is raised once per failure episode — it will not repeat while " <>
            "the same error keeps recurring."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  defp dispatch_stuck_label({:ambiguous_repo, repos}) when is_list(repos),
    do: "ambiguous repo — #{Enum.join(repos, ", ")} are all configured"

  defp dispatch_stuck_label(:no_repo_configured), do: "no repo configured for this workspace"

  defp dispatch_stuck_label({:repo_not_found, repo}),
    do: "configured repo #{inspect(repo)} not found"

  defp dispatch_stuck_label(reason), do: describe_reason(reason)

  defp dispatch_stuck_action({:ambiguous_repo, _repos}) do
    "set a default repo for this workspace, or the issue's own repo attribute, and the " <>
      "next tick will dispatch it."
  end

  defp dispatch_stuck_action(:no_repo_configured) do
    "configure at least one repo for this workspace and the next tick will dispatch it."
  end

  defp dispatch_stuck_action({:repo_not_found, _repo}) do
    "fix the workspace's repo config so it resolves and the next tick will dispatch it."
  end

  defp dispatch_stuck_action(_reason) do
    "this may be transient (quota, network) — inspect the error above; if it recurs it " <>
      "likely needs a config or account fix."
  end

  @doc """
  Escalate a blocked merge the Watchdog tried — and failed — to auto-resolve
  (#354, Phase 2a).

  Fired by `Arbiter.Worker.Watchdog` after it has attempted to mechanically
  resolve a `:behind_base` (update-branch) or `:ci_failed` (fix-pass worker)
  block `attempts` times without the PR becoming mergeable. Unlike
  `merge_blocked/3` — which fires immediately for a block the Watchdog does not
  auto-resolve — this names the auto-resolve attempt count so the operator knows
  the autonomous path was tried first. Same addressed `:escalation` **mailbox**
  shape. Best-effort, returns `:ok`.
  """
  @spec merge_block_unresolved(map(), String.t() | nil, atom(), non_neg_integer()) :: :ok
  def merge_block_unresolved(snapshot, mr_ref, reason, attempts) do
    escalate_event("merge_block_unresolved/4", snapshot, fn task_id ->
      ws_id = snapshot.workspace_id

      subject = "#{task_id} auto-resolve exhausted (#{attempts}×) — #{block_label(reason)}"

      body =
        [
          "#{title_for(task_id)} still cannot merge after #{attempts} auto-resolve " <>
            "attempt(s): #{block_label(reason)}.",
          mr_ref && "PR/MR: #{mr_ref}",
          "Reason: #{reason}",
          "Auto-resolve attempts: #{attempts}",
          "Remediation: #{block_remediation(reason, auto_merge?(ws_id))}",
          "The Watchdog auto-resolved this block #{attempts} time(s) without success " <>
            "and has stopped retrying. Resolve it manually (or force-merge) and the " <>
            "next poll will pick it up."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  @doc """
  Escalate an approved-but-parked PR awaiting a manual merge (bd-b4pwxa).

  Fired by `Arbiter.Worker.Watchdog` when a PR is approved and mergeable (no
  outstanding block) on a lane where `merge.auto_merge` is `false`. auto_merge
  off is a legitimate "ask a human before merging" policy — but the Watchdog used
  to honour it *silently*: it parked the PR and polled forever without ever
  telling the coordinator the PR was ready. Approved-and-done work could sit
  indefinitely with nothing in the inbox (the whole incident this addresses).

  This surfaces the ready-to-merge PR as an addressed `:escalation` **mailbox**
  message (`to_ref: "coordinator"`) — the same shape as `merge_blocked/3` — so it
  lands in `arb inbox` as an actionable item the moment the review passes. A
  block (`merge_blocked/3`) is escalated separately; this fires only when nothing
  is blocking the merge and it is purely awaiting the human decision.

  `snapshot` carries `:task_id` + `:workspace_id`; `mr_ref` is the PR/MR ref (may
  be `nil`); `via_review_gate` names the approval source in the body. Best-effort,
  returns `:ok`.
  """
  @spec approved_awaiting_merge(map(), String.t() | nil, boolean()) :: :ok
  def approved_awaiting_merge(snapshot, mr_ref, via_review_gate) do
    escalate_event("approved_awaiting_merge/3", snapshot, fn task_id ->
      subject = "#{task_id} approved — awaiting manual merge (auto_merge off)"

      approval_line =
        if via_review_gate do
          "The ReviewGate approved this PR in-process and no merge block remains."
        else
          "This PR is approved and no merge block remains."
        end

      body =
        [
          "#{title_for(task_id)} is approved and ready to merge, but this workspace " <>
            "has `merge.auto_merge` disabled — so the fleet will not merge it " <>
            "automatically and it is parked awaiting a human decision.",
          mr_ref && "PR/MR: #{mr_ref}",
          approval_line,
          "Merge it now (or set `merge.auto_merge` to true for this workspace) and " <>
            "the Watchdog will complete the task on its next poll. Until then the PR " <>
            "stays open and the Watchdog keeps watching — no work is lost."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  defp block_subject(task_id, reason), do: "#{task_id} merge blocked — #{block_label(reason)}"

  # The dedupe key (bd-brwx7w). Reasons in one family describe the same
  # real-world block under different names, so they must not page separately:
  #
  #   * `:needs_approval` — the generic "a required approval is missing" path.
  #   * `:needs_nonauthor_approval` — the same PR seen by the Watchdog's
  #     non-author path, which knows the fleet authored it.
  #
  # Two pollers alternating between these two atoms is precisely what produced
  # the ~1/min flood: each poller's per-reason latch reset on every flip.
  defp block_family(reason) when reason in @approval_block_reasons,
    do: @approval_block_reasons

  defp block_family(reason), do: [reason]

  # Blocks the fleet structurally cannot clear by retrying: the forge forbids a
  # PR's author approving it, so no amount of polling changes the answer. These
  # are the ones that earn the post-clear cooldown below. Every other reason
  # (`:conflict`, `:ci_failed`, `:behind_base`, …) *can* resolve and then
  # genuinely recur, so once the coordinator has cleared its page, a fresh
  # occurrence is fresh news and pages again immediately.
  defp fleet_unresolvable?(reason), do: reason in @approval_block_reasons

  # True when an identical page for this workspace/task/reason-family is still
  # uncleared, or — for a block the fleet cannot resolve — was raised inside the
  # cooldown window. Both checks read the durable message table, so they hold
  # across pollers *and* across restarts, which is what kills the stale
  # duplicates that used to survive a server restart.
  #
  # Fails open: an unreadable mailbox must never swallow a genuine escalation.
  defp duplicate_block_escalation?(ws_id, task_id, reason) do
    subjects = Enum.map(block_family(reason), &block_subject(task_id, &1))
    scope = [workspace_id: ws_id, task_ref: task_id]
    coordinator = Message.coordinator_ref()

    cond do
      Message.last_with_subject(coordinator, subjects, scope ++ [uncleared: true]) != nil ->
        true

      not fleet_unresolvable?(reason) ->
        false

      true ->
        case Message.last_with_subject(coordinator, subjects, scope) do
          nil -> false
          last -> within_cooldown?(last)
        end
    end
  rescue
    _ -> false
  end

  defp within_cooldown?(%{inserted_at: %DateTime{} = at}) do
    cooldown =
      Application.get_env(
        :arbiter,
        :merge_block_escalation_cooldown_ms,
        @default_block_escalation_cooldown_ms
      )

    is_integer(cooldown) and cooldown > 0 and
      DateTime.diff(DateTime.utc_now(), at, :millisecond) < cooldown
  end

  defp within_cooldown?(_), do: false

  # Whether this workspace merges an approved PR itself. Defaults to `false` on
  # an unreadable workspace, matching `Workspace.auto_merge?/1`'s own default:
  # promising an auto-merge that never comes is the failure this guards against.
  defp auto_merge?(ws_id) when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, workspace} -> Workspace.auto_merge?(workspace)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp auto_merge?(_), do: false

  defp block_label(:conflict), do: "merge conflict with the base branch"
  defp block_label(:behind_base), do: "branch is behind the base branch"
  defp block_label(:ci_failed), do: "required CI checks are failing"
  defp block_label(:needs_approval), do: "required approval is missing"

  defp block_label(:needs_nonauthor_approval),
    do:
      "a required approval from a reviewer other than the author (the fleet cannot self-approve)"

  defp block_label(:draft), do: "the PR is still a draft"
  defp block_label(:blocked_other), do: "a forge merge rule is unsatisfied"
  defp block_label(other), do: "merge is blocked (#{other})"

  defp block_remediation(reason, auto_merge?)

  defp block_remediation(:conflict, _auto_merge?),
    do: "rebase or resolve the conflicts with the base branch, then re-push."

  defp block_remediation(:behind_base, _auto_merge?),
    do: "update the branch from its base (merge or rebase) and re-push."

  defp block_remediation(:ci_failed, _auto_merge?),
    do: "fix the failing checks (or re-run flaky ones), then re-push."

  defp block_remediation(:needs_approval, auto_merge?),
    do:
      "approve the PR, or re-request review if a prior approval was dismissed. " <>
        after_approval_note(auto_merge?)

  # bd-brwx7w: this used to promise "will auto-merge once approved"
  # unconditionally, which is a lie on a `merge.auto_merge: false` workspace —
  # an operator who approves and walks away leaves the PR sitting open forever,
  # and the *same* mailbox already carried an `approved_awaiting_merge/3` page
  # saying the opposite about the same PR.
  defp block_remediation(:needs_nonauthor_approval, auto_merge?),
    do:
      "have a human reviewer (someone other than the PR author) approve the PR — " <>
        "the fleet authored it and the forge forbids self-approval. " <>
        after_approval_note(auto_merge?)

  defp block_remediation(:draft, _auto_merge?), do: "mark the PR ready for review."

  defp block_remediation(:blocked_other, _auto_merge?),
    do: "inspect the PR's merge requirements on the forge and satisfy them."

  defp block_remediation(_other, _auto_merge?), do: "inspect the PR on the forge."

  # What actually happens once the approval lands — conditional on the
  # workspace's merge policy rather than asserted.
  defp after_approval_note(true),
    do:
      "The PR is parked and will auto-merge once approved; no further action is " <>
        "needed to keep it alive."

  defp after_approval_note(false),
    do:
      "The PR is parked, but this workspace has `merge.auto_merge` disabled — so " <>
        "the fleet will not merge it automatically. Merge it yourself once it is " <>
        "approved (or set `merge.auto_merge` to true for this workspace); the " <>
        "Watchdog keeps watching until then, so nothing is lost."

  defp describe_reason(%{message: msg, kind: kind}) when is_binary(msg),
    do: "#{msg} (#{kind})"

  defp describe_reason(reason) when is_binary(reason), do: reason
  defp describe_reason(reason), do: inspect(reason)

  defp format_elapsed_seconds(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)}s"

  # A required tracker field had no produced value on the task — name the
  # specific field(s) rather than the generic status_map hint, which would
  # send the operator down the wrong path (this is a missing-value problem, not
  # a config-mismatch one).
  defp sync_hint(%{kind: :gated_fields_missing, missing_fields: names})
       when is_list(names) and names != [] do
    "The task has not produced a value for required tracker field(s): " <>
      "#{Enum.join(names, ", ")}. Populate them on the task " <>
      "(e.g. `arb issue update <id> --qa-notes ... --deployment-notes ...`) and re-run the sync."
  end

  # Provider explicitly rejected the payload (field-validation gate, required
  # fields not populated, etc.). The provider's real reason is already in the
  # "Error:" line — no secondary hint needed; the status_map hint would be
  # actively misleading here.
  defp sync_hint(%{kind: :validation_failed}), do: nil

  # Auth / permission failures — config-mismatch hint is wrong; name the
  # actual remediation so the operator goes to the right place.
  defp sync_hint(%{kind: :unauthenticated}) do
    "The tracker rejected the credentials — re-authenticate and update the workspace token."
  end

  defp sync_hint(%{kind: :forbidden}) do
    "The tracker rejected the request as forbidden — verify that the API token " <>
      "has the necessary permissions/scopes for this project and operation."
  end

  # A rate-limited sync already retried with backoff (see
  # `Arbiter.Trackers.Sync.do_transition/3`) before reaching escalation — say
  # how many attempts and over what window, so the reader can tell "we tried
  # and the tracker kept refusing" from "we gave up instantly". No config hint:
  # this is transient load (often GitHub's secondary/burst limit, which fires
  # even with primary quota untouched), not a config mismatch.
  defp sync_hint(%{kind: :rate_limited, retry_attempts: attempts, retry_elapsed_ms: elapsed_ms})
       when is_integer(attempts) and is_integer(elapsed_ms) do
    "Retried #{attempts} time(s) over #{format_elapsed_seconds(elapsed_ms)} honoring the " <>
      "tracker's Retry-After/backoff, but the rate limit never cleared. This is very likely " <>
      "transient load (e.g. concurrent workers tripping GitHub's secondary/burst limit) — " <>
      "no action is typically needed unless this recurs."
  end

  defp sync_hint(%{kind: :rate_limited}) do
    "The tracker's rate limit did not clear — this is likely transient load; retry the sync."
  end

  # Transient failures — no config change indicated.
  defp sync_hint(%{kind: :server_error}) do
    "The tracker returned a server error — this is likely transient. " <>
      "Retry the sync or check the tracker's status page."
  end

  defp sync_hint(%{kind: :network}) do
    "A network error occurred reaching the tracker — check connectivity and retry."
  end

  # Genuine config-mismatch: the adapter found the target status in status_map
  # but BFS could not find any path through the configured transition_graph.
  defp sync_hint(%{kind: :no_transition_path}) do
    "No path exists through the configured `transition_graph` to the target status. " <>
      "Reconcile the workspace `status_map` / `transition_graph` with the tracker's " <>
      "actual workflow (see Arbiter.Trackers.Jira.Config) and re-run the sync."
  end

  # Catch-all for any other unexpected error: demote the config hint to a
  # secondary suggestion rather than the primary explanation.
  defp sync_hint(_reason) do
    "If this persists unexpectedly, also check that the workspace `status_map` / " <>
      "`transition_graph` matches the tracker's real workflow " <>
      "(see Arbiter.Trackers.Jira.Config)."
  end

  # ---- core ---------------------------------------------------------------

  # A notification must be scoped to a workspace (Message.workspace_id is
  # required), so a worker with no workspace_id has nowhere to post.
  defp post(event, %{workspace_id: ws_id} = snapshot) when is_binary(ws_id) do
    if enabled?(ws_id) do
      Message.notify(build(event, snapshot))
    end

    :ok
  rescue
    e ->
      Logger.debug("CoordinatorNotifier.post/2 swallowed: #{Exception.message(e)}")
      :ok
  end

  defp post(_event, _snapshot), do: :ok

  # Actionable escalations are addressed mailbox messages (not broadcast
  # notifications) so they queue in `arb inbox` for the coordinator. They are NOT
  # gated by the `coordinator_notifications` toggle — silencing routine completion
  # noise must never silence a "your credentials expired" alarm. A worker with
  # no workspace_id has nowhere to post (Message.workspace_id is required).
  defp escalate(event, %{workspace_id: ws_id} = snapshot, %StopReason{} = reason)
       when is_binary(ws_id) do
    {subject, body} = escalation_payload(event, snapshot, reason)

    Message.send_mail(%{
      kind: :escalation,
      to_ref: Message.coordinator_ref(),
      from_ref: Map.get(snapshot, :task_id, "system"),
      workspace_id: ws_id,
      task_ref: Map.get(snapshot, :task_id),
      subject: subject,
      body: body
    })

    :ok
  rescue
    e ->
      Logger.debug("CoordinatorNotifier.escalate/3 swallowed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp escalate(_event, _snapshot, _reason), do: :ok

  # Shared plumbing for the direct-`Message.send_mail`-style escalations above
  # (`tracker_sync_failed/3` .. `approved_awaiting_merge/3`): guard on a binary
  # `workspace_id`, resolve `task_id`, hand both to `build_fun`, and post the
  # `{subject, body}` it returns as the standard `:escalation` envelope —
  # swallowing any failure so a notification bug never disrupts the caller's
  # real work. `build_fun` may return `:skip` instead of `{subject, body}` to
  # suppress sending without erroring (used by `merge_blocked/3`'s dedupe).
  # `opts[:task_ref]` overrides the default `task_ref: task_id` — needed by
  # `overage_alert/3`, whose `task_ref` is the raw (possibly-nil) snapshot
  # `:task_id` rather than the "system"-defaulted one used for `subject`/`body`.
  defp escalate_event(label, snapshot, build_fun),
    do: escalate_event(label, snapshot, [], build_fun)

  defp escalate_event(label, %{workspace_id: ws_id} = snapshot, opts, build_fun)
       when is_binary(ws_id) do
    task_id = Map.get(snapshot, :task_id, "system")

    case build_fun.(task_id) do
      :skip ->
        :ok

      {subject, body} ->
        Message.send_mail(%{
          kind: :escalation,
          to_ref: Message.coordinator_ref(),
          from_ref: task_id,
          workspace_id: ws_id,
          task_ref: Keyword.get(opts, :task_ref, task_id),
          subject: subject,
          body: body
        })

        :ok
    end
  rescue
    e ->
      Logger.debug("CoordinatorNotifier.#{label} swallowed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp escalate_event(_label, _snapshot, _opts, _build_fun), do: :ok

  defp escalation_payload(:credential_expired, snapshot, %StopReason{} = reason) do
    adapter = Map.get(snapshot, :adapter)
    adapter_label = if adapter, do: inspect(adapter), else: "agent"
    short_name = if adapter, do: adapter |> Module.split() |> List.last(), else: "Agent"

    subject = "#{short_name} credentials expired — proactive detection"

    body =
      [
        "Proactive credential probe: #{adapter_label} failed authentication.",
        reason.summary,
        reason.remediation && "Remediation: #{reason.remediation}",
        "Note: new worker dispatches for this adapter are suspended until credentials are restored."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {subject, body}
  end

  # bd-8lq2g7: a *subordinate* pass (merge-queue CI fix pass / conflict
  # resolver) runs under the task's own id but its own registry key, alongside
  # the task's primary worker parked at `:awaiting_review`. Its death is not the
  # task's worker dying, and the generic payload below said it was — subject
  # `"<task_id> stopped — exited without completing (exit 0)"` with the
  # remediation "run `arb worker resume <task_id>`". That hint is both wrong and
  # unfollowable: `resume` is refused while the primary is parked, so the
  # operator stops the healthy primary and the whole ReviewGate re-runs from
  # round 1. Attribute the stop to the pass that actually stopped instead.
  defp escalation_payload(:worker_stopped, %{task_id: task_id} = snapshot, %StopReason{} = reason) do
    case Arbiter.Worker.subordinate_label(snapshot) do
      nil ->
        primary_escalation_payload(:worker_stopped, snapshot, reason)

      label ->
        registry_key = Map.get(snapshot, :registry_key) || task_id
        subject = "#{task_id} #{label} stopped — #{StopReason.label(reason)}"

        body =
          [
            "The #{label} for #{title_for(task_id)} stopped: #{reason.summary}.",
            "Task: #{task_id}",
            "Worker: #{registry_key} (subordinate #{label} — NOT the task's own worker)",
            "Repo: #{repo(snapshot)}",
            exit_line(reason),
            activity_line(snapshot),
            subordinate_remediation(reason),
            "The task's own worker is unaffected — it is still parked awaiting its " <>
              "merge/review and must be left alone. Do NOT run `arb worker stop`/" <>
              "`arb worker resume` on #{task_id}: that kills the healthy worker and " <>
              "re-runs the review gate from scratch. #{retry_hint(label, task_id, registry_key)}"
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        {subject, body}
    end
  end

  defp escalation_payload(event, snapshot, %StopReason{} = reason),
    do: primary_escalation_payload(event, snapshot, reason)

  # Categories whose remediation is nothing but "re-dispatch (the task)" —
  # `:exited_without_done` ("Review the transcript, then re-dispatch"),
  # `:stalled` ("stop and re-dispatch the task"), `:crashed` ("check stderr,
  # then re-dispatch"). For a subordinate that verb points at the TASK, which is
  # the exact harm this payload exists to prevent, and the merge queue already
  # owns the pass's own retry — so those lines are dropped.
  @task_redispatch_only [:exited_without_done, :stalled, :crashed]

  # Every other category's remediation is about the environment, the account, or
  # the harness (re-authenticate, wait for the quota window, top up credits, use
  # a 1M-context model, pin the agent CLI) and applies no matter who re-runs the
  # pass. Dropping those wholesale left the coordinator with an escalation that
  # said only "the queue retries automatically" — i.e. retry straight back into
  # the same expired credential. Carry them, pass-scoped so the label can't be
  # read as an instruction to re-dispatch the task (bd-8lq2g7).
  defp subordinate_remediation(%StopReason{category: category})
       when category in @task_redispatch_only,
       do: nil

  defp subordinate_remediation(%StopReason{remediation: nil}), do: nil

  defp subordinate_remediation(%StopReason{remediation: remediation}),
    do: "Remediation (for the pass, not the task): #{remediation}"

  # The merge queue owns re-dispatch for both subordinate passes: the Watchdog
  # re-dispatches a fix pass on its next poll once this worker is terminal
  # (`fix_pass_active?/1` treats :failed as not active), and the queue re-runs
  # conflict resolution on its next tick. That re-dispatch goes through
  # `Worker.start_or_reap_terminal/1`, which reaps this now-terminal worker so
  # it can't squat the subordinate registry key and no-op every retry — without
  # that, the promise below would be a lie and the task would park forever
  # (bd-8lq2g7). The manual fallback names the SUBORDINATE key, the only
  # intervention that is safe here: `arb worker stop` takes a registry key
  # verbatim, so it reaches the pass without touching the task's own worker.
  defp retry_hint("fix pass", task_id, registry_key),
    do:
      "The merge queue re-dispatches the fix pass automatically on its next poll " <>
        "(this terminal pass is reaped when it does); inspect the run with " <>
        "`arb worker runs #{task_id}`, and if the pass itself is wedged stop it by " <>
        "its own key — `arb worker stop #{registry_key}` — never by the task id."

  defp retry_hint(_label, task_id, registry_key),
    do:
      "The merge queue owns the retry; inspect the run with `arb worker runs #{task_id}`, " <>
        "and if the pass itself is wedged stop it by its own key — " <>
        "`arb worker stop #{registry_key}` — never by the task id."

  defp primary_escalation_payload(event, %{task_id: task_id} = snapshot, %StopReason{} = reason) do
    verb =
      case event do
        :worker_stopped -> "stopped"
        :preflight_failed -> "pre-flight auth failed"
        :spawn_failed -> "spawn failed"
      end

    subject = "#{task_id} #{verb} — #{StopReason.label(reason)}"

    lead =
      case event do
        :worker_stopped ->
          "Worker for #{title_for(task_id)} stopped: #{reason.summary}."

        :preflight_failed ->
          "Refused to dispatch #{title_for(task_id)} — agent pre-flight auth probe failed: " <>
            "#{reason.summary}."

        :spawn_failed ->
          "Worker for #{title_for(task_id)} failed to spawn: #{reason.summary}."
      end

    body =
      [
        lead,
        "Task: #{task_id}",
        "Repo: #{repo(snapshot)}",
        exit_line(reason),
        activity_line(snapshot),
        reason.remediation && "Remediation: #{reason.remediation}",
        resume_hint(event, task_id)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {subject, body}
  end

  # bd-auma3z: a stopped worker's worktree (committed/uncommitted
  # progress) is preserved, so the operator can continue rather than re-dispatching
  # from scratch. Offer the resume verb right in the escalation. Only for
  # `:worker_stopped` — a `:preflight_failed` refusal happens before any work,
  # so there is no worktree to resume.
  defp resume_hint(:worker_stopped, task_id),
    do: "Resume: run `arb worker resume #{task_id}` to continue from the preserved worktree."

  # bd-bi5pn0: a spawn failure happens before the agent ever ran, so there is
  # no prior session/worktree progress to resume from — a plain re-dispatch
  # (not `resume`) is the correct retry.
  defp resume_hint(:spawn_failed, task_id),
    do: "Re-dispatch: run `arb dispatch #{task_id}` to retry."

  defp resume_hint(_event, _task_id), do: nil

  defp repo(%{repo: repo}) when is_binary(repo) and repo != "", do: repo
  defp repo(_), do: "unknown"

  defp exit_line(%StopReason{exit_status: nil, signal: nil}), do: nil
  defp exit_line(%StopReason{exit_status: nil}), do: nil

  defp exit_line(%StopReason{exit_status: code, signal: nil}),
    do: "Exit code: #{code}"

  defp exit_line(%StopReason{exit_status: code, signal: sig}),
    do: "Exit code: #{code} (signal #{sig})"

  defp activity_line(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :activity) do
      %{label: label} when is_binary(label) -> "Last activity: #{label}"
      label when is_binary(label) and label != "" -> "Last activity: #{label}"
      _ -> nil
    end
  end

  defp activity_line(_), do: nil

  # ---- payload construction ----------------------------------------------

  defp build(:completed, %{task_id: task_id} = snapshot) do
    base(task_id, snapshot, "completed", fn title ->
      "#{title} completed in #{format_duration(elapsed_seconds(snapshot))}"
    end)
  end

  defp build(:failed, %{task_id: task_id} = snapshot) do
    case review_gate_reason(snapshot) do
      nil ->
        duration = format_duration(elapsed_seconds(snapshot))

        base(task_id, snapshot, "failed", fn title ->
          case exit_code(snapshot) do
            nil -> "#{title} failed after #{duration}"
            code -> "#{title} failed after #{duration} — exit code #{code}"
          end
        end)

      reason ->
        base(task_id, snapshot, "escalated — #{review_gate_label(reason)}", fn title ->
          "#{title} escalated — #{review_gate_sentence(reason, snapshot)}"
        end)
    end
  end

  defp build(:awaiting_review, %{task_id: task_id} = snapshot) do
    base(task_id, snapshot, "awaiting review", fn title ->
      case mr_ref(snapshot) do
        nil -> "#{title} — awaiting review"
        ref -> "#{title} opened MR #{ref} — awaiting review"
      end
    end)
  end

  defp build(:pipeline_failed, %{task_id: task_id} = snapshot) do
    base(task_id, snapshot, "CI pipeline failed", fn title ->
      case mr_ref(snapshot) do
        nil ->
          "#{title} — CI pipeline failed (parked; human action required)"

        ref ->
          "#{title} MR #{ref} — CI pipeline failed (parked; human action required)"
      end
    end)
  end

  defp build(:awaiting_review_stuck, %{task_id: task_id} = snapshot) do
    base(task_id, snapshot, "stuck awaiting review", fn title ->
      case mr_ref(snapshot) do
        nil ->
          "#{title} stuck at awaiting_review — escalated (no terminal MR outcome)"

        ref ->
          "#{title} stuck at awaiting_review (MR #{ref}) — escalated (no terminal MR outcome)"
      end
    end)
  end

  defp base(task_id, snapshot, subject_suffix, body_fun) do
    title = title_for(task_id)

    %{
      workspace_id: snapshot.workspace_id,
      from_ref: task_id,
      subject: "#{task_id} #{subject_suffix}",
      body: body_fun.(title)
    }
  end

  # ---- lookups ------------------------------------------------------------

  # The task's human-readable title, falling back to the task id when the Issue
  # row can't be read (e.g. ad-hoc runs, or a workspace with no tracker row).
  defp title_for(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %{title: title}} when is_binary(title) and title != "" -> title
      _ -> task_id
    end
  rescue
    _ -> task_id
  end

  # Default-on: only an explicit `false` disables auto-posts. A missing or
  # unreadable workspace falls back to enabled. The new key wins when both are
  # set; the legacy key is consulted only when the new key is absent, so
  # workspaces configured before the bd-2bsahq rename keep their opt-out.
  defp enabled?(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %{config: config}} ->
        config = config || %{}
        legacy_default = Map.get(config, @legacy_config_key, true)
        Map.get(config, @config_key, legacy_default) != false

      _ ->
        true
    end
  rescue
    _ -> true
  end

  defp exit_code(%{meta: meta}) when is_map(meta), do: Map.get(meta, :exit_status)
  defp exit_code(_), do: nil

  # bd-3wgdie: a worker parked by ReviewGate (non-convergence or an
  # unparseable verdict) completed its work and exited cleanly — it lost a
  # review argument, it did not crash. `:failed` + `exit code 0` reads as a
  # dead worker and buries the fact that a human decision is needed. Detect
  # the two review-gate `failure_reason`s here so `build/2` can give them
  # distinct, honest wording instead of the generic crash template.
  defp review_gate_reason(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :failure_reason) do
      :review_gate_rejected -> :rejected
      :review_gate_inconclusive -> :inconclusive
      _ -> nil
    end
  end

  defp review_gate_reason(_), do: nil

  defp review_gate_label(:rejected), do: "ReviewGate did not converge"
  defp review_gate_label(:inconclusive), do: "ReviewGate inconclusive"

  defp review_gate_sentence(:rejected, snapshot) do
    "ReviewGate did not converge#{rounds_suffix(snapshot)} — the implementer and reviewer " <>
      "did not reach agreement and it needs your judgement (see review_gate_rounds_list or " <>
      "your inbox escalation for the full argument)."
  end

  defp review_gate_sentence(:inconclusive, snapshot) do
    "ReviewGate produced no parseable verdict#{rounds_suffix(snapshot)} and needs your " <>
      "judgement (see your inbox escalation for details)."
  end

  defp rounds_suffix(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :review_gate_rounds) do
      n when is_integer(n) -> " after #{n} round(s)"
      _ -> ""
    end
  end

  defp rounds_suffix(_), do: ""

  defp mr_ref(%{meta: meta}) when is_map(meta),
    do: Map.get(meta, :mr_ref) || Map.get(meta, :mr_url)

  defp mr_ref(_), do: nil

  # ---- formatting ---------------------------------------------------------

  defp elapsed_seconds(%{started_at: %DateTime{} = started_at}),
    do: max(DateTime.diff(DateTime.utc_now(), started_at), 0)

  defp elapsed_seconds(_), do: 0

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)

    case rem(seconds, 60) do
      0 -> "#{minutes}m"
      rest -> "#{minutes}m #{rest}s"
    end
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)

    case div(rem(seconds, 3600), 60) do
      0 -> "#{hours}h"
      minutes -> "#{hours}h #{minutes}m"
    end
  end
end
