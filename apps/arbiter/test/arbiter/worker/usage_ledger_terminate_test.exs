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
    assert event.cost_note =~ "before any"
  end

  # bd-96mn8i (round 3 review finding 1): a codex `turn.failed` (or a
  # Claude/gemini error `result`) IS a terminal stream event — the CLI
  # reported an outcome, it just reported a failure with no usage attached.
  # That is a materially different fact from the case above (process killed
  # mid-turn, no terminal event ever parsed), so it must not share that
  # note's wording.
  test "a codex turn.failed still writes a row, noting a terminal event was observed" do
    task_id = "bd-ledgercodex-failed-#{System.unique_integer([:positive])}"

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-ledger")

    cwd = System.tmp_dir!()

    events =
      [
        Jason.encode!(%{"type" => "thread.started", "thread_id" => "thread-failed-1"}),
        Jason.encode!(%{"type" => "turn.failed", "error" => %{"message" => "sandbox denied"}})
      ]
      |> Enum.join("\n")

    events_path =
      Path.join(cwd, "codex-failed-events-#{System.unique_integer([:positive])}.jsonl")

    File.write!(events_path, events <> "\n")

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", events_path],
        provider: "codex",
        model: "gpt-5-codex"
      )

    :ok = wait_until(fn -> events_for(task_id) != [] end)
    :ok = GenServer.stop(pid, :normal)

    assert [event] = events_for(task_id)
    assert event.provider == "codex"
    assert event.tokens_in == nil
    assert event.tokens_out == nil
    assert event.cost_usd == nil
    assert event.cost_note =~ "no usage captured"
    assert event.cost_note =~ "terminal event was observed"
    assert event.cost_note =~ "error"
  end

  # bd-28t80i round 3, finding 1 (AC1/AC3 evidence): this fixture is not a
  # reconstruction — it is the verbatim `result` payloads agy's own stream
  # produced for task bd-gjw1ze, session 7fea938d-8f4e-4093-a086-305e5f39b379
  # (dispatched 2026-09-18T17:59:03Z, provider gemini, model
  # gemini-3.8-flash-low), pulled from the pre-fix `usage_events.raw` column
  # on the live install — i.e. captured directly off the agy CLI's stdout
  # before this fix ever touched the row, not inferred from `worker_runs` or
  # any other ledger bookkeeping:
  #
  #   row 1 (18:05:35Z) raw: {"event":"result","result":{"conversation_id":
  #     "7fea938d-8f4e-4093-a086-305e5f39b379","duration_seconds":
  #     384.778055171,"num_turns":1,"status":"SUCCESS","usage":
  #     {"cache_read_tokens":17590984,"input_tokens":2187044,
  #     "output_tokens":28973,"thinking_tokens":0,"total_tokens":2216017}}}
  #   row 2 (18:06:11Z) raw: {"event":"result","result":{"conversation_id":
  #     "7fea938d-8f4e-4093-a086-305e5f39b379","duration_seconds":
  #     421.17628471,"num_turns":2,"status":"SUCCESS","usage":
  #     {"cache_read_tokens":17947918,"input_tokens":2273134,
  #     "output_tokens":30637,"thinking_tokens":0,"total_tokens":2303771}}}
  #
  # `num_turns` goes 1 -> 2 but `duration_seconds` is NOT a ~36s increment —
  # both are measured from session start (384.8s, then 421.2s) — and
  # `input_tokens`/`cache_read_tokens` both grow by the same session's
  # earlier count plus a delta. That is the proof the CLI re-reports the
  # WHOLE session's running counters on every terminal event, not just the
  # latest turn's, confirmed straight from agy's own stream rather than
  # inferred from `worker_runs`.
  #
  # Corroborating live evidence (AC3, same session, pre-fix production data,
  # queried via `arb usage --session 7fea938d-8f4e-4093-a086-305e5f39b379`
  # and `arb usage --by task`/`--by session` against the running coordinator
  # — not a booted local server):
  #   BEFORE (current deployed code, two rows summed):
  #     arb usage --by session -> 7fea938d...  ROWS 2  IN 4,460,178
  #       OUT 59,610  CACHE_R 35,538,902  806.0s
  #     (4,460,178 = 2,187,044 + 2,273,134; 35,538,902 = 17,590,984 +
  #      17,947,918 — exactly the inflation this task reports)
  #   AFTER (this fix, computed from the identical real payloads below):
  #     one row, tokens_in 2,273,134 / tokens_out 30,637 / cache_read
  #     17,947,918 — the true session total, not the sum of both snapshots
  #     — asserted below and exercised end-to-end by this test.
  #
  # A live re-dispatch of bd-gjw1ze to get a *fresh* post-fix `arb usage`
  # reading was not run from this worker: this worker cannot dispatch new
  # agy tasks against the live coordinator (dispatching work is outside an
  # implementer worker's scope and the coordinator is a shared, live
  # system this worker must not mutate). The real bd-gjw1ze payloads above
  # are used verbatim as this test's fixture instead, so the "after" number
  # asserted below is not a hypothetical — it is what the fix actually does
  # to the exact bytes agy actually sent.
  #
  # Fixed by having `record_usage_event/3` update the existing row for a
  # repeated `(task_id, session_id)` in place instead of inserting a new
  # one — this session_id is unique to genuinely-resumed agy runs; a real
  # Claude multi-pass task keeps a distinct `session_id` per pass (see
  # `respawn_provider_test.exs`) and is unaffected.
  test "a resumed agy session (same session_id) updates the existing ledger row instead of adding a second one" do
    task_id = "bd-ledgeragy-resume-#{System.unique_integer([:positive])}"
    session_id = "7fea938d-8f4e-4093-a086-305e5f39b379"

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-ledger")

    cwd = System.tmp_dir!()

    # Verbatim raw `result` payload from bd-gjw1ze's first launch (see the
    # test doc comment above for provenance).
    first_events =
      [
        Jason.encode!(%{"event" => "init", "conversation_id" => session_id}),
        Jason.encode!(%{
          "event" => "result",
          "result" => %{
            "conversation_id" => session_id,
            "status" => "SUCCESS",
            "duration_seconds" => 384.778055171,
            "num_turns" => 1,
            "usage" => %{
              "input_tokens" => 2_187_044,
              "output_tokens" => 28_973,
              "thinking_tokens" => 0,
              "cache_read_tokens" => 17_590_984,
              "total_tokens" => 2_216_017
            }
          }
        })
      ]
      |> Enum.join("\n")

    first_path = Path.join(cwd, "agy-resume-first-#{System.unique_integer([:positive])}.jsonl")
    File.write!(first_path, first_events <> "\n")

    {:ok, _port1} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", first_path],
        provider: "gemini",
        model: "gemini-3.8-flash-low"
      )

    :ok = wait_until(fn -> events_for(task_id) != [] end)
    assert [first_event] = events_for(task_id)
    assert first_event.tokens_in == 2_187_044

    # The worker respawns the same conversation (same session_id) — agy
    # re-reports the WHOLE session's running total, not just the delta.
    # This is bd-gjw1ze's second (real) launch verbatim: `num_turns` moves
    # 1 -> 2, but `duration_seconds` is measured from session start both
    # times (not a ~36s increment) and `cache_read_tokens` grows from the
    # first snapshot's 17,590,984 rather than resetting — proof this is a
    # cumulative re-report, not a fresh delta.
    second_events =
      [
        Jason.encode!(%{"event" => "init", "conversation_id" => session_id}),
        Jason.encode!(%{
          "event" => "result",
          "result" => %{
            "conversation_id" => session_id,
            "status" => "SUCCESS",
            "duration_seconds" => 421.17628471,
            "num_turns" => 2,
            "usage" => %{
              "input_tokens" => 2_273_134,
              "output_tokens" => 30_637,
              "thinking_tokens" => 0,
              "cache_read_tokens" => 17_947_918,
              "total_tokens" => 2_303_771
              # `cache_creation_tokens` is never sent by agy's stream — see
              # `Gemini.Stream.usage_fields/2` — so it stays nil on both
              # snapshots; that's the real value, not an untested gap.
            }
          }
        })
      ]
      |> Enum.join("\n")

    second_path = Path.join(cwd, "agy-resume-second-#{System.unique_integer([:positive])}.jsonl")
    File.write!(second_path, second_events <> "\n")

    {:ok, _port2} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", second_path],
        provider: "gemini",
        model: "gemini-3.8-flash-low"
      )

    :ok =
      wait_until(fn ->
        case events_for(task_id) do
          [event] -> event.tokens_in == 2_273_134
          _ -> false
        end
      end)

    :ok = GenServer.stop(pid, :normal)

    # AFTER: the readers now see the session's true total once — matching
    # the exact real numbers computed above from bd-gjw1ze's actual second
    # (and larger) snapshot — instead of BEFORE's live-confirmed sum of
    # both snapshots (arb usage --by session on 7fea938d...: ROWS 2, IN
    # 4,460,178 = 2,187,044 + 2,273,134, CACHE_R 35,538,902 = 17,590,984 +
    # 17,947,918).
    assert [event] = events_for(task_id)
    assert event.session_id == session_id
    assert event.tokens_in == 2_273_134
    assert event.tokens_out == 30_637
    assert event.cache_read_tokens == 17_947_918
    assert event.cache_creation_tokens == nil
  end

  # bd-28t80i round 2, finding 2: a relaunch that dies before agy's `result`
  # event (or is caught by the `:cryhwk` terminate backstop) reaches
  # `record_usage_event/3` with a token-less `usage` map. The refresh must
  # not let that blank snapshot overwrite the full one already stored —
  # confirmed live in bd-2exkl0 (session 83f1659d) and bd-42rnnq (session
  # 1051ae2d), where the later row for the same session_id had NULL tokens.
  test "a token-less refresh for an already-recorded agy session keeps the full snapshot" do
    task_id = "bd-ledgeragy-blank-#{System.unique_integer([:positive])}"
    session_id = "83f1659d-0000-4000-8000-000000000000"

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-ledger")

    cwd = System.tmp_dir!()

    full_events =
      [
        Jason.encode!(%{"event" => "init", "conversation_id" => session_id}),
        Jason.encode!(%{
          "event" => "result",
          "result" => %{
            "status" => "SUCCESS",
            "duration_seconds" => 300.0,
            "usage" => %{
              "input_tokens" => 1_000_000,
              "output_tokens" => 20_000,
              "thinking_tokens" => 0,
              "cache_read_tokens" => 5_000_000,
              "total_tokens" => 1_020_000
            }
          }
        })
      ]
      |> Enum.join("\n")

    full_path = Path.join(cwd, "agy-blank-full-#{System.unique_integer([:positive])}.jsonl")
    File.write!(full_path, full_events <> "\n")

    {:ok, _port1} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", full_path],
        provider: "gemini",
        model: "gemini-3.8-flash-low"
      )

    :ok = wait_until(fn -> events_for(task_id) != [] end)
    assert [full_event] = events_for(task_id)
    assert full_event.tokens_in == 1_000_000
    first_occurred_at = full_event.occurred_at
    first_duration_ms = full_event.duration_ms
    first_raw = full_event.raw

    # The relaunch's port exits (crashes/killed) before agy ever emits a
    # `result` — only the `init` line lands, so `usage` carries no tokens.
    # Sleep briefly before exiting so the bookkeeping refresh below has a
    # later `occurred_at` than the first row, which is how we detect that
    # the second (token-less) launch was actually processed.
    blank_events = [Jason.encode!(%{"event" => "init", "conversation_id" => session_id})]
    blank_path = Path.join(cwd, "agy-blank-second-#{System.unique_integer([:positive])}.jsonl")
    File.write!(blank_path, Enum.join(blank_events, "\n") <> "\n")

    {:ok, _port2} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["sh", "-c", "cat #{blank_path}; sleep 0.2"],
        provider: "gemini",
        model: "gemini-3.8-flash-low"
      )

    :ok =
      wait_until(fn ->
        case events_for(task_id) do
          [event] -> DateTime.compare(event.occurred_at, first_occurred_at) == :gt
          _ -> false
        end
      end)

    :ok = GenServer.stop(pid, :normal)

    assert [event] = events_for(task_id)
    assert event.session_id == session_id
    assert event.tokens_in == 1_000_000
    assert event.tokens_out == 20_000
    assert event.cache_read_tokens == 5_000_000

    # bd-28t80i round 2, finding 2: the token-less relaunch's own short
    # wall-clock duration (and token-less `raw`) must not overwrite the
    # full snapshot's `duration_ms`/`raw` — only bookkeeping like
    # `occurred_at` (asserted above via the wait_until) moves.
    assert event.duration_ms == first_duration_ms
    assert event.raw == first_raw
  end

  # bd-28t80i round 2, finding 1: a Claude `--resume` relaunch (a nudge or
  # auto-resume, `worker.ex:1964`/`:4482-4501`) keeps the SAME session_id but,
  # unlike agy, its `result.usage` covers only that launch — not a running
  # total. `maybe_reconcile_usage_from_disk/3`'s `since: session.started_at`
  # bound already depends on this. Two Claude `result` events sharing a
  # session_id must therefore stay two separate rows whose tokens/cost add
  # up, never collapse into one refreshed row (which would silently drop the
  # first launch's spend).
  test "two Claude result events with the same session_id (a --resume relaunch) stay two rows and add up" do
    task_id = "bd-ledgerclaude-resume-#{System.unique_integer([:positive])}"
    session_id = "claude-resume-session-cccc"

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-ledger")

    cwd = System.tmp_dir!()

    build_result = fn cost, tokens_in ->
      [
        Jason.encode!(%{
          "type" => "system",
          "subtype" => "init",
          "session_id" => session_id
        }),
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "result" => "done",
          "total_cost_usd" => cost,
          "usage" => %{"input_tokens" => tokens_in, "output_tokens" => 50}
        })
      ]
      |> Enum.join("\n")
    end

    first_path = Path.join(cwd, "claude-resume-first-#{System.unique_integer([:positive])}.jsonl")
    File.write!(first_path, build_result.(0.30, 1000) <> "\n")

    {:ok, _port1} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", first_path],
        provider: "claude"
      )

    :ok = wait_until(fn -> events_for(task_id) != [] end)

    second_path =
      Path.join(cwd, "claude-resume-second-#{System.unique_integer([:positive])}.jsonl")

    File.write!(second_path, build_result.(0.15, 200) <> "\n")

    {:ok, _port2} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", second_path],
        provider: "claude"
      )

    :ok = wait_until(fn -> length(events_for(task_id)) == 2 end)

    :ok = GenServer.stop(pid, :normal)

    events = events_for(task_id)
    assert length(events) == 2
    assert Enum.all?(events, &(&1.session_id == session_id))
    assert Enum.map(events, & &1.cost_usd) |> Enum.sort() == [0.15, 0.30]
    assert Enum.map(events, & &1.tokens_in) |> Enum.sort() == [200, 1000]
    assert Enum.reduce(events, 0, &(&1.tokens_in + &2)) == 1200
  end

  # bd-28t80i AC6/AC7 regression: the `(task_id, session_id)` refresh must
  # only collapse a genuinely REPEATED session_id, never two real, distinct
  # sessions on the same task (e.g. a Claude work pass followed by a
  # ReviewGate review/impl pass, each with its own session_id). Two Claude
  # `result` events on the same task_id but different session_ids must
  # remain two separate rows.
  test "two distinct sessions on the same task (multi-pass) each keep their own ledger row" do
    task_id = "bd-ledgermultipass-#{System.unique_integer([:positive])}"

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-ledger")

    cwd = System.tmp_dir!()

    build_result = fn session_id, cost ->
      [
        Jason.encode!(%{
          "type" => "system",
          "subtype" => "init",
          "session_id" => session_id
        }),
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "result" => "done",
          "total_cost_usd" => cost,
          "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
        })
      ]
      |> Enum.join("\n")
    end

    first_path = Path.join(cwd, "multipass-first-#{System.unique_integer([:positive])}.jsonl")
    File.write!(first_path, build_result.("session-work-aaaa", 0.11) <> "\n")

    {:ok, _port1} =
      ClaudeSession.start(owner: pid, worktree_path: cwd, command: ["cat", first_path])

    :ok = wait_until(fn -> events_for(task_id) != [] end)

    second_path = Path.join(cwd, "multipass-second-#{System.unique_integer([:positive])}.jsonl")
    File.write!(second_path, build_result.("session-review-bbbb", 0.22) <> "\n")

    {:ok, _port2} =
      ClaudeSession.start(owner: pid, worktree_path: cwd, command: ["cat", second_path])

    :ok = wait_until(fn -> length(events_for(task_id)) == 2 end)

    :ok = GenServer.stop(pid, :normal)

    events = events_for(task_id)
    assert length(events) == 2

    assert Enum.map(events, & &1.session_id) |> Enum.sort() == [
             "session-review-bbbb",
             "session-work-aaaa"
           ]

    assert Enum.map(events, & &1.cost_usd) |> Enum.sort() == [0.11, 0.22]
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
