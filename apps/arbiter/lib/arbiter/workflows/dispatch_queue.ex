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

  ## `:continue` — overage alert debounce

  When the gate returns `{:overage, spend_usd}` (dispatch proceeds past the cap),
  the dispatcher calls `record_overage/3`. This process tracks the windowed
  overage spend against the workspace's `overage_alert_usd` threshold and fires
  exactly one `Arbiter.Messages.CoordinatorNotifier.overage_alert/3` per threshold
  crossing (debounced on the crossed multiple) — it never stops dispatch.

  ## Injection seams (start_link opts / app-env)

    * `:dispatcher` → `:arbiter, :dispatch_queue_dispatcher` → `Arbiter.Worker.Dispatch`
      — the module whose `dispatch/2` drains held intents. Tests pass a stub.
    * `:quota_reader` → `Arbiter.Quota` — supplies `latest/2` snapshots on drain.
    * `:notifier` → `Arbiter.Messages.CoordinatorNotifier` — the overage-alert channel.
    * `:auto_subscribe` (default `true`) — subscribe to the `quota:<ws>` topic.
  """

  use GenServer

  require Logger

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.DispatchQueueSupervisor

  @typedoc "A held dispatch intent."
  @type item :: %{
          task_id: String.t(),
          opts: keyword(),
          priority: non_neg_integer(),
          opened_at: DateTime.t(),
          reason: term()
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

  Returns `:ok` on enqueue, `{:error, reason}` if the queue can't be reached (the
  caller then fails open and dispatches, rather than dropping the work).
  """
  @spec hold(String.t(), String.t(), keyword(), term()) :: :ok | {:error, term()}
  def hold(workspace_id, task_id, opts, reason)
      when is_binary(workspace_id) and is_binary(task_id) do
    with {:ok, pid} <- DispatchQueueSupervisor.ensure_started(workspace_id) do
      GenServer.call(pid, {:hold, task_id, opts, reason})
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, r -> {:error, {:exit, r}}
  end

  def hold(_workspace_id, _task_id, _opts, _reason), do: {:error, :no_workspace}

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
  def handle_call({:hold, task_id, opts, reason}, _from, %State{} = state) do
    state =
      if already_held?(state, task_id) do
        state
      else
        item = new_item(state, task_id, opts, reason)
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
  @impl true
  def handle_cast({:requeue, item}, %State{} = state) do
    state =
      if already_held?(state, item.task_id) do
        state
      else
        %{state | items: [item | state.items]}
      end

    {:noreply, schedule_reset_drain(state)}
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
    quota = safe_latest(state)
    gate = Arbiter.Quota.gate_for_workspace(state.workspace)

    # Partition (fast: a pure gate check per item) into those the gate still
    # holds and those there is now headroom for. The gate check and quota read
    # are cheap; the expensive part — the real dispatch of each drained intent —
    # is handed off to a supervised Task below so it never runs inside (and
    # blocks) this GenServer's message loop (finding 3).
    {to_dispatch, keep} =
      state.items
      |> Enum.sort_by(&queue_order_key/1)
      |> Enum.split_with(fn _item ->
        case gate.check(nil, quota, state.workspace, []) do
          {:hold, _} -> false
          _allow_or_overage -> true
        end
      end)

    # Optimistically remove the to-dispatch intents now; the drain Task casts
    # `{:requeue, item}` back for any that fail, so nothing is dropped.
    _ = spawn_drain(state, to_dispatch)
    %{state | items: keep}
  end

  # Dispatch the drained intents off-process, sequentially in the priority order
  # already established by the caller, so headroom is consumed highest-priority
  # first. Fire-and-forget under a supervisor; failures are re-queued via cast.
  defp spawn_drain(_state, []), do: :ok

  defp spawn_drain(%State{dispatcher: dispatcher}, items) do
    queue = self()

    start_drain_task(fn ->
      Enum.each(items, fn item ->
        case safe_dispatch(dispatcher, item) do
          {:ok, _} -> :ok
          _err -> GenServer.cast(queue, {:requeue, item})
        end
      end)
    end)
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

  defp safe_latest(%State{quota_reader: reader, workspace_id: ws_id}) do
    reader.latest(ws_id, "claude")
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # (Re)arm the deterministic reset-drain timer from the latest snapshot's
  # `reset_5h_at`. No-op when nothing is queued or no reset time is known.
  defp schedule_reset_drain(%State{items: []} = state), do: cancel_reset_timer(state)

  defp schedule_reset_drain(%State{} = state) do
    state = cancel_reset_timer(state)

    case safe_latest(state) do
      %{reset_5h_at: %DateTime{} = reset} ->
        delay = DateTime.diff(reset, DateTime.utc_now(), :millisecond)

        if delay > 0 do
          ref = Process.send_after(self(), :drain_on_reset, delay)
          %{state | reset_timer_ref: ref}
        else
          # reset_5h_at is already in the past — the window has rolled. Do NOT
          # re-arm against a past time or a held-items cycle becomes a hot loop.
          # The staleness check in Gate.over_cap?/in_overage? now fails open for
          # stale snapshots, so the next drain trigger (PubSub quota_updated or
          # a new hold/4 call that re-reads the snapshot) will clear any queued
          # items.
          state
        end

      _ ->
        state
    end
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

  defp new_item(%State{} = state, task_id, opts, reason) do
    %{
      task_id: task_id,
      opts: opts,
      priority: task_priority(state, task_id),
      opened_at: DateTime.utc_now(),
      reason: reason
    }
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
