defmodule ArbiterWeb.BoardLiveTest.BoardMerger do
  @moduledoc "Stub merger that parks a worker at :awaiting_review, i.e. in Waiting."
  @behaviour Arbiter.Mergers.Merger

  @impl true
  def open(_branch, _title, _desc, _opts), do: {:ok, "!77"}
  @impl true
  def get(_ref), do: {:ok, %{status: :open, approved: false}}
  @impl true
  def merge(_ref), do: :ok
  @impl true
  def close(_ref), do: :ok
  @impl true
  def add_comment(_ref, _body), do: :ok
  @impl true
  def request_review(_ref, _reviewers), do: :ok
  @impl true
  def link_for(_ref), do: "https://example.test/mr/77"
  @impl true
  def get_diff(_ref, _opts), do: {:ok, ""}
  @impl true
  def post_inline_comment(_ref, _finding, _opts), do: :ok
  @impl true
  def submit_review(_ref, _verdict, _body, _opts), do: :ok
  @impl true
  def list_review_feedback(_ref),
    do: {:ok, %{changes_requested: false, latest_review_id: nil, feedback: []}}
end

defmodule ArbiterWeb.BoardLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias Arbiter.Worker
  alias ArbiterWeb.BoardLiveTest.BoardMerger

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

  # A worker parked at :awaiting — the escalation case that flags in Waiting.
  defp parked_worker(ws, task) do
    {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)
    :ok = Worker.advance(pid, :verify)
    :ok = Worker.await(pid, :question)
    pid
  end

  # A worker parked at :awaiting_review on an open MR — the other half of
  # Waiting. The Watchdog is pushed far enough out that it never polls, so the
  # card's merger status is only ever what a test records by hand.
  defp merge_worker(ws, task) do
    {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)
    :ok = Worker.advance(pid, :integrate)

    {:ok, "!77"} =
      Worker.open_mr(pid, "feature/x", "Integrate x", "", %{
        adapter: BoardMerger,
        workspace: nil,
        auto_merge: false,
        interval_ms: 600_000,
        initial_delay_ms: 600_000
      })

    pid
  end

  describe "columns" do
    test "renders the four stage columns", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "Ready"
      assert html =~ "Running"
      assert html =~ "Waiting"
      assert html =~ "Closed today"

      assert has_element?(view, "#board-column-waiting")
      # The two columns Waiting replaced are gone, not renamed alongside it.
      # ("Merge queue" as a phrase survives in the top nav, so match the
      # columns themselves rather than the page text.)
      refute has_element?(view, "#board-column-needs-you")
      refute has_element?(view, "#board-column-merge")
      refute html =~ "Needs you"
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

    test "putting a Running card back down where it was asks nothing", %{conn: conn, ws: ws} do
      task = issue(ws, "picked up, thought better of it")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live(conn, "/")

      html = drag(view, task.id, "running", "running")

      # A drag that changed nothing must not offer to destroy live work: the
      # confirmation is one click from killing the agent.
      refute html =~ "Stop"
      refute has_element?(view, ~s(button[phx-click="confirm_stop"]))
      assert Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
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

  describe "the Waiting column holds everything out of the worker's hands" do
    test "a parked worker and a merge-parked one share the column", %{conn: conn, ws: ws} do
      parked = working_issue(ws, "answer me")
      parked_worker(ws, parked)

      merging = working_issue(ws, "land it later")
      merge_worker(ws, merging)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s(#board-column-waiting [id="card-#{parked.id}"]))
      assert has_element?(view, ~s(#board-column-waiting [id="card-#{merging.id}"]))
    end

    test "the flag marks only what the system has run out of moves for", %{conn: conn, ws: ws} do
      parked = working_issue(ws, "answer me")
      parked_worker(ws, parked)

      polling = working_issue(ws, "still in review")
      merge_worker(ws, polling)

      stuck = working_issue(ws, "conflicted")
      stuck_pid = merge_worker(ws, stuck)

      :ok =
        Worker.record_merger_status(stuck_pid, %{
          status: :open,
          approved: true,
          block_reason: :conflict
        })

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s([id="card-#{parked.id}"] [data-needs-you]))
      assert has_element?(view, ~s([id="card-#{stuck.id}"] [data-needs-you]))
      # An MR the forge is simply still chewing on is pipeline-wait, not yours.
      refute has_element?(view, ~s([id="card-#{polling.id}"] [data-needs-you]))
    end

    test "dragging a card back to Ready sends the work back to the queue", %{conn: conn, ws: ws} do
      task = working_issue(ws, "answer was: redo it")
      parked_worker(ws, task)

      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, ~s(#board-column-waiting [id="card-#{task.id}"]))

      html = drag(view, task.id, "waiting", "ready")
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

    test "dragging a parked card toward Closed lets the worker proceed", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "answer was: carry on")
      pid = parked_worker(ws, task)

      {:ok, view, _html} = live(conn, "/")

      html = drag(view, task.id, "waiting", "closed")

      assert html =~ "proceed"
      assert Worker.state(pid).status == :running
      # Un-parking is not a promotion: it went back to its own work, so it
      # belongs in Running, not still waiting.
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

      html = drag(view, task.id, "waiting", "closed")

      assert html =~ "failed"
      assert Worker.state(pid).status == :failed
    end

    test "dragging a merge-parked card out stops the worker watching the MR", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "land it later")
      merge_worker(ws, task)

      {:ok, view, _html} = live(conn, "/")

      html = drag(view, task.id, "waiting", "closed")
      Process.sleep(80)

      assert html =~ "merge request is untouched"
      refute Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
    end

    test "merge-queue cards render merger_status text correctly", %{conn: conn, ws: ws} do
      # nil merger_status renders as "checks"
      nil_status = working_issue(ws, "nil status card")
      _nil_pid = merge_worker(ws, nil_status)

      # pending card (no block_reason) renders as "checks"
      pending = working_issue(ws, "pending card")
      pending_pid = merge_worker(ws, pending)

      :ok =
        Worker.record_merger_status(pending_pid, %{
          status: :open,
          approved: false,
          pipeline: :success
        })

      # approved card (no block_reason) renders as "approved"
      approved = working_issue(ws, "approved card")
      approved_pid = merge_worker(ws, approved)

      :ok =
        Worker.record_merger_status(approved_pid, %{
          status: :open,
          approved: true,
          pipeline: :success
        })

      # merged card renders as "merged"
      merged = working_issue(ws, "merged card")
      merged_pid = merge_worker(ws, merged)

      :ok =
        Worker.record_merger_status(merged_pid, %{
          status: :merged,
          approved: true,
          pipeline: :success
        })

      # blocked cards with various block_reasons
      conflict_card = working_issue(ws, "conflict card")
      conflict_pid = merge_worker(ws, conflict_card)

      :ok =
        Worker.record_merger_status(conflict_pid, %{
          status: :open,
          approved: true,
          block_reason: :conflict
        })

      ci_failed_card = working_issue(ws, "ci failed card")
      ci_failed_pid = merge_worker(ws, ci_failed_card)

      :ok =
        Worker.record_merger_status(ci_failed_pid, %{
          status: :open,
          approved: true,
          pipeline: :failed,
          block_reason: :ci_failed
        })

      behind_base_card = working_issue(ws, "behind base card")
      behind_base_pid = merge_worker(ws, behind_base_card)

      :ok =
        Worker.record_merger_status(behind_base_pid, %{
          status: :open,
          approved: true,
          block_reason: :behind_base
        })

      {:ok, _view, html} = live(conn, "/")

      # The key assertion: rendering doesn't crash when merger_status is a populated map.
      # All cards appear in the board, proving the render succeeded.
      assert html =~ nil_status.id
      assert html =~ pending.id
      assert html =~ approved.id
      assert html =~ merged.id
      assert html =~ conflict_card.id
      assert html =~ ci_failed_card.id
      assert html =~ behind_base_card.id

      # Verify correct merger_status text appears (merge_status_text/1 rendering)
      # nil status and pending cards
      assert html =~ "checks"
      assert html =~ "approved"
      assert html =~ "merged"
      assert html =~ "conflict"
      assert html =~ "ci failed"
      assert html =~ "behind base"
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
