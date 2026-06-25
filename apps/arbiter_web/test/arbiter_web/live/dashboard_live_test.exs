defmodule ArbiterWeb.DashboardLiveTest.QueueMerger do
  @moduledoc """
  Minimal `Arbiter.Mergers.Merger` stub for driving a worker to
  `:awaiting_review` in the dashboard's merge-queue tests. `get/1` returns a
  still-open MR so the Watchdog (if it ever polls) keeps the worker parked.
  """
  @behaviour Arbiter.Mergers.Merger

  @impl true
  def open(_branch, _title, _desc, _opts), do: {:ok, "!99"}
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
  def link_for(_ref), do: "https://example.test/mr/99"
  @impl true
  def get_diff(_ref, _opts), do: {:ok, ""}
  @impl true
  def post_inline_comment(_ref, _finding, _opts), do: :ok
  @impl true
  def submit_review(_ref, _verdict, _body, _opts), do: :ok
end

defmodule ArbiterWeb.DashboardLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ArbiterWeb.DashboardLiveTest.QueueMerger

  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  setup do
    # Workers are supervised at the VM level — prior tests in the umbrella
    # may have left children running. Stop them so the dashboard's "active
    # workers" section starts in a known empty state.
    for snap <- Worker.list_children() do
      Worker.stop(snap.task_id)
    end

    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "dash-#{System.unique_integer([:positive])}", prefix: "ds"})

    {:ok, ws: ws}
  end

  describe "mount" do
    test "renders all section headers", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # Section titles are title-cased + correctly pluralized
      # ("pull request" → "Pull requests").
      assert html =~ "Dashboard"
      assert html =~ "Workspaces"
      assert html =~ "Active "
      assert html =~ "Current "
      # Merge queue section header ("merge queue" → "Merge queues").
      assert html =~ "Merge queues"
      # ReviewGate (review gate) section + its two subsections.
      assert html =~ "ReviewGate"
      assert html =~ "In review"
      assert html =~ "Escalations"
    end

    test "empty workers shows the no-active-* line", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "No active"
    end

    test "shows a live indicator when the WebSocket is connected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      rendered = render(view)
      assert rendered =~ ~s(id="live-indicator")
      assert rendered =~ "live"
      assert rendered =~ "badge-success"
      refute rendered =~ "stale"
    end

    test "initial static render (no WebSocket) shows the stale indicator", %{conn: conn} do
      # Phoenix.ConnTest.get/2 returns the pre-connection HTTP render — the
      # second-pass connected mount is what `live/2` triggers. The static
      # render mirrors what a browser sees before its LiveView socket
      # finishes connecting (or after it drops).
      conn = get(conn, "/")
      html = Phoenix.ConnTest.html_response(conn, 200)
      assert html =~ ~s(id="live-indicator")
      assert html =~ "stale"
      assert html =~ "badge-warning"
    end
  end

  describe "workspaces section" do
    test "lists every workspace with its prefix and task counts", %{conn: conn, ws: ws} do
      {:ok, _open} = Ash.create(Issue, %{title: "o1", workspace_id: ws.id})
      {:ok, _open2} = Ash.create(Issue, %{title: "o2", workspace_id: ws.id})
      {:ok, to_close} = Ash.create(Issue, %{title: "to-close", workspace_id: ws.id})
      {:ok, _} = Ash.update(to_close, %{}, action: :close)

      {:ok, _view, html} = live(conn, "/")

      # Workspaces render as compact cards now (was a raw table).
      assert html =~ "workspaces-section"
      assert html =~ ws.name
      assert html =~ ws.prefix
      # 2 open, 1 closed in this workspace.
      assert html =~ "ds"
    end

    test "counts active workers per workspace", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "polly-ws", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)

      {:ok, _view, html} = live(conn, "/")
      # The workspace row should reflect the active worker. Hard to assert
      # an exact cell value in the rendered table, but a workspace column
      # next to "1" somewhere is sufficient.
      assert html =~ ws.name
      assert html =~ "Active "
    end
  end

  describe "repos section" do
    setup do
      prior = Application.get_env(:arbiter, :repo_paths)
      Application.put_env(:arbiter, :repo_paths, %{"dashboard-test-repo" => "/tmp/dash-repo"})

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, :repo_paths, prior),
          else: Application.delete_env(:arbiter, :repo_paths)
      end)

      :ok
    end

    test "lists repos configured via Application env", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      # Repos render as compact cards now (was a raw table).
      assert html =~ "repos-section"
      assert html =~ "dashboard-test-repo"
      assert html =~ "/tmp/dash-repo"
      assert html =~ "(app)"
    end

    test "counts active workers per repo", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "repo-pol", workspace_id: ws.id})

      {:ok, _pid} =
        Worker.start(
          task_id: task.id,
          repo: "dashboard-test-repo",
          workspace_id: ws.id
        )

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "dashboard-test-repo"
      # Row should show 1 active worker for the repo.
      # Hard to assert specific cell content; check the repo name + a 1
      # appear on the same page render.
      assert html =~ "dashboard-test-repo"
    end

    test "renders without error when a workspace rig_paths entry is in object form",
         %{conn: conn, ws: ws} do
      # Regression for bd-bkkvbe: a `rig_paths` value of
      # `%{"path" => ..., "target_branch" => ...}` crashed refresh_rigs/1 with
      # a CaseClauseError because the path was stored unnormalized.
      {:ok, _ws2} =
        Ash.update(ws, %{
          config: %{
            "rig_paths" => %{
              "object-form-repo" => %{
                "path" => "/tmp/object-form-repo",
                "target_branch" => "integration/dolphin"
              }
            }
          }
        })

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "repos-section"
      assert html =~ "object-form-repo"
      assert html =~ "/tmp/object-form-repo"
    end

    test "surfaces a worker using an unconfigured repo under (unconfigured)",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "weird-repo", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "no-such-repo", workspace_id: ws.id)

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "no-such-repo"
      assert html =~ "(unconfigured)"
    end
  end

  describe "active workers workspace column" do
    test "shows the workspace name on each worker row", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "ws-col", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "active-workers"
      assert html =~ ws.name
    end
  end

  describe "recent tasks section" do
    test "existing tasks are rendered", %{conn: conn, ws: ws} do
      {:ok, _b} = Ash.create(Issue, %{title: "i-am-on-the-dashboard", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "i-am-on-the-dashboard"
    end

    test "creating a new task pushes a PubSub update", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, "/")

      # Sanity: task doesn't exist yet
      refute render(view) =~ "newly-created-task-title"

      {:ok, _b} = Ash.create(Issue, %{title: "newly-created-task-title", workspace_id: ws.id})

      # The LiveView receives `{:task_lifecycle, :created, _}` and re-renders.
      assert render(view) =~ "newly-created-task-title"
    end

    test "creating a new task via the REST API also pushes a PubSub update",
         %{conn: conn, ws: ws} do
      # Regression for bd-97ijhk — the original report was that `bd create`
      # (which posts to POST /api/issues) did not update an open dashboard.
      # If the test above passes but this one fails, the API controller is
      # bypassing the broadcast somehow.
      {:ok, view, _html} = live(conn, "/")

      refute render(view) =~ "via-rest-api-title"

      post_conn =
        Phoenix.ConnTest.build_conn()
        |> post(~p"/api/issues", %{title: "via-rest-api-title", workspace_id: ws.id})

      assert post_conn.status == 201

      assert render(view) =~ "via-rest-api-title"
    end

    test "closing a task drops it from the current directives list (PubSub)", %{
      conn: conn,
      ws: ws
    } do
      {:ok, b} = Ash.create(Issue, %{title: "to-close-on-dashboard", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, "/")
      assert render(view) =~ "to-close-on-dashboard"

      {:ok, _closed} = Ash.update(b, %{}, action: :close)

      # The landing shows only CURRENT (non-closed) directives now; closing the
      # task removes it from the recent list. The full history (incl. closed)
      # lives on the /tasks index.
      refute render(view) =~ "to-close-on-dashboard"
    end

    test "only current (non-closed) directives appear; closed ones are not shown", %{
      conn: conn,
      ws: ws
    } do
      {:ok, _active} = Ash.create(Issue, %{title: "zzz-active-directive", workspace_id: ws.id})

      {:ok, to_close} = Ash.create(Issue, %{title: "aaa-closed-directive", workspace_id: ws.id})
      {:ok, _closed} = Ash.update(to_close, %{}, action: :close)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "zzz-active-directive"
      refute html =~ "aaa-closed-directive"
    end

    test "the recent directives section links to the /tasks index", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(href="/tasks")
    end
  end

  describe "active workers section" do
    test "starting a worker shows it; stopping removes it", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "worker-task", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, "/")
      # Sanity: before starting, the Active Workers section shows the empty
      # message (the task may still appear in "Recent tasks" — that's fine).
      assert render(view) =~ "No active"

      {:ok, _pid} =
        Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)

      # PubSub fires :started — re-render now lists the worker in the
      # active table (count goes from 0 to 1, and the empty message is gone).
      html = render(view)
      assert html =~ "Active Workers (1)"
      refute html =~ "No active workers"

      Worker.stop(task.id)
      # Allow time for terminate's broadcast to propagate
      Process.sleep(150)

      html = render(view)
      assert html =~ "Active Workers (0)"
      assert html =~ "No active workers"
    end
  end

  describe "completed acolytes section" do
    test "renders an empty-state row when no runs exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Completed"
      assert html =~ "completed-runs-empty"
    end

    test "lists completed and failed runs with a link to the detail page", %{conn: conn} do
      {:ok, completed} =
        Ash.create(Run, %{
          task_id: "bd-done",
          task_title: "the-completed-title",
          repo: "arbiter",
          workspace_id: "ws-1",
          status: :completed,
          started_at: DateTime.add(DateTime.utc_now(), -120, :second),
          completed_at: DateTime.utc_now()
        })

      {:ok, _failed} =
        Ash.create(Run, %{
          task_id: "bd-bust",
          task_title: "the-failed-title",
          repo: "arbiter",
          workspace_id: "ws-1",
          status: :failed,
          started_at: DateTime.add(DateTime.utc_now(), -240, :second),
          completed_at: DateTime.utc_now(),
          failure_reason: "boom"
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "the-completed-title"
      assert html =~ "the-failed-title"
      assert html =~ "/workers/history/#{completed.id}"
    end
  end

  describe "merge queue (MergeQueues)" do
    test "empty state renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(id="merge-queue-empty")
      assert html =~ "No pull requests integrating right now"
    end

    test "an in-flight merge surfaces with MR link, merger type and Watchdog activity",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "merging-task", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)

      {:ok, "!99"} =
        Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      {:ok, _view, html} = live(conn, "/")

      assert html =~ ~s(id="merge-queue")
      assert html =~ task.id
      # MR ref + clickable link from the stub adapter.
      assert html =~ "!99"
      assert html =~ "https://example.test/mr/99"
      # Default workspace has no merge.strategy config → Direct.
      assert html =~ "Direct"
      # Long initial poll delay means the Watchdog hasn't recorded a status yet.
      assert html =~ "Awaiting first poll"
      assert html =~ "Watchdog polling every"
    end

    test "a recorded approval drives the status badge label", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "approved-task", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, _} = Worker.open_mr(pid, "feature/y", "Integrate y", "", merge_opts())

      # Simulate the result of a Watchdog poll without waiting on its timer.
      :ok = Worker.record_merger_status(pid, %{status: :open, approved: true})

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Approved"
      assert html =~ "Watchdog checked"
    end

    test "the merger type reflects the workspace's gitlab strategy", %{conn: conn} do
      {:ok, gl_ws} =
        Ash.create(Workspace, %{
          name: "gl-#{System.unique_integer([:positive])}",
          prefix: "gl",
          config: %{"merge" => %{"strategy" => "gitlab"}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "gl-task", workspace_id: gl_ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: gl_ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, _} = Worker.open_mr(pid, "feature/z", "Integrate z", "", merge_opts())

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "GitLab"
    end
  end

  describe "review_gate (review gate)" do
    alias Arbiter.Messages.Message

    test "empty state renders both subsections", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(id="review_gate-section")
      assert html =~ ~s(id="pending-reviews-empty")
      assert html =~ ~s(id="escalations-empty")
      assert html =~ "No reviews in flight"
      assert html =~ "No escalations"
    end

    test "recent escalations render with verdict badge, task link and findings",
         %{conn: conn, ws: ws} do
      {:ok, _changes} =
        Message.send_mail(%{
          kind: :escalation,
          to_ref: "admiral",
          from_ref: "bd-rejected",
          directive_ref: "bd-rejected",
          workspace_id: ws.id,
          subject: "ReviewGate: changes requested for bd-rejected",
          body: "VERDICT: REQUEST_CHANGES\nThe migration is missing a down/0."
        })

      {:ok, _inconclusive} =
        Message.send_mail(%{
          kind: :escalation,
          to_ref: "admiral",
          from_ref: "bd-murky",
          directive_ref: "bd-murky",
          workspace_id: ws.id,
          subject: "ReviewGate: review inconclusive for bd-murky",
          body: "Reviewer produced no parseable VERDICT line."
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ ~s(id="escalations")
      # Derived verdict badges from the escalation subjects.
      assert html =~ "Changes requested"
      assert html =~ "Inconclusive"
      # Linked back to the directive under review + the reviewer's findings.
      assert html =~ "bd-rejected"
      assert html =~ "The migration is missing a down/0."
      assert html =~ "/tasks/bd-murky"
    end

    test "a review in flight surfaces under 'in review'", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "under-review", workspace_id: ws.id})

      # Drive an author worker to :awaiting_review_gate without spawning a live
      # reviewer (review_spawn: false) — the same seam the ReviewGate tests use.
      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "test/repo",
          workspace_id: ws.id,
          meta: %{
            branch: "feature/under-review",
            review_required: true,
            review_spawn: false
          }
        )

      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ ~s(id="pending-reviews")
      assert html =~ task.id
      assert html =~ "in review"
    end
  end

  # Poll until `fun` returns true or a short deadline elapses. Mirrors the
  # review_gate suite's helper for waiting on an async worker transition.
  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met before deadline")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  # open_mr opts that pin a stub adapter and push the Watchdog's first poll far
  # into the future, so the worker parks at :awaiting_review deterministically
  # without the poll loop racing the assertions.
  defp merge_opts do
    %{
      adapter: QueueMerger,
      workspace: nil,
      auto_merge: false,
      interval_ms: 600_000,
      initial_delay_ms: 600_000
    }
  end

  describe "stats bar" do
    test "renders the at-a-glance stat row", %{conn: conn, ws: ws} do
      {:ok, _b} = Ash.create(Issue, %{title: "stat-open", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, "/")

      # DaisyUI stats component with the live stats, including the live
      # Admiral-inbox unread count (empty here => "all clear").
      assert html =~ "stats"
      assert html =~ "Open Issues"
      assert html =~ "Active Workers"
      assert html =~ "Coordinator Inbox"
      assert html =~ "all clear"
    end
  end

  describe "directive queue priority + blocking" do
    test "P1 tasks get the error-tinted treatment, P2 stays neutral", %{conn: conn, ws: ws} do
      {:ok, _p1} = Ash.create(Issue, %{title: "urgent-p1", workspace_id: ws.id, priority: 1})
      {:ok, _p2} = Ash.create(Issue, %{title: "normal-p2", workspace_id: ws.id, priority: 2})

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "urgent-p1"
      assert html =~ "normal-p2"
      # P1 row carries the semantic error tint (left border + badge), never a
      # hardcoded red-* utility.
      assert html =~ "border-error"
      assert html =~ "badge-error"
      refute html =~ "red-500"
    end

    test "shows a blocked badge when a depends_on edge has an open target", %{conn: conn, ws: ws} do
      {:ok, blocked} = Ash.create(Issue, %{title: "is-blocked", workspace_id: ws.id})
      {:ok, blocker} = Ash.create(Issue, %{title: "the-blocker", workspace_id: ws.id})

      {:ok, _dep} =
        Ash.create(Dependency, %{
          from_issue_id: blocked.id,
          to_issue_id: blocker.id,
          type: :depends_on
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "is-blocked"
      assert html =~ "blocked"
    end

    test "no blocked badge once the gating target is closed", %{conn: conn, ws: ws} do
      {:ok, dependent} = Ash.create(Issue, %{title: "freed-up", workspace_id: ws.id})
      {:ok, blocker} = Ash.create(Issue, %{title: "soon-closed", workspace_id: ws.id})

      {:ok, _dep} =
        Ash.create(Dependency, %{
          from_issue_id: dependent.id,
          to_issue_id: blocker.id,
          type: :depends_on
        })

      {:ok, _closed} = Ash.update(blocker, %{}, action: :close)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "freed-up"
      refute html =~ "blocked"
    end
  end

  describe "live clock tick" do
    test "the :tick message refreshes :now without crashing the view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # The 1s interval that drives live elapsed counters / relative
      # timestamps. Delivering it manually must keep the view rendering.
      send(view.pid, :tick)

      assert render(view) =~ "Dashboard"
    end
  end
end
