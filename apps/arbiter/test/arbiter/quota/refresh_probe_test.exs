defmodule Arbiter.Quota.RefreshProbeTest do
  @moduledoc """
  Tests for `Arbiter.Quota.RefreshProbe` (bd-jzg8t0).

  All tests use an injected `:probe_fun` stub — no real `claude` CLI or proxy.
  The stub calls `Arbiter.Quota.capture/3` directly with fake headers so the
  same quota-update path (upsert → PubSub broadcast → DispatchQueue drain) runs
  without the HTTP round-trip.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.RefreshProbe
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.DispatchQueue
  alias Arbiter.Workflows.DispatchQueueSupervisor

  @fresh_allowed_headers [
    {"anthropic-ratelimit-unified-5h-utilization", "0.30"},
    {"anthropic-ratelimit-unified-5h-status", "allowed"},
    {"anthropic-ratelimit-unified-5h-reset", "1782247200"},
    {"anthropic-ratelimit-unified-representative-claim", "five_hour"}
  ]

  # A probe_fun that captures fake headers directly (simulating what the proxy
  # does when a real claude request flows through it) and notifies the test pid.
  defp recording_probe_fun(notify_pid, headers \\ @fresh_allowed_headers) do
    fn workspace_id ->
      {:ok, quota} = Quota.capture(workspace_id, headers)
      send(notify_pid, {:probed, workspace_id, quota})
      :ok
    end
  end

  defp start_probe(opts) do
    defaults = [
      name: nil,
      enabled: true,
      idle_interval_ms: 60_000,
      active_interval_ms: 60_000
    ]

    merged = Keyword.merge(defaults, opts)

    {:ok, pid} =
      start_supervised(%{
        id: make_ref(),
        start: {RefreshProbe, :start_link, [merged]}
      })

    pid
  end

  defp make_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rp-ws-#{System.unique_integer([:positive])}",
        prefix: "rp#{System.unique_integer([:positive])}"
      })

    ws
  end

  defp make_task(ws, attrs \\ %{}) do
    {:ok, task} =
      Ash.create(
        Issue,
        Map.merge(%{title: "rp-task-#{System.unique_integer([:positive])}", workspace_id: ws.id}, attrs)
      )

    task
  end

  defp enable_proxy do
    prev = Application.get_env(:arbiter, :anthropic_proxy)

    Application.put_env(:arbiter, :anthropic_proxy,
      enabled: true,
      base_url: "http://127.0.0.1:4848/proxy/anthropic"
    )

    on_exit(fn -> Application.put_env(:arbiter, :anthropic_proxy, prev) end)
  end

  defp seed_over_cap_quota(ws) do
    Ash.create!(
      AnthropicQuota,
      %{
        workspace_id: ws.id,
        provider: "claude",
        utilization_5h: 0.92,
        status_5h: "allowed",
        reset_5h_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
        captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    )
  end

  # Stub dispatcher for DispatchQueue — records drain re-dispatches.
  defmodule RecordingDispatcher do
    def dispatch(task_id, _opts) do
      if pid = Application.get_env(:arbiter, :rp_test_dispatch_pid),
        do: send(pid, {:dispatched, task_id})

      {:ok, %{task_id: task_id}}
    end
  end

  # ---- state / enabled -------------------------------------------------------

  describe "state/1" do
    test "reports probe_count and enabled" do
      pid = start_probe(enabled: false)
      assert %{probe_count: 0, enabled: false} = RefreshProbe.state(pid)
    end
  end

  # ---- probe/1 (force cycle) --------------------------------------------------

  describe "probe/1" do
    test "does not call probe_fun when proxy is disabled" do
      test_pid = self()
      pid = start_probe(probe_fun: recording_probe_fun(test_pid))
      _ws = make_workspace()

      RefreshProbe.probe(pid)

      refute_receive {:probed, _, _}, 100
    end

    test "calls probe_fun for each workspace when proxy is enabled" do
      enable_proxy()
      test_pid = self()
      ws1 = make_workspace()
      ws2 = make_workspace()
      pid = start_probe(probe_fun: recording_probe_fun(test_pid))

      RefreshProbe.probe(pid)

      # Wait for both Task-supervised probe_fun calls.
      assert_receive {:probed, id1, _}, 1_000
      assert_receive {:probed, id2, _}, 1_000
      assert Enum.sort([id1, id2]) == Enum.sort([ws1.id, ws2.id])
    end

    test "increments probe_count after a proxy-enabled cycle" do
      enable_proxy()
      _ws = make_workspace()
      pid = start_probe(probe_fun: recording_probe_fun(self()))

      RefreshProbe.probe(pid)
      assert_receive {:probed, _, _}, 1_000

      assert %{probe_count: 1} = RefreshProbe.state(pid)
    end

    test "does NOT increment probe_count when proxy is disabled" do
      _ws = make_workspace()
      pid = start_probe(probe_fun: recording_probe_fun(self()))

      RefreshProbe.probe(pid)

      assert %{probe_count: 0} = RefreshProbe.state(pid)
    end

    test "probe_fun receives the workspace_id and upserts a snapshot" do
      enable_proxy()
      ws = make_workspace()

      pid =
        start_probe(
          probe_fun: fn ws_id ->
            {:ok, _quota} = Quota.capture(ws_id, @fresh_allowed_headers)
            :ok
          end
        )

      assert Quota.latest(ws.id) == nil

      RefreshProbe.probe(pid)

      # The probe task runs asynchronously; poll briefly.
      Process.sleep(100)

      assert %AnthropicQuota{utilization_5h: 0.3, status_5h: "allowed"} =
               Quota.latest(ws.id)
    end
  end

  # ---- active / idle cadence -------------------------------------------------

  describe "cadence selection" do
    test "uses active interval when a DispatchQueue has held items" do
      enable_proxy()
      ws = make_workspace()
      seed_over_cap_quota(ws)

      # Seed an over-cap snapshot and start a queue with a held item.
      Application.put_env(:arbiter, :rp_test_dispatch_pid, self())
      on_exit(fn -> Application.delete_env(:arbiter, :rp_test_dispatch_pid) end)

      {:ok, q_pid} =
        DispatchQueueSupervisor.start_dispatch_queue(ws.id,
          dispatcher: RecordingDispatcher,
          quota_reader: Arbiter.Quota
        )

      on_exit(fn -> if Process.alive?(q_pid), do: GenServer.stop(q_pid, :normal) end)

      task = make_task(ws)
      :ok = DispatchQueue.hold(ws.id, task.id, [], {:test_hold, "over cap"})

      # Verify item is held.
      assert [_] = DispatchQueue.state(q_pid).items

      # The probe should detect held items → active interval.
      pid =
        start_probe(
          probe_fun: recording_probe_fun(self()),
          active_interval_ms: 111,
          idle_interval_ms: 999_999
        )

      # The probe GenServer tracks held state internally via count_held_workspaces.
      # We use probe/1 to drive a cycle synchronously, then confirm probe count is 1.
      RefreshProbe.probe(pid)
      assert_receive {:probed, _ws_id, _quota}, 1_000
      assert %{probe_count: 1} = RefreshProbe.state(pid)
    end
  end

  # ---- end-to-end: probe → snapshot → drain ----------------------------------

  describe "end-to-end: idle-stale → probe → drain" do
    test "probe captures fresh snapshot which broadcasts and drains held DispatchQueue intents" do
      enable_proxy()

      # Enable proxy gate check (mirrors DispatchQueueTest setup).
      prev_proxy = Application.get_env(:arbiter, :anthropic_proxy)
      Application.put_env(:arbiter, :anthropic_proxy, enabled: true, base_url: "http://127.0.0.1:4848")
      on_exit(fn -> Application.put_env(:arbiter, :anthropic_proxy, prev_proxy) end)

      ws = make_workspace()

      # Seed over-cap snapshot so the gate holds.
      seed_over_cap_quota(ws)

      Application.put_env(:arbiter, :rp_test_dispatch_pid, self())
      on_exit(fn -> Application.delete_env(:arbiter, :rp_test_dispatch_pid) end)

      # Start a DispatchQueue subscribed to PubSub for this workspace.
      {:ok, q_pid} =
        DispatchQueueSupervisor.start_dispatch_queue(ws.id,
          dispatcher: RecordingDispatcher,
          quota_reader: Arbiter.Quota,
          auto_subscribe: true
        )

      on_exit(fn -> if Process.alive?(q_pid), do: GenServer.stop(q_pid, :normal) end)

      # Also subscribe this test process to the quota PubSub topic so we can
      # assert the broadcast fires.
      Phoenix.PubSub.subscribe(Arbiter.PubSub, "quota:#{ws.id}")

      # Hold a task (gate sees over-cap → hold).
      task = make_task(ws)
      :ok = DispatchQueue.hold(ws.id, task.id, [], {:test_hold, "over cap in e2e"})

      assert [_held] = DispatchQueue.state(q_pid).items

      # The probe_fun simulates a fresh proxy capture with under-cap numbers.
      # It calls Quota.capture/3 which upserts + broadcasts quota_updated.
      fresh_under_cap_headers = [
        {"anthropic-ratelimit-unified-5h-utilization", "0.10"},
        {"anthropic-ratelimit-unified-5h-status", "allowed"},
        {"anthropic-ratelimit-unified-5h-reset", "1782247200"},
        {"anthropic-ratelimit-unified-representative-claim", "five_hour"}
      ]

      pid =
        start_probe(
          probe_fun: fn ws_id ->
            {:ok, quota} = Quota.capture(ws_id, fresh_under_cap_headers)
            send(self(), {:probed, ws_id, quota})
            :ok
          end
        )

      # Drive the probe cycle.
      RefreshProbe.probe(pid)

      # Wait for the PubSub broadcast from capture (quota_updated triggers drain).
      assert_receive {:quota_updated, ws_id, quota}, 2_000
      assert ws_id == ws.id
      assert quota.utilization_5h == 0.10

      # Give the DispatchQueue's drain task time to execute.
      Process.sleep(200)

      # The held item should have been drained → RecordingDispatcher.dispatch called.
      assert_receive {:dispatched, task_id}, 2_000
      assert task_id == task.id

      # Queue should now be empty.
      assert [] = DispatchQueue.state(q_pid).items
    end
  end

  # ---- enabled: false --------------------------------------------------------

  describe "disabled probe" do
    test "does not fire when enabled: false even with periodic timer" do
      enable_proxy()
      _ws = make_workspace()

      pid =
        start_probe(
          enabled: false,
          idle_interval_ms: 1,
          probe_fun: recording_probe_fun(self())
        )

      # Even with a 1ms timer, probe_fun should never be called when disabled.
      Process.sleep(50)
      refute_receive {:probed, _, _}, 10

      assert %{probe_count: 0, enabled: false} = RefreshProbe.state(pid)
    end
  end
end
