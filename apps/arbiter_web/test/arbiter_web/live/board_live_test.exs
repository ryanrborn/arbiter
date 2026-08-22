defmodule ArbiterWeb.BoardLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias Arbiter.Worker

  setup do
    # Workers are supervised at the VM level — a prior test in the umbrella may
    # have left children running, and every one of them lands in a column.
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)
    Process.sleep(50)

    # The autopilot is one process for the whole VM and ships paused, which
    # would make every Ready card read "scheduler paused". These tests are
    # about a board whose scheduler is live, so resume it for the duration and
    # put it back afterwards. `interval_ms: :never` in the test env means a
    # resumed autopilot still never dispatches on its own.
    Autopilot.resume(Autopilot)
    on_exit(fn -> Autopilot.pause(Autopilot) end)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "board-#{System.unique_integer([:positive])}", prefix: "bd"})

    {:ok, ws: ws}
  end

  defp issue(ws, title, attrs \\ %{}) do
    {:ok, issue} = Ash.create(Issue, Map.merge(%{title: title, workspace_id: ws.id}, attrs))
    issue
  end

  # `:status` is not a create input — a task becomes in_progress by being
  # worked, which is exactly the state these drags start from.
  defp working_issue(ws, title) do
    {:ok, issue} = Ash.update(issue(ws, title), %{status: :in_progress})
    issue
  end

  # The one gesture the client reports: this card, out of that column, into
  # this one. The board decides what — if anything — that means.
  defp drag(view, id, from, to),
    do: render_hook(view, "drag", %{"id" => id, "from" => from, "to" => to})

  # A worker parked at :awaiting — the escalation case that fills Needs you.
  defp parked_worker(ws, task) do
    {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)
    :ok = Worker.advance(pid, :verify)
    :ok = Worker.await(pid, :question)
    pid
  end

  describe "columns" do
    test "renders the five stage columns", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Ready"
      assert html =~ "Running"
      assert html =~ "Needs you"
      assert html =~ "Merge queue"
      assert html =~ "Closed today"
    end

    test "an open issue nobody is working shows up in Ready", %{conn: conn, ws: ws} do
      task = issue(ws, "collapse duplicate status helpers")

      {:ok, _view, html} = live(conn, "/")

      assert html =~ task.id
      assert html =~ "collapse duplicate status helpers"
    end

    test "a closed issue leaves Ready for Closed today", %{conn: conn, ws: ws} do
      task = issue(ws, "already landed")
      {:ok, _} = Ash.update(task, %{}, action: :close)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s(#board-column-closed [id="card-#{task.id}"]))
      refute has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
    end
  end

  describe "the queue reads its own reason" do
    test "the head of an idle queue says it is next up", %{conn: conn, ws: ws} do
      issue(ws, "first in line")

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "next up"
    end

    test "a card behind the head shows its queue position", %{conn: conn, ws: ws} do
      issue(ws, "leader", %{priority: 1})
      issue(ws, "follower", %{priority: 3})

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "1 ahead in queue"
    end

    test "a dependency-blocked card names the blocker instead of a position", %{
      conn: conn,
      ws: ws
    } do
      blocker = issue(ws, "must land first")
      blocked = issue(ws, "waits on the other")

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: blocked.id,
          to_issue_id: blocker.id,
          type: :depends_on
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "blocked"
      assert html =~ blocker.id
    end
  end

  describe "hand-ranking Ready" do
    test "reordering moves a card to the head of the queue and makes it next up", %{
      conn: conn,
      ws: ws
    } do
      leader = issue(ws, "machine's pick", %{priority: 1})
      underdog = issue(ws, "operator's pick", %{priority: 4})

      {:ok, view, html} = live(conn, "/")
      assert html =~ "next up"

      render_hook(view, "reorder_ready", %{"order" => [underdog.id, leader.id]})

      html = render(view)
      # The operator's card now leads: it carries the promotion reason and the
      # machine's pick has fallen in behind it.
      assert html =~ ~s(id="card-#{underdog.id}")
      assert board_position(html, underdog.id) < board_position(html, leader.id)
    end

    test "an id that is no longer Ready is ignored rather than fatal", %{conn: conn, ws: ws} do
      task = issue(ws, "still here")

      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "reorder_ready", %{"order" => ["bd-vanished", task.id]})

      assert render(view) =~ task.id
    end
  end

  describe "drag is a human action, and Running is not one of its targets" do
    test "dragging a card INTO Running is refused with an explanation", %{conn: conn, ws: ws} do
      task = issue(ws, "impatient")

      {:ok, view, _html} = live(conn, "/")

      html = drag(view, task.id, "ready", "running")

      assert html =~ "scheduler"
      # The card did not move. Whether it dispatches is the scheduler's call,
      # and it makes it from Ready.
      assert has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
      refute has_element?(view, ~s(#board-column-running [id="card-#{task.id}"]))
    end
  end

  describe "pulling work out of Running" do
    test "asks for confirmation before it stops anything", %{conn: conn, ws: ws} do
      task = issue(ws, "in flight")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live(conn, "/")

      html = drag(view, task.id, "running", "ready")

      assert html =~ "Stop"
      # Still running — nothing was stopped by asking.
      assert Enum.any?(Worker.list_children(), &(&1.task_id == task.id))

      view |> element(~s(button[phx-click="confirm_stop"])) |> render_click()
      Process.sleep(80)

      refute Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
    end

    test "cancelling the confirmation leaves the worker alone", %{conn: conn, ws: ws} do
      task = issue(ws, "leave me be")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live(conn, "/")
      drag(view, task.id, "running", "ready")

      view |> element(~s(button[phx-click="cancel_stop"])) |> render_click()

      assert Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
    end
  end

  describe "the Needs-you column is the one a person decides" do
    test "dragging a card back to Ready sends the work back to the queue", %{conn: conn, ws: ws} do
      task = working_issue(ws, "answer was: redo it")
      parked_worker(ws, task)

      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, ~s(#board-column-needs-you [id="card-#{task.id}"]))

      html = drag(view, task.id, "needs_you", "ready")
      Process.sleep(80)

      assert html =~ "queue"
      # The worker is gone and the issue is open again, so the scheduler picks
      # it up on its own terms rather than resuming a halted session.
      refute Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
      assert Ash.get!(Issue, task.id).status == :open

      html = render(view)
      assert html =~ task.id
      assert has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
    end

    test "dragging a card toward the merge queue lets the parked worker proceed", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "answer was: carry on")
      pid = parked_worker(ws, task)

      {:ok, view, _html} = live(conn, "/")

      html = drag(view, task.id, "needs_you", "merge")

      assert html =~ "proceed"
      assert Worker.state(pid).status == :running
      # Un-parking is not a promotion: it went back to its own work, so it
      # belongs in Running, not the merge queue.
      assert has_element?(view, ~s(#board-column-running [id="card-#{task.id}"]))
    end

    test "a card the worker FSM will not un-park says so rather than moving", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "reviewer said no")
      pid = parked_worker(ws, task)
      :ok = Worker.fail(pid, :review_rejected)

      {:ok, view, _html} = live(conn, "/")

      html = drag(view, task.id, "needs_you", "merge")

      assert html =~ "failed"
      assert Worker.state(pid).status == :failed
    end
  end

  describe "pulling a card out of the merge queue" do
    test "stops the worker watching the merge request", %{conn: conn, ws: ws} do
      task = working_issue(ws, "land it later")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live(conn, "/")

      html = drag(view, task.id, "merge", "needs_you")
      Process.sleep(80)

      assert html =~ "merge queue"
      refute Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
    end
  end

  describe "drops that mean nothing" do
    test "dropping onto Closed today changes nothing and says nothing", %{conn: conn, ws: ws} do
      task = issue(ws, "not done yet")

      {:ok, view, _html} = live(conn, "/")

      drag(view, task.id, "ready", "closed")

      assert has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
      assert Ash.get!(Issue, task.id).status == :open
    end
  end

  describe "the scheduler switch" do
    test "pausing is visible on every Ready card", %{conn: conn, ws: ws} do
      issue(ws, "would have gone next")

      {:ok, view, _html} = live(conn, "/")

      html = view |> element(~s(button[phx-click="toggle_scheduler"])) |> render_click()

      assert html =~ "scheduler paused"
    end
  end

  describe "toolbar" do
    test "reports the fleet's slot arithmetic", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "slots free"
    end

    test "the filter narrows the board to matching issues", %{conn: conn, ws: ws} do
      keep = issue(ws, "keep this one")
      drop = issue(ws, "unrelated work")

      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> form("#board-filter-form", %{"filter" => "keep this"})
        |> render_change()

      assert html =~ keep.id
      refute html =~ drop.id
    end
  end

  # Index of a card's DOM id in the rendered page — a crude but sufficient
  # proxy for "which one comes first in the column".
  defp board_position(html, id) do
    case :binary.match(html, ~s(id="card-#{id}")) do
      {at, _} -> at
      :nomatch -> flunk("card #{id} is not on the board")
    end
  end
end
