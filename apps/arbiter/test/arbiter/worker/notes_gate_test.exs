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

  defp tmp_dir!(tag) do
    dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Drive a REAL session port that does the agent's work and exits cleanly
  # (status 0) WITHOUT ever printing `arb done` — the exact wrap-up failure mode
  # from bd-2da6ay. The port exit (not a synthetic done message) is what routes
  # the worker through the deferred stop check.
  defp exit_clean_without_done(pid, tag) do
    cwd = tmp_dir!(tag)

    {:ok, _port} =
      Arbiter.Worker.ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["sh", "-c", "echo 'findings recorded; wrapping up'; exit 0"]
      )

    :ok
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

      # Coordinator receives an escalation naming the gate failure.
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

  describe "exit-without-done finalization (bd-2da6ay)" do
    # The wrap-up failure mode: a task-type worker reaches the end of its work
    # and the subprocess exits cleanly (status 0) but the agent never printed
    # `arb done`. Before this fix the worker routed into the bd-t9uq25 resume
    # loop, which only replayed the identical clean exit — burning Opus until
    # the resume cap was exhausted, then failing. Now the worker finalizes
    # through the notes gate the same way `arb done` does.

    test "clean exit with populated notes completes via the notes gate (no resume loop)",
         %{ws: ws} do
      task = new_task(ws, "## Findings\n\nInvestigation complete. Conclusion: viable.")
      pid = start_worker(task, %{notes_nudge_cap: 0})

      :ok = exit_clean_without_done(pid, "ng-exit-populated")

      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      assert snap.status == :completed
      # It completed straight through the notes gate — never down the resume
      # path (no resume attempt was ever recorded) and never failed.
      refute Map.has_key?(snap.meta, :resume_attempts)
      refute Map.has_key?(snap.meta, :stop_reason)
    end

    test "clean exit with blank notes fails + escalates instead of looping on resume",
         %{ws: ws} do
      task = new_task(ws)
      # Pin the nudge cap to 0 so we hit the structural park path immediately,
      # without respawning a session.
      pid = start_worker(task, %{notes_nudge_cap: 0})

      :ok = exit_clean_without_done(pid, "ng-exit-blank")

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      # Failed via the notes gate (concrete cause), NOT via the resume/stop path.
      assert snap.meta.failure_reason == :blank_notes_at_completion
      assert snap.meta.notes_gate_detail == :cap_exhausted
      refute Map.has_key?(snap.meta, :resume_attempts)

      # Task stays open — the notes gate never pollutes the notes field.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.status == :closed

      # Coordinator receives the notes-gate escalation naming the failure.
      escalation =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.find(&(&1.kind == :escalation and &1.directive_ref == task.id))

      assert escalation
      assert escalation.subject =~ "Notes gate"
    end
  end
end
