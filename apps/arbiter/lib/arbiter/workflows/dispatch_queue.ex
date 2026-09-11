defmodule Arbiter.Workflows.DispatchQueue do
  @moduledoc """
  Per-workspace draining dispatch queue for quota-aware throttling (bd-7cd38f).

  Modeled on `Arbiter.Workflows.MergeQueue`: one GenServer per workspace,
  registered under `Arbiter.Workflows.DispatchQueueRegistry` keyed by
  `workspace_id`. It is the holding pen for dispatches the quota gate
  (`Arbiter.Quota.Gate.Throttle`) decided to HOLD near the 5h cap, plus the
  per-workspace state for `:continue`-mode overage alerting.

  ## `:throttle` — hold + drain

  When `Arbiter.Worker.Dispatch.dispatch/2`'s quota seam gets `{:hold, reason}`,
  it calls `hold/4`, which enqueues the `(task_id, opts)` intent here instead of
  spawning a worker. The held task is NOT transitioned to `:in_progress` — it
  stays in its pre-dispatch DB status, so nothing is lost even across a restart
  (the task is still resolvable and re-dispatchable from its status).

  The queue drains — re-running `dispatch/2` for held intents in priority order —
  on two triggers:

    * `{:quota_updated, ws, quota}` on PubSub topic `quota:<ws>` — a fresh capture
      that may show headroom (bd-5boun6's broadcast).
    * a `reset_5h_at` `Process.send_after` timer — a deterministic wake at the 5h
      window reset, so the queue drains even if no traffic produces a fresh
      capture.

  On drain, each intent is re-checked against the current gate/quota; only those
  the gate now `:allow`s are dispatched (with `skip_quota_gate: true` so they
  don't re-enter the gate and loop). Order is priority-first, FIFO tiebreak —
  the same `{priority, opened_at}` key `MergeQueue` uses.

  ## A held intent for a task that has since closed is dropped, not retried forever (bd-atjyzu)

  A held intent outlives the task it was created for: nothing un-holds it when
  the task closes out from under it. Two mechanisms together make sure that
  doesn't turn into a permanent, silently-failing re-dispatch every drain:

    * `drop/2` — the task's `:close` action calls this directly
      (`Arbiter.Tasks.Issue.Changes.DropDispatchHold`) so the hold is removed
      the instant the task closes, not on the next drain.
    * a terminal-vs-retryable split in the requeue path — a drain that still
      finds a stale hold (the close raced the drop, or predates this fix)
      re-dispatches it and gets back a **terminal** failure, which is dropped
      instead of requeued:
        - `{:task_closed, _}` — `Dispatch.dispatch/2`'s `ensure_not_closed/1`
        - `{:task_not_found, _}` — `Dispatch.dispatch/2`'s `load_task/1`
      Every other failure shape is **retryable** and requeues unchanged —
      quota still held, a live agent session already on the task, a
      migration/preflight hiccup, a transient exception/exit, or the
      quota-exhausted pre-flight refusal below (which gets its own backoff,
      not a drop).

  ## A quota-exhausted pre-flight failure is held, not redrained every cycle (bd-8lnnnt)

  A gate `:allow` only means the *quota snapshot* has headroom — it says
  nothing about whether the CLI's own cheap auth probe (`Dispatch.run_preflight/2`)
  will actually succeed right now, since that probe can fail with a classified
  `:quota_exhausted` `StopReason` (the account's 5h window) even when the last
  captured snapshot looked fine. Without a hold, a held intent whose dispatch
  fails this way gets `{:requeue, item}`'d (below) and re-attempted on the very
  next drain trigger — and `RefreshProbe`/`CloudProbe` broadcast `quota_updated`
  every 5 minutes for as long as anything is held, so the doomed probe reran on
  a ~5-minute cadence for the whole incident this bug tracks (bd-7qbavq: 12
  identical failures, each preceded by a `quota_gate_bypass` event, landing on
  5-minute wall-clock boundaries — the queue drain, not `Arbiter.Board.Autopilot`'s
  15s tick, which would have produced ~300 attempts in that window, not 12).

  So a quota-exhausted pre-flight failure sets `retry_not_before` on the
  requeued item (`Arbiter.Worker.PreflightHold.retry_not_before/3` — the same
  policy `Autopilot` uses for its own tick: the probe's reported reset time
  when known, else a bounded exponential backoff), and `maybe_drain/1` skips
  re-checking/re-dispatching a held item until that time passes, regardless of
  what the gate says. `schedule_reset_drain/1`'s timer wakes the queue at
  `next_reset_at/1` — the earliest of any held provider's snapshot reset_at
  *or* any item's own `retry_not_before` — so a hold that falls after the raw
  snapshot reset (the reset-buffer or a no-reset-time backoff) still gets its
  own precise wake instead of waiting on the next 5-minute broadcast.

  ## `:continue` — overage alert debounce

  When the gate returns `{:overage, spend_usd}` (dispatch proceeds past the cap),
  the dispatcher calls `record_overage/3`. This process tracks the windowed
  overage spend against the workspace's `overage_alert_usd` threshold and fires
  exactly one `Arbiter.Messages.CoordinatorNotifier.overage_alert/3` per threshold
  crossing (debounced on the crossed multiple) — it never stops dispatch.

  ## Injection seams (start_link opts / app-env)

    * `:dispatcher` → `:arbiter, :dispatch_queue_dispatcher` → `Arbiter.Worker.Dispatch`
      — the module whose `dispatch/2` drains held intents. Tests pass a stub.
    * `:quota_reader` → `Arbiter.Quota` — supplies `latest_for_provider/2`
      snapshots on drain (one per distinct provider held).
    * `:notifier` → `Arbiter.Messages.CoordinatorNotifier` — the overage-alert channel.
    * `:auto_subscribe` (default `true`) — subscribe to the `quota:<ws>` topic.
  """

  use GenServer

  require Logger

  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.PreflightHold
  alias Arbiter.Workflows.DispatchQueueSupervisor

  @typedoc """
  A held dispatch intent. `provider` is the agent type the dispatch resolved to
  (`:claude` / `:codex` / `:gemini`) — the drain re-checks each item against
  *that* provider's quota snapshot (bd-2mpo3f), so a Codex hold is not gated on
  Anthropic headroom and vice versa.
  """
  @type item :: %{
          task_id: String.t(),
          opts: keyword(),
          priority: non_neg_integer(),
          opened_at: DateTime.t(),
          reason: term(),
          provider: atom(),
          preflight_failures: non_neg_integer(),
          retry_not_before: DateTime.t() | nil
        }

  defmodule State do
    @moduledoc false
    defstruct [
      :workspace_id,
      :workspace,
      :dispatcher,
      :quota_reader,
      :notifier,
      :auto_subscribe,
      :reset_timer_ref,
      items: [],
      last_overage_alert_multiple: 0
    ]
  end

  # ---- public API (facade over the per-workspace registry) ----------------

  @doc """
  Start a dispatch queue for a workspace. See moduledoc for options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  HOLD a dispatch intent for `workspace_id` (the `:throttle` path). Resolves —
  starting if necessary — the workspace's queue and enqueues the intent.

  `provider` is the agent type the held dispatch resolved to; the drain re-checks
  the intent against that provider's quota snapshot (bd-2mpo3f). Defaults to
  `:claude`.

  Returns `:ok` on enqueue, `{:error, reason}` if the queue can't be reached (the
  caller then fails open and dispatches, rather than dropping the work).
  """
  @spec hold(String.t(), String.t(), keyword(), term(), atom()) :: :ok | {:error, term()}
  def hold(workspace_id, task_id, opts, reason, provider \\ :claude)

  def hold(workspace_id, task_id, opts, reason, provider)
      when is_binary(workspace_id) and is_binary(task_id) do
    with {:ok, pid} <- DispatchQueueSupervisor.ensure_started(workspace_id) do
      GenServer.call(pid, {:hold, task_id, opts, reason, provider})
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, r -> {:error, {:exit, r}}
  end

  def hold(_workspace_id, _task_id, _opts, _reason, _provider), do: {:error, :no_workspace}

  @doc """
  Record windowed overage `spend_usd` for `workspace_id` (the `:continue` path)
  and fire an alert if it crossed a new `overage_alert_usd` multiple. Best-effort
  — never blocks or fails a dispatch.
  """
  @spec record_overage(String.t(), Issue.t(), float()) :: :ok
  def record_overage(workspace_id, %Issue{} = task, spend_usd)
      when is_binary(workspace_id) and is_number(spend_usd) do
    with {:ok, pid} <- DispatchQueueSupervisor.ensure_started(workspace_id) do
      GenServer.call(pid, {:record_overage, task, spend_usd * 1.0})
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def record_overage(_workspace_id, _task, _spend), do: :ok

  @doc "Force a drain cycle. Returns `:ok` once it completes."
  @spec drain(GenServer.server()) :: :ok
  def drain(server \\ __MODULE__), do: GenServer.call(server, :drain)

  @doc """
  Drop any held intent for `task_id` in `workspace_id`'s queue (bd-atjyzu).

  Called from the task's `:close` teardown so a closed task's hold is
  removed the moment it closes rather than waiting to be discovered — and
  requeued anyway — on the next drain trigger. Best-effort: `:ok` whether or
  not a queue is running, or the task was ever held there.
  """
  @spec drop(String.t(), String.t()) :: :ok
  def drop(workspace_id, task_id) when is_binary(workspace_id) and is_binary(task_id) do
    case DispatchQueueSupervisor.whereis(workspace_id) do
      pid when is_pid(pid) -> GenServer.call(pid, {:drop, task_id})
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def drop(_workspace_id, _task_id), do: :ok

  @doc "Return a snapshot of the queue state for inspection / tests."
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc """
  Whether a task is currently held in `workspace_id`'s queue. Best-effort:
  `false` if the queue isn't running.
  """
  @spec held?(String.t(), String.t()) :: boolean()
  def held?(workspace_id, task_id) when is_binary(workspace_id) and is_binary(task_id) do
    case DispatchQueueSupervisor.whereis(workspace_id) do
      pid when is_pid(pid) ->
        pid |> state() |> Map.get(:items, []) |> Enum.any?(&(&1.task_id == task_id))

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # ---- GenServer callbacks ------------------------------------------------

  @impl true
  def init(opts) do
    workspace_id =
      case Keyword.fetch(opts, :workspace_id) do
        {:ok, id} when is_binary(id) and id != "" -> id
        _ -> raise ArgumentError, "DispatchQueue requires :workspace_id"
      end

    auto_subscribe = Keyword.get(opts, :auto_subscribe, true)
    if auto_subscribe, do: Phoenix.PubSub.subscribe(Arbiter.PubSub, "quota:" <> workspace_id)

    state = %State{
      workspace_id: workspace_id,
      workspace: load_workspace(workspace_id),
      dispatcher:
        Keyword.get(
          opts,
          :dispatcher,
          Application.get_env(:arbiter, :dispatch_queue_dispatcher, Arbiter.Worker.Dispatch)
        ),
      quota_reader: Keyword.get(opts, :quota_reader, Arbiter.Quota),
      notifier: Keyword.get(opts, :notifier, Arbiter.Messages.CoordinatorNotifier),
      auto_subscribe: auto_subscribe,
      items: [],
      last_overage_alert_multiple: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:hold, task_id, opts, reason, provider}, _from, %State{} = state) do
    state =
      if already_held?(state, task_id) do
        state
      else
        item = new_item(state, task_id, opts, reason, provider)
        %{state | items: [item | state.items]}
      end

    # A held intent needs a deterministic wake at the 5h reset even if no fresh
    # capture arrives — (re)arm the reset timer from the latest snapshot.
    state = schedule_reset_drain(state)
    {:reply, :ok, state}
  end

  def handle_call({:record_overage, task, spend}, _from, %State{} = state) do
    {reply, state} = do_record_overage(state, task, spend)
    {:reply, reply, state}
  end

  def handle_call(:drain, _from, %State{} = state) do
    {:reply, :ok, drain_and_reschedule(state)}
  end

  def handle_call({:drop, task_id}, _from, %State{} = state) do
    items = Enum.reject(state.items, &(&1.task_id == task_id))
    {:reply, :ok, schedule_reset_drain(%{state | items: items})}
  end

  def handle_call(:state, _from, %State{} = state) do
    {:reply, snapshot(state), state}
  end

  @impl true
  def handle_info({:quota_updated, _ws_id, _quota}, %State{} = state) do
    {:noreply, drain_and_reschedule(state)}
  end

  def handle_info(:drain_on_reset, %State{} = state) do
    {:noreply, drain_and_reschedule(%{state | reset_timer_ref: nil})}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  # A drained intent whose off-process dispatch failed comes back here so it is
  # retried on a later drain trigger — no work is dropped (finding 3). Re-arm the
  # reset timer since we may have gone from empty back to non-empty.
  #
  # A competing `hold/5` for the same task can land while the drain Task that
  # produces this cast is still in flight (finding 2, bd-8lnnnt round 2):
  # `maybe_drain/1` removes the task from `state.items` optimistically before
  # dispatching, so a fresh `hold/5` for that same task in the gap sees
  # `already_held?/2` false and inserts a new `retry_not_before: nil` item.
  # If this cast then just no-op'd on "already held", the computed hold would
  # be silently discarded and the task left eligible to redrain immediately —
  # so merge the requeued hold fields onto whatever is currently present
  # instead of dropping them.
  @impl true
  def handle_cast({:requeue, item}, %State{} = state) do
    {:noreply, schedule_reset_drain(%{state | items: merge_requeued_item(state.items, item)})}
  end

  # ---- drain --------------------------------------------------------------

  defp drain_and_reschedule(state) do
    state
    |> reload_workspace()
    |> maybe_drain()
    |> schedule_reset_drain()
  end

  # Reload the workspace so a runtime config change (mode / threshold) is picked
  # up on the next drain, mirroring MergeQueue's per-cycle workspace reload.
  defp reload_workspace(%State{workspace_id: ws_id} = state) do
    %{state | workspace: load_workspace(ws_id) || state.workspace}
  end

  defp maybe_drain(%State{items: []} = state), do: state

  defp maybe_drain(%State{} = state) do
    # A quota-exhausted pre-flight failure holds its item until its own
    # `retry_not_before` passes (bd-8lnnnt) — set aside before the gate check
    # even runs, since the gate has no notion of this per-item hold.
    now = DateTime.utc_now()
    {on_hold, eligible} = Enum.split_with(state.items, &preflight_held?(&1, now))

    # One snapshot read per distinct provider held in this queue (bd-2mpo3f) —
    # a Codex hold must be re-checked against CodexQuota, not AnthropicQuota, or
    # it would drain on Anthropic's headroom (or never drain at all, since a
    # Codex-only install has no Anthropic snapshot).
    snapshots = provider_snapshots(state)
    gate = Arbiter.Quota.gate_for_workspace(state.workspace)

    # Partition (fast: a pure gate check per item) into those the gate still
    # holds and those there is now headroom for. The gate check and quota read
    # are cheap; the expensive part — the real dispatch of each drained intent —
    # is handed off to a supervised Task below so it never runs inside (and
    # blocks) this GenServer's message loop (finding 3).
    {to_dispatch, keep} =
      eligible
      |> Enum.sort_by(&queue_order_key/1)
      |> Enum.split_with(fn item ->
        quota = Map.get(snapshots, item_provider(item))

        case gate.check(nil, quota, state.workspace, []) do
          {:hold, _} -> false
          _allow_or_overage -> true
        end
      end)

    # Optimistically remove the to-dispatch intents now; the drain Task casts
    # `{:requeue, item}` back for any that fail, so nothing is dropped.
    _ = spawn_drain(state, to_dispatch)
    %{state | items: on_hold ++ keep}
  end

  defp preflight_held?(%{retry_not_before: %DateTime{} = at}, now),
    do: DateTime.compare(now, at) == :lt

  defp preflight_held?(_item, _now), do: false

  # Dispatch the drained intents off-process, sequentially in the priority order
  # already established by the caller, so headroom is consumed highest-priority
  # first. Fire-and-forget under a supervisor; failures are re-queued via cast.
  defp spawn_drain(_state, []), do: :ok

  defp spawn_drain(%State{dispatcher: dispatcher}, items) do
    queue = self()

    start_drain_task(fn ->
      Enum.each(items, fn item ->
        case safe_dispatch(dispatcher, item) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            requeue_or_drop(queue, item, reason)

          other ->
            requeue_or_drop(queue, item, other)
        end
      end)
    end)
  end

  # A dispatch failure is either terminal (the task can never dispatch again
  # as-is, e.g. it closed underneath the hold) or retryable (a later drain
  # might succeed, e.g. quota is still held). Terminal failures are dropped —
  # `maybe_drain/1` already removed the item from `state.items` optimistically
  # before dispatch, so "drop" here just means "don't requeue it" — a
  # requeue would otherwise re-dispatch and fail the same way forever
  # (bd-atjyzu). Retryable failures requeue exactly as before.
  #
  # Terminal (drop, don't requeue):
  #   * `{:task_closed, _}`     — `Dispatch.dispatch/2`'s `ensure_not_closed/1`
  #   * `{:task_not_found, _}`  — `Dispatch.dispatch/2`'s `load_task/1`
  #
  # Retryable (requeue, same as before): everything else — quota still held,
  # a live agent session already running the task, a migration/preflight
  # hiccup, a transient exception/exit, the quota-exhausted pre-flight
  # refusal `hold_item/2` already gives its own backoff.
  defp requeue_or_drop(queue, item, reason) do
    if terminal_dispatch_failure?(reason) do
      Logger.info(
        "DispatchQueue: dropping held intent for #{item.task_id}, terminal dispatch failure: #{inspect(reason)}"
      )

      :ok
    else
      GenServer.cast(queue, {:requeue, hold_item(item, reason)})
    end
  end

  defp terminal_dispatch_failure?({:task_closed, _}), do: true
  defp terminal_dispatch_failure?({:task_not_found, _}), do: true
  defp terminal_dispatch_failure?(_), do: false

  # A dispatch that failed on this drain gets requeued (below) so it isn't
  # dropped. If the failure was a quota-exhausted pre-flight refusal
  # (bd-8lnnnt), set `retry_not_before` so `maybe_drain/1` doesn't re-run the
  # same doomed CLI probe on the next 5-minute broadcast — see this module's
  # moduledoc and `Arbiter.Worker.PreflightHold`. Any other failure shape
  # requeues with no hold, unchanged from before.
  defp hold_item(item, reason) do
    count = Map.get(item, :preflight_failures, 0) + 1

    item
    |> Map.put(:preflight_failures, count)
    |> Map.put(
      :retry_not_before,
      PreflightHold.retry_not_before(reason, count, DateTime.utc_now())
    )
  end

  # Prefer the app-supervised Task.Supervisor; fall back to an unsupervised
  # process if it isn't running (e.g. a bare unit test), so drain still proceeds.
  defp start_drain_task(fun) do
    case Process.whereis(Arbiter.Workflows.DispatchDrainSupervisor) do
      pid when is_pid(pid) -> Task.Supervisor.start_child(pid, fun)
      _ -> {:ok, spawn(fun)}
    end
  rescue
    _ -> {:ok, spawn(fun)}
  end

  defp safe_dispatch(dispatcher, %{task_id: task_id, opts: opts}) do
    dispatcher.dispatch(task_id, Keyword.put(opts, :skip_quota_gate, true))
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, r -> {:error, {:exit, r}}
  end

  # `%{provider_atom => snapshot_row | nil}` for every provider currently held.
  defp provider_snapshots(%State{items: items} = state) do
    items
    |> Enum.map(&item_provider/1)
    |> Enum.uniq()
    |> Map.new(&{&1, safe_latest(state, &1)})
  end

  defp safe_latest(%State{quota_reader: reader, workspace_id: ws_id}, provider) do
    reader.latest_for_provider(ws_id, provider)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # (Re)arm the deterministic reset-drain timer from the earliest primary-window
  # reset across the providers currently held — whichever provider frees up first
  # should wake the queue. No-op when nothing is queued or no reset time is known.
  defp schedule_reset_drain(%State{items: []} = state), do: cancel_reset_timer(state)

  defp schedule_reset_drain(%State{} = state) do
    state = cancel_reset_timer(state)

    case next_reset_at(state) do
      %DateTime{} = reset ->
        delay = DateTime.diff(reset, DateTime.utc_now(), :millisecond)

        if delay > 0 do
          ref = Process.send_after(self(), :drain_on_reset, delay)
          %{state | reset_timer_ref: ref}
        else
          # The reset time is already in the past — the window has rolled. Do NOT
          # re-arm against a past time or a held-items cycle becomes a hot loop.
          # The staleness check in Gate.over_cap?/in_overage? now fails open for
          # stale snapshots, so the next drain trigger (PubSub quota_updated or
          # a new hold/5 call that re-reads the snapshot) will clear any queued
          # items.
          state
        end

      _ ->
        state
    end
  end

  # The wake time is the earliest of: a provider's snapshot reset_at, or any
  # held item's own `retry_not_before` (finding 2, bd-8lnnnt round 2) — a
  # `PreflightHold`-derived hold can fall after the snapshot's reset_at (the
  # +60s buffer, or a fallback backoff with no reset_at at all), and without
  # this the queue only re-arms a timer for the snapshot's reset, then finds
  # `maybe_drain/1` still holds the item and has nothing left to wake it until
  # the next `quota_updated` broadcast (up to 5 minutes late).
  defp next_reset_at(%State{} = state) do
    snapshot_resets =
      state
      |> provider_snapshots()
      |> Map.values()
      |> Enum.map(&Snapshot.normalize/1)
      |> Enum.flat_map(fn
        %{reset_at: %DateTime{} = reset} -> [reset]
        _ -> []
      end)

    item_holds =
      state.items
      |> Enum.flat_map(fn
        %{retry_not_before: %DateTime{} = at} -> [at]
        _ -> []
      end)

    now = DateTime.utc_now()

    # A stale/past snapshot reset_at must not win over a still-future item
    # hold just for being numerically smaller — `schedule_reset_drain/1`
    # already declines to arm a timer for a past time, so filter those out
    # here rather than letting one suppress a real future wake.
    (snapshot_resets ++ item_holds)
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp cancel_reset_timer(%State{reset_timer_ref: nil} = state), do: state

  defp cancel_reset_timer(%State{reset_timer_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | reset_timer_ref: nil}
  end

  # ---- overage alerting (debounced) ---------------------------------------

  defp do_record_overage(%State{} = state, task, spend) do
    case Workspace.quota_overage_alert_usd(state.workspace) do
      alert_usd when is_number(alert_usd) and alert_usd > 0 ->
        multiple = trunc(Float.floor(spend / alert_usd))
        last = state.last_overage_alert_multiple

        cond do
          multiple > last ->
            fire_overage_alert(state, task, spend, alert_usd)
            {{:alerted, multiple}, %{state | last_overage_alert_multiple: multiple}}

          multiple < last ->
            # Spend dropped (the 5h window rolled) — reset the debounce so the
            # next crossing alerts again, but don't alert on the way down.
            {:ok, %{state | last_overage_alert_multiple: multiple}}

          true ->
            {:ok, state}
        end

      _ ->
        # No threshold configured — record silently, never alert.
        {:ok, state}
    end
  end

  defp fire_overage_alert(%State{} = state, %Issue{} = task, spend, alert_usd) do
    snapshot = %{workspace_id: state.workspace_id, task_id: task.id}
    state.notifier.overage_alert(snapshot, spend, alert_usd)
    :ok
  rescue
    e ->
      Logger.debug("DispatchQueue.fire_overage_alert swallowed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  # ---- helpers ------------------------------------------------------------

  defp already_held?(%State{items: items}, task_id),
    do: Enum.any?(items, &(&1.task_id == task_id))

  # Insert `item` if its task isn't already present; otherwise merge its hold
  # fields onto the existing entry rather than dropping them (finding 2,
  # bd-8lnnnt round 2) — takes the later of the two `retry_not_before` values
  # and the higher `preflight_failures` count, on the theory that either
  # represents a hold computed from real information and neither should be
  # allowed to erase the other.
  defp merge_requeued_item(items, item) do
    case Enum.find(items, &(&1.task_id == item.task_id)) do
      nil ->
        [item | items]

      existing ->
        merged = merge_hold_fields(existing, item)

        Enum.map(items, fn
          %{task_id: task_id} when task_id == item.task_id -> merged
          other -> other
        end)
    end
  end

  defp merge_hold_fields(existing, requeued) do
    %{
      existing
      | retry_not_before: later_retry(existing.retry_not_before, requeued.retry_not_before),
        preflight_failures:
          max(
            Map.get(existing, :preflight_failures, 0),
            Map.get(requeued, :preflight_failures, 0)
          )
    }
  end

  defp later_retry(nil, nil), do: nil
  defp later_retry(nil, %DateTime{} = b), do: b
  defp later_retry(%DateTime{} = a, nil), do: a

  defp later_retry(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end

  defp new_item(%State{} = state, task_id, opts, reason, provider) do
    %{
      task_id: task_id,
      opts: opts,
      priority: task_priority(state, task_id),
      opened_at: DateTime.utc_now(),
      reason: reason,
      provider: provider,
      preflight_failures: 0,
      retry_not_before: nil
    }
  end

  # The provider a held intent was gated on. Items enqueued before this field
  # existed (or by a caller that omitted it) read as :claude — the historical
  # Anthropic-only behaviour.
  defp item_provider(item) do
    case Map.get(item, :provider) do
      p when is_atom(p) and not is_nil(p) -> p
      p when is_binary(p) and p != "" -> String.to_existing_atom(p)
      _ -> :claude
    end
  rescue
    ArgumentError -> :claude
  end

  # Task priority (0 = P0 highest … 4 = P4 lowest) for the queue order key.
  # Best-effort load; defaults to P2 if the task can't be read.
  defp task_priority(_state, task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{priority: p}} when is_integer(p) -> p
      _ -> 2
    end
  rescue
    _ -> 2
  end

  # Priority-first, FIFO tiebreak — same shape as MergeQueue.queue_order_key/1.
  defp queue_order_key(item) do
    {Map.get(item, :priority) || 2, opened_at_key(item.opened_at)}
  end

  defp opened_at_key(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp opened_at_key(_), do: 9_223_372_036_854_775_807

  defp load_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp snapshot(%State{} = s) do
    %{
      workspace_id: s.workspace_id,
      items: s.items,
      last_overage_alert_multiple: s.last_overage_alert_multiple,
      dispatcher: s.dispatcher,
      quota_reader: s.quota_reader
    }
  end
end
