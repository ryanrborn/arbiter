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
      assert html =~ "Workspace:"
      assert html =~ ws.name
    end

    test "Stop button kills the worker and redirects to /", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-stop", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r")

      {:ok, view, html} = live(conn, ~p"/workers/#{task.id}")
      assert html =~ "Stop worker"

      result = render_click(view, "stop")

      # push_navigate emits a {:live_redirect, ...} return from render_click.
      assert {:error, {:live_redirect, %{to: "/"}}} = result
      assert Worker.whereis(task.id) == nil
    end

    test "no Stop button when the worker is :completed", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "pd-done", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r")
      :ok = Worker.advance(pid, :design)
      :ok = Worker.complete(pid, :done)

      {:ok, _view, html} = live(conn, ~p"/workers/#{task.id}")
      refute html =~ "Stop worker"
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

      assert html =~ "Workflow:"
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
