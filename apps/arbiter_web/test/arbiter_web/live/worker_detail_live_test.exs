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

    test "shows the workspace context when the task exists", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-ws", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")
      assert html =~ "Workspace"
      assert html =~ ws.name
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
