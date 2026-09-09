defmodule Arbiter.Worker.ReviewNotStartedStatusTest do
  # bd-8tjcms / #1511 (acceptance 3) — a run that reached `arb done` and exited
  # successfully must not be recorded `failed` just because the *review* stage
  # never started.
  #
  # vs-ehjarz run 39c6b497 printed `arb done`, reported `session success`, pushed
  # its branch and opened MR !183 — and was then written to `worker_runs` as
  # `status: :failed, failure_reason: "{:awaiting_review_timeout, 30}"` because
  # no reviewer picked it up inside the Watchdog's poll ceiling. "The
  # implementation run failed" is the wrong description of that.
  #
  # The durable run row now carries its own status, `:review_not_started`. The
  # worker's in-memory FSM status stays `:failed` on purpose: it is the terminal
  # state `Dispatch.resume/2` requires before it will re-attach, and the
  # Watchdog's bounded auto-resume (bd-8eheb6) depends on that.
  #
  # async: false — the Worker registry and DynamicSupervisor are global.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  require Ash.Query

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "review-not-started-ws", prefix: "rns"})
    {:ok, task} = Ash.create(Issue, %{title: "ship the thing", workspace_id: ws.id})
    {:ok, ws: ws, task: task}
  end

  defp start_worker!(ws, task) do
    {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  defp run_for(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
    |> List.first()
  end

  test "an awaiting_review_timeout is recorded as :review_not_started", %{ws: ws, task: task} do
    pid = start_worker!(ws, task)

    :ok = Worker.fail(pid, {:awaiting_review_timeout, 30})

    run = run_for(task.id)
    assert run.status == :review_not_started
    assert run.failure_reason == "{:awaiting_review_timeout, 30}"

    # The FSM status is untouched — Dispatch.resume/2 and the Watchdog's
    # auto-resume both require a terminal worker.
    assert Worker.state(pid).status == :failed
  end

  test "any other failure is still recorded as :failed", %{ws: ws, task: task} do
    pid = start_worker!(ws, task)

    :ok = Worker.fail(pid, {:claude_exit, 1})

    assert run_for(task.id).status == :failed
  end

  test ":review_not_started is a valid run status", %{ws: _ws, task: _task} do
    assert :review_not_started in Run.statuses()
  end
end
