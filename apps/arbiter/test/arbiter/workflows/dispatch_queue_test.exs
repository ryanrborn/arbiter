defmodule Arbiter.Workflows.DispatchQueueTest do
  @moduledoc """
  Integration coverage for the quota-aware dispatch throttle (bd-7cd38f):
  the `:throttle` hold+drain path, the `:continue` proceed+alert path, fail-open,
  and restart durability — all driven through `Arbiter.Worker.Dispatch.dispatch/2`
  and the per-workspace `Arbiter.Workflows.DispatchQueue`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workflows.DispatchQueue
  alias Arbiter.Workflows.DispatchQueueSupervisor

  # Records each drain re-dispatch to the pid stashed in app-env, so the
  # priority-order drain can be asserted without spawning real workers.
  defmodule RecordingDispatcher do
    def dispatch(task_id, opts) do
      if pid = Application.get_env(:arbiter, :test_dispatch_pid),
        do: send(pid, {:dispatched, task_id, opts})

      {:ok, %{task_id: task_id}}
    end
  end

  # Always errors so items are requeued after every drain attempt.
  defmodule FailingDispatcher do
    def dispatch(task_id, _opts) do
      if pid = Application.get_env(:arbiter, :test_dispatch_pid),
        do: send(pid, {:dispatch_attempt, task_id})

      {:error, :always_fails}
    end
  end

  # Records overage alerts to the pid in app-env.
  defmodule RecordingNotifier do
    def overage_alert(snapshot, spend, threshold) do
      if pid = Application.get_env(:arbiter, :test_notifier_pid),
        do: send(pid, {:overage_alert, snapshot, spend, threshold})

      :ok
    end
  end

  setup do
    # The gate is a no-op when the proxy is disabled (the test default). Flip it
    # on so the gate actually consults the seeded quota snapshots.
    prev = Application.get_env(:arbiter, :anthropic_proxy)

    Application.put_env(:arbiter, :anthropic_proxy,
      enabled: true,
      base_url: "http://127.0.0.1:4848"
    )

    on_exit(fn -> Application.put_env(:arbiter, :anthropic_proxy, prev) end)
    :ok
  end

  defp make_workspace(config) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "dq-#{System.unique_integer([:positive])}",
        prefix: "dq#{System.unique_integer([:positive])}",
        config: config
      })

    ws
  end

  defp make_task(ws, attrs \\ %{}) do
    {:ok, task} =
      Ash.create(
        Issue,
        Map.merge(%{title: "t-#{System.unique_integer([:positive])}", workspace_id: ws.id}, attrs)
      )

    task
  end

  defp seed_quota(ws, attrs) do
    Ash.create!(
      AnthropicQuota,
      Map.merge(
        %{
          workspace_id: ws.id,
          provider: "claude",
          captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        attrs
      )
    )
  end

  defp start_queue(ws, opts) do
    {:ok, pid} = DispatchQueueSupervisor.start_dispatch_queue(ws.id, opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  describe ":throttle — holds near the cap" do
    test "queues the dispatch, does not spawn a worker, leaves task un-transitioned" do
      ws = make_workspace(%{"quota" => %{"on_exhaustion" => "throttle"}})
      task = make_task(ws)
      seed_quota(ws, %{status_5h: "rejected", utilization_5h: 0.99})

      assert {:error, {:quota_held, task_id}} = Dispatch.dispatch(task.id, start_driver: false)
      assert task_id == task.id

      # Task was NOT flipped to :in_progress and no worker spawned — it is held.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :open
      assert Worker.whereis(task.id) == nil

      # The intent is in the workspace's queue.
      assert DispatchQueue.held?(ws.id, task.id)

      if pid = DispatchQueueSupervisor.whereis(ws.id) do
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      end
    end
  end

  describe ":throttle — drains in priority order as headroom frees" do
    test "held P0 + P2 both dispatch, P0 first, none dropped" do
      Application.put_env(:arbiter, :test_dispatch_pid, self())
      on_exit(fn -> Application.delete_env(:arbiter, :test_dispatch_pid) end)

      ws = make_workspace(%{"quota" => %{"on_exhaustion" => "throttle"}})
      # Pre-start the queue with a recording dispatcher so draining doesn't spawn
      # real workers, and no PubSub auto-subscribe so only our explicit drain fires.
      pid = start_queue(ws, dispatcher: RecordingDispatcher, auto_subscribe: false)

      p2 = make_task(ws, %{priority: 2})
      p0 = make_task(ws, %{priority: 0})

      # Over the cap → both are held.
      seed_quota(ws, %{status_5h: "rejected", utilization_5h: 0.99})
      assert {:error, {:quota_held, _}} = Dispatch.dispatch(p2.id, start_driver: false)
      assert {:error, {:quota_held, _}} = Dispatch.dispatch(p0.id, start_driver: false)

      assert length(DispatchQueue.state(pid).items) == 2

      # Headroom returns → drain dispatches both, priority-first.
      seed_quota(ws, %{status_5h: "allowed", utilization_5h: 0.10})
      :ok = DispatchQueue.drain(pid)

      assert_receive {:dispatched, first, opts1}
      assert_receive {:dispatched, second, _opts2}
      assert first == p0.id
      assert second == p2.id
      # Drain re-dispatches with the gate bypassed so it can't re-enqueue.
      assert Keyword.get(opts1, :skip_quota_gate) == true

      # Queue fully drained — nothing dropped, nothing left.
      assert DispatchQueue.state(pid).items == []
    end
  end

  describe ":continue — proceeds past the cap and alerts once per crossing" do
    test "dispatch spawns a worker, records overage, alerts exactly once" do
      Application.put_env(:arbiter, :test_notifier_pid, self())
      on_exit(fn -> Application.delete_env(:arbiter, :test_notifier_pid) end)

      ws =
        make_workspace(%{
          "quota" => %{"on_exhaustion" => "continue", "overage_alert_usd" => 1.0}
        })

      # Pre-start the queue with the recording notifier (no auto-subscribe).
      _pid = start_queue(ws, notifier: RecordingNotifier, auto_subscribe: false)

      # In overage, and $5 spent this window → crosses the $1 threshold.
      seed_quota(ws, %{status_5h: "allowed", overage_status: "in_overage"})
      seed_usage(ws, 5.0)

      t1 = make_task(ws)
      assert {:ok, result} = Dispatch.dispatch(t1.id, repo: "r", start_driver: false)
      assert result.task.status == :in_progress
      assert is_pid(result.worker_pid)

      assert_receive {:overage_alert, snapshot, spend, threshold}
      assert snapshot.workspace_id == ws.id
      assert threshold == 1.0
      assert spend >= 5.0

      # A second dispatch in the same window (same crossing) must NOT re-alert,
      # and must still proceed.
      t2 = make_task(ws)
      assert {:ok, _} = Dispatch.dispatch(t2.id, repo: "r", start_driver: false)
      refute_receive {:overage_alert, _, _, _}, 100
    end
  end

  describe "fail-open" do
    test "proxy disabled → dispatch proceeds regardless of quota/config" do
      Application.put_env(:arbiter, :anthropic_proxy, enabled: false)

      ws = make_workspace(%{"quota" => %{"on_exhaustion" => "throttle"}})
      task = make_task(ws)
      # Even an over-cap snapshot is ignored because the proxy is off.
      seed_quota(ws, %{status_5h: "rejected", utilization_5h: 0.99})

      assert {:ok, result} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)
      assert result.task.status == :in_progress
    end

    test "no snapshot (latest == nil) → dispatch proceeds" do
      ws = make_workspace(%{"quota" => %{"on_exhaustion" => "throttle"}})
      task = make_task(ws)
      # No AnthropicQuota row seeded → latest/2 is nil → fail open.

      assert {:ok, result} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)
      assert result.task.status == :in_progress
    end
  end

  # Regression tests for bd-3mb41v — stale-snapshot expiry
  describe "stale snapshot (reset_5h_at in the past)" do
    test "dispatch proceeds even when stale snapshot shows over-cap utilization" do
      ws = make_workspace(%{"quota" => %{"on_exhaustion" => "throttle"}})
      task = make_task(ws)

      # Snapshot whose 5h window reset 1 hour ago → stale.
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      seed_quota(ws, %{
        status_5h: "allowed_warning",
        utilization_5h: 0.94,
        reset_5h_at: past
      })

      # Gate must fail open and dispatch proceeds normally.
      assert {:ok, result} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)
      assert result.task.status == :in_progress
    end

    test "fresh over-cap snapshot still holds (staleness fix does not break throttle)" do
      ws = make_workspace(%{"quota" => %{"on_exhaustion" => "throttle"}})
      task = make_task(ws)

      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      seed_quota(ws, %{
        status_5h: "rejected",
        utilization_5h: 0.99,
        reset_5h_at: future
      })

      assert {:error, {:quota_held, task_id}} = Dispatch.dispatch(task.id, start_driver: false)
      assert task_id == task.id
      assert DispatchQueue.held?(ws.id, task.id)

      if pid = DispatchQueueSupervisor.whereis(ws.id) do
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      end
    end

    test "no :drain_on_reset busy-loop when held items remain after drain with past reset" do
      Application.put_env(:arbiter, :test_dispatch_pid, self())
      on_exit(fn -> Application.delete_env(:arbiter, :test_dispatch_pid) end)

      ws = make_workspace(%{"quota" => %{"on_exhaustion" => "throttle"}})

      # First seed a fresh over-cap snapshot so hold/4 arms a real future timer.
      future = DateTime.utc_now() |> DateTime.add(5 * 3600, :second) |> DateTime.truncate(:second)
      seed_quota(ws, %{status_5h: "rejected", utilization_5h: 0.99, reset_5h_at: future})

      # Start queue with FailingDispatcher so any drain attempt leaves items held,
      # and a RecordingDispatcher alias for later verification.
      pid =
        start_queue(ws,
          dispatcher: FailingDispatcher,
          auto_subscribe: false
        )

      task = make_task(ws)
      assert {:error, {:quota_held, _}} = Dispatch.dispatch(task.id, start_driver: false)
      assert DispatchQueue.held?(ws.id, task.id)

      # Update snapshot to be stale (reset 1 hour ago).
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      seed_quota(ws, %{status_5h: "rejected", utilization_5h: 0.99, reset_5h_at: past})

      # Force a drain. The gate now fails open (stale), so the dispatcher is
      # called. FailingDispatcher errors → item is requeued. schedule_reset_drain
      # must NOT send another :drain_on_reset since reset is in the past.
      :ok = DispatchQueue.drain(pid)

      # Give the queue and the drain task time to finish.
      Process.sleep(100)

      # No :drain_on_reset messages must be pending in the queue's mailbox.
      {:messages, msgs} = Process.info(pid, :messages)
      drain_msgs = Enum.filter(msgs, &(&1 == :drain_on_reset))

      assert drain_msgs == [],
             "Expected no pending :drain_on_reset, got #{length(drain_msgs)}"
    end
  end

  describe "restart durability" do
    test "held work survives a queue restart (task recoverable from its status)" do
      ws = make_workspace(%{"quota" => %{"on_exhaustion" => "throttle"}})
      task = make_task(ws)
      seed_quota(ws, %{status_5h: "rejected", utilization_5h: 0.99})

      assert {:error, {:quota_held, _}} = Dispatch.dispatch(task.id, start_driver: false)

      # Simulate a restart: kill the queue process. The held intent is in-memory
      # and lost, BUT the task was never transitioned, so it is still resolvable
      # and re-dispatchable from its pre-dispatch status — no work is lost.
      if pid = DispatchQueueSupervisor.whereis(ws.id), do: GenServer.stop(pid, :normal)
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :open

      # Headroom returns; a fresh dispatch (new queue) proceeds normally.
      seed_quota(ws, %{status_5h: "allowed", utilization_5h: 0.10})
      assert {:ok, result} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)
      assert result.task.status == :in_progress

      if pid = DispatchQueueSupervisor.whereis(ws.id) do
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      end
    end
  end

  defp seed_usage(ws, cost_usd) do
    Ash.create!(Arbiter.Usage.Event, %{
      task_id: "usage-#{System.unique_integer([:positive])}",
      workspace_id: ws.id,
      step: :work,
      cost_usd: cost_usd,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end
end
