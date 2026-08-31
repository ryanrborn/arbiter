defmodule Arbiter.Board.AutopilotIntegrationTest do
  @moduledoc """
  The autopilot against a real board read.

  `Arbiter.Board.AutopilotTest` stubs the snapshot so it can drive one
  decision at a time; this file leaves `Snapshot.load/1` in place and only
  stubs the dispatch, so the wiring the product actually depends on — issues
  in the database → `Snapshot.load/1` → `Scheduler.plan/1` → a dispatch —
  is exercised end to end. Nothing here spawns a worker: the seam under test
  is *which* id the autopilot hands to dispatch, not what dispatch does with
  it.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Snapshot
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Dependency, Issue, Workspace}

  setup do
    # Workers are supervised at the VM level and every one of them lands in a
    # column, so a leftover child from an earlier test would occupy a slot.
    for snap <- Arbiter.Worker.list_children(), do: Arbiter.Worker.stop(snap.task_id)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "autopilot-#{System.unique_integer([:positive])}",
        prefix: "bd"
      })

    {:ok, ws: ws}
  end

  # bd-b5wyjd: a created issue is unrefined, i.e. Backlog, and the autopilot
  # only ever dispatches out of Ready. Every fixture here is meant to be a
  # queue candidate, so it is promoted on the way out.
  defp issue(ws, title, attrs) do
    {:ok, created} = Ash.create(Issue, Map.merge(%{title: title, workspace_id: ws.id}, attrs))
    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    issue
  end

  # A live autopilot reading the real world, dispatching into the mailbox.
  defp start_autopilot(opts \\ []) do
    test = self()

    {:ok, pid} =
      Autopilot.start_link(
        Keyword.merge(
          [
            name: nil,
            interval_ms: :never,
            paused: false,
            snapshot: &Snapshot.load/1,
            dispatch: fn id -> send(test, {:dispatched, id}) && {:ok, %{task_id: id}} end
          ],
          opts
        )
      )

    pid
  end

  # `Snapshot.load/1` reads every workspace, and the suite's database is shared
  # across tests in this file, so assert on *our* ids rather than on the shape
  # of the whole queue.
  defp ready_ids(board), do: Enum.map(board.ready, & &1.id)

  test "promotes the top eligible card in the real queue", %{ws: ws} do
    task = issue(ws, "the only thing ready", %{priority: 0})

    pid = start_autopilot()
    board = Autopilot.board(pid, [])

    assert task.id in ready_ids(board)
    assert {:ok, promoted} = Autopilot.tick(pid)
    assert_receive {:dispatched, ^promoted}
    # Priority 0 beats anything another test left behind at the default.
    assert promoted == task.id
  end

  test "a dependency-blocked card is skipped, and says why", %{ws: ws} do
    blocker = issue(ws, "must land first", %{priority: 1})
    blocked = issue(ws, "waits on the other", %{priority: 0})

    {:ok, _} =
      Ash.create(Dependency, %{
        from_issue_id: blocked.id,
        to_issue_id: blocker.id,
        type: :depends_on
      })

    pid = start_autopilot()
    board = Autopilot.board(pid, [])

    entry = Enum.find(board.ready, &(&1.id == blocked.id))
    assert entry.state == :blocked
    assert entry.reason =~ blocker.id

    # Even though the blocked card sorts ahead on priority, the one that goes
    # is its blocker.
    assert {:ok, blocker_id} = Autopilot.tick(pid)
    assert blocker_id == blocker.id
    assert_receive {:dispatched, ^blocker_id}
  end

  test "a paused autopilot reads the same world and dispatches nothing", %{ws: ws} do
    task = issue(ws, "ready but held", %{priority: 0})

    pid = start_autopilot(paused: true)
    board = Autopilot.board(pid, [])

    entry = Enum.find(board.ready, &(&1.id == task.id))
    assert entry.state == :blocked
    assert entry.reason == "scheduler paused"

    assert :paused = Autopilot.tick(pid)
    refute_receive {:dispatched, _}
  end

  # bd-b5wyjd — the safety property the Backlog column buys: an unrefined card
  # is not merely rendered elsewhere, it is invisible to dispatch. Asserted
  # end to end (database → Snapshot.load → Scheduler.plan → dispatch) rather
  # than against a hand-built snapshot, because that is the path that would
  # actually spend credits on an unrefined ticket.
  test "an unrefined card is never dispatched, however free the fleet is", %{ws: ws} do
    {:ok, unrefined} =
      Ash.create(Issue, %{title: "not thought through", workspace_id: ws.id, priority: 0})

    pid = start_autopilot()
    board = Autopilot.board(pid, [])

    refute unrefined.id in ready_ids(board)
    assert unrefined.id in Enum.map(board.backlog, & &1.id)

    assert :idle = Autopilot.tick(pid)
    refute_receive {:dispatched, _}

    # ...and promotion is all it takes.
    {:ok, _} = Ash.update(unrefined, %{}, action: :promote_to_ready)

    assert {:ok, promoted} = Autopilot.tick(pid)
    assert promoted == unrefined.id
    assert_receive {:dispatched, ^promoted}
  end

  test "an operator's hand-ranking decides which card goes next", %{ws: ws} do
    _leader = issue(ws, "what the machine would pick", %{priority: 0})
    underdog = issue(ws, "what the operator wants", %{priority: 3})

    pid = start_autopilot()

    assert %{promote: promoted} = Autopilot.board(pid, ready_order: [underdog.id])
    assert promoted == underdog.id
  end

  # `Arbiter.Board.AutopilotTest` covers the retry/escalation bookkeeping
  # against a stubbed `:escalate` seam; this exercises the real
  # `default_escalate/3` path (an `Ash.get(Issue, id)` lookup for the
  # workspace, then a real `CoordinatorNotifier.dispatch_stuck/3` post) so the
  # end-to-end wiring — dispatch failure -> Issue lookup -> coordinator inbox
  # — is proven, not just the seam it plugs into (bd-a40f4q).
  test "a card stuck on a deterministic dispatch error lands in the coordinator inbox", %{
    ws: ws
  } do
    task = issue(ws, "ambiguous repo victim", %{priority: 0})

    pid =
      start_autopilot(
        dispatch: fn _id -> {:error, {:ambiguous_repo, ["tonic", "tonic_device"]}} end
      )

    assert {:error, {:ambiguous_repo, _}} = Autopilot.tick(pid)

    assert [escalation] = Message.inbox("admiral", workspace_id: ws.id)
    assert escalation.kind == :escalation
    assert escalation.directive_ref == task.id
    assert escalation.subject =~ "dispatch stuck"
    assert escalation.body =~ "tonic"
  end
end
