defmodule Arbiter.Usage.LiveSpendTest do
  @moduledoc """
  bd-8vnuy3: a running worker's spend, read live off its session JSONL and
  composed with the settled ledger without ever counting a pass twice.

  Every test hands `LiveSpend` its worker snapshots through `:workers` — the
  same shape `Arbiter.Worker.list_children/0` returns — so the liveness,
  project-dir and attribution rules are exercised without spawning an agent.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Usage.Event
  alias Arbiter.Usage.LiveSpend

  # claude-sonnet-5 is $10 per MTok out, so 100_000 output tokens is $1.00.
  @model "claude-sonnet-5"
  @dollar 100_000

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "live-spend-#{System.unique_integer([:positive])}",
        prefix: "ls#{System.unique_integer([:positive])}"
      })

    root =
      Path.join(System.tmp_dir!(), "live-spend-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    now = DateTime.utc_now()

    %{
      ws: ws,
      config_dir: Path.join(root, "claude"),
      cwd: Path.join(root, "worktree"),
      now: now,
      started_at: DateTime.add(now, -600, :second)
    }
  end

  defp task_id, do: "ls-#{System.unique_integer([:positive])}"

  # A worker snapshot as `Worker.list_children/0` returns it.
  defp worker(ctx, task_id, overrides \\ %{}) do
    meta =
      Map.merge(
        %{config_dir: ctx.config_dir, cwd: ctx.cwd, provider: "claude"},
        Map.get(overrides, :meta, %{})
      )

    %{
      task_id: task_id,
      agent_live: Map.get(overrides, :agent_live, true),
      started_at: Map.get(overrides, :started_at, ctx.started_at),
      status: :running,
      meta: meta
    }
  end

  # One assistant turn per `{seconds_before_now, dollars}`.
  defp session!(ctx, session_id, turns, opts \\ []) do
    dir = Path.join([ctx.config_dir, "projects", ClaudeSessionFile.project_slug(ctx.cwd)])
    File.mkdir_p!(dir)
    path = Path.join(dir, session_id <> ".jsonl")

    lines =
      Enum.map(turns, fn {ago, dollars} ->
        ts = ctx.now |> DateTime.add(-ago, :second) |> DateTime.to_iso8601()

        Jason.encode!(%{
          "type" => "assistant",
          "sessionId" => session_id,
          "timestamp" => ts,
          "message" => %{
            "id" => "msg-#{session_id}-#{ago}",
            "model" => Keyword.get(opts, :model, @model),
            "usage" => %{"input_tokens" => 0, "output_tokens" => round(dollars * @dollar)}
          }
        })
      end)

    File.write!(path, Enum.join(lines, "\n") <> "\n" <> Keyword.get(opts, :tail, ""))
    path
  end

  defp settle!(ctx, task_id, attrs) do
    base = %{
      task_id: task_id,
      base_task_id: Arbiter.Worker.ReviewGate.base_task_id(task_id),
      source: :task,
      step: :work,
      role: "base",
      workspace_id: ctx.ws.id,
      occurred_at: ctx.now
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  describe "a worker mid-pass" do
    test "its unsettled turns are read off the session file, on top of the ledger", ctx do
      id = task_id()
      settle!(ctx, id, %{cost_usd: 2.0, session_id: "earlier", occurred_at: ctx.started_at})
      session!(ctx, "sid-live", [{300, 1.0}, {200, 0.5}])

      spend = LiveSpend.for_task(id, workers: [worker(ctx, id)])

      assert spend.settled_usd == 2.0
      assert spend.live_usd == 1.5
      assert spend.total_usd == 3.5
      assert spend.total_usd > spend.settled_usd
      assert spend.live?
      refute spend.degraded?
      refute spend.unpriced?
    end

    test "a reviewer or fix round folds into the base task's figure", ctx do
      id = task_id()
      session!(ctx, "sid-review", [{100, 1.25}])

      spend = LiveSpend.for_task(id, workers: [worker(ctx, id <> "#review#r2")])

      assert spend.live_usd == 1.25
      assert spend.total_usd == 1.25
    end

    test "no live agent means no live figure, even with a recent unsettled file", ctx do
      id = task_id()
      settle!(ctx, id, %{cost_usd: 2.0})
      session!(ctx, "sid-parked", [{100, 9.0}])

      # Parked at awaiting_review: the GenServer (and its `running` Run row)
      # outlives the agent session. Only an open port is in flight.
      spend = LiveSpend.for_task(id, workers: [worker(ctx, id, %{agent_live: false})])

      assert spend.total_usd == 2.0
      assert spend.live_usd == 0.0
      refute spend.live?
    end

    test "no workers at all is the settled figure, and a task that spent nothing is 0.0",
         ctx do
      id = task_id()
      settle!(ctx, id, %{cost_usd: 4.25})

      assert %{total_usd: 4.25, live?: false} = LiveSpend.for_task(id, workers: [])
      assert %{total_usd: +0.0, live?: false} = LiveSpend.for_task(task_id(), workers: [])
    end
  end

  describe "never double-counted" do
    test "the total does not move when a pass ends and writes its ledger row", ctx do
      id = task_id()
      # A finished pass: its file still sits in the worktree's project dir.
      session!(ctx, "sid-done", [{500, 3.0}])
      settle!(ctx, id, %{cost_usd: 3.0, session_id: "sid-done", occurred_at: add(ctx, -450)})
      # …and the live one.
      session!(ctx, "sid-now", [{300, 1.0}, {100, 1.0}])

      during = LiveSpend.for_task(id, workers: [worker(ctx, id)])
      assert during.settled_usd == 3.0
      assert during.live_usd == 2.0
      assert during.total_usd == 5.0

      # The live pass ends: its result lands in the ledger. Same moment, same
      # files — the pass must now be counted once, from the ledger.
      settle!(ctx, id, %{cost_usd: 2.0, session_id: "sid-now", occurred_at: add(ctx, -50)})

      after_end = LiveSpend.for_task(id, workers: [worker(ctx, id)])
      assert after_end.settled_usd == 5.0
      assert after_end.live_usd == 0.0
      assert after_end.total_usd == during.total_usd
    end

    test "a resumed session counts only the turns after its last ledger row", ctx do
      id = task_id()
      # `--resume` / a nudge relaunch appends to the same <sid>.jsonl.
      session!(ctx, "sid-resumed", [{500, 3.0}, {100, 0.75}])
      settle!(ctx, id, %{cost_usd: 3.0, session_id: "sid-resumed", occurred_at: add(ctx, -400)})

      spend = LiveSpend.for_task(id, workers: [worker(ctx, id, %{started_at: add(ctx, -900)})])

      assert spend.live_usd == 0.75
      assert spend.total_usd == 3.75
    end

    test "turns from before the live worker started are never live", ctx do
      id = task_id()
      session!(ctx, "sid-old", [{700, 6.0}, {100, 1.0}])

      spend = LiveSpend.for_task(id, workers: [worker(ctx, id)])

      # started_at is 600s ago: the 700s-old turn belongs to someone earlier.
      assert spend.live_usd == 1.0
    end
  end

  describe "keyed by the worktree's project dir, not worker_runs" do
    test "finds a session no run row and no worker meta knows about (the 1aaccf48 shape)",
         ctx do
      id = task_id()
      # The worker's meta still names the session it started; the CLI rolled
      # over to a new id in the same project dir.
      session!(ctx, "sid-known", [{400, 1.0}])
      session!(ctx, "1aaccf48-unknown", [{200, 2.0}])

      spend =
        LiveSpend.for_task(id,
          workers: [worker(ctx, id, %{meta: %{session_id: "sid-known"}})]
        )

      assert spend.live_usd == 3.0
    end

    test "skips a file the ledger attributes to another task", ctx do
      id = task_id()
      other = task_id()
      session!(ctx, "sid-mine", [{200, 1.0}])
      session!(ctx, "sid-theirs", [{200, 4.0}])
      settle!(ctx, other, %{cost_usd: 0.5, session_id: "sid-theirs", occurred_at: add(ctx, -500)})

      spend = LiveSpend.for_task(id, workers: [worker(ctx, id)])

      assert spend.live_usd == 1.0
    end

    test "a file untouched since the worker started is not read", ctx do
      id = task_id()
      path = session!(ctx, "sid-stale", [{100, 5.0}])
      File.touch!(path, ctx.started_at |> DateTime.add(-3600, :second) |> DateTime.to_unix())

      assert LiveSpend.for_task(id, workers: [worker(ctx, id)]).live_usd == 0.0
    end

    test "a project dir shared with another task's worker counts only this task's own sessions",
         ctx do
      id = task_id()
      other = task_id()
      session!(ctx, "sid-a", [{200, 1.0}])
      session!(ctx, "sid-b", [{200, 7.0}])
      session!(ctx, "sid-nobody", [{200, 3.0}])

      workers = [
        worker(ctx, id, %{meta: %{session_id: "sid-a"}}),
        worker(ctx, other, %{meta: %{session_id: "sid-b"}})
      ]

      spends = LiveSpend.for_tasks([id, other], workers: workers)

      # `sid-nobody` could be either task's: unattributable, so neither's.
      assert spends[id].live_usd == 1.0
      assert spends[other].live_usd == 7.0
    end
  end

  describe "unpriced providers render as n/a, never $0.00 (bd-481sz7)" do
    test "a task whose only spend is unpriced has no total", ctx do
      id = task_id()
      settle!(ctx, id, %{cost_usd: nil, provider: "agy"})

      spend = LiveSpend.for_task(id, workers: [])

      assert spend.total_usd == nil
      assert spend.unpriced?
    end

    test "a live agy worker with nothing priced has no total", ctx do
      id = task_id()

      spend =
        LiveSpend.for_task(id, workers: [worker(ctx, id, %{meta: %{provider: "agy"}})])

      assert spend.total_usd == nil
      assert spend.unpriced?
      assert spend.live?
    end

    test "priced spend plus a live agy pass is a floor, flagged unpriced", ctx do
      id = task_id()
      settle!(ctx, id, %{cost_usd: 2.5})

      spend =
        LiveSpend.for_task(id, workers: [worker(ctx, id, %{meta: %{provider: "antigravity"}})])

      assert spend.total_usd == 2.5
      assert spend.unpriced?
    end

    test "a live session on a model the price table does not know is unpriced", ctx do
      id = task_id()
      session!(ctx, "sid-mystery", [{100, 1.0}], model: "claude-mystery-9")

      spend = LiveSpend.for_task(id, workers: [worker(ctx, id)])

      assert spend.total_usd == nil
      assert spend.unpriced?
    end
  end

  describe "fault tolerance" do
    test "a torn / mid-write file withholds its live share and flags the figure degraded",
         ctx do
      id = task_id()
      settle!(ctx, id, %{cost_usd: 2.0})
      session!(ctx, "sid-torn", [{200, 1.0}], tail: ~s({"type":"assistant","message":{"id":"x))

      spend = LiveSpend.for_task(id, workers: [worker(ctx, id)])

      assert spend.total_usd == 2.0
      assert spend.live_usd == 0.0
      assert spend.degraded?
      assert spend.live?
    end

    test "a known live session with no file on disk is degraded, not zero-and-complete",
         ctx do
      id = task_id()
      settle!(ctx, id, %{cost_usd: 2.0})

      File.mkdir_p!(
        Path.join([ctx.config_dir, "projects", ClaudeSessionFile.project_slug(ctx.cwd)])
      )

      spend =
        LiveSpend.for_task(id, workers: [worker(ctx, id, %{meta: %{session_id: "sid-missing"}})])

      assert spend.total_usd == 2.0
      assert spend.degraded?
    end

    test "a claude worker with no recorded config dir or cwd is degraded", ctx do
      id = task_id()
      settle!(ctx, id, %{cost_usd: 2.0})

      spend =
        LiveSpend.for_task(id, workers: [worker(ctx, id, %{meta: %{config_dir: nil}})])

      assert spend.total_usd == 2.0
      assert spend.degraded?
    end
  end

  defp add(ctx, seconds), do: DateTime.add(ctx.now, seconds, :second)
end
