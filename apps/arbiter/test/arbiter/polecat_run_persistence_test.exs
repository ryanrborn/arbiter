defmodule Arbiter.PolecatRunPersistenceTest do
  # DataCase (async: false → shared sandbox) so the polecat process, which
  # runs under the DynamicSupervisor, can reach the same DB connection when
  # it writes / updates the Run row.
  use Arbiter.DataCase, async: false

  alias Arbiter.Polecat
  alias Arbiter.Polecats.Run
  alias Arbiter.Test.StubMerger
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

  test "a polecat that stops while :awaiting_review finalizes its run row :completed" do
    # Mirrors the production gap: the acolyte finished and an MR was opened
    # (lifecycle parked at :awaiting_review), but the process goes away before
    # the Warden drives it to :completed. The terminate/2 backstop must stamp
    # the row :completed so the historical view never shows a stuck :running.
    StubMerger.reset()
    bead_id = "bd-runpark-#{System.unique_integer([:positive])}"

    {:ok, pid} = Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: "ws-runs")

    :ok = Polecat.advance(pid, :implement)
    StubMerger.next_open_ref("!park")

    # Park the Warden far in the future so it never completes the polecat: the
    # only thing that can finalize the row is the terminate backstop.
    {:ok, "!park"} =
      Polecat.open_mr(pid, "feature/parked", "Parked", "", %{
        adapter: StubMerger,
        workspace: nil,
        interval_ms: 1_000_000,
        initial_delay_ms: 1_000_000
      })

    assert Polecat.state(pid).status == :awaiting_review
    assert [%{status: :running}] = runs_for(bead_id)

    # Process goes away (clean node shutdown / stop) before the Warden polls.
    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

    [run] = runs_for(bead_id)
    assert run.status == :completed
    assert %DateTime{} = run.completed_at
  end

  test "a polecat stopped mid-work (:running) is left for the boot reconciler" do
    # The flip side of the backstop: a process dying genuinely mid-work was
    # interrupted, not completed. We must NOT mark it :completed — that's the
    # boot reconciler's job (it sweeps it to :failed on next start).
    bead_id = "bd-runmid-#{System.unique_integer([:positive])}"

    {:ok, pid} = Polecat.start(bead_id: bead_id, rig: "arbiter", workspace_id: "ws-runs")
    :ok = Polecat.advance(pid, :implement)
    assert Polecat.state(pid).status == :running

    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

    [run] = runs_for(bead_id)
    assert run.status == :running
    assert run.completed_at == nil
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
