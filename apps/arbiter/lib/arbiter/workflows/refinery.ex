defmodule Arbiter.Workflows.Refinery do
  @moduledoc """
  Per-workspace merge-queue GenServer. Picks up "polecat done" events,
  opens PRs (or merges directly per workspace config), polls them for
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
      loads bead → reads merge_strategy → opens PR (or skips for :direct)
        │
        ▼
      tick/0 (every poll_interval_ms) → polls in-flight PRs → merges → closes bead

  ## State machine (per in-flight item)

  The status is an explicit atom enum, not a polymorphic struct or behaviour:

      :opening
        │   pr_open succeeded
        ▼
      :awaiting_approval
        │   reviewDecision == "APPROVED"
        ▼
      :ci_running
        │   mergeStateStatus == "clean"
        ▼
      :ready_to_merge
        │   pr_merge accepted
        ▼
      :merging
        │   merge confirmed
        ▼
      :done   →   bead transitioned to :closed, item removed

  Errors anywhere set status to `:failed` and stop further polling on that
  item; the bead is NOT closed on failure. The reviewer can drive recovery
  manually.

  ## Auto-resolved merge conflicts (bd-dolcqq)

  When `pr_get` reports a CONFLICTING PR (`mergeable: false`) we used to
  freeze the item and wait for a human rebase — twice in one morning that
  meant an Admiral page on parallel dispatcher-bead waves. Now the Refinery
  side-steps that:

      :awaiting_approval (or any non-terminal status)
        │   pr_get reports mergeable: false
        ▼
      :conflict_resolving — spawn `Arbiter.Workflows.Refinery.ConflictResolver`
                            (a swappable behaviour, defaults to a Polecat +
                            ClaudeSession running rebase + force-push)
        │   acolyte pushes resolved branch
        ▼
      (next tick observes mergeable: true; restore_after_resolution/1
       returns the item to its prior status and the queue resumes)

  The resolver acolyte is spawned at most `:resolver_max_attempts` times
  (default 1) per item. When attempts are exhausted — or the spawn itself
  fails — the Refinery posts an `:escalation` mail to the workspace's
  Admiral mailbox via
  `Arbiter.Workflows.Refinery.ConflictResolver.escalate_unresolved/4` and
  marks the item `:failed`. Better a loud escalation than a silent stall.

  The resolver module is injected via `:conflict_resolver` (start_link opt)
  → `:arbiter, :refinery_conflict_resolver` (application env) → the default
  real implementation. Tests pass a stub so they don't spawn real acolytes.

  ## merge_strategy

  Read from `workspace.config["merge"]["strategy"]`. Valid values:

    * `"squash"` (default) — `GitHub.pr_merge/4` with `:squash`
    * `"merge"`            — `:merge`
    * `"rebase"`           — `:rebase`
    * `"direct"`           — **never opens a PR**. The bead is immediately
      transitioned to `:done` (and then `:closed`). This is the "personal
      project" path; the polecat is assumed to have already pushed +
      merged its branch out-of-band. It exists specifically because
      verus_server-style team workflows must default to `pr`, and earlier
      Phase-3 code conflated "merge directly" with "no PR" in a way that
      was hostile to the team default.

  In particular, **`merge_strategy="pr"` (or any non-direct value) MUST
  NEVER call `Worktree.push/2` from this module**. The polecat that
  produced the "done" event is responsible for pushing its branch. The
  refinery's job ends at the PR boundary.

  ## PubSub topic

  Subscribes to `"polecat:done:" <> workspace_id`. Per-workspace because
  each Refinery process runs against exactly one workspace and shouldn't
  see other workspaces' events. The polecat (or the orchestrator that
  drives it) is responsible for broadcasting to that topic when its
  workflow completes successfully.

  Subscribers to `"refinery:" <> workspace_id` will receive
  `{:bead_closed_by_refinery, bead_id}` once the merge lands.

  ## Supervision

  This GenServer is **NOT** started under `Arbiter.Application` by
  default. Workspaces are dynamic — there's no static list to enumerate at
  boot — so a future supervisor (gte-024 territory) will start one
  refinery per workspace lazily. For now, tests and CLI tools start it
  manually with `start_link/1`.

  ## Configuration knobs (start_link/1 opts)

    * `:workspace_id` (string, required) — the workspace this refinery serves.
    * `:name` — process name (default `__MODULE__`).
    * `:poll_interval_ms` — how often `:tick` fires (default 30_000).
    * `:repo` / `:base` — override the repo + base branch instead of reading
      them from `workspace.config["merge"]`. Convenient for tests.
    * `:github_token` — passed through to every `Arbiter.GitHub` call.
    * `:auto_tick` — when `false` (default `true`), the periodic `:tick`
      timer is not scheduled. Tests use `false` and drive ticks via
      `tick/1` so they don't race with real time.
    * `:conflict_resolver` — module implementing the
      `Arbiter.Workflows.Refinery.ConflictResolver` behaviour. Defaults to
      the real implementation (which spawns a Polecat + ClaudeSession);
      tests pass a stub.
    * `:resolver_max_attempts` — cap on consecutive resolver spawns per
      item before the Refinery escalates and marks the item :failed.
      Defaults to `1` (one mechanical rebase pass; anything semantic
      needs a human).
  """

  use GenServer

  require Logger

  alias Arbiter.Beads.Issue
  alias Arbiter.GitHub

  @default_poll_interval_ms 30_000
  @default_strategy "squash"

  # Cap on consecutive conflict-resolver acolyte spawns for a single item
  # before the Refinery gives up and escalates to the Admiral. One attempt is
  # the sensible default: if a clean rebase + force-push didn't unblock the
  # PR, the conflict is almost certainly semantic and a human needs to look.
  @default_resolver_max_attempts 1

  @typedoc "Status atom for an in-flight item."
  @type status ::
          :opening
          | :awaiting_approval
          | :ci_running
          | :ready_to_merge
          | :merging
          | :conflict_resolving
          | :done
          | :failed

  @typedoc "An in-flight merge queue item."
  @type item :: %{
          bead_id: String.t(),
          pr_number: pos_integer() | nil,
          status: status(),
          strategy: String.t(),
          opened_at: DateTime.t() | nil,
          last_polled_at: DateTime.t() | nil,
          last_error: term() | nil,
          resolver_spawned_at: DateTime.t() | nil,
          resolver_attempts: non_neg_integer(),
          prior_status: status() | nil
        }

  defmodule State do
    @moduledoc false
    defstruct [
      :workspace_id,
      :repo,
      :base,
      :github_token,
      :poll_interval_ms,
      :auto_tick,
      :pubsub_topic,
      :conflict_resolver,
      :resolver_max_attempts,
      items: []
    ]
  end

  # ---- public API ---------------------------------------------------------

  @doc """
  Start a refinery for a workspace. See moduledoc for options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Synchronously enqueue a bead for merging. Behaves the same as receiving
  a `{:polecat_done, bead_id}` PubSub message. Returns `:ok` on enqueue
  even if the actual PR open / merge hasn't happened yet (it runs inside
  the GenServer's `handle_call` though, so by the time this returns the
  initial state transition has been recorded).
  """
  @spec enqueue(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def enqueue(server \\ __MODULE__, bead_id) when is_binary(bead_id) do
    GenServer.call(server, {:enqueue, bead_id})
  end

  @doc """
  Return a snapshot of the refinery state for inspection / tests.
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
        _ -> raise ArgumentError, "Refinery requires :workspace_id"
      end

    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    auto_tick = Keyword.get(opts, :auto_tick, true)
    topic = "polecat:done:" <> workspace_id

    # Subscribe to polecat done events for this workspace.
    :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

    state = %State{
      workspace_id: workspace_id,
      repo: Keyword.get(opts, :repo),
      base: Keyword.get(opts, :base, "main"),
      github_token: Keyword.get(opts, :github_token),
      poll_interval_ms: poll_interval_ms,
      auto_tick: auto_tick,
      pubsub_topic: topic,
      conflict_resolver:
        Keyword.get(
          opts,
          :conflict_resolver,
          Application.get_env(
            :arbiter,
            :refinery_conflict_resolver,
            Arbiter.Workflows.Refinery.ConflictResolver
          )
        ),
      resolver_max_attempts:
        Keyword.get(opts, :resolver_max_attempts, @default_resolver_max_attempts),
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
        strategy = strategy_for(bead.workspace, "merge", "strategy", @default_strategy)

        cond do
          already_queued?(state, bead_id) ->
            {{:ok, :already_queued}, state}

          strategy == "direct" ->
            # direct: never call PR APIs. The polecat owned the push + merge;
            # we just transition the bead. This is the explicit escape hatch
            # for personal projects that don't use the PR workflow.
            item = new_item(bead_id, strategy, status: :done)
            state = %{state | items: [item | state.items]}
            state = close_bead_and_finalize(state, item)
            {:ok, state}

          true ->
            open_pr_for(state, bead, strategy)
        end

      {:error, _} = err ->
        {err, state}
    end
  end

  defp open_pr_for(state, bead, strategy) do
    repo = state.repo || strategy_for(bead.workspace, "merge", "repo", nil)
    base = state.base || strategy_for(bead.workspace, "merge", "base", "main") || "main"
    branch = strategy_for(bead.workspace, "merge", "branch_prefix", "") <> bead.id
    title = bead.title
    body = bead.description || ""

    cond do
      is_nil(repo) ->
        item = new_item(bead.id, strategy, status: :failed, last_error: :no_repo_configured)
        {{:error, :no_repo_configured}, %{state | items: [item | state.items]}}

      true ->
        case GitHub.pr_open(repo, branch, base, title, body, gh_opts(state)) do
          {:ok, %{"number" => pr_number}} when is_integer(pr_number) ->
            item =
              new_item(bead.id, strategy,
                pr_number: pr_number,
                status: :awaiting_approval,
                opened_at: DateTime.utc_now()
              )

            # Record PR number on the bead via tracker_ref if it doesn't already
            # have one. Best-effort: failure to update the bead doesn't fail the
            # whole enqueue.
            _ = maybe_record_tracker_ref(bead, pr_number)

            {:ok, %{state | items: [item | state.items]}}

          {:ok, _other} ->
            item = new_item(bead.id, strategy, status: :failed, last_error: :pr_open_no_number)
            {{:error, :pr_open_no_number}, %{state | items: [item | state.items]}}

          {:error, reason} ->
            item = new_item(bead.id, strategy, status: :failed, last_error: reason)
            {{:error, reason}, %{state | items: [item | state.items]}}
        end
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

  defp poll_item(state, %{pr_number: nil} = item) do
    # Should not happen: only the :direct path skips pr_number, and that path
    # sets status to :done immediately. Defensive.
    {item, state}
  end

  defp poll_item(state, item) do
    case GitHub.pr_get(repo_for(state, item), item.pr_number, gh_opts(state)) do
      {:ok, pr_payload} ->
        advance_status(state, item, pr_payload)

      {:error, reason} ->
        {%{item | status: :failed, last_error: reason, last_polled_at: DateTime.utc_now()},
         state}
    end
  end

  # Walk the PR payload through the status machine. We re-evaluate the
  # *current* status against the payload on every tick so a long-lived item
  # can climb several rungs in one cycle (e.g. open → approved + clean in
  # one poll → ready_to_merge → merging → done).
  defp advance_status(state, item, pr_payload) do
    review = Map.get(pr_payload, "reviewDecision")
    merge_state = Map.get(pr_payload, "mergeStateStatus")
    now = DateTime.utc_now()

    item = %{item | last_polled_at: now}

    cond do
      # Top-priority guard: a CONFLICTING PR never advances state. Before
      # bd-dolcqq this just froze the item and the bead sat there until a
      # human rebased. Now the Crucible auto-spawns an acolyte to rebase +
      # resolve + force-push (debounced via :resolver_spawned_at so back-
      # to-back ticks don't spawn duplicates), and escalates via the
      # mailbox when attempts are exhausted.
      GitHub.conflicting?(pr_payload) ->
        handle_conflict(state, item)

      # Once the conflict clears (mergeable: true on a later tick) restore
      # the item to its prior status so the normal advancement resumes.
      item.status == :conflict_resolving ->
        restored = restore_after_resolution(item)
        advance_status(state, restored, pr_payload)

      item.status == :awaiting_approval and review == "APPROVED" and merge_state == "clean" ->
        try_merge(state, %{item | status: :ready_to_merge})

      item.status == :awaiting_approval and review == "APPROVED" ->
        {%{item | status: :ci_running}, state}

      item.status == :ci_running and merge_state == "clean" ->
        try_merge(state, %{item | status: :ready_to_merge})

      item.status == :ready_to_merge and merge_state == "clean" ->
        try_merge(state, item)

      true ->
        # No transition this cycle.
        {item, state}
    end
  end

  # Handle a CONFLICTING PR payload. First-touch spawns the resolver acolyte;
  # subsequent ticks while the same conflict persists either keep waiting (if
  # under the attempt cap) or escalate + park.
  defp handle_conflict(state, %{status: :conflict_resolving} = item) do
    cond do
      item.resolver_attempts >= state.resolver_max_attempts ->
        escalate_resolver_exhausted(state, item)
        {%{item | status: :failed, last_error: :conflict_unresolved}, state}

      true ->
        # Resolver is still in flight; the next poll will either see mergeable
        # again (rebase pushed) or we'll re-enter this branch and bump the
        # attempt counter.
        {item, state}
    end
  end

  defp handle_conflict(state, item) do
    if item.resolver_attempts >= state.resolver_max_attempts do
      escalate_resolver_exhausted(state, item)
      {%{item | status: :failed, last_error: :conflict_unresolved}, state}
    else
      spawn_conflict_resolver(state, item)
    end
  end

  # Re-fire the resolver and transition the item to :conflict_resolving. The
  # item's prior status is stashed so a successful push restores us to
  # exactly where the state machine was before the conflict was detected
  # (e.g. :awaiting_approval) — we don't want a clean rebase to silently
  # downgrade an already-approved PR.
  defp spawn_conflict_resolver(state, item) do
    prior = item.prior_status || item.status

    args = %{
      bead_id: item.bead_id,
      workspace_id: state.workspace_id,
      target_branch: state.base,
      pr_ref: item.pr_number
    }

    case safe_resolve(state.conflict_resolver, args) do
      {:ok, _info} ->
        Logger.info(
          "Refinery: spawned conflict resolver for bead=#{item.bead_id} " <>
            "(attempt #{item.resolver_attempts + 1})"
        )

        item = %{
          item
          | status: :conflict_resolving,
            prior_status: prior,
            resolver_spawned_at: DateTime.utc_now(),
            resolver_attempts: item.resolver_attempts + 1
        }

        {item, state}

      {:error, reason} ->
        Logger.warning(
          "Refinery: conflict resolver failed for bead=#{item.bead_id}: #{inspect(reason)}"
        )

        # We couldn't even spawn the acolyte (no rig configured, worktree
        # creation failed, workspace gone). Escalate to the Admiral so the
        # bead doesn't sit in CONFLICTING limbo, and mark the item :failed
        # so we don't spin on the next tick.
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

  defp restore_after_resolution(%{prior_status: nil} = item),
    do: %{item | status: :awaiting_approval, prior_status: nil}

  defp restore_after_resolution(%{prior_status: prior} = item),
    do: %{item | status: prior, prior_status: nil}

  defp safe_resolve(resolver_module, args) when is_atom(resolver_module) do
    resolver_module.resolve(args)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp escalate_resolver_exhausted(state, item) do
    safe_escalate(
      state.conflict_resolver,
      item.bead_id,
      state.workspace_id,
      item_branch_label(item),
      {:attempts_exhausted, item.resolver_attempts}
    )
  end

  # Call `escalate_unresolved/4` on the injected resolver module (so test
  # stubs can intercept the escalation) and fall back to the real resolver
  # when the injected module doesn't implement that optional callback.
  defp safe_escalate(resolver_module, bead_id, workspace_id, branch, reason)
       when is_atom(resolver_module) do
    target =
      if function_exported?(resolver_module, :escalate_unresolved, 4) do
        resolver_module
      else
        Arbiter.Workflows.Refinery.ConflictResolver
      end

    target.escalate_unresolved(bead_id, workspace_id, branch, reason)
  rescue
    e ->
      Logger.warning(
        "Refinery.safe_escalate: swallowed exception for bead=#{bead_id}: " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  # Best-effort human label for a branch we may not have the canonical name
  # for in the item map. PRs carry the head ref on their payload, but the
  # Refinery has been deliberately keeping its item state minimal — fall
  # back to the bead id which is what the escalation reader cares about.
  defp item_branch_label(%{bead_id: bead_id}), do: "bead=" <> bead_id

  defp try_merge(state, item) do
    strategy_atom = strategy_to_atom(item.strategy)
    repo = repo_for(state, item)

    case GitHub.pr_merge(repo, item.pr_number, strategy_atom, gh_opts(state)) do
      {:ok, _payload} ->
        item = %{item | status: :merging}
        # Synchronously finalize. We could leave :merging in place and confirm
        # on the next tick, but pr_merge returning {:ok, ...} is the merge
        # confirmation from GitHub's perspective, so it's safe to close now.
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
        case Ash.update(bead, %{}, action: :close) do
          {:ok, _closed} ->
            broadcast_refinery_event(state, {:bead_closed_by_refinery, item.bead_id})

          {:error, reason} ->
            Logger.warning(
              "Refinery: failed to close bead #{item.bead_id}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.warning(
          "Refinery: bead #{item.bead_id} vanished before close: #{inspect(reason)}"
        )
    end

    state
  end

  # ---- helpers ------------------------------------------------------------

  defp new_item(bead_id, strategy, overrides) do
    base = %{
      bead_id: bead_id,
      pr_number: nil,
      status: :opening,
      strategy: strategy,
      opened_at: nil,
      last_polled_at: nil,
      last_error: nil,
      resolver_spawned_at: nil,
      resolver_attempts: 0,
      prior_status: nil
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

  defp strategy_to_atom("squash"), do: :squash
  defp strategy_to_atom("merge"), do: :merge
  defp strategy_to_atom("rebase"), do: :rebase
  defp strategy_to_atom(_), do: :squash

  defp gh_opts(%State{github_token: nil}), do: []
  defp gh_opts(%State{github_token: token}), do: [token: token]

  defp repo_for(state, _item), do: state.repo

  defp maybe_record_tracker_ref(%Issue{tracker_ref: ref}, _pr_number)
       when is_binary(ref) and ref != "" do
    :ok
  end

  defp maybe_record_tracker_ref(%Issue{} = bead, pr_number) do
    case Ash.update(bead, %{tracker_ref: to_string(pr_number)}, action: :update) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_tick(%State{poll_interval_ms: ms}) do
    Process.send_after(self(), :tick, ms)
  end

  defp broadcast_refinery_event(%State{workspace_id: ws_id}, msg) do
    _ = Phoenix.PubSub.broadcast(Arbiter.PubSub, "refinery:" <> ws_id, msg)
    :ok
  end

  defp snapshot(%State{} = s) do
    %{
      workspace_id: s.workspace_id,
      repo: s.repo,
      base: s.base,
      poll_interval_ms: s.poll_interval_ms,
      auto_tick: s.auto_tick,
      pubsub_topic: s.pubsub_topic,
      items: s.items
    }
  end
end
