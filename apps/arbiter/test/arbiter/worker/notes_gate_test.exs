defmodule Arbiter.Worker.NotesGateTest do
  @moduledoc """
  Regression tests for the notes gate introduced for `issue_type: :task`.

  A task-type directive's deliverable is a findings summary written to the
  `notes` field — not a code change. The notes gate fires when the worker
  signals `arb done` but `notes` is still blank. Like the commit gate, the
  nudge cap is pinned to 0 in these tests so we assert the structural gate
  behaviour (fail + escalate) without exercising the retry layer.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "notes-gate-ws-#{System.unique_integer([:positive])}",
        prefix: "ng",
        config: %{}
      })

    %{ws: ws}
  end

  defp new_task(ws, notes \\ nil) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "notes-gate task",
        workspace_id: ws.id,
        issue_type: :task
      })

    {:ok, task} = Ash.update(task, %{status: :in_progress})

    task =
      if notes do
        {:ok, t} = Ash.update(task, %{notes: notes}, action: :update)
        t
      else
        task
      end

    task
  end

  defp start_worker(task, extra_meta) do
    meta =
      Map.merge(
        %{
          # Dispatch stamps issue_type into meta; replicate that here so the
          # worker's task_type? guard routes through the notes gate path.
          issue_type: :task,
          review_spawn: false
        },
        extra_meta
      )

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        # Task-type workers have no worktree; dispatch defaults repo to "unknown".
        repo: "unknown",
        workspace_id: task.workspace_id,
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  describe "notes gate (bd-5lc99r)" do
    test "arb-done with blank notes fails + escalates instead of completing", %{ws: ws} do
      task = new_task(ws)
      # Pin nudge cap to 0 so we hit the structural fail path immediately,
      # without the retry layer spawning a new session.
      pid = start_worker(task, %{notes_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)

      # Must not have completed or routed to any review path.
      refute snap.status == :completed
      refute snap.status == :awaiting_review_gate

      # fail_now/2 stores the failure reason under :failure_reason in meta.
      assert snap.meta.failure_reason == :blank_notes_at_completion
      # park_notes_gate also records the structural why under :notes_gate_detail.
      assert snap.meta.notes_gate_detail == :cap_exhausted

      # Task stays open — the notes gate deliberately does NOT write to the
      # notes field (unlike the commit gate), because polluting notes would
      # let a re-dispatched worker satisfy the gate without producing real
      # findings. The escalation carries the diagnostic instead.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.status == :closed

      # Admiral receives an escalation naming the gate failure.
      escalations = Message.inbox("admiral", workspace_id: ws.id)

      escalation =
        Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == task.id))

      assert escalation
      assert escalation.subject =~ "Notes gate"
    end

    test "arb-done with populated notes completes cleanly", %{ws: ws} do
      task = new_task(ws, "## Findings\n\nResearch complete. Conclusion: viable.")
      pid = start_worker(task, %{notes_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      assert snap.status == :completed
    end

    test "whitespace-only notes are treated as blank", %{ws: ws} do
      task = new_task(ws, "   \n\t  ")
      pid = start_worker(task, %{notes_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      assert Worker.state(pid).meta.failure_reason == :blank_notes_at_completion
    end
  end
end
