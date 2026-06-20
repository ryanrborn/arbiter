defmodule Arbiter.WorkerRunPersistenceTest do
  # DataCase (async: false → shared sandbox) so the worker process, which
  # runs under the DynamicSupervisor, can reach the same DB connection when
  # it writes / updates the Run row.
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Workers.Run
  require Ash.Query

  @fixture Path.expand("../fixtures/echo_with_done.sh", __DIR__)

  defp runs_for(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  test "starting a worker creates a :running Run row" do
    task_id = "bd-runstart-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    [run] = runs_for(task_id)
    assert run.status == :running
    assert run.repo == "arbiter"
    assert run.workspace_id == "ws-runs"
    assert %DateTime{} = run.started_at
    assert run.completed_at == nil
  end

  test "completing a worker stamps the Run row :completed with output_lines" do
    task_id = "bd-runcomp-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.report(pid, :output_lines, ["line one", "line two"])
    :ok = Worker.report(pid, :exit_status, 0)
    :ok = Worker.complete(pid, :done)

    [run] = runs_for(task_id)
    assert run.status == :completed
    assert run.exit_code == 0
    assert run.output_lines == ["line one", "line two"]
    assert %DateTime{} = run.completed_at
  end

  test "claude __claude_session_done__ also persists :completed" do
    task_id = "bd-runclaude-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :run_claude)
    send(pid, {:__claude_session_done__, "arb done"})

    # Wait briefly for the cast-like handle_info to land + write.
    :ok = wait_until(fn -> match?([%{status: :completed}], runs_for(task_id)) end)

    [run] = runs_for(task_id)
    assert run.status == :completed
  end

  test "terminate from a non-terminal state finalizes the Run row :completed" do
    # Mirror the REAL worker-completion teardown: a claude-driven worker sits
    # at a non-terminal status (:running) and is torn down by the task `:close`
    # after-action (StopWorker -> Worker.stop -> terminate/2) WITHOUT any
    # explicit Worker.complete/2 ever firing. Before bd-39q7sk this left the
    # row stuck :running until the next boot reconcile.
    task_id = "bd-runterm-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    :ok = Worker.advance(pid, :run_claude)
    :ok = Worker.report(pid, :output_lines, ["working", "arb done"])
    :ok = Worker.report(pid, :exit_status, 0)

    [running] = runs_for(task_id)
    assert running.status == :running
    assert running.completed_at == nil

    # Synchronous stop: GenServer.stop blocks until terminate/2 returns, so the
    # row write has landed by the time this returns.
    :ok = Worker.stop(pid, :normal)

    [run] = runs_for(task_id)
    assert run.status == :completed
    assert %DateTime{} = run.completed_at
    assert run.exit_code == 0
    assert run.output_lines == ["working", "arb done"]
  end

  test "terminate after an explicit :completed does not double-write the Run row" do
    # complete_now/2 already stamped the row; terminate/2 must no-op so it does
    # not clobber the completed_at / exit fields written at completion time.
    task_id = "bd-runterm2-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.report(pid, :exit_status, 0)
    :ok = Worker.complete(pid, :done)

    [completed] = runs_for(task_id)
    assert completed.status == :completed
    first_completed_at = completed.completed_at

    :ok = Worker.stop(pid, :normal)

    [run] = runs_for(task_id)
    assert run.status == :completed
    assert run.completed_at == first_completed_at
  end

  test "failing a worker stamps the Run row :failed with failure_reason" do
    task_id = "bd-runfail-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :verify)
    :ok = Worker.fail(pid, :max_ticks_exceeded)

    [run] = runs_for(task_id)
    assert run.status == :failed
    assert run.failure_reason == ":max_ticks_exceeded"
    assert %DateTime{} = run.completed_at
  end

  test "ClaudeSession output lines flow end-to-end into the Run row on completion" do
    # Exercises the full path from port data through the worker's session
    # tracking, sync_session_meta, and record_run_finished into the DB, so that
    # `arb worker show <task-id>` on a closed task shows real output.
    task_id = "bd-sessionlines-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: System.tmp_dir!(),
        command: [@fixture]
      )

    # Wait for the fixture's "arb done" to land and the Run row to be stamped.
    :ok = wait_until(fn -> match?([%{status: :completed}], runs_for(task_id)) end, 2000)

    [run] = runs_for(task_id)
    assert run.status == :completed
    assert %DateTime{} = run.completed_at
    # The fixture emits these lines; they must survive into the DB row.
    assert "doing important work" in run.output_lines
    assert "arb done" in run.output_lines
    # Lines appear oldest-first, so "doing important work" precedes "arb done".
    assert Enum.find_index(run.output_lines, &(&1 == "doing important work")) <
             Enum.find_index(run.output_lines, &(&1 == "arb done"))
  end

  test "output_lines capped to last #{500} lines when session is very chatty" do
    # Verifies that a session producing more than @max_output_lines (500) lines
    # only persists the last 500 rather than bloating the row indefinitely.
    task_id = "bd-linesclip-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    # Inject 600 lines directly via report/3 (same mechanism sync_session_meta
    # uses) so we don't need a subprocess fixture that produces 600+ lines.
    lines = Enum.map(1..600, &"line #{&1}")
    :ok = Worker.advance(pid, :implement)
    :ok = Worker.report(pid, :output_lines, lines)
    :ok = Worker.complete(pid, :done)

    [run] = runs_for(task_id)
    assert length(run.output_lines) == 500
    # The LAST 500 lines (101–600) should be retained, not the first 500.
    assert "line 101" in run.output_lines
    assert "line 600" in run.output_lines
    refute "line 100" in run.output_lines
  end

  defp wait_until(fun, timeout_ms \\ 500, step_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline, step_ms)
  end

  defp do_wait(fun, deadline, step_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until/3 timed out")
      else
        Process.sleep(step_ms)
        do_wait(fun, deadline, step_ms)
      end
    end
  end
end
