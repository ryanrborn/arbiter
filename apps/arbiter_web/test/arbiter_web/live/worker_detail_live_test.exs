defmodule ArbiterWeb.WorkerDetailLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  setup do
    for snap <- Worker.list_children() do
      Worker.stop(snap.task_id)
    end

    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "pd-ws-#{System.unique_integer([:positive])}", prefix: "pd"})

    {:ok, ws: ws}
  end

  describe "GET /workers/:task_id" do
    test "renders the snapshot for a running worker", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-test", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo")
      :ok = Worker.report(pid, :output_lines, ["hello", "world", "arb done"])

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")

      assert html =~ task.id
      assert html =~ "test/repo"
      assert html =~ "hello"
      assert html =~ "arb done"
    end

    test "tells the user when no worker is registered", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workers/no-such-task")
      assert html =~ "No worker registered"
    end

    test "updates live when the worker receives new output", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-live", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, view, html} = live(conn, ~p"/workers/#{task.id}")
      refute html =~ "fresh-line"

      # Push an output line via the same PubSub topic the worker would use.
      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        "worker:" <> task.id,
        {:worker_output, task.id, "fresh-line"}
      )

      # Worker's meta won't actually contain the line because we only
      # broadcast — but the LiveView still re-reads the snapshot on the
      # event. So let's seed the output_lines via report/3 and then
      # broadcast to trigger the refresh.
      :ok = Worker.report(pid, :output_lines, ["fresh-line"])

      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        "worker:" <> task.id,
        {:worker_output, task.id, "fresh-line"}
      )

      assert render(view) =~ "fresh-line"
    end

    test "toolbar shows elapsed runtime beside the status chip", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-elapsed", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")

      # started_at is "now" at spawn time, so the toolbar reads e.g. "0s"/"0m".
      assert html =~ ~r/font-mono[^>]*>\s*\d+[smh]/
    end

    test "shows the workspace context when the task exists", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-ws", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")
      assert html =~ "Workspace"
      assert html =~ ws.name
    end

    test "toolbar wraps on mobile", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-wrap", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      # Toolbar should have flex-wrap to allow items to wrap on narrow viewports
      assert has_element?(view, "div[class*='flex-wrap'][class*='gap-\\[14px\\]']")
    end

    test "metadata rail is responsive on mobile", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-responsive", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")

      # Metadata rail grid should be responsive: single column on mobile, two columns on large screens
      assert has_element?(view, "div[class*='grid-cols-1'][class*='lg:grid-cols-']")
    end

    test "Stop signals the worker, stays on the page, and toasts the worktree notice",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-stop", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      assert has_element?(view, "#worker-stop-btn")

      html = render_click(view, "stop")

      # Stays on the page — no redirect — but the worker really is gone.
      assert Worker.whereis(task.id) == nil

      # Verbatim toast copy per the design handoff; the worktree survives.
      assert html =~ "Stop signalled to #{task.id} — the worktree is left in place"
      assert html =~ ~s(id="stop-toast")

      # Stop button flips to a secondary Resume action.
      refute has_element?(view, "#worker-stop-btn")
      assert has_element?(view, "#worker-toolbar-resume-btn")

      # The chip/flow node read as failed/stopped.
      assert html =~ ~s(badge-error)

      # The phx-click lives on the "resume" action span only, not the toast
      # root — clicking the toast body/dismiss hint must not open the modal.
      refute has_element?(view, ~s(div#stop-toast[phx-click]))
      assert has_element?(view, ~s(#stop-toast span[phx-click="open_retry"]), "resume")
    end

    test "stop notice clears when the worker restarts from outside this view",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-restart", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      html = render_click(view, "stop")
      assert html =~ "the worktree is left in place"
      assert has_element?(view, "#worker-toolbar-resume-btn")

      # Simulate the worker being resumed from outside this LiveView (another
      # tab, the issue page, `arb worker resume`) — a fresh `:started` echo
      # arrives on the shared "workers" topic.
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      html = render(view)
      refute html =~ "the worktree is left in place"
      refute has_element?(view, "#worker-toolbar-resume-btn")
    end

    test "stop notice survives an unrelated worker's lifecycle events",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-stop-unrelated", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, other_task} = Ash.create(Issue, %{title: "pd-other", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      html = render_click(view, "stop")
      assert html =~ "the worktree is left in place"
      assert has_element?(view, "#worker-toolbar-resume-btn")
      assert html =~ ~s(badge-error)

      # An unrelated worker starting (and later stopping) broadcasts on the
      # same shared "workers" topic — it must not clobber our synthetic
      # stopped snapshot/toast/chip/flow.
      {:ok, _other_pid} = Worker.start(task_id: other_task.id, repo: "r")
      Worker.stop(other_task.id)
      Process.sleep(20)

      html = render(view)
      assert html =~ "the worktree is left in place"
      assert has_element?(view, "#worker-toolbar-resume-btn")
      assert html =~ ~s(badge-error)
    end

    test "no Stop button when the worker is :completed", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-done", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.advance(pid, :design)
      :ok = Worker.complete(pid, :done)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      refute has_element?(view, "#worker-stop-btn")
    end

    test "status badge for :resuming is colored and labeled with the literal status",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-resuming", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", meta: %{resume: true})

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")

      assert html =~ "badge-info"
      assert html =~ "resuming"
    end

    test "status badge for :awaiting_review_gate is colored and labeled with the literal status",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-review-gate", workspace_id: ws.id})

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "test/repo",
          workspace_id: ws.id,
          meta: %{
            branch: "feature/pd-review-gate",
            review_required: true,
            review_spawn: false
          }
        )

      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")

      assert html =~ "badge-warning"
      assert html =~ "awaiting_review_gate"
    end

    test "renders the workflow step bar when a MachineState exists",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-wf", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, _machine_id} =
        Arbiter.Workflows.Machine.attach(Arbiter.Workflows.Work, task.id, %{
          task_id: task.id,
          worktree_path: nil,
          repo: "r"
        })

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")

      assert html =~ "Workflow"
      # Work's first step is :load_context.
      assert html =~ "load_context"
      assert html =~ "submit"
    end

    test "a claude-driven worker shows live activity, not frozen workflow steps",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-claude", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")

      # Even with a MachineState attached (slung workers always have one), a
      # claude-driven run must NOT show the never-advancing fixed steps — it
      # shows the live activity derived from the stream instead. See bd-c919xj.
      {:ok, _machine_id} =
        Arbiter.Workflows.Machine.attach(Arbiter.Workflows.Work, task.id, %{
          task_id: task.id,
          worktree_path: nil,
          repo: "r"
        })

      :ok = Worker.advance(pid, :claude)
      :ok = Worker.report(pid, :claude_session, true)
      :ok = Worker.report(pid, :activity, "running tests")

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")

      assert html =~ "Live activity"
      assert html =~ "running tests"
      # The misleading frozen workflow card + fixed steps are suppressed.
      refute html =~ "Workflow:"
      refute html =~ "load_context"
    end

    test "approval badge shows 'CI running' when pipeline is in progress" do
      # Test the approval_label_default/1 function directly
      status_with_ci_running = %{
        status: :open,
        approved: false,
        pipeline: :running
      }

      # The approval_label_default function is private, but we can test through
      # the approval_label/1 which calls it
      label = ArbiterWeb.WorkerDetailLive.approval_label(status_with_ci_running)
      assert label == "Open · CI running"
    end

    test "approval badge shows 'awaiting approval' when pipeline is settled" do
      # Test when pipeline is settled (not running)
      status_awaiting_approval = %{
        status: :open,
        approved: false,
        pipeline: :success
      }

      label = ArbiterWeb.WorkerDetailLive.approval_label(status_awaiting_approval)
      assert label == "Open · awaiting approval"
    end

    test "approval badge color is info for CI running" do
      status_with_ci_running = %{
        status: :open,
        approved: false,
        pipeline: :running
      }

      badge_class = ArbiterWeb.WorkerDetailLive.approval_class(status_with_ci_running)
      assert badge_class == "badge-info"
    end

    test "approval badge color is warning for awaiting approval" do
      status_awaiting_approval = %{
        status: :open,
        approved: false,
        pipeline: :success
      }

      badge_class = ArbiterWeb.WorkerDetailLive.approval_class(status_awaiting_approval)
      assert badge_class == "badge-warning"
    end

    test "live activity badge advances after mount with no manual lifecycle event",
         %{conn: conn, ws: ws} do
      # Regression for bd-c919xj: meta[:activity] updates on every stream line,
      # but that path must also *broadcast* so a mounted view refreshes. Mount
      # first, then have the live session emit a second event that changes the
      # activity label, and assert the badge advances — driven solely by the
      # worker's own activity-change broadcast, not an injected lifecycle event.
      {:ok, task} = Ash.create(Issue, %{title: "pd-advance", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")

      cwd = Path.join(System.tmp_dir!(), "pd-advance-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      e1 = Path.join(cwd, "e1.jsonl")
      e2 = Path.join(cwd, "e2.jsonl")

      File.write!(e1, tool_use_event("Edit", %{"file_path" => "/r/widget.ex"}) <> "\n")
      File.write!(e2, tool_use_event("Bash", %{"command" => "mix test"}) <> "\n")

      # Emit the first event, pause, then emit the second. The pause leaves a
      # window to mount the view between the two activities.
      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "cat #{e1}; sleep 0.4; cat #{e2}"]
        )

      # First activity distilled → mount → badge shows it.
      wait_until(fn ->
        match?(%{label: "editing widget.ex"}, Map.get(Worker.state(task.id).meta, :activity))
      end)

      {:ok, view, html} = live(conn, ~p"/workers/#{task.id}")
      assert html =~ "editing widget.ex"
      refute html =~ "running tests"

      # Second activity arrives on the live session. When the worker's state
      # reflects it, its activity-change broadcast has already been delivered to
      # the (subscribed) view's mailbox, so the next render processes it first.
      wait_until(fn ->
        match?(%{label: "running tests"}, Map.get(Worker.state(task.id).meta, :activity))
      end)

      assert render(view) =~ "running tests"
    end

    test "output section has proper phx-hook attribute for auto-scroll", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-scroll", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.report(pid, :output_lines, ["line 1", "line 2"])

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")

      # The log_stream component brings its own colocated stick-to-bottom
      # hook. Per Phoenix.LiveView.ColocatedHook convention, the source uses
      # name=".LogStreamStick" and phx-hook=".LogStreamStick", but at render
      # time Phoenix qualifies it to the module path for resolution.
      assert html =~ ~s(id="worker-output")
      assert html =~ ~s(phx-hook="ArbiterWeb.CoreComponents.Domain.LogStreamStick")
    end

    test "long output lines keep their full text reachable via title", %{conn: conn, ws: ws} do
      long_line = String.duplicate("x", 400)
      {:ok, task} = Ash.create(Issue, %{title: "pd-long-line", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.report(pid, :output_lines, [long_line])

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")

      assert html =~ ~s(title="#{long_line}")
    end

    test "navigation actions render as buttons, not buttons nested in anchors",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-nav", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.fail(pid, :boom)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")

      refute has_element?(view, "a button")
    end

    test "awaiting-review panel's Open PR link is not a button nested in an anchor",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-awaiting-ref", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.advance(pid, :claude)
      :ok = Worker.report(pid, :mr_ref, "https://github.com/org/repo/pull/42")
      :ok = Worker.await(pid)

      {:ok, view, html} = live(conn, ~p"/workers/#{task.id}")

      refute has_element?(view, "a button")
      assert has_element?(view, ~s(a[href="https://github.com/org/repo/pull/42"]))
      assert html =~ "Open pull request"
    end
  end

  describe "retry / resume" do
    test "a failed worker offers a Resume action", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-failed", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.fail(pid, :boom)

      {:ok, view, html} = live(conn, ~p"/workers/#{task.id}")

      assert has_element?(view, "#worker-toolbar-resume-btn")
      assert html =~ "Resume"
    end

    test "a running worker offers no active Resume action", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-running", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      refute has_element?(view, "#worker-toolbar-resume-btn")
      refute has_element?(view, "#worker-fallback-resume-btn")
      # The rail's "Resume with note" action stays visible but disabled.
      assert has_element?(view, "#worker-resume-note-btn[disabled]")
    end

    test "an unregistered worker still offers Resume when the task exists",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-gone", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      assert has_element?(view, "#worker-fallback-resume-btn")
    end

    test "no Resume for a task that doesn't exist at all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workers/no-such-task")
      refute has_element?(view, "#worker-fallback-resume-btn")
    end

    # `Dispatch.resume/2` refuses a closed issue outright, so offering an
    # active button would only ever produce an error flash.
    test "no active Resume for a closed issue", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-closed", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.fail(pid, :boom)
      {:ok, _} = Ash.update(task, %{}, action: :close)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      refute has_element?(view, "#worker-toolbar-resume-btn")
      refute has_element?(view, "#worker-fallback-resume-btn")
      refute has_element?(view, "#worker-resume-note-btn")
    end

    test "the Retry modal warns about API credits before re-spawning",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-retry-modal", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.fail(pid, :boom)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      html = view |> element("#worker-toolbar-resume-btn") |> render_click()

      assert html =~ ~s(id="worker-retry-modal")
      assert html =~ "API credits"
    end

    # Confirming runs the same `Dispatch.resume/2` path `arb worker resume`
    # uses. This task has no preserved worktree, so it fails there — before
    # any agent is spawned — and the reason is surfaced to the operator.
    #
    # Resume runs in start_async/3 (same reason dispatch does — a provider CLI
    # auth preflight is far too long to hold the LiveView process for), so the
    # click only shows the pending state and the outcome lands after.
    test "confirming retry runs the real resume path and surfaces its error",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-retry-run", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.fail(pid, :boom)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      view |> element("#worker-toolbar-resume-btn") |> render_click()

      pending = render_click(view, "retry")
      assert pending =~ ~s(id="worker-retry-pending")

      html = render_async(view)

      # The modal stays open with the reason inline, rather than closing and
      # leaving the operator to catch a flash.
      assert html =~ "Resume failed"
      assert html =~ ~s(id="worker-retry-modal")
      refute html =~ ~s(id="worker-retry-pending")
    end

    test "a second retry click while one is in flight does not spend credits twice",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-retry-double", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.fail(pid, :boom)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      view |> element("#worker-toolbar-resume-btn") |> render_click()

      render_click(view, "retry")
      # Still pending — the guard clause drops this one on the floor rather
      # than starting a second resume.
      render_click(view, "retry")

      assert render_async(view) =~ "Resume failed"
    end
  end

  describe "retry auto-resolve (bd-bspakl)" do
    alias Arbiter.Test.StubMerger
    alias Arbiter.Worker.Watchdog

    setup do
      StubMerger.reset()
      :ok
    end

    # Actually drives the task's real Watchdog to the state under test, rather
    # than just faking the merger-status meta — the button now gates on the
    # Watchdog's own `park_reason` (`parked_on/1`), which is only set once the
    # Watchdog itself processes a poll (bd-bspakl review round 1). Setting
    # `max_auto_resolve_attempts: 0` on the workspace makes the very first
    # `:ci_failed` poll exhaust immediately, so no fix-pass worker is ever
    # dispatched.
    defp park_awaiting_review(pid, task, merger_status, opts \\ []) do
      :ok = Worker.advance(pid, :implement)
      ref = "!bd-bspakl-#{System.unique_integer([:positive])}"
      StubMerger.next_open_ref(ref)
      StubMerger.queue_get(ref, [merger_status])

      {:ok, workspace} = Ash.get(Workspace, task.workspace_id)

      {:ok, _} =
        Worker.open_mr(
          pid,
          "feature/x",
          "Add x",
          "desc",
          Map.merge(
            %{
              adapter: StubMerger,
              workspace: workspace,
              auto_merge: true,
              interval_ms: 15,
              initial_delay_ms: 0
            },
            Map.new(opts)
          )
        )

      ref
    end

    defp set_max_auto_resolve_attempts(ws, n) do
      {:ok, ws} =
        Ash.update(ws, %{patch: %{"merge" => %{"max_auto_resolve_attempts" => n}}},
          action: :patch_config
        )

      ws
    end

    test "offers Retry auto-resolve once the Watchdog genuinely parks on exhausted :ci_failed",
         %{conn: conn, ws: ws} do
      ws = set_max_auto_resolve_attempts(ws, 0)
      {:ok, task} = Ash.create(Issue, %{title: "pd-ci-failed", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      park_awaiting_review(pid, task, %{status: :open, approved: true, block_reason: :ci_failed})

      wait_until(fn -> Watchdog.parked_on(task.id) == :ci_failed end)

      {:ok, view, html} = live(conn, ~p"/workers/#{task.id}")

      assert has_element?(view, "#worker-retry-auto-resolve-btn")
      assert html =~ "Retry auto-resolve"
    end

    test "keeps offering Retry auto-resolve after an :ci_failed_external verdict (bd-5mzzww)",
         %{conn: conn, ws: ws} do
      # Marking the park external reclassifies it but does not make it any less
      # retryable — once the infrastructure is fixed, re-arming is exactly the
      # right move. Hiding the button here would strand the task.
      ws = set_max_auto_resolve_attempts(ws, 0)
      {:ok, task} = Ash.create(Issue, %{title: "pd-ci-ext", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      park_awaiting_review(pid, task, %{status: :open, approved: true, block_reason: :ci_failed})

      wait_until(fn -> Watchdog.parked_on(task.id) == :ci_failed end)
      assert :ok = Watchdog.mark_ci_external(task.id, "shared runners down repo-wide today")
      wait_until(fn -> Watchdog.parked_on(task.id) == :ci_failed_external end)

      {:ok, view, html} = live(conn, ~p"/workers/#{task.id}")

      assert has_element?(view, "#worker-retry-auto-resolve-btn")
      assert html =~ "Retry auto-resolve"
    end

    test "offers Retry auto-resolve for a ReviewGate lane even though the forge shows approved: false",
         %{conn: conn, ws: ws} do
      # The exact gap this ticket closed: on a ReviewGate-driven lane the forge
      # never sees the in-process approval, so `approved` stays false even
      # though the Watchdog (using the ReviewGate-aware poll path) genuinely
      # parks on the block. The old arity-1 `effective_block_reason/1` gate
      # hardcoded `via_review_gate: false` and could never see this.
      ws = set_max_auto_resolve_attempts(ws, 0)
      {:ok, task} = Ash.create(Issue, %{title: "pd-ci-failed-gate", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")

      park_awaiting_review(
        pid,
        task,
        %{status: :open, approved: false, block_reason: :ci_failed},
        via_review_gate: true
      )

      wait_until(fn -> Watchdog.parked_on(task.id) == :ci_failed end)

      {:ok, view, html} = live(conn, ~p"/workers/#{task.id}")

      assert has_element?(view, "#worker-retry-auto-resolve-btn")
      assert html =~ "Retry auto-resolve"
    end

    test "does not offer Retry auto-resolve for an approved MR blocked on something else",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-conflict", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      park_awaiting_review(pid, task, %{status: :open, approved: true, block_reason: :conflict})

      # Not waiting on `parked_on/1` here: a `:conflict` block only parks
      # after exhausting its own bounded rebase-attempt budget, which is not
      # guaranteed to land inside a short poll window. Waiting for the
      # Watchdog to exist and letting one poll interval elapse is enough to
      # observe the button's render decision either way — it must not appear
      # for a `:conflict` reason regardless of whether the block has parked.
      wait_until(fn -> Watchdog.whereis(task.id) != nil end)
      Process.sleep(50)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")

      refute has_element?(view, "#worker-retry-auto-resolve-btn")
    end

    test "does not offer Retry auto-resolve while still awaiting approval",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-pending", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      park_awaiting_review(pid, task, %{status: :open, approved: false})

      # See the :conflict test above for why this waits on Watchdog liveness
      # plus one poll interval rather than on `parked_on/1`.
      wait_until(fn -> Watchdog.whereis(task.id) != nil end)
      Process.sleep(50)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")

      refute has_element?(view, "#worker-retry-auto-resolve-btn")
    end

    test "clicking Retry auto-resolve re-arms the Watchdog and reports the next-poll timing accurately",
         %{conn: conn, ws: ws} do
      ws = set_max_auto_resolve_attempts(ws, 0)
      {:ok, task} = Ash.create(Issue, %{title: "pd-retry-flash", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      park_awaiting_review(pid, task, %{status: :open, approved: true, block_reason: :ci_failed})

      wait_until(fn -> Watchdog.parked_on(task.id) == :ci_failed end)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")

      html = render_click(view, "retry_auto_resolve")

      # Pins the accurate claim (round-1 review: the old copy claimed "a
      # fresh fix-pass is starting" / "a poll fired now", which is false —
      # `handle_call(:retry_auto_resolve, ...)` deliberately does not
      # schedule an immediate poll, so the fix-pass only starts once the
      # already-pending poll timer next fires).
      assert html =~ "will start on the next watchdog poll"
      refute html =~ "is starting"
    end

    test "the retry_auto_resolve event shows a friendly error when nothing is parked",
         %{conn: conn, ws: ws} do
      # The button itself no longer renders unless the Watchdog is genuinely
      # parked (see above), but the event handler is still reachable directly
      # (e.g. a stale page, or a race between render and the block clearing)
      # and must still fail soft rather than crash the LiveView.
      {:ok, task} = Ash.create(Issue, %{title: "pd-click-error", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")

      html = render_click(view, "retry_auto_resolve")

      # No Watchdog was started for this task, so `retry_auto_resolve/1`
      # deterministically returns `{:error, :not_found}` — this pins that
      # specific soft-failure message rather than accepting either branch.
      assert html =~ "No merge watchdog is currently running"
    end
  end

  describe "dead watchdog (bd-8jixav)" do
    alias Arbiter.Test.StubMerger
    alias Arbiter.Worker.Watchdog

    setup do
      StubMerger.reset()
      :ok
    end

    # Reproduces the incident exactly: the MR is genuinely open, the worker is
    # parked at :awaiting_review, and no Watchdog is registered. The
    # `watchdog_start_error` escape hatch gets us there without killing a real
    # process mid-poll.
    defp park_without_watchdog(pid, task, ref) do
      :ok = Worker.advance(pid, :implement)
      StubMerger.next_open_ref(ref)
      {:ok, workspace} = Ash.get(Workspace, task.workspace_id)

      {:ok, _} =
        Worker.open_mr(pid, "feature/x", "Add x", "desc", %{
          adapter: StubMerger,
          workspace: workspace,
          auto_merge: true,
          interval_ms: 15,
          initial_delay_ms: 0,
          watchdog_start_error: true
        })

      ref
    end

    test "warns that no watchdog is running and offers a restart", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-dead-wd", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      park_without_watchdog(pid, task, "!wd-dead-1")

      refute Watchdog.alive?(task.id)

      {:ok, view, html} = live(conn, ~p"/workers/#{task.id}")

      assert html =~ "No watchdog is running"
      assert has_element?(view, "#worker-restart-watchdog-btn")
    end

    test "shows neither warning nor button while a watchdog is alive", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-live-wd", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.advance(pid, :implement)
      StubMerger.next_open_ref("!wd-live-1")
      # Never resolves, so the Watchdog stays alive polling.
      StubMerger.queue_get("!wd-live-1", [%{status: :open, approved: false}])
      {:ok, workspace} = Ash.get(Workspace, task.workspace_id)

      {:ok, _} =
        Worker.open_mr(pid, "feature/x", "Add x", "desc", %{
          adapter: StubMerger,
          workspace: workspace,
          auto_merge: false,
          interval_ms: 10_000,
          initial_delay_ms: 10_000
        })

      wait_until(fn -> Watchdog.alive?(task.id) end)

      {:ok, view, html} = live(conn, ~p"/workers/#{task.id}")

      refute html =~ "No watchdog is running"
      refute has_element?(view, "#worker-restart-watchdog-btn")
    end

    test "the restart_watchdog event starts a real replacement watchdog", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-restart-wd", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      ref = park_without_watchdog(pid, task, "!wd-dead-2")
      # The replacement's first poll finds it still open, so it keeps running.
      StubMerger.queue_get(ref, [%{status: :open, approved: false}])

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")

      render_click(view, "restart_watchdog")
      # The handler runs via `start_async`, so wait for the reply to land
      # rather than assuming render_click drained it.
      wait_until(fn -> render(view) =~ "Restarted the merge watchdog" end)

      assert Watchdog.alive?(task.id)
      # And the page stops warning, since the snapshot is refreshed.
      refute render(view) =~ "No watchdog is running"
    end

    test "the restart_watchdog event fails soft when there is no worker", %{conn: conn, ws: ws} do
      # Reachable from a stale page after the worker exited.
      {:ok, task} = Ash.create(Issue, %{title: "pd-restart-noworker", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      park_without_watchdog(pid, task, "!wd-dead-3")

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")

      Worker.stop(pid)
      wait_until(fn -> is_nil(Worker.whereis(task.id)) end)

      render_click(view, "restart_watchdog")
      wait_until(fn -> render(view) =~ "No worker is running" end)

      refute Watchdog.alive?(task.id)
    end
  end

  defp tool_use_event(name, input) do
    Jason.encode!(%{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "tool_use", "name" => name, "input" => input}]
      }
    })
  end

  defp wait_until(fun, timeout_ms \\ 2_000, step_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline, step_ms)
  end

  defp do_wait_until(fun, deadline, step_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until/3 timed out")
      else
        Process.sleep(step_ms)
        do_wait_until(fun, deadline, step_ms)
      end
    end
  end
end
