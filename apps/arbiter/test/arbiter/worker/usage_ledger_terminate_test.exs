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

  # bd-481sz7: an agy session's ledger row must carry full token accounting
  # (including thinking_tokens), the model threaded onto the session at
  # spawn time (T1 — agy's own stream never names a model), and cost_usd
  # nil with a subscription-not-priced cost_note, never a "model unknown"
  # explanation now that the model is in fact known.
  test "an agy session's ledger row carries thinking_tokens, the pre-resolved model, and no cost" do
    task_id = "bd-ledgeragy-#{System.unique_integer([:positive])}"

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-ledger")

    cwd = System.tmp_dir!()

    result_event =
      Jason.encode!(%{
        "event" => "result",
        "result" => %{
          "status" => "SUCCESS",
          "duration_seconds" => 1.1,
          "usage" => %{
            "input_tokens" => 17529,
            "output_tokens" => 118,
            "thinking_tokens" => 110,
            "cache_read_tokens" => 0,
            "total_tokens" => 17647
          }
        }
      })

    events_path = Path.join(cwd, "agy-events-#{System.unique_integer([:positive])}.jsonl")
    File.write!(events_path, result_event <> "\n")

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", events_path],
        provider: "gemini",
        model: "gemini-3.8-flash-low"
      )

    :ok = wait_until(fn -> events_for(task_id) != [] end)
    :ok = GenServer.stop(pid, :normal)

    assert [event] = events_for(task_id)
    assert event.model == "gemini-3.8-flash-low"
    assert event.tokens_in == 17529
    assert event.tokens_out == 118
    assert event.thinking_tokens == 110
    assert event.cost_usd == nil
    assert event.cost_note =~ "no cost"
  end

  # bd-96mn8i (round 2): a resumed agy conversation observed live carried an
  # `init` event (so the session had a real, provider-confirmed start) but the
  # process was stopped before any `result`/`error` terminal event ever
  # reached the stream — the exact shape of the bug report (worker_stop +
  # worker_resume on a task, `session_id`/`provider` present on the ledger
  # row, every token field NULL). Gemini/agy has no on-disk fallback the way
  # Claude does (`maybe_reconcile_usage_from_disk/3` only reconciles Claude),
  # so the row's tokens correctly stay nil — but it must say WHY, not look
  # like an unhandled gap indistinguishable from a genuinely-zero-cost run.
  test "an agy session stopped before any terminal event still writes an explicitly-unknown row" do
    task_id = "bd-ledgeragy-noterm-#{System.unique_integer([:positive])}"

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-ledger")

    cwd = System.tmp_dir!()

    init_event =
      Jason.encode!(%{
        "event" => "init",
        "conversation_id" => "89a2b784-6bd5-46e6-a971-2178ca58cdcd"
      })

    events_path = Path.join(cwd, "agy-noterm-events-#{System.unique_integer([:positive])}.jsonl")
    # `sleep` keeps the port open (mid-turn) — the child never reaches a
    # terminal event, mirroring the real run stopping mid tool-call.
    File.write!(events_path, init_event <> "\n")

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["sh", "-c", "cat #{events_path}; sleep 5"],
        provider: "gemini",
        model: "gemini-3.8-flash-low"
      )

    :ok =
      wait_until(fn ->
        case Worker.state(pid) do
          %{meta: %{session_id: "89a2b784-6bd5-46e6-a971-2178ca58cdcd"}} -> true
          _ -> false
        end
      end)

    :ok = GenServer.stop(pid, :normal)

    assert [event] = events_for(task_id)
    assert event.provider == "gemini"
    assert event.session_id == "89a2b784-6bd5-46e6-a971-2178ca58cdcd"
    assert event.tokens_in == nil
    assert event.tokens_out == nil
    assert event.cost_usd == nil
    assert event.cost_note =~ "no usage captured"
  end

  # P9 (bd-al9qqe, docs/provider-account-design.md §8): every code path that
  # writes `usage_events.workspace_id` must also write `provider_account_id`.
  test "a task session's ledger row carries the workspace's linked provider_account_id" do
    {:ok, ws} =
      Ash.create(Arbiter.Tasks.Workspace, %{
        name: "pab-worker-#{System.unique_integer([:positive])}"
      })

    {:ok, account} =
      Ash.create(Arbiter.Accounts.ProviderAccount, %{
        provider: :claude,
        slug: "pab-worker-#{System.unique_integer([:positive])}"
      })

    {:ok, _link} =
      Ash.create(Arbiter.Accounts.WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :claude,
        provider_account_id: account.id
      })

    task_id = "bd-ledgeraccount-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: ws.id)

    cwd = System.tmp_dir!()

    result_event =
      Jason.encode!(%{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "result" => "done",
        "total_cost_usd" => 0.1,
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })

    events_path = Path.join(cwd, "account-events-#{System.unique_integer([:positive])}.jsonl")
    File.write!(events_path, result_event <> "\n")

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", events_path],
        provider: "claude"
      )

    :ok = wait_until(fn -> events_for(task_id) != [] end)
    :ok = GenServer.stop(pid, :normal)

    assert [event] = events_for(task_id)
    assert event.workspace_id == ws.id
    assert event.provider == "claude"
    assert event.provider_account_id == account.id
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
