defmodule ArbiterWeb.TaskIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}
  require Ash.Query

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "bi-#{System.unique_integer([:positive])}", prefix: "bix"})

    {:ok, ws: ws}
  end

  test "lists all directives regardless of status", %{conn: conn, ws: ws} do
    {:ok, _open} = Ash.create(Issue, %{title: "open-directive", workspace_id: ws.id})
    {:ok, to_close} = Ash.create(Issue, %{title: "closed-directive", workspace_id: ws.id})
    {:ok, _} = Ash.update(to_close, %{}, action: :close)

    {:ok, _view, html} = live(conn, ~p"/tasks")

    # The index shows EVERYTHING (open + closed), unlike the dashboard.
    assert html =~ "open-directive"
    assert html =~ "closed-directive"
    assert html =~ ~s(id="tasks")
  end

  test "the closed filter narrows to closed directives only", %{conn: conn, ws: ws} do
    {:ok, _open} = Ash.create(Issue, %{title: "still-open", workspace_id: ws.id})
    {:ok, to_close} = Ash.create(Issue, %{title: "now-closed", workspace_id: ws.id})
    {:ok, _} = Ash.update(to_close, %{}, action: :close)

    {:ok, _view, html} = live(conn, ~p"/tasks?#{%{status: :closed}}")

    assert html =~ "now-closed"
    refute html =~ "still-open"
  end

  test "empty filter renders the empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/tasks?#{%{status: :in_progress}}")
    assert html =~ ~s(id="tasks-empty")
  end

  test "a row links to the task detail page", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "linkable", workspace_id: ws.id})

    {:ok, _view, html} = live(conn, ~p"/tasks")
    assert html =~ ~s(href="/tasks/#{task.id}")
  end

  test "live: a newly created directive appears via PubSub", %{conn: conn, ws: ws} do
    {:ok, view, _html} = live(conn, ~p"/tasks")
    refute render(view) =~ "freshly-minted"

    {:ok, _b} = Ash.create(Issue, %{title: "freshly-minted", workspace_id: ws.id})

    assert render(view) =~ "freshly-minted"
  end

  describe "create" do
    test "the New button reveals the inline create form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/tasks")
      refute html =~ ~s(id="task-create-form")

      html = view |> element(~s(button[phx-click="new"])) |> render_click()

      assert html =~ ~s(id="task-create-form")
    end

    test "creating an issue persists it and navigates to its detail page",
         %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      view |> element(~s(button[phx-click="new"])) |> render_click()

      {:ok, _detail, html} =
        view
        |> form("#task-create-form", %{
          "task" => %{
            "title" => "made-from-the-dashboard",
            "workspace_id" => ws.id,
            "issue_type" => "bug",
            "priority" => "1",
            "difficulty" => "3",
            "description" => "filed without the CLI"
          }
        })
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "made-from-the-dashboard"
      assert html =~ "filed without the CLI"

      [task] =
        Issue
        |> Ash.Query.filter(title == "made-from-the-dashboard")
        |> Ash.read!()

      assert task.workspace_id == ws.id
      assert task.issue_type == :bug
      assert task.priority == 1
      assert task.difficulty == 3
    end

    test "a blank title is refused with an inline error", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      view |> element(~s(button[phx-click="new"])) |> render_click()

      html =
        view
        |> form("#task-create-form", %{
          "task" => %{"title" => "   ", "workspace_id" => ws.id}
        })
        |> render_submit()

      assert html =~ "Title can&#39;t be empty."
      # Still on the index, form still open.
      assert html =~ ~s(id="task-create-form")
    end

    # The workspace select always has a value, so this guards the hand-rolled
    # POST rather than the happy-path form: an issue must never be created
    # unattached to a workspace.
    test "a missing workspace is refused with an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      view |> element(~s(button[phx-click="new"])) |> render_click()

      html =
        render_submit(view, "create", %{"task" => %{"title" => "orphan", "workspace_id" => ""}})

      assert html =~ "Pick a workspace"
    end
  end
end
