defmodule Arbiter.PolecatRunPersistenceTest do
  # DataCase (async: false → shared sandbox) so the polecat process, which
  # runs under the DynamicSupervisor, can reach the same DB connection when
  # it writes / updates the Run row.
  use Arbiter.DataCase, async: false

  alias Arbiter.Polecat
  alias Arbiter.Polecats.Run
  require Ash.Query

  defp runs_for(bead_id) do
    Run
    |> Ash.Query.filter(bead_id == ^bead_id)
    |> Ash.read!()
  end

  test "starting a polecat creates a :running Run row" do
    bead_id = "bd-runstart-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    [run] = runs_for(bead_id)
    assert run.status == :running
    assert run.rig == "arbiter"
    assert run.workspace_id == "ws-runs"
    assert %DateTime{} = run.started_at
    assert run.completed_at == nil
  end

  test "completing a polecat stamps the Run row :completed with output_lines" do
    bead_id = "bd-runcomp-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Polecat.advance(pid, :implement)
    :ok = Polecat.report(pid, :output_lines, ["line one", "line two"])
    :ok = Polecat.report(pid, :exit_status, 0)
    :ok = Polecat.complete(pid, :done)

    [run] = runs_for(bead_id)
    assert run.status == :completed
    assert run.exit_code == 0
    assert run.output_lines == ["line one", "line two"]
    assert %DateTime{} = run.completed_at
  end

  test "claude __claude_session_done__ also persists :completed" do
    bead_id = "bd-runclaude-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Polecat.advance(pid, :run_claude)
    send(pid, {:__claude_session_done__, "arb done"})

    # Wait briefly for the cast-like handle_info to land + write.
    :ok = wait_until(fn -> match?([%{status: :completed}], runs_for(bead_id)) end)

    [run] = runs_for(bead_id)
    assert run.status == :completed
  end

  test "terminate from a non-terminal state finalizes the Run row :completed" do
    # Mirror the REAL acolyte-completion teardown: a claude-driven polecat sits
    # at a non-terminal status (:running) and is torn down by the bead `:close`
    # after-action (StopPolecat -> Polecat.stop -> terminate/2) WITHOUT any
    # explicit Polecat.complete/2 ever firing. Before bd-39q7sk this left the
    # row stuck :running until the next boot reconcile.
    bead_id = "bd-runterm-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: "ws-runs")

    :ok = Polecat.advance(pid, :run_claude)
    :ok = Polecat.report(pid, :output_lines, ["working", "arb done"])
    :ok = Polecat.report(pid, :exit_status, 0)

    [running] = runs_for(bead_id)
    assert running.status == :running
    assert running.completed_at == nil

    # Synchronous stop: GenServer.stop blocks until terminate/2 returns, so the
    # row write has landed by the time this returns.
    :ok = Polecat.stop(pid, :normal)

    [run] = runs_for(bead_id)
    assert run.status == :completed
    assert %DateTime{} = run.completed_at
    assert run.exit_code == 0
    assert run.output_lines == ["working", "arb done"]
  end

  test "terminate after an explicit :completed does not double-write the Run row" do
    # complete_now/2 already stamped the row; terminate/2 must no-op so it does
    # not clobber the completed_at / exit fields written at completion time.
    bead_id = "bd-runterm2-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: "ws-runs")

    :ok = Polecat.advance(pid, :implement)
    :ok = Polecat.report(pid, :exit_status, 0)
    :ok = Polecat.complete(pid, :done)

    [completed] = runs_for(bead_id)
    assert completed.status == :completed
    first_completed_at = completed.completed_at

    :ok = Polecat.stop(pid, :normal)

    [run] = runs_for(bead_id)
    assert run.status == :completed
    assert run.completed_at == first_completed_at
  end

  test "failing a polecat stamps the Run row :failed with failure_reason" do
    bead_id = "bd-runfail-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Polecat.advance(pid, :verify)
    :ok = Polecat.fail(pid, :max_ticks_exceeded)

    [run] = runs_for(bead_id)
    assert run.status == :failed
    assert run.failure_reason == ":max_ticks_exceeded"
    assert %DateTime{} = run.completed_at
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
