defmodule Arbiter.WorkerPrRefTest do
  @moduledoc """
  bd-7b46wd: when the worker opens its own PR/MR (the worker finished and the
  branch is integrated through the configured merger), the opened ref must be
  persisted onto the task's `pr_ref`.

  This is the single signal the workspace MergeQueue reads to ADOPT an already-open
  PR (`MergeQueue.existing_mr_ref/1`) instead of opening a duplicate. Without it
  the Watchdog-merged PR is invisible to the MergeQueue: it falls through to
  `open_mr_for/3`, fails opening a second PR on the already-merged branch, and
  the task is never auto-closed — exactly the recurring silent-stall the task
  describes.
  """

  # DataCase (async: false → shared sandbox) so the worker process started under
  # the DynamicSupervisor reaches the same DB connection, and StubMerger is a
  # singleton named Agent.
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run
  alias Arbiter.Test.StubMerger

  # Park the auto-started Watchdog far in the future so it doesn't merge/complete
  # (and tear the worker + task down) while we assert on the recorded pr_ref.
  @parked %{
    adapter: StubMerger,
    workspace: nil,
    interval_ms: 1_000_000,
    initial_delay_ms: 1_000_000,
    max_polls: :infinity
  }

  setup do
    StubMerger.reset()
    {:ok, ws} = Ash.create(Workspace, %{name: "pr-ref-ws", prefix: "pr"})
    {:ok, task} = Ash.create(Issue, %{title: "record my pr_ref", workspace_id: ws.id})
    {:ok, _} = Ash.update(task, %{status: :in_progress})
    {:ok, ws: ws, task: task}
  end

  test "open_mr records the opened ref onto the task's pr_ref", %{ws: ws, task: task} do
    StubMerger.next_open_ref("#1234")

    {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "arbiter", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal) end)

    :ok = Worker.advance(worker_pid, :running)

    assert {:ok, "#1234"} =
             Worker.open_mr(worker_pid, "bd-branch", "title", "body", @parked)

    # The task now carries the PR ref so the MergeQueue adopts it instead of
    # opening a duplicate.
    {:ok, reloaded} = Ash.get(Issue, task.id)
    assert reloaded.pr_ref == "#1234"
    # The worker is parked for review; the task is not closed yet.
    assert reloaded.status == :in_progress
    assert Worker.state(worker_pid).status == :awaiting_review
  end

  test "open_mr also records the ref onto this run's durable Workers.Run row (bd-6h4ia3)", %{
    ws: ws,
    task: task
  } do
    StubMerger.next_open_ref("#5678")

    {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "arbiter", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal) end)

    :ok = Worker.advance(worker_pid, :running)

    assert {:ok, "#5678"} =
             Worker.open_mr(worker_pid, "bd-branch", "title", "body", @parked)

    [run] =
      Run
      |> Ash.Query.filter(task_id == ^task.id)
      |> Ash.read!()

    assert run.mr_ref == "#5678"
    assert run.merger_url == "https://stub.example/mr/#5678"
  end
end
