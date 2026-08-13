defmodule Arbiter.Worker.UsageLedgerTerminateTest do
  # DataCase (async: false → shared sandbox) so the worker process, which runs
  # under the DynamicSupervisor, can reach the same DB connection when it
  # writes the ledger row.
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Usage.Event
  require Ash.Query

  defp events_for(task_id) do
    Event
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  # bd-cryhwk: the coordinator's `:close` after-action stops the worker
  # (`Worker.stop/2` -> `GenServer.stop/2` -> `terminate/2`) as soon as it
  # sees "arb done" on stdout — it does not wait for the child process to
  # actually exit. If the underlying Claude CLI process is still alive when
  # that stop lands, the port's `{:exit_status, _}` message never arrives (the
  # port is torn down with the owning process), so `record_usage_event/3` —
  # previously only wired to that message — never fires and the session's
  # spend is dropped from `Arbiter.Usage.Event` entirely: not a zero-cost row,
  # no row at all. This reproduces that race directly: the fixture process
  # prints its terminal `result` event (with a real cost figure) and then
  # sleeps well past when the test stops the worker, so `exit_status` is
  # guaranteed not to have arrived yet.
  test "a session whose port exit_status races the worker's own stop still writes a ledger row" do
    task_id = "bd-ledgerrace-#{System.unique_integer([:positive])}"

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-ledger")

    cwd = System.tmp_dir!()

    result_event =
      Jason.encode!(%{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "result" => "done",
        "total_cost_usd" => 0.741102,
        "duration_ms" => 93_000,
        "usage" => %{
          "input_tokens" => 1234,
          "output_tokens" => 567
        }
      })

    events_path = Path.join(cwd, "race-events-#{System.unique_integer([:positive])}.jsonl")
    File.write!(events_path, result_event <> "\n")

    # Print the result line, then sit well past this test's own timeout so
    # `exit_status` genuinely cannot have arrived before we stop the worker.
    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["sh", "-c", "cat #{events_path}; sleep 5"]
      )

    # Wait for the result event to actually land on the session (proving the
    # stream data — not just the exit — was processed) before racing ahead.
    :ok =
      wait_until(fn ->
        case Worker.state(pid) do
          %{meta: %{result_subtype: "success"}} -> true
          _ -> false
        end
      end)

    # Simulate the coordinator's close-triggered stop: the child is still
    # sleeping, so exit_status has not been delivered.
    :ok = GenServer.stop(pid, :normal)

    [event] = events_for(task_id)
    assert event.cost_usd == 0.741102
    assert event.tokens_in == 1234
    assert event.tokens_out == 567
  end

  test "a session whose exit was already processed is not double-recorded on terminate" do
    task_id = "bd-ledgernorace-#{System.unique_integer([:positive])}"

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-ledger")

    cwd = System.tmp_dir!()

    result_event =
      Jason.encode!(%{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "result" => "done",
        "total_cost_usd" => 0.5,
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      })

    events_path = Path.join(cwd, "norace-events-#{System.unique_integer([:positive])}.jsonl")
    File.write!(events_path, result_event <> "\n")

    {:ok, _port} =
      ClaudeSession.start(owner: pid, worktree_path: cwd, command: ["cat", events_path])

    # `cat` exits immediately after writing its output — wait for the normal
    # exit_status path to actually record the row before tearing down.
    :ok = wait_until(fn -> events_for(task_id) != [] end)

    :ok = GenServer.stop(pid, :normal)

    assert [_single] = events_for(task_id)
  end

  defp wait_until(fun, timeout_ms \\ 2000, step_ms \\ 20) do
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
