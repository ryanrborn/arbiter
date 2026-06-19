defmodule Arbiter.Worker.WatchdogFailureTest do
  @moduledoc """
  Regression test for bd-91rnwq.

  Root cause: when `Arbiter.Worker.Watchdog.start/1` returns `{:error, reason}`
  (Watchdog startup failure), `start_watchdog/3` returns `:error`. The `try/rescue`
  block in `do_open_mr` only handled exceptions and exits — a plain `:error`
  return value was silently discarded. The MR was already open on the forge but
  the worker had no Watchdog watching it, so the bead hung at `:awaiting_review`
  indefinitely with no path to completion.

  The fix captures the `start_watchdog` result and escalates to the Admiral when
  it is not `:ok`, so the orphaned MR is surfaced rather than silently lost.
  The worker still parks at `:awaiting_review` (the MR is real and must be
  preserved), but the Admiral can manually complete or fail the worker once
  the MR resolves.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Issue, Workspace}
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

  defp new_bead(ws) do
    {:ok, bead} =
      Ash.create(Issue, %{
        title: "watchdog failure bead",
        workspace_id: ws.id,
        issue_type: :feature
      })

    bead
  end

  defp running_worker(bead, ws) do
    {:ok, pid} =
      Worker.start(
        bead_id: bead.id,
        repo: "wf/repo",
        workspace_id: ws.id
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :implement)
    pid
  end

  describe "Watchdog startup failure (bd-91rnwq)" do
    test "worker stays :awaiting_review when Watchdog fails to start" do
      ws = new_workspace()
      bead = new_bead(ws)
      pid = running_worker(bead, ws)

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
      bead = new_bead(ws)
      pid = running_worker(bead, ws)

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
        Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == bead.id))

      assert escalation, "expected an Admiral escalation for the orphaned MR"
      assert escalation.subject =~ "Watchdog startup failed"
      assert escalation.body =~ "!orphan2"
      assert escalation.body =~ bead.id
    end
  end
end
