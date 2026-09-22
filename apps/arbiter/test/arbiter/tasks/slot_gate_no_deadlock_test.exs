defmodule Arbiter.Tasks.SlotGateNoDeadlockTest do
  @moduledoc """
  bd-aw2cyt acceptance 2: the cap gates **new dispatches only**. Review,
  implementer and fix-pass rounds for already-dispatched work still spawn
  above the cap, so cap=1 with a review round needed cannot deadlock.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.SlotGate
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "nodl-#{System.unique_integer([:positive])}",
        prefix: "ndl#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  defp task(ws) do
    {:ok, t} =
      Ash.create(Issue, %{
        title: "nodl-#{System.unique_integer([:positive])}",
        workspace_id: ws.id
      })

    t
  end

  defp start_worker(ws, opts) do
    opts = Keyword.merge([repo: "test/repo", workspace_id: ws.id], opts)
    {:ok, pid} = Worker.start(opts)
    task_id = Keyword.fetch!(opts, :task_id)
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(task_id, :normal) end)
    pid
  end

  test "a review round starts while the cap is full, and the cap stays honest", %{ws: ws} do
    author_task = task(ws)
    author = start_worker(ws, task_id: author_task.id)
    :ok = Worker.advance(author, :implement)

    # Cap of 1, and the author already holds it. (Its agent is not really live
    # here, so pin the occupancy question at the predicate instead of the
    # process: what matters is that nothing consults the cap before spawning.)
    assert SlotGate.free(1, [%{status: :running, agent_live: true}], :agents) == 0

    # The reviewer spawns regardless — no cap check stands between a task that
    # needs review and its review.
    reviewer_id = author_task.id <> "#review"

    reviewer =
      start_worker(ws,
        task_id: reviewer_id,
        meta: %{role: :reviewer, reviews: author_task.id}
      )

    assert Process.alive?(reviewer)
    assert Worker.whereis(reviewer_id) == reviewer

    # And an implementer round on top of that, which is the deadlock shape:
    # the author cannot finish until the round does.
    impl_id = author_task.id <> "#review#impl1"

    impl =
      start_worker(ws,
        task_id: impl_id,
        meta: %{role: :implementer, revises: author_task.id}
      )

    assert Process.alive?(impl)
  end

  test "the rounds still count toward the cap once they are running", %{ws: ws} do
    # Three live agents against a cap of 2: the board reports zero free slots
    # (so nothing NEW is dispatched) and never a negative number.
    workers = [
      %{task_id: "bd-1", status: :awaiting_review_gate, role: nil, meta: %{}, agent_live: false},
      %{
        task_id: "bd-1#review",
        status: :running,
        role: :reviewer,
        meta: %{role: :reviewer, reviews: "bd-1"},
        agent_live: true
      },
      %{task_id: "bd-2", status: :running, role: nil, meta: %{}, agent_live: true},
      %{task_id: "bd-3", status: :running, role: nil, meta: %{}, agent_live: true}
    ]

    assert SlotGate.occupied(workers, :agents) == 3
    assert SlotGate.free(2, workers, :agents) == 0

    board =
      Snapshot.derive(%{
        issues: [],
        workers: Enum.map(workers, &Map.merge(&1, %{started_at: DateTime.utc_now()})),
        now: DateTime.utc_now(),
        slots_total: 2,
        slot_basis: :agents
      })

    assert board.agents_live == 3
    assert board.slots_free == 0
    assert board.promote == nil

    _ = ws
  end

  test "no round-spawning module consults the slot predicate" do
    # A structural guard on the invariant above: if a future change makes the
    # ReviewGate or a merge-queue dispatcher ask "is there room?", cap=1 will
    # deadlock the moment a round is needed, and this fails first.
    spawners = [
      "lib/arbiter/worker/review_gate.ex",
      "lib/arbiter/workflows/merge_queue/fix_pass_dispatcher.ex",
      "lib/arbiter/workflows/merge_queue/conflict_resolver.ex",
      "lib/arbiter/workflows/review_gate_fix_round_dispatcher.ex"
    ]

    for rel <- spawners do
      path = Path.join(app_source(), rel)
      assert File.exists?(path), "#{rel} moved — re-point this guard at it"
      source = File.read!(path)

      refute source =~ "SlotGate",
             "#{rel} must not gate a review/fix round on the slot predicate"

      refute source =~ "slots_free",
             "#{rel} must not gate a review/fix round on free slots"
    end
  end

  # The app's source tree, not its build artefact.
  defp app_source do
    __ENV__.file
    |> Path.dirname()
    |> Path.join("../../..")
    |> Path.expand()
  end
end
