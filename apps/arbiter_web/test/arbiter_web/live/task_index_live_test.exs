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

  describe "row anatomy and design" do
    test "a P1 issue row carries the red tint and left rule", %{conn: conn, ws: ws} do
      {:ok, p1} =
        Ash.create(Issue, %{title: "urgent-fix", workspace_id: ws.id, priority: 1})

      {:ok, p2} = Ash.create(Issue, %{title: "normal-fix", workspace_id: ws.id, priority: 2})

      {:ok, _view, html} = live(conn, ~p"/tasks")

      p1_row = row_html(html, p1.id)
      p2_row = row_html(html, p2.id)

      assert p1_row =~ "bg-[var(--arb-fail-wash)]"
      refute p1_row =~ "bg-[var(--surface-card)]"
      assert p1_row =~ "arb-fail"
      refute p2_row =~ "arb-fail"
    end

    test "a closed issue row is rendered at reduced opacity", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "wraps-up", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{}, action: :close)

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert row_html(html, task.id) =~ "opacity-[0.62]"
    end

    test "a row shows the priority tag, difficulty meter, id, title, and status chip",
         %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "full-anatomy",
          workspace_id: ws.id,
          priority: 3,
          difficulty: 2
        })

      {:ok, _view, html} = live(conn, ~p"/tasks")
      row = row_html(html, task.id)

      assert row =~ "P3"
      assert row =~ "Difficulty D2"
      assert row =~ task.id
      assert row =~ "full-anatomy"
      assert row =~ "open"
    end

    defp row_html(html, id) do
      link = ~s(href="/tasks/#{id}")
      link_pos = :binary.match(html, link) |> elem(0)

      li_start =
        :binary.matches(html, "<li ")
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&(&1 < link_pos))
        |> List.last()

      li_end =
        :binary.match(html, "</li>", scope: {link_pos, byte_size(html) - link_pos}) |> elem(0)

      binary_part(html, li_start, li_end - li_start)
    end
  end

  describe "filter tabs" do
    test "renders literal status values with human labels", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "All"
      assert html =~ "Open"
      assert html =~ "In progress"
      assert html =~ "Closed"
      assert html =~ ~r/href="\/tasks\?[^"]*status=in_progress/
      assert html =~ ~r/href="\/tasks\?[^"]*status=closed/
    end
  end

  describe "new issue navigation" do
    test "the primary New issue action links to the Create screen", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "&quot;navigate&quot;"
      assert html =~ "&quot;href&quot;:&quot;/tasks/new&quot;"
    end
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

      # The create runs in start_async/3, so the navigate lands once the async
      # task resolves rather than inside the submit itself.
      {path, flash} = assert_redirect(view)
      assert flash["info"] =~ "Created"

      [task] =
        Issue
        |> Ash.Query.filter(title == "made-from-the-dashboard")
        |> Ash.read!()

      assert path == "/tasks/#{task.id}"
      assert task.workspace_id == ws.id
      assert task.issue_type == :bug
      assert task.priority == 1
      assert task.difficulty == 3

      {:ok, _detail, html} = live(conn, path)
      assert html =~ "made-from-the-dashboard"
      assert html =~ "filed without the CLI"
    end

    # `issue_type` is only defaulted on a *missing* key; a blank one used to
    # survive as "" and reach Ash as a bad atom cast.
    test "a blank issue_type falls back to the default rather than erroring",
         %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      view |> element(~s(button[phx-click="new"])) |> render_click()

      render_submit(view, "create", %{
        "task" => %{
          "title" => "blank-type",
          "workspace_id" => ws.id,
          "issue_type" => ""
        }
      })

      assert_redirect(view)

      [task] = Issue |> Ash.Query.filter(title == "blank-type") |> Ash.read!()
      assert task.issue_type == :feature
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

    # LiveView preserves only the focused input across a re-render, so a
    # rejected submit used to wipe a long description the operator had just
    # typed. The form now re-renders from the submitted params.
    test "a rejected submit re-renders what was typed", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      view |> element(~s(button[phx-click="new"])) |> render_click()

      html =
        view
        |> form("#task-create-form", %{
          "task" => %{
            "title" => "   ",
            "workspace_id" => ws.id,
            "description" => "a long body I do not want to retype",
            "acceptance" => "it demonstrably works"
          }
        })
        |> render_submit()

      assert html =~ "Title can&#39;t be empty."
      assert html =~ "a long body I do not want to retype"
      assert html =~ "it demonstrably works"
    end
  end

  describe "create — duplicate check" do
    test "an open issue with the same title is flagged instead of silently duplicated",
         %{conn: conn, ws: ws} do
      {:ok, _existing} =
        Ash.create(Issue, %{title: "Fix the flaky merge queue test", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      view |> element(~s(button[phx-click="new"])) |> render_click()

      view
      |> form("#task-create-form", %{
        "task" => %{"title" => "fix the FLAKY merge queue test", "workspace_id" => ws.id}
      })
      |> render_submit()

      html = render_async(view)

      assert html =~ ~s(id="task-create-dup")
      assert html =~ "already exists"
      assert html =~ ~s(phx-click="create_force")

      # Nothing was created — the same 409 the REST API would have returned.
      assert length(open_issues(ws)) == 1
    end

    test "'Create anyway' is the dashboard's --force", %{conn: conn, ws: ws} do
      {:ok, _existing} = Ash.create(Issue, %{title: "dupe-me", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      view |> element(~s(button[phx-click="new"])) |> render_click()

      view
      |> form("#task-create-form", %{
        "task" => %{"title" => "dupe-me", "workspace_id" => ws.id}
      })
      |> render_submit()

      render_async(view)

      view |> element(~s(button[phx-click="create_force"])) |> render_click()
      assert_redirect(view)

      assert length(open_issues(ws)) == 2
    end

    defp open_issues(ws) do
      Issue
      |> Ash.Query.filter(workspace_id == ^ws.id and status in [:open, :in_progress])
      |> Ash.read!()
    end
  end

  describe "create — tracker mirror" do
    # `Issue.create` returns {:ok, issue} even when the upstream tracker create
    # failed, stashing the reason for the caller to drain. The REST API answers
    # that with a 502; the dashboard must not report a clean create.
    test "a failed tracker mirror is surfaced, not swallowed", %{conn: conn} do
      # A github-tracked workspace whose credentials ref points at an unset env
      # var: the upstream create fails deterministically, before any HTTP.
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "gh-#{System.unique_integer([:positive])}",
          prefix: "ghx",
          config: %{
            "tracker" => %{
              "type" => "github",
              "config" => %{
                "owner" => "acme",
                "repo" => "widget",
                "credentials_ref" => "env:ARB_NO_SUCH_TOKEN_#{System.unique_integer([:positive])}"
              }
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/tasks")
      view |> element(~s(button[phx-click="new"])) |> render_click()

      view
      |> form("#task-create-form", %{
        "task" => %{"title" => "mirror-fails", "workspace_id" => ws.id}
      })
      |> render_submit()

      {_path, flash} = assert_redirect(view)

      assert flash["error"] =~ "tracker mirror failed"
      refute flash["info"]

      # The issue is still durable — only the mirror failed.
      [task] = Issue |> Ash.Query.filter(title == "mirror-fails") |> Ash.read!()
      assert is_nil(task.tracker_ref)
    end
  end
end
