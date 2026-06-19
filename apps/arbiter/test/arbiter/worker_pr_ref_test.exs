defmodule Arbiter.WorkerPrRefTest do
  @moduledoc """
  bd-7b46wd: when the worker opens its own PR/MR (the worker finished and the
  branch is integrated through the configured merger), the opened ref must be
  persisted onto the bead's `pr_ref`.

  This is the single signal the workspace MergeQueue reads to ADOPT an already-open
  PR (`MergeQueue.existing_mr_ref/1`) instead of opening a duplicate. Without it
  the Watchdog-merged PR is invisible to the MergeQueue: it falls through to
  `open_mr_for/3`, fails opening a second PR on the already-merged branch, and
  the bead is never auto-closed — exactly the recurring silent-stall the bead
  describes.
  """

  # DataCase (async: false → shared sandbox) so the worker process started under
  # the DynamicSupervisor reaches the same DB connection, and StubMerger is a
  # singleton named Agent.
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Test.StubMerger

  # Park the auto-started Watchdog far in the future so it doesn't merge/complete
  # (and tear the worker + bead down) while we assert on the recorded pr_ref.
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
    {:ok, bead} = Ash.create(Issue, %{title: "record my pr_ref", workspace_id: ws.id})
    {:ok, _} = Ash.update(bead, %{status: :in_progress})
    {:ok, ws: ws, bead: bead}
  end

  test "open_mr records the opened ref onto the bead's pr_ref", %{ws: ws, bead: bead} do
    StubMerger.next_open_ref("#1234")

    {:ok, worker_pid} = Worker.start(bead_id: bead.id, repo: "arbiter", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal) end)

    :ok = Worker.advance(worker_pid, :running)

    assert {:ok, "#1234"} =
             Worker.open_mr(worker_pid, "bd-branch", "title", "body", @parked)

    # The bead now carries the PR ref so the MergeQueue adopts it instead of
    # opening a duplicate.
    {:ok, reloaded} = Ash.get(Issue, bead.id)
    assert reloaded.pr_ref == "#1234"
    # The worker is parked for review; the bead is not closed yet.
    assert reloaded.status == :in_progress
    assert Worker.state(worker_pid).status == :awaiting_review
  end
end
