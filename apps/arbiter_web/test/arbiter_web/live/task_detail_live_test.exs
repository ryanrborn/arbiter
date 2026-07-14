defmodule ArbiterWeb.TaskDetailLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  setup do
    for snap <- Worker.list_children() do
      Worker.stop(snap.task_id)
    end

    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "bd-ws-#{System.unique_integer([:positive])}", prefix: "bdt"})

    {:ok, ws: ws}
  end

  describe "GET /tasks/:id" do
    test "renders the task with workspace, status, and history", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "important thing",
          description: "do the thing",
          workspace_id: ws.id,
          priority: 1
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ task.id
      assert html =~ "important thing"
      assert html =~ "do the thing"
      assert html =~ ws.name
      # History section shows the :create version.
      assert html =~ "History"
      assert html =~ "create"
    end

    test "renders blocked-by + blocks dependency sections", %{conn: conn, ws: ws} do
      {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :blocks
        })

      {:ok, _view, html} = live(conn, ~p"/tasks/#{a.id}")

      assert html =~ "Blocked by (1)"
      assert html =~ b.id
      assert html =~ "B"
    end

    test "shows worker info inline when one is running", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "polly", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo")

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Worker"
      assert html =~ "idle"
      assert html =~ "view full output"
    end

    # Regression for bd-bb9fev: a worker snapshot without `:claude_session?`
    # used to crash render/1 with BadBooleanError because the strict `and`
    # operator rejected a nil left operand.
    test "renders when the worker snapshot has no :claude_session? field",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no-claude", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo")

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ task.id
      assert html =~ "Worker"
    end

    test "tells the user when no worker is running", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "lonely", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ "No worker running"
      assert html =~ "arb dispatch"
    end

    test "404-ish state when task doesn't exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks/bdt-doesnotexist")
      assert html =~ "not found"
    end

    test "re-renders when a relevant task_lifecycle fires", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "transitioning", workspace_id: ws.id})

      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
      assert html =~ "open"

      {:ok, _} = Ash.update(task, %{status: :in_progress})

      assert render(view) =~ "in_progress"
    end
  end

  describe "Merge section — prior MR history (bd-6h4ia3)" do
    defp create_run(task, mr_ref, started_at) do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: task.id,
          repo: "test/repo",
          status: :completed,
          started_at: started_at,
          mr_ref: mr_ref
        })

      run
    end

    test "single worker run with one MR shows no history clutter", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "one mr", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{pr_ref: "#100"})

      create_run(task, "#100", ~U[2026-07-01 00:00:00.000000Z])

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "#100"
      refute html =~ "Prior MRs"
    end

    test "multiple runs opening genuinely different MRs show all, most recent first", %{
      conn: conn,
      ws: ws
    } do
      {:ok, task} = Ash.create(Issue, %{title: "many mrs", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{pr_ref: "#300"})

      create_run(task, "#100", ~U[2026-07-01 00:00:00.000000Z])
      create_run(task, "#200", ~U[2026-07-02 00:00:00.000000Z])
      create_run(task, "#300", ~U[2026-07-03 00:00:00.000000Z])

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ "Prior MRs"
      assert html =~ "#100"
      assert html =~ "#200"
      assert html =~ "#300"

      idx200 = :binary.match(html, "#200") |> elem(0)
      idx100 = :binary.match(html, "#100") |> elem(0)
      assert idx200 < idx100
    end

    test "task resumed multiple times against the same MR shows it once", %{
      conn: conn,
      ws: ws
    } do
      {:ok, task} = Ash.create(Issue, %{title: "resumed same mr", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{pr_ref: "#100"})

      create_run(task, "#100", ~U[2026-07-01 00:00:00.000000Z])
      create_run(task, "#100", ~U[2026-07-02 00:00:00.000000Z])
      create_run(task, "#100", ~U[2026-07-03 00:00:00.000000Z])

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert (html |> String.split("#100") |> length()) - 1 == 1
      refute html =~ "Prior MRs"
    end
  end
end
