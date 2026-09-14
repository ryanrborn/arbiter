defmodule ArbiterWeb.BoardLiveTest.BoardMerger do
  @moduledoc "Stub merger that parks a worker at :awaiting_review, i.e. in Waiting."
  @behaviour Arbiter.Mergers.Merger

  @impl true
  def open(_branch, _title, _desc, _opts), do: {:ok, "!77"}
  @impl true
  def get(_ref), do: {:ok, %{status: :open, approved: false}}
  @impl true
  def merge(_ref, _expected_sha), do: :ok
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

  # bd-b5wyjd: a freshly created issue is unrefined, i.e. Backlog. Almost every
  # test here is about a card that has already been refined into the queue, so
  # this helper promotes; `backlog_issue/3` is the un-promoted one.
  defp issue(ws, title, attrs \\ %{}) do
    {:ok, issue} = Ash.update(backlog_issue(ws, title, attrs), %{}, action: :promote_to_ready)
    issue
  end

  defp backlog_issue(ws, title, attrs \\ %{}) do
    # bd-7mbrlg: `:promote_to_ready` now refuses a gated type with no
    # acceptance criteria. Nothing in this file is testing that guard, so the
    # fixture carries a placeholder AC unless the caller overrides it.
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: title, workspace_id: ws.id, acceptance: "- board fixture"}, attrs)
      )

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
    test "renders the five stage columns", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "Backlog"
      assert html =~ "Ready"
      assert html =~ "Running"
      assert html =~ "Waiting"
      assert html =~ "Closed today"

      assert has_element?(view, "#board-column-backlog")
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

    # bd-5l88o5 — every board card carries a copy-id control so an operator
    # can grab the issue id without leaving the board. bd-1rreu1 moved card
    # navigation off a wrapping `<a>` onto a `phx-click={JS.navigate(...)}`
    # div, so the copy button is no longer nested inside a link at all — it
    # relies solely on the CopyId hook's `e.preventDefault()` +
    # `e.stopPropagation()` to keep its click from also bubbling into the
    # card's own navigation. That hook JS is asserted directly in
    # core_test.exs; this test only pins the button's presence and that it
    # is not nested inside any `<a>` (no `<a>`-in-`<a>` regression either).
    test "a card carries a copy-id button naming the issue id, not nested inside a link", %{
      conn: conn,
      ws: ws
    } do
      task = issue(ws, "collapse duplicate status helpers")

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(
               view,
               ~s(div[id="card-#{task.id}"] button[type="button"][aria-label="Copy issue id #{task.id}"])
             )

      refute has_element?(
               view,
               ~s(div[id="card-#{task.id}"] a button[type="button"][aria-label="Copy issue id #{task.id}"])
             )
    end
  end

  # bd-1rreu1 — before this, the same click opened a task, a worker, or the
  # merge queue depending on which column the card sat in. Now the card body
  # and title always go to the issue's own page, in every column; a column's
  # contextual destination (the running worker, the merge queue, a dead
  # watchdog's restart) survives only as an explicit inner link, never as
  # the whole-card click target. Card navigation moved off a wrapping `<a>`
  # onto `phx-click={JS.navigate(...)}` so those inner links (activity line,
  # action chips) can be real `<a>` elements without nesting one `<a>`
  # inside another.
  describe "card body navigation always opens the issue" do
    # The attribute substring selector pins the check to the card wrapper's
    # own `phx-click` attribute, not any link nested inside it (e.g. the
    # Running activity line or a Waiting action chip, both of which may
    # legitimately point elsewhere within the same card).
    defp card_navigates_to?(view, card_id, href) do
      has_element?(view, ~s([id="card-#{card_id}"][phx-click*="#{href}"]))
    end

    test "Backlog card body navigates to the task page", %{conn: conn, ws: ws} do
      task = backlog_issue(ws, "half an idea")

      {:ok, view, _html} = live(conn, "/")

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
    end

    test "Ready card body navigates to the task page", %{conn: conn, ws: ws} do
      task = issue(ws, "queued work")

      {:ok, view, _html} = live(conn, "/")

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
    end

    test "Running card body navigates to the task page, not the worker page", %{
      conn: conn,
      ws: ws
    } do
      task = issue(ws, "in flight")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live(conn, "/")

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
      refute card_navigates_to?(view, task.id, "/workers/#{task.id}")
    end

    test "Waiting card body navigates to the task page, not the worker page", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "still in review")
      merge_worker(ws, task)

      {:ok, view, _html} = live(conn, "/")

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
    end

    test "Closed card body navigates to the task page", %{conn: conn, ws: ws} do
      task = issue(ws, "already landed")
      {:ok, _} = Ash.update(task, %{}, action: :close)

      {:ok, view, _html} = live(conn, "/")

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
    end

    test "no board card nests an <a> inside another <a>", %{conn: conn, ws: ws} do
      running = issue(ws, "running card")
      {:ok, _pid} = Worker.start(task_id: running.id, repo: "r", workspace_id: ws.id)

      waiting = working_issue(ws, "waiting card")
      merge_worker(ws, waiting)

      {:ok, view, html} = live(conn, "/")

      refute Regex.match?(~r/<a\b[^>]*>(?:(?!<\/a>).)*<a\b/s, html)

      # The action chips still render real links even though the card
      # wrapper itself is no longer an `<a>`.
      assert has_element?(view, ~s([id="card-#{waiting.id}"] a))
    end
  end

  describe "Running column: the activity line links to the worker" do
    test "the activity line is a link to the worker page", %{conn: conn, ws: ws} do
      task = issue(ws, "in flight")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(
               view,
               ~s(#board-column-running [id="card-#{task.id}"] a[href="/workers/#{task.id}"])
             )
    end
  end

  describe "Waiting column: the action chip keeps today's contextual destination" do
    test "awaiting verification points the chip at the task page", %{conn: conn, ws: ws} do
      task = working_issue(ws, "doctor probe")
      {:ok, task} = Ash.update(task, %{}, action: :await_verification)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(
               view,
               ~s([id="card-#{task.id}"] a[href="/tasks/#{task.id}"])
             )
    end

    test "a dead watchdog points the chip at the worker page, not the merge queue", %{
      conn: conn,
      ws: ws
    } do
      dead = working_issue(ws, "nobody is watching this")
      {:ok, pid} = Worker.start(task_id: dead.id, repo: "r", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)

      {:ok, _} =
        Worker.open_mr(pid, "feature/x", "Integrate x", "", %{
          adapter: BoardMerger,
          workspace: nil,
          auto_merge: false,
          interval_ms: 600_000,
          initial_delay_ms: 600_000,
          watchdog_start_error: true
        })

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s([id="card-#{dead.id}"] a[href="/workers/#{dead.id}"]))
    end

    test "an open MR under review points the chip at the merge queue", %{conn: conn, ws: ws} do
      task = working_issue(ws, "under review")
      merge_worker(ws, task)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s([id="card-#{task.id}"] a[href="/merge_queue"]))
    end

    test "a parked worker awaiting an answer points the chip at the worker page", %{
      conn: conn,
      ws: ws
    } do
      task = issue(ws, "needs an answer")
      parked_worker(ws, task)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s([id="card-#{task.id}"] a[href="/workers/#{task.id}"]))
    end
  end

  # bd-b5wyjd — Backlog is where work is born, and the promote button on the
  # detail page is the only door out of it.
  describe "the Backlog column" do
    test "a brand-new issue lands in Backlog, not Ready", %{conn: conn, ws: ws} do
      task = backlog_issue(ws, "half an idea")

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s(#board-column-backlog [id="card-#{task.id}"]))
      refute has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
    end

    test "promoting moves the card into Ready", %{conn: conn, ws: ws} do
      task = backlog_issue(ws, "now refined")
      {:ok, _} = Ash.update(task, %{}, action: :promote_to_ready)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
      refute has_element?(view, ~s(#board-column-backlog [id="card-#{task.id}"]))
    end

    test "an unrefined card never claims the head of the queue", %{conn: conn, ws: ws} do
      backlog_issue(ws, "unrefined")

      {:ok, _view, html} = live(conn, "/")

      refute html =~ "next up — dispatching"
    end

    test "Backlog is newest-first", %{conn: conn, ws: ws} do
      first = backlog_issue(ws, "thought one")
      second = backlog_issue(ws, "thought two")

      {:ok, _view, html} = live(conn, "/")

      assert board_position(html, second.id) < board_position(html, first.id)
    end

    test "the filter box reaches Backlog like every other column", %{conn: conn, ws: ws} do
      keep = backlog_issue(ws, "caching strategy")
      drop = backlog_issue(ws, "unrelated")

      {:ok, view, _html} = live(conn, "/")
      html = render_change(view, "filter", %{"filter" => "caching"})

      assert html =~ keep.id
      refute html =~ drop.id
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

  describe "Running column rendering" do
    test "displays difficulty on running cards", %{conn: conn, ws: ws} do
      task = issue(ws, "work with difficulty", %{difficulty: 2})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(
               view,
               ~s(#board-column-running [id="card-#{task.id}"] [aria-label="Difficulty D2"])
             )
    end

    test "does not crash when difficulty is not set", %{conn: conn, ws: ws} do
      task = issue(ws, "no difficulty set")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ task.id
    end
  end

  describe "the Waiting column holds everything out of the worker's hands" do
    # bd-8jixav: the Watchdog is a :temporary process, so a crash leaves the
    # worker parked at :awaiting_review with an open MR nothing polls. The
    # board used to keep showing an ordinary merge card.
    defp merge_worker_without_watchdog(ws, task) do
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)

      {:ok, _} =
        Worker.open_mr(pid, "feature/x", "Integrate x", "", %{
          adapter: BoardMerger,
          workspace: nil,
          auto_merge: false,
          interval_ms: 600_000,
          initial_delay_ms: 600_000,
          watchdog_start_error: true
        })

      pid
    end

    test "a card whose watchdog died says so and offers the restart", %{conn: conn, ws: ws} do
      dead = working_issue(ws, "nobody is watching this")
      merge_worker_without_watchdog(ws, dead)

      {:ok, view, html} = live(conn, "/")

      assert has_element?(view, ~s(#board-column-waiting [id="card-#{dead.id}"]))
      assert html =~ "no watchdog"
      # A dead watchdog means nothing is left for the system to try.
      assert has_element?(view, ~s([id="card-#{dead.id}"] [data-needs-you]))
      # And the card routes to the worker page — where the restart lives —
      # rather than to the merge queue, which can do nothing about it.
      assert has_element?(view, ~s([id="card-#{dead.id}"] a[href="/workers/#{dead.id}"]))
    end

    test "a card with a live watchdog says nothing about one", %{conn: conn, ws: ws} do
      polling = working_issue(ws, "still in review")
      merge_worker(ws, polling)

      {:ok, _view, html} = live(conn, "/")

      refute html =~ "no watchdog"
    end

    # The other half of bd-8jixav: a task with both a primary :awaiting_review
    # row and a subordinate failed fix-pass row rendered as two cards.
    test "a task with a subordinate pass renders one card, not two", %{conn: conn, ws: ws} do
      task = working_issue(ws, "one card please")
      merge_worker(ws, task)

      # A subordinate pass registers under `<task_id>:fixpass` and carries its
      # role in meta — the same shape MergeQueue.FixPassDispatcher starts.
      {:ok, fixpass} =
        Worker.start(
          task_id: task.id,
          repo: "r",
          workspace_id: ws.id,
          registry_key: "#{task.id}:fixpass",
          meta: %{role: :fix_pass}
        )

      :ok = Worker.fail(fixpass, "fix pass blew up")

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s(#board-column-waiting [id="card-#{task.id}"]))

      assert view
             |> render()
             |> then(&Regex.scan(~r/id="card-#{task.id}"/, &1))
             |> length() == 1
    end

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

  # bd-9so315 — a merged-but-unverified task has no worker, so without its own
  # card it would be invisible on the board: exactly the gap the state exists
  # to close.
  describe "the Waiting column lists tasks awaiting verification" do
    defp awaiting_issue(ws, title) do
      task = working_issue(ws, title)
      {:ok, awaiting} = Ash.update(task, %{}, action: :await_verification)
      awaiting
    end

    test "a parked task renders a Waiting card with its age and needs-you", %{conn: conn, ws: ws} do
      task = awaiting_issue(ws, "doctor probe")

      {:ok, view, html} = live(conn, "/")

      assert has_element?(view, ~s(#board-column-waiting [id="card-#{task.id}"]))
      assert html =~ "awaiting verification"
      assert has_element?(view, ~s([id="card-#{task.id}"] [data-needs-you]))
      # It routes to the task, where the verification evidence lives — not to a
      # worker page for a worker the merge already tore down.
      assert has_element?(view, ~s([id="card-#{task.id}"] a[href="/tasks/#{task.id}"]))
    end

    test "dragging it out points at the verify verb instead of guessing", %{conn: conn, ws: ws} do
      task = awaiting_issue(ws, "capture path")

      {:ok, view, _html} = live(conn, "/")

      html = drag(view, task.id, "waiting", "closed")
      assert html =~ "arb issue verify"

      # And the task did not move.
      assert Ash.get!(Issue, task.id).status == :awaiting_verification
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

    test "scheduler toggle button has cursor-pointer class", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ~s(#board-scheduler-toggle.cursor-pointer))
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

  describe "mobile horizontal scrolling layout" do
    test "board columns container uses flexbox with horizontal scrolling", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # Verify the board-columns div has flex and overflow-x-auto for horizontal scrolling
      assert html =~ ~s(id="board-columns")
      assert html =~ ~s(flex overflow-x-auto snap-x snap-mandatory)
    end

    test "each column div has fixed width and prevents shrinking", %{conn: conn, ws: ws} do
      issue(ws, "test issue")
      {:ok, _view, html} = live(conn, "/")

      # Each column should have flex-shrink-0 to maintain width while scrolling
      # and a responsive width (w-[85vw] on mobile, md:w-72 on desktop)
      assert html =~ ~s(id="board-column-backlog")
      assert html =~ ~s(flex-shrink-0)
      assert html =~ ~s(snap-start)
    end

    test "toolbar dropdowns are responsive and do not have fixed widths", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # Verify the toolbar form inputs don't have restrictive fixed widths
      assert html =~ ~s(id="board-workspace-form")
      assert html =~ ~s(id="board-filter-form")
      # Should NOT have the old fixed widths
      refute html =~ ~s(w-[136px])
      refute html =~ ~s(w-[260px])
    end

    test "toolbar wraps on narrow viewports instead of overflowing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # The toolbar outer container must wrap items to multiple rows on mobile
      assert html =~ ~s(id="board" class="border border-solid)
      # Verify the toolbar div has flex-wrap for wrapping behavior
      assert html =~ ~s(flex flex-wrap items-center gap-3)
      # Verify the ml-auto span also wraps independently
      assert html =~ ~s(ml-auto flex flex-wrap items-center gap-2.5)
      # Verify board-slots text is hidden on mobile (sm:inline shows on small+)
      assert html =~ ~s(hidden sm:inline)
      # Verify old fixed widths from before #1395 are gone
      refute html =~ ~s(w-[136px])
      refute html =~ ~s(w-[260px])
    end

    test "columns fill the full width on xl breakpoint and above", %{conn: conn, ws: ws} do
      issue(ws, "test issue")
      {:ok, _view, html} = live(conn, "/")

      # The board-columns container must switch to grid layout on xl:
      # xl:grid switches display from flex to grid at that breakpoint
      assert html =~ "xl:grid xl:grid-cols-5"

      # Each column must have xl:w-auto so grid tracks stretch to fill width
      assert html =~ "xl:w-auto"
    end
  end
end
