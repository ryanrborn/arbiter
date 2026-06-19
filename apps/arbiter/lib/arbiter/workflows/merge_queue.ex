defmodule Arbiter.Workflows.MergeQueue do
  @moduledoc """
  Per-workspace merge-queue GenServer. Picks up "polecat done" events,
  opens MRs/PRs (or merges directly per workspace config), polls them for
  approval + CI, merges with the configured strategy, and transitions
  beads to `:closed` when the merge lands.

  ## Lifecycle

      start_link(workspace_id: ws.id)
        │
        ▼
      subscribes to PubSub topic "polecat:done:" <> workspace_id
        │
        ▼
      receives {:polecat_done, bead_id}
        │
        ▼
      loads bead → resolves merge adapter → opens MR (or skips for :direct)
        │
        ▼
      tick/0 (every poll_interval_ms) → polls in-flight MRs → merges → closes bead

  ## State machine (per in-flight item)

  The status is an explicit atom enum, not a polymorphic struct or behaviour:

      :opening
        │   adapter.open succeeded
        ▼
      :awaiting_approval
        │   approved == true
        ▼
      :ci_running
        │   ci_clean == true
        ▼
      :ready_to_merge
        │   adapter.merge accepted
        ▼
      :merging
        │   merge confirmed
        ▼
      :done   →   bead transitioned to :closed, item removed

  Errors anywhere set status to `:failed` and stop further polling on that
  item; the bead is NOT closed on failure. The reviewer can drive recovery
  manually.

  ## Auto-resolved merge conflicts (bd-dolcqq)

  When `adapter.get` reports `conflicting: true` we used to
  freeze the item and wait for a human rebase — twice in one morning that
  meant an Admiral page on parallel dispatcher-bead waves. Now the MergeQueue
  side-steps that:

      :awaiting_approval (or any non-terminal status)
        │   adapter.get reports conflicting: true
        ▼
      :conflict_resolving — spawn `Arbiter.Workflows.MergeQueue.ConflictResolver`
                            (a swappable behaviour, defaults to a Polecat +
                            ClaudeSession running rebase + force-push)
        │   worker pushes resolved branch
        ▼
      (next tick observes conflicting: false; restore_after_resolution/2
       returns the item to its prior status, posts a :notification so the
       Admiral feed sees the auto-rebase succeeded, and the queue resumes)

  Each conflict gets **exactly one** resolver attempt. The resolver is a
  *mechanical* rebase; if a single pass + force-push doesn't unblock the
  MR (the next tick still sees `conflicting: true`), the conflict is almost
  certainly semantic and the MergeQueue posts an `:escalation` mail (via
  `Arbiter.Workflows.MergeQueue.ConflictResolver.escalate_unresolved/4`)
  and parks the item `:failed`. Spawn failures (no rig configured,
  worktree creation failed, workspace gone, resolver already running)
  take the same escalation path. Better a loud escalation than a silent
  stall.

  The resolver module is injected via `:conflict_resolver` (start_link opt)
  → `:arbiter, :merge_queue_conflict_resolver` (application env) → the default
  real implementation. Tests pass a stub so they don't spawn real workers.

  ## Auto-revise on requested changes (bd-95lsjb)

  When `adapter.get` reports a CHANGES_REQUESTED review (the latest verdict
  per reviewer) newer than the last one the queue handled, the MergeQueue
  dispatches a single revise pass on the **existing worktree** instead of
  idling at `:awaiting_approval`:

      :awaiting_approval
        │   adapter.get reports changes_requested: true with a new
        │   latest_review_id (not yet debounced)
        ▼
      :changes_requested — fetch the full feedback
                           (`adapter.list_review_feedback/1`), post a brief
                           acknowledging comment, then spawn
                           `Arbiter.Workflows.MergeQueue.ReviseDispatcher` (the
                           `arb resume` path: a fresh worker on the bead's
                           preserved worktree + `pr_ref`, briefed with the
                           reviewer feedback). It commits + pushes to the SAME
                           branch — no new PR (pairs with bd-53xrmi).
        │   next tick
        ▼
      :awaiting_approval (re-review) — the review id is recorded in
                           `last_handled_review_id`, so the same
                           CHANGES_REQUESTED (still in the PR's review history)
                           is not actioned twice. A later APPROVE supersedes it
                           (latest-verdict-per-reviewer) and advances to merge
                           as today.

  Each distinct CHANGES_REQUESTED review gets **exactly one** revise pass. A
  dispatch failure parks the item `:failed` (no retry loop). The `Direct`
  merger no-ops (no forge review surface), so direct-strategy beads are
  unaffected. The dispatcher module is injected via `:revise_dispatcher`
  (start_link opt) → `:arbiter, :merge_queue_revise_dispatcher` (application env)
  → the default real implementation; tests pass a stub.

  ## Merge adapter

  The merge adapter is resolved from `workspace.config["merge"]["strategy"]`
  via `Arbiter.Mergers.for_workspace/1`. Valid values:

    * `"github"` — `Arbiter.Mergers.Github` adapter (PR-based)
    * `"gitlab"` — `Arbiter.Mergers.Gitlab` adapter (MR-based)
    * `"direct"` — `Arbiter.Mergers.Direct` adapter. **Never opens a
      MR/PR**. The bead is immediately transitioned to `:done` (and then
      `:closed`). This is the "personal project" path; the polecat is
      assumed to have already pushed + merged its branch out-of-band.

  ## PubSub topic

  Subscribes to `"polecat:done:" <> workspace_id`. Per-workspace because
  each MergeQueue process runs against exactly one workspace and shouldn't
  see other workspaces' events. The polecat (or the orchestrator that
  drives it) is responsible for broadcasting to that topic when its
  workflow completes successfully.

  Subscribers to `"merge_queue:" <> workspace_id` will receive
  `{:bead_closed_by_merge_queue, bead_id}` once the merge lands.

  ## Supervision

  This GenServer is **NOT** started under `Arbiter.Application` by
  default. Workspaces are dynamic — there's no static list to enumerate at
  boot — so a future supervisor (gte-024 territory) will start one
  merge_queue per workspace lazily. For now, tests and CLI tools start it
  manually with `start_link/1`.

  ## Configuration knobs (start_link/1 opts)

    * `:workspace_id` (string, required) — the workspace this merge_queue serves.
    * `:name` — process name (default `__MODULE__`).
    * `:poll_interval_ms` — how often `:tick` fires (default 30_000).
    * `:base` — an explicit *queue-level* base override. It sits **below** a
      bead's own `target_branch` and the per-rig default (so those still win),
      but above the workspace `merge.base`. Defaults to `nil`, in which case the
      base is resolved entirely from bead/rig/workspace config via
      `Arbiter.Polecat.TargetBranch`. Convenient for tests.
    * `:auto_tick` — when `false` (default `true`), the periodic `:tick`
      timer is not scheduled. Tests use `false` and drive ticks via
      `tick/1` so they don't race with real time.
    * `:conflict_resolver` — module implementing the
      `Arbiter.Workflows.MergeQueue.ConflictResolver` behaviour. Defaults to
      the real implementation (which spawns a Polecat + ClaudeSession);
      tests pass a stub.
    * `:revise_dispatcher` — module implementing the
      `Arbiter.Workflows.MergeQueue.ReviseDispatcher` behaviour (bd-95lsjb).
      Defaults to the real implementation (which resumes the bead's worktree
      via `Arbiter.Polecat.Dispatch.resume/2`); tests pass a stub.
  """

  use GenServer

  require Logger
  require Ash.Query

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Mergers
  alias Arbiter.Polecat.PRTemplate
  alias Arbiter.Polecat.TargetBranch
  alias Arbiter.Polecat.Worktree
  alias Arbiter.Polecats.Run
  alias Arbiter.Trackers

  @default_poll_interval_ms 30_000

  @typedoc "Status atom for an in-flight item."
  @type status ::
          :opening
          | :awaiting_approval
          | :ci_running
          | :ready_to_merge
          | :merging
          | :conflict_resolving
          | :changes_requested
          | :done
          | :failed

  @typedoc "An in-flight merge queue item."
  @type item :: %{
          bead_id: String.t(),
          mr_ref: String.t() | nil,
          status: status(),
          strategy: String.t(),
          base: String.t() | nil,
          opened_at: DateTime.t() | nil,
          last_polled_at: DateTime.t() | nil,
          last_error: term() | nil,
          resolver_spawned_at: DateTime.t() | nil,
          prior_status: status() | nil,
          last_handled_review_id: term() | nil
        }

  defmodule State do
    @moduledoc false
    defstruct [
      :workspace_id,
      :adapter,
      :base,
      :poll_interval_ms,
      :auto_tick,
      :pubsub_topic,
      :conflict_resolver,
      :revise_dispatcher,
      :worktree_module,
      items: []
    ]
  end

  # ---- public API ---------------------------------------------------------

  @doc """
  Start a merge_queue for a workspace. See moduledoc for options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Synchronously enqueue a bead for merging. Behaves the same as receiving
  a `{:polecat_done, bead_id}` PubSub message. Returns `:ok` on enqueue
  even if the actual MR open / merge hasn't happened yet (it runs inside
  the GenServer's `handle_call` though, so by the time this returns the
  initial state transition has been recorded).
  """
  @spec enqueue(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def enqueue(server \\ __MODULE__, bead_id) when is_binary(bead_id) do
    GenServer.call(server, {:enqueue, bead_id})
  end

  @doc """
  Return a snapshot of the merge_queue state for inspection / tests.
  """
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__) do
    GenServer.call(server, :state)
  end

  @doc """
  Force a poll cycle. In tests, prefer this over waiting for the periodic
  timer. Returns `:ok` once the cycle completes.
  """
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__) do
    GenServer.call(server, :tick)
  end

  # ---- GenServer callbacks ------------------------------------------------

  @impl true
  def init(opts) do
    workspace_id =
      case Keyword.fetch(opts, :workspace_id) do
        {:ok, id} when is_binary(id) and id != "" -> id
        _ -> raise ArgumentError, "MergeQueue requires :workspace_id"
      end

    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    auto_tick = Keyword.get(opts, :auto_tick, true)
    topic = "polecat:done:" <> workspace_id

    # Subscribe to polecat done events for this workspace.
    :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

    # Resolve adapter from workspace config. Defaults to Direct when the
    # workspace can't be loaded (e.g. a fake ID in supervisor tests, or DB
    # not yet ready at boot).
    {adapter, workspace} = load_adapter_for(workspace_id)
    if workspace, do: Mergers.prepare(workspace)

    state = %State{
      workspace_id: workspace_id,
      adapter: adapter,
      base: Keyword.get(opts, :base),
      poll_interval_ms: poll_interval_ms,
      auto_tick: auto_tick,
      pubsub_topic: topic,
      conflict_resolver:
        Keyword.get(
          opts,
          :conflict_resolver,
          Application.get_env(
            :arbiter,
            :merge_queue_conflict_resolver,
            Arbiter.Workflows.MergeQueue.ConflictResolver
          )
        ),
      revise_dispatcher:
        Keyword.get(
          opts,
          :revise_dispatcher,
          Application.get_env(
            :arbiter,
            :merge_queue_revise_dispatcher,
            Arbiter.Workflows.MergeQueue.ReviseDispatcher
          )
        ),
      worktree_module: Keyword.get(opts, :worktree_module, Worktree),
      items: []
    }

    if auto_tick, do: schedule_tick(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, bead_id}, _from, %State{} = state) do
    {reply, state} = do_enqueue(state, bead_id)
    {:reply, reply, state}
  end

  def handle_call(:state, _from, %State{} = state) do
    {:reply, snapshot(state), state}
  end

  def handle_call(:tick, _from, %State{} = state) do
    {:reply, :ok, poll_all(state)}
  end

  @impl true
  def handle_info({:polecat_done, bead_id}, %State{} = state) when is_binary(bead_id) do
    {_reply, state} = do_enqueue(state, bead_id)
    {:noreply, state}
  end

  def handle_info(:tick, %State{} = state) do
    state = poll_all(state)
    if state.auto_tick, do: schedule_tick(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- enqueue + state-machine driver -------------------------------------

  defp do_enqueue(state, bead_id) do
    case Ash.get(Issue, bead_id) do
      {:ok, bead} ->
        # Reload workspace to pick up the merge config block. Issue belongs_to
        # workspace but the relationship isn't always loaded.
        {:ok, bead} = Ash.load(bead, [:workspace])

        # Re-seed the adapter's per-process config from the latest workspace
        # state, then resolve the adapter module.
        Mergers.prepare(bead.workspace)
        adapter = Mergers.for_workspace(bead.workspace)
        state = %{state | adapter: adapter}

        strategy = Atom.to_string(Workspace.merger_strategy(bead.workspace))

        cond do
          already_queued?(state, bead_id) ->
            {{:ok, :already_queued}, state}

          strategy == "direct" ->
            # direct: never call MR/PR APIs. The polecat owned the push + merge;
            # we just transition the bead. This is the explicit escape hatch
            # for personal projects that don't use the PR/MR workflow.
            item = new_item(bead_id, strategy, status: :done)
            state = %{state | items: [item | state.items]}
            state = close_bead_and_finalize(state, item)
            {:ok, state}

          existing_mr_ref(bead) ->
            # bd-auma3z: the bead already has an open MR/PR (e.g. a prior worker
            # opened one before it stopped, and was then resumed). Adopt that MR
            # into the queue and poll it to completion rather than calling
            # `adapter.open` again — that would create a DUPLICATE for the same
            # branch. The resumed worker's work lands on the same branch the MR
            # already tracks.
            adopt_existing_mr(state, bead, strategy)

          true ->
            open_mr_for(state, bead, strategy)
        end

      {:error, _} = err ->
        {err, state}
    end
  end

  # The bead's recorded MR ref, if any — set by `maybe_record_mr_ref/2` when
  # an MR was opened. nil/blank means no open MR to adopt.
  defp existing_mr_ref(%Issue{pr_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp existing_mr_ref(_), do: nil

  # Adopt a bead's already-open MR into the merge queue without opening a new
  # one (bd-auma3z no-duplicate guard). Slots it in at `:awaiting_approval`
  # so the normal poll loop drives it the rest of the way.
  defp adopt_existing_mr(state, bead, strategy) do
    mr_ref = existing_mr_ref(bead)

    Logger.info(
      "MergeQueue: bead #{bead.id} already has MR #{mr_ref}; adopting it " <>
        "instead of opening a duplicate"
    )

    item =
      new_item(bead.id, strategy,
        mr_ref: mr_ref,
        status: :awaiting_approval,
        base: resolve_base(state, bead),
        opened_at: DateTime.utc_now()
      )

    {:ok, %{state | items: [item | state.items]}}
  end

  # Resolve the PR base for a bead via the shared resolver, identical to the
  # chain `Arbiter.Polecat.Dispatch` uses for the worktree base, so the two can
  # never diverge (bd-b6rzoc). `state.base` is threaded in as the queue-level
  # `:workspace_base` — below the bead/rig config, never short-circuiting it.
  defp resolve_base(%State{} = state, %Issue{} = bead) do
    TargetBranch.resolve(bead,
      workspace_base: state.base,
      rig: resolve_bead_rig(bead)
    )
  end

  # The rig the bead was actually worked in — drawn from its most recent
  # polecat run, the same rig `Dispatch` cut the worktree with. nil when the bead
  # has no run on record (e.g. a bead enqueued without ever being slung), in
  # which case the per-rig default simply doesn't apply.
  defp resolve_bead_rig(%Issue{id: bead_id}) do
    Run
    |> Ash.Query.filter(bead_id == ^bead_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read()
    |> case do
      {:ok, [%Run{rig: rig} | _]} when is_binary(rig) and rig != "" -> rig
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp open_mr_for(state, bead, strategy) do
    base = resolve_base(state, bead)

    branch = strategy_for(bead.workspace, "merge", "branch_prefix", "") <> bead.id
    title = bead.title
    description = pr_description_for(bead)

    worktree_path = state.worktree_module.worktree_path(branch)

    with {:ok, _} <- push_worktree_branch(state.worktree_module, worktree_path, branch),
         {:ok, mr_ref} when is_binary(mr_ref) <-
           state.adapter.open(branch, title, description, %{target_branch: base}) do
      item =
        new_item(bead.id, strategy,
          mr_ref: mr_ref,
          status: :awaiting_approval,
          base: base,
          opened_at: DateTime.utc_now()
        )

      # Record MR ref on the bead's pr_ref field. Best-effort: failure
      # to update the bead doesn't fail the whole enqueue.
      _ = maybe_record_mr_ref(bead, mr_ref)

      # Link the MR back onto the upstream tracker ticket. Best-effort and
      # tracker-agnostic — a no-op for trackers without remote links.
      _ = maybe_link_mr_to_tracker(bead, state.adapter, mr_ref)

      {:ok, %{state | items: [item | state.items]}}
    else
      {:error, {:push_failed, _} = reason} ->
        item = new_item(bead.id, strategy, status: :failed, last_error: reason)
        {{:error, reason}, %{state | items: [item | state.items]}}

      {:error, reason} ->
        item = new_item(bead.id, strategy, status: :failed, last_error: reason)
        {{:error, reason}, %{state | items: [item | state.items]}}
    end
  end

  # The PR/MR body the MergeQueue opens with. Precedence:
  #
  #   1. the worker-authored `pr_body` (bd-53xrmi) — Summary / Test plan /
  #      References written *after* the change landed, filling the repo's PR
  #      template when present. This is the canonical, worker-quality body.
  #   2. the bead's originating `description` (the ticket spec) — a reasonable
  #      stand-in when no worker body was produced (older beads, review-only).
  #   3. `PRTemplate.default_body/1` — a minimal `## <title>` + description +
  #      tracker-link body.
  #
  # The final fallback is what root-causes the empty-body incident (#3606):
  # `bead.description || ""` returned `""` whenever the local bead's
  # description was empty/nil (e.g. the spec lived only upstream), and GitHub
  # injects the repo's bare PR template whenever the body is empty. `pr_body ||
  # description || default_body` is *always* non-empty (default_body always
  # carries the title), so the MergeQueue can never again open a bare-template PR.
  # The bead is fetched fresh via `Ash.get/2` in `do_enqueue/2`, which selects
  # all attributes — so `pr_body` and `description` are loaded, never silently
  # nil from a partial select.
  defp pr_description_for(%Issue{} = bead) do
    present(bead.pr_body) || present(bead.description) || PRTemplate.default_body(bead)
  end

  # A string is "present" when it's a non-blank binary; nil/""/whitespace-only
  # collapse to nil so the `||` chain falls through to the next source.
  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp present(_), do: nil

  defp push_worktree_branch(worktree_module, worktree_path, branch) do
    case worktree_module.push(worktree_path, set_upstream: true, branch: branch) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:push_failed, reason}}
    end
  end

  defp poll_all(%State{items: items} = state) do
    {new_items, state} =
      Enum.map_reduce(items, state, fn item, acc -> poll_item(acc, item) end)

    # Drop items that have reached :done — they've been closed already.
    new_items = Enum.reject(new_items, &(&1.status == :done))
    %{state | items: new_items}
  end

  defp poll_item(state, %{status: :failed} = item), do: {item, state}
  defp poll_item(state, %{status: :done} = item), do: {item, state}

  defp poll_item(state, %{mr_ref: nil} = item) do
    # Should not happen: only the :direct path skips mr_ref, and that path
    # sets status to :done immediately. Defensive.
    {item, state}
  end

  defp poll_item(state, item) do
    case state.adapter.get(item.mr_ref) do
      {:ok, mr_state} ->
        advance_status(state, item, mr_state)

      {:error, reason} ->
        {%{item | status: :failed, last_error: reason, last_polled_at: DateTime.utc_now()}, state}
    end
  end

  # Walk the MR state through the status machine. We re-evaluate the
  # *current* status against the adapter response on every tick so a long-lived
  # item can climb several rungs in one cycle.
  defp advance_status(state, item, mr_state) do
    now = DateTime.utc_now()
    item = %{item | last_polled_at: now}

    cond do
      # Top-priority guard: a CONFLICTING MR never advances state. The
      # merge queue auto-spawns a worker to rebase + resolve + force-push
      # (one attempt; the in-flight resolver parks the item at
      # :conflict_resolving so back-to-back ticks don't spawn duplicates).
      # A second observation of conflicting while parked means the rebase
      # didn't clear it — escalate via the mailbox.
      mr_state.conflicting ->
        handle_conflict(state, item)

      # Once the conflict clears (conflicting: false on a later tick) restore
      # the item to its prior status so the normal advancement resumes.
      item.status == :conflict_resolving ->
        restored = restore_after_resolution(state, item)
        advance_status(state, restored, mr_state)

      # A revise pass was dispatched on a prior tick; the worker is addressing
      # the feedback asynchronously on the same branch. Return the item to
      # :awaiting_approval so it awaits re-review, then re-evaluate against the
      # current MR state. The debounce on last_handled_review_id (below)
      # prevents the same review from re-dispatching. Mirrors the
      # :conflict_resolving restore (bd-95lsjb).
      item.status == :changes_requested ->
        advance_status(state, %{item | status: :awaiting_approval}, mr_state)

      # MR was already merged externally (e.g. the Watchdog merged it for a
      # ReviewGate-approved bead before the MergeQueue processed the polecat_done
      # event). Close the bead directly without re-attempting adapter.merge/1
      # — that call would fail on an already-closed PR. bd-d1jp4r. Checked
      # before the changes-requested branch so a merged PR never triggers a
      # revise on a stale review.
      mr_state.status == :merged ->
        item = %{item | status: :done}
        state = close_bead_and_finalize(state, item)
        {item, state}

      # A reviewer requested changes with a review we haven't actioned yet:
      # dispatch exactly one revise pass on the existing worktree. Debounced on
      # the review id so the same CHANGES_REQUESTED (still in the PR's review
      # history after the revise lands) is not actioned twice.
      unhandled_changes_requested?(item, mr_state) ->
        dispatch_revise(state, item, mr_state)

      item.status == :awaiting_approval and mr_state.approved and mr_state.ci_clean ->
        try_merge(state, %{item | status: :ready_to_merge})

      item.status == :awaiting_approval and mr_state.approved ->
        {%{item | status: :ci_running}, state}

      item.status == :ci_running and mr_state.ci_clean ->
        try_merge(state, %{item | status: :ready_to_merge})

      item.status == :ready_to_merge and mr_state.ci_clean ->
        try_merge(state, item)

      true ->
        # No transition this cycle.
        {item, state}
    end
  end

  # Handle a CONFLICTING MR payload. First observation spawns the resolver;
  # observing the conflict again while already in `:conflict_resolving` means
  # the rebase did not clear the conflict (semantic, not mechanical) — escalate
  # and park `:failed`. There is no retry loop — the resolver is one
  # mechanical rebase pass; anything more is a human decision.
  defp handle_conflict(state, %{status: :conflict_resolving} = item) do
    safe_escalate(
      state.conflict_resolver,
      item.bead_id,
      state.workspace_id,
      item_branch_label(item),
      :resolver_did_not_clear_conflict
    )

    {%{item | status: :failed, last_error: :conflict_unresolved}, state}
  end

  defp handle_conflict(state, item), do: spawn_conflict_resolver(state, item)

  # Spawn the resolver and transition the item to :conflict_resolving. The
  # item's prior status is stashed so a successful push restores us to
  # exactly where the state machine was before the conflict was detected.
  defp spawn_conflict_resolver(state, item) do
    prior = item.prior_status || item.status

    # Rebase onto the SAME branch the PR targets — the base resolved when the
    # item was opened (bd-b6rzoc). Falls back to the queue-level base for items
    # that predate the field; the resolver itself fills any remaining nil from
    # workspace config.
    args = %{
      bead_id: item.bead_id,
      workspace_id: state.workspace_id,
      target_branch: item.base || state.base,
      pr_ref: item.mr_ref
    }

    case safe_resolve(state.conflict_resolver, args) do
      {:ok, _info} ->
        Logger.info("MergeQueue: spawned conflict resolver for bead=#{item.bead_id}")

        item = %{
          item
          | status: :conflict_resolving,
            prior_status: prior,
            resolver_spawned_at: DateTime.utc_now()
        }

        {item, state}

      {:error, reason} ->
        Logger.warning(
          "MergeQueue: conflict resolver failed for bead=#{item.bead_id}: #{inspect(reason)}"
        )

        safe_escalate(
          state.conflict_resolver,
          item.bead_id,
          state.workspace_id,
          item_branch_label(item),
          reason
        )

        {%{item | status: :failed, last_error: {:resolver_spawn_failed, reason}}, state}
    end
  end

  # Restore item state after a successful auto-rebase.
  defp restore_after_resolution(state, %{prior_status: nil} = item) do
    safe_notify_resolution(state, item)
    %{item | status: :awaiting_approval, prior_status: nil, resolver_spawned_at: nil}
  end

  defp restore_after_resolution(state, %{prior_status: prior} = item) do
    safe_notify_resolution(state, item)
    %{item | status: prior, prior_status: nil, resolver_spawned_at: nil}
  end

  # ---- changes-requested → auto-revise (bd-95lsjb) ------------------------

  # A CHANGES_REQUESTED review is actionable when it is newer than the last one
  # we dispatched a revise for. The debounce key is the review id (the merger
  # derives it from the review's id/timestamp). Only fire from a settled
  # awaiting-review status — never mid-merge or while already revising.
  defp unhandled_changes_requested?(item, mr_state) do
    item.status in [:awaiting_approval, :ci_running] and
      Map.get(mr_state, :changes_requested, false) and
      not is_nil(Map.get(mr_state, :latest_review_id)) and
      Map.get(mr_state, :latest_review_id) != item.last_handled_review_id
  end

  # Fetch the full review feedback, post a brief acknowledging comment, and
  # dispatch a revise pass on the existing worktree (same branch, no new PR).
  # On success the item is parked at :changes_requested with the review id
  # recorded; the next tick returns it to :awaiting_approval to await re-review.
  # A dispatch failure parks the item :failed (no retry loop — the reviewer can
  # drive recovery), mirroring the conflict-resolver spawn-failure path.
  defp dispatch_revise(state, item, mr_state) do
    review_id = Map.get(mr_state, :latest_review_id)
    feedback = fetch_review_feedback(state, item)

    _ = post_revise_ack(state, item)

    args = %{
      bead_id: item.bead_id,
      workspace_id: state.workspace_id,
      target_branch: item.base || state.base,
      pr_ref: item.mr_ref,
      feedback: feedback
    }

    case safe_dispatch_revise(state.revise_dispatcher, args) do
      {:ok, _info} ->
        Logger.info(
          "MergeQueue: dispatched revise pass for bead=#{item.bead_id} " <>
            "(review=#{inspect(review_id)})"
        )

        item = %{
          item
          | status: :changes_requested,
            last_handled_review_id: review_id,
            resolver_spawned_at: DateTime.utc_now()
        }

        {item, state}

      {:error, reason} ->
        Logger.warning(
          "MergeQueue: revise dispatch failed for bead=#{item.bead_id}: #{inspect(reason)}"
        )

        {%{item | status: :failed, last_error: {:revise_dispatch_failed, reason}}, state}
    end
  end

  # Best-effort fetch of the structured review feedback for the prompt. A
  # failure (or an adapter without the callback) degrades to an empty list —
  # the revise still dispatches; the worker re-reads the PR thread.
  defp fetch_review_feedback(state, item) do
    if function_exported?(state.adapter, :list_review_feedback, 1) do
      case state.adapter.list_review_feedback(item.mr_ref) do
        {:ok, %{feedback: feedback}} when is_list(feedback) -> feedback
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

  # Post a short acknowledgement on the PR so the reviewer sees the fleet is
  # acting on the feedback. Best-effort: never fails the revise dispatch.
  defp post_revise_ack(state, item) do
    body =
      "🤖 Addressing review feedback on the existing branch for bead " <>
        "#{item.bead_id} — a revision will be pushed to this PR shortly."

    state.adapter.add_comment(item.mr_ref, body)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_dispatch_revise(dispatcher_module, args) when is_atom(dispatcher_module) do
    dispatcher_module.dispatch(args)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe_resolve(resolver_module, args) when is_atom(resolver_module) do
    resolver_module.resolve(args)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe_escalate(resolver_module, bead_id, workspace_id, branch, reason)
       when is_atom(resolver_module) do
    target =
      if function_exported?(resolver_module, :escalate_unresolved, 4) do
        resolver_module
      else
        Arbiter.Workflows.MergeQueue.ConflictResolver
      end

    target.escalate_unresolved(bead_id, workspace_id, branch, reason)
  rescue
    e ->
      Logger.warning(
        "MergeQueue.safe_escalate: swallowed exception for bead=#{bead_id}: " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_notify_resolution(%State{conflict_resolver: resolver_module} = state, item) do
    target =
      if function_exported?(resolver_module, :notify_resolution, 3) do
        resolver_module
      else
        Arbiter.Workflows.MergeQueue.ConflictResolver
      end

    target.notify_resolution(item.bead_id, state.workspace_id, item_branch_label(item))
  rescue
    e ->
      Logger.warning(
        "MergeQueue.safe_notify_resolution: swallowed exception for bead=#{item.bead_id}: " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  defp item_branch_label(%{bead_id: bead_id}), do: "bead=" <> bead_id

  defp try_merge(state, item) do
    case state.adapter.merge(item.mr_ref) do
      :ok ->
        item = %{item | status: :merging}
        # Synchronously finalize. adapter.merge/1 returning :ok is the merge
        # confirmation, so it's safe to close now.
        item = %{item | status: :done}
        state = close_bead_and_finalize(state, item)
        {item, state}

      {:error, reason} ->
        {%{item | status: :failed, last_error: reason}, state}
    end
  end

  defp close_bead_and_finalize(state, item) do
    case Ash.get(Issue, item.bead_id) do
      {:ok, bead} ->
        case Ash.update(bead, %{close_upstream: true}, action: :close) do
          {:ok, _closed} ->
            broadcast_merge_queue_event(state, {:bead_closed_by_merge_queue, item.bead_id})

          {:error, reason} ->
            Logger.warning("MergeQueue: failed to close bead #{item.bead_id}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("MergeQueue: bead #{item.bead_id} vanished before close: #{inspect(reason)}")
    end

    state
  end

  # ---- helpers ------------------------------------------------------------

  defp new_item(bead_id, strategy, overrides) do
    base = %{
      bead_id: bead_id,
      mr_ref: nil,
      status: :opening,
      strategy: strategy,
      base: nil,
      opened_at: nil,
      last_polled_at: nil,
      last_error: nil,
      resolver_spawned_at: nil,
      prior_status: nil,
      last_handled_review_id: nil
    }

    Map.merge(base, Map.new(overrides))
  end

  defp already_queued?(%State{items: items}, bead_id) do
    Enum.any?(items, fn i -> i.bead_id == bead_id and i.status not in [:done, :failed] end)
  end

  defp strategy_for(workspace, key1, key2, default) do
    case workspace && workspace.config do
      %{} = config ->
        config
        |> Map.get(key1, %{})
        |> case do
          %{} = inner -> Map.get(inner, key2, default)
          _ -> default
        end

      _ ->
        default
    end
  end

  defp maybe_record_mr_ref(%Issue{} = bead, mr_ref) do
    case Ash.update(bead, %{pr_ref: mr_ref}, action: :update) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Attach the opened MR as a remote link on the bead's upstream tracker
  # ticket. Dispatches on the bead's `tracker_type`, seeds the adapter's
  # per-process config from the bead's workspace, and tolerates trackers that
  # don't support remote links. Never fails the enqueue.
  defp maybe_link_mr_to_tracker(%Issue{tracker_type: :none}, _adapter, _mr_ref), do: :ok

  defp maybe_link_mr_to_tracker(%Issue{} = bead, adapter, mr_ref) do
    url = adapter.link_for(mr_ref)
    title = "MR #{mr_ref} (bead #{bead.id})"

    Trackers.prepare(bead, bead.workspace)

    case Trackers.add_remote_link(bead, url, title) do
      :ok ->
        :ok

      {:error, :not_supported} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "MergeQueue: failed to link MR #{mr_ref} onto tracker " <>
            "#{bead.tracker_type} ref=#{bead.tracker_ref} for bead=#{bead.id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "MergeQueue: error linking MR #{mr_ref} for bead=#{bead.id}: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "MergeQueue: exit linking MR #{mr_ref} for bead=#{bead.id}: #{inspect(reason)}"
      )

      :ok
  end

  defp schedule_tick(%State{poll_interval_ms: ms}) do
    Process.send_after(self(), :tick, ms)
  end

  defp broadcast_merge_queue_event(%State{workspace_id: ws_id}, msg) do
    _ = Phoenix.PubSub.broadcast(Arbiter.PubSub, "merge_queue:" <> ws_id, msg)
    :ok
  end

  defp snapshot(%State{} = s) do
    %{
      workspace_id: s.workspace_id,
      adapter: s.adapter,
      base: s.base,
      poll_interval_ms: s.poll_interval_ms,
      auto_tick: s.auto_tick,
      pubsub_topic: s.pubsub_topic,
      items: s.items
    }
  end

  # Load the workspace and resolve the adapter module. Returns {adapter, workspace}
  # with workspace=nil if the load fails (e.g. fake ID in supervisor tests or DB
  # not yet ready). Defaults to Mergers.Direct so the MergeQueue still starts.
  defp load_adapter_for(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, workspace} -> {Mergers.for_workspace(workspace), workspace}
      _ -> {Mergers.Direct, nil}
    end
  rescue
    _ -> {Mergers.Direct, nil}
  end
end
