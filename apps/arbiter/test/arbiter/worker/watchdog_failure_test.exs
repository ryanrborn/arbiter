defmodule Arbiter.Worker.WatchdogFailureTest do
  @moduledoc """
  Regression test for bd-91rnwq.

  Root cause: when `Arbiter.Worker.Watchdog.start/1` returns `{:error, reason}`
  (Watchdog startup failure), `start_watchdog/3` returns `:error`. The `try/rescue`
  block in `do_open_mr` only handled exceptions and exits — a plain `:error`
  return value was silently discarded. The MR was already open on the forge but
  the worker had no Watchdog watching it, so the task hung at `:awaiting_review`
  indefinitely with no path to completion.

  The fix captures the `start_watchdog` result and escalates to the Admiral when
  it is not `:ok`, so the orphaned MR is surfaced rather than silently lost.
  The worker still parks at `:awaiting_review` (the MR is real and must be
  preserved), but the Admiral can manually complete or fail the worker once
  the MR resolves.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Test.StubMerger

  setup do
    StubMerger.reset()
    :ok
  end

  defp new_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "watchdog-fail-ws-#{System.unique_integer([:positive])}",
        prefix: "wf"
      })

    ws
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "watchdog failure task",
        workspace_id: ws.id,
        issue_type: :feature
      })

    task
  end

  defp running_worker(task, ws) do
    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "wf/repo",
        workspace_id: ws.id
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :implement)
    pid
  end

  defp start_watchdog(worker_pid, task_id, ws, mr_ref, opts) do
    base = [
      task_id: task_id,
      worker: worker_pid,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: ws,
      interval_ms: 20,
      initial_delay_ms: 0
    ]

    {:ok, wpid} = Arbiter.Worker.Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> if Process.alive?(wpid), do: GenServer.stop(wpid, :normal) end)
    wpid
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  describe "auto-merge stall notification (bd-6gxosc)" do
    test "Admiral receives an inbox escalation after N consecutive safe_merge failures" do
      ws = new_workspace()
      task = new_task(ws)
      pid = running_worker(task, ws)

      StubMerger.queue_get("!stall1", [%{status: :open, approved: true}])
      StubMerger.set_merge_result({:error, :mergeable_state_unknown})

      start_watchdog(pid, task.id, ws, "!stall1",
        auto_merge: true,
        merge_fail_notify_threshold: 3
      )

      # Wait until at least 3 merge attempts have been made.
      wait_until(fn -> StubMerger.merge_count("!stall1") >= 3 end)
      # Let a poll interval pass to ensure the notifier call fires.
      Process.sleep(60)

      escalations = Message.inbox("admiral", workspace_id: ws.id)

      stall_msg =
        Enum.find(escalations, fn m ->
          m.kind == :escalation and m.directive_ref == task.id and
            String.contains?(m.subject || "", "stalled")
        end)

      assert stall_msg, "expected an Admiral escalation for the stalled auto-merge"
      assert stall_msg.subject =~ task.id
      assert stall_msg.body =~ "!stall1"
      assert stall_msg.body =~ "3"
      assert stall_msg.body =~ "mergeable_state_unknown"
    end

    test "only one stall message is sent per stall episode (no repeated inbox spam)" do
      ws = new_workspace()
      task = new_task(ws)
      pid = running_worker(task, ws)

      StubMerger.queue_get("!stall2", [%{status: :open, approved: true}])
      StubMerger.set_merge_result({:error, :transient})

      start_watchdog(pid, task.id, ws, "!stall2",
        auto_merge: true,
        merge_fail_notify_threshold: 3
      )

      # Let 6+ failures accumulate (2× the threshold).
      wait_until(fn -> StubMerger.merge_count("!stall2") >= 6 end)
      Process.sleep(40)

      escalations = Message.inbox("admiral", workspace_id: ws.id)

      stall_msgs =
        Enum.filter(escalations, fn m ->
          m.kind == :escalation and m.directive_ref == task.id and
            String.contains?(m.subject || "", "stalled")
        end)

      assert length(stall_msgs) == 1,
             "expected exactly 1 stall escalation, got #{length(stall_msgs)}"
    end
  end

  describe "Watchdog startup failure (bd-91rnwq)" do
    test "worker stays :awaiting_review when Watchdog fails to start" do
      ws = new_workspace()
      task = new_task(ws)
      pid = running_worker(task, ws)

      StubMerger.next_open_ref("!orphan")

      assert {:ok, "!orphan"} =
               Worker.open_mr(
                 pid,
                 "feature/orphan",
                 "Orphan MR",
                 "desc",
                 %{
                   adapter: StubMerger,
                   workspace: nil,
                   interval_ms: 1_000_000,
                   initial_delay_ms: 1_000_000,
                   watchdog_start_error: true
                 }
               )

      snap = Worker.state(pid)
      assert snap.status == :awaiting_review
      assert snap.mr_ref == "!orphan"
    end

    test "Admiral is escalated with the MR ref when Watchdog fails to start" do
      ws = new_workspace()
      task = new_task(ws)
      pid = running_worker(task, ws)

      StubMerger.next_open_ref("!orphan2")

      Worker.open_mr(
        pid,
        "feature/orphan2",
        "Orphan MR 2",
        "",
        %{
          adapter: StubMerger,
          workspace: nil,
          interval_ms: 1_000_000,
          initial_delay_ms: 1_000_000,
          watchdog_start_error: true
        }
      )

      # Give the synchronous escalation call time to commit (it happens inline,
      # but the Ecto sandbox may need a moment to flush the write).
      Process.sleep(50)

      escalations = Message.inbox("admiral", workspace_id: ws.id)

      escalation =
        Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == task.id))

      assert escalation, "expected an Admiral escalation for the orphaned MR"
      assert escalation.subject =~ "Watchdog startup failed"
      assert escalation.body =~ "!orphan2"
      assert escalation.body =~ task.id
    end
  end

  describe ":merged tracker lifecycle (bd-blwx2u)" do
    @jira_env_wd "GTE_WD_MERGED_JIRA_TOKEN"

    defp jira_workspace do
      {:ok, ws} =
        Ash.create(Arbiter.Tasks.Workspace, %{
          name: "wd-jira-ws-#{System.unique_integer([:positive])}",
          prefix: "wj",
          config: %{
            "tracker" => %{
              "type" => "jira",
              "config" => %{
                "host" => "leotechnologies.atlassian.net",
                "project_key" => "VR",
                "credentials_ref" => "env:#{@jira_env_wd}",
                "email" => "tester@example.com",
                "status_map" => %{"merged" => "Code Complete"}
              }
            }
          }
        })

      ws
    end

    setup do
      System.put_env(@jira_env_wd, "test-jira-token")
      on_exit(fn -> System.delete_env(@jira_env_wd) end)
      :ok
    end

    test "Watchdog fires :merged tracker lifecycle when the watched MR is merged" do
      test_pid = self()
      ws = jira_workspace()

      {:ok, task} =
        Ash.create(Arbiter.Tasks.Issue, %{
          title: "watchdog-merged-tracker",
          tracker_type: :jira,
          tracker_ref: "VR-77777",
          skip_upstream_create: true,
          workspace_id: ws.id
        })

      pid = running_worker(task, ws)
      StubMerger.queue_get("!mrgd1", [%{status: :merged}])

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        cond do
          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "444",
                  "name" => "Approved and merged",
                  "to" => %{"name" => "Code Complete"}
                }
              ]
            })

          conn.method == "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:jira_transition, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)

      wpid = start_watchdog(pid, task.id, ws, "!mrgd1", [])
      Req.Test.allow(Arbiter.Trackers.Jira.HTTP, self(), wpid)

      wait_until(fn -> Worker.state(pid).status == :completed end)

      assert_receive {:jira_transition, %{"transition" => %{"id" => "444"}}}, 1_000
    end

    test "Watchdog fires :merged tracker lifecycle on auto-merge path" do
      test_pid = self()
      ws = jira_workspace()

      {:ok, task} =
        Ash.create(Arbiter.Tasks.Issue, %{
          title: "watchdog-automerged-tracker",
          tracker_type: :jira,
          tracker_ref: "VR-77778",
          skip_upstream_create: true,
          workspace_id: ws.id
        })

      pid = running_worker(task, ws)
      StubMerger.queue_get("!mrgd2", [%{status: :open, approved: true}])

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        cond do
          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "445",
                  "name" => "Approved and merged",
                  "to" => %{"name" => "Code Complete"}
                }
              ]
            })

          conn.method == "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:jira_transition, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)

      wpid = start_watchdog(pid, task.id, ws, "!mrgd2", auto_merge: true)
      Req.Test.allow(Arbiter.Trackers.Jira.HTTP, self(), wpid)

      wait_until(fn -> Worker.state(pid).status == :completed end)

      assert_receive {:jira_transition, %{"transition" => %{"id" => "445"}}}, 1_000
    end
  end
end
