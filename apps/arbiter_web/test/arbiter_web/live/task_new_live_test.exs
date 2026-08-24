defmodule ArbiterWeb.TaskNewLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}
  require Ash.Query

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "bi-#{System.unique_integer([:positive])}", prefix: "bix"})

    {:ok, ws: ws}
  end

  test "renders the standalone create screen with header, panel, and back link",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/tasks/new")

    assert html =~ "Create an issue"
    assert html =~ "Writes through the same action the CLI and MCP tools use"
    assert html =~ ~s(id="task-new-form")
    assert html =~ "Back to board"
  end

  test "creating an issue persists it and navigates to its detail page",
       %{conn: conn, ws: ws} do
    {:ok, view, _html} = live(conn, ~p"/tasks/new")

    view
    |> form("#task-new-form", %{
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
    # bd-b5wyjd: the dashboard form is not a shortcut into the queue either —
    # it lands in Backlog like every other creation path, and says so.
    assert flash["info"] =~ "Backlog"

    [task] =
      Issue
      |> Ash.Query.filter(title == "made-from-the-dashboard")
      |> Ash.read!()

    assert path == "/tasks/#{task.id}"
    assert task.workspace_id == ws.id
    refute task.refined
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
    {:ok, view, _html} = live(conn, ~p"/tasks/new")

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

  test "a blank title is refused with an inline error under the field", %{conn: conn, ws: ws} do
    {:ok, view, _html} = live(conn, ~p"/tasks/new")

    html =
      view
      |> form("#task-new-form", %{
        "task" => %{"title" => "   ", "workspace_id" => ws.id}
      })
      |> render_submit()

    assert html =~ "Title can&#39;t be empty."
    # Still on the create screen, form still open.
    assert html =~ ~s(id="task-new-form")
  end

  # The workspace select always has a value, so this guards the hand-rolled
  # POST rather than the happy-path form: an issue must never be created
  # unattached to a workspace.
  test "a missing workspace is refused with an inline error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks/new")

    html =
      render_submit(view, "create", %{"task" => %{"title" => "orphan", "workspace_id" => ""}})

    assert html =~ "Pick a workspace"
  end

  # LiveView preserves only the focused input across a re-render, so a
  # rejected submit used to wipe a long description the operator had just
  # typed. The form now re-renders from the submitted params.
  test "a rejected submit re-renders what was typed", %{conn: conn, ws: ws} do
    {:ok, view, _html} = live(conn, ~p"/tasks/new")

    html =
      view
      |> form("#task-new-form", %{
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

  describe "CLI preview footer" do
    test "shows the bare arb issue create command before anything is typed",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks/new")

      assert html =~ ~s(id="task-new-cli-preview")
      assert html =~ "arb issue create &#39;&#39;"
    end

    test "updates live as the title and other fields are typed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-new-form", %{
          "task" => %{
            "title" => "Fix the flaky merge queue test",
            "issue_type" => "bug",
            "priority" => "1",
            "difficulty" => "3",
            "description" => "context here"
          }
        })
        |> render_change()

      assert html =~
               ~s(arb issue create &#39;Fix the flaky merge queue test&#39; --type bug --priority 1 --difficulty 3 --description &#39;context here&#39;)
    end

    test "defaults (feature type, priority 2, unset difficulty) are omitted from the preview",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-new-form", %{
          "task" => %{"title" => "plain title", "issue_type" => "feature", "priority" => "2"}
        })
        |> render_change()

      assert html =~ ~s(arb issue create &#39;plain title&#39;)
      refute html =~ "--type"
      refute html =~ "--priority"
      refute html =~ "--difficulty"
      refute html =~ "--description"
    end

    test "single quotes in the title are escaped in the preview", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-new-form", %{"task" => %{"title" => ~s(say 'hi')}})
        |> render_change()

      assert html =~ ~s(arb issue create &#39;say &#39;\\&#39;&#39;hi&#39;\\&#39;&#39;&#39;)
    end

    test "shell metacharacters in the title stay inert inside single quotes",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-new-form", %{"task" => %{"title" => ~s(Bump $VERSION `date`)}})
        |> render_change()

      assert html =~ ~s(arb issue create &#39;Bump $VERSION `date`&#39;)
    end

    test "the selected workspace is appended as --workspace, shell-quoted", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-new-form", %{
          "task" => %{"title" => "route me right", "workspace_id" => ws.id}
        })
        |> render_change()

      assert html =~ ~s(--workspace &#39;#{ws.name}&#39;)
    end

    test "a non-blank acceptance is flagged as not covered by the CLI command",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      html =
        view
        |> form("#task-new-form", %{
          "task" => %{"title" => "has acceptance", "acceptance" => "works when X"}
        })
        |> render_change()

      refute html =~ "--acceptance"
      assert html =~ "Acceptance isn&#39;t set by"
    end
  end

  describe "duplicate check" do
    test "an open issue with the same title is flagged instead of silently duplicated",
         %{conn: conn, ws: ws} do
      {:ok, _existing} =
        Ash.create(Issue, %{title: "Fix the flaky merge queue test", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      view
      |> form("#task-new-form", %{
        "task" => %{"title" => "fix the FLAKY merge queue test", "workspace_id" => ws.id}
      })
      |> render_submit()

      html = render_async(view)

      assert html =~ ~s(id="task-new-dup")
      assert html =~ "already have a similar title — file it anyway?"
      assert html =~ ~s(phx-click="create_force")

      # Nothing was created — the same 409 the REST API would have returned.
      assert length(open_issues(ws)) == 1
    end

    test "'Create anyway' is the dashboard's --force", %{conn: conn, ws: ws} do
      {:ok, _existing} = Ash.create(Issue, %{title: "dupe-me", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      view
      |> form("#task-new-form", %{
        "task" => %{"title" => "dupe-me", "workspace_id" => ws.id}
      })
      |> render_submit()

      render_async(view)

      view |> element(~s(button[phx-click="create_force"])) |> render_click()
      assert_redirect(view)

      assert length(open_issues(ws)) == 2
    end

    test "editing the title clears the duplicate warning back to the editing state",
         %{conn: conn, ws: ws} do
      {:ok, _existing} = Ash.create(Issue, %{title: "dupe-me-too", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      view
      |> form("#task-new-form", %{
        "task" => %{"title" => "dupe-me-too", "workspace_id" => ws.id}
      })
      |> render_submit()

      html = render_async(view)
      assert html =~ ~s(id="task-new-dup")

      html =
        view
        |> form("#task-new-form", %{
          "task" => %{"title" => "a completely different title", "workspace_id" => ws.id}
        })
        |> render_change()

      refute html =~ ~s(id="task-new-dup")
      refute html =~ ~s(phx-click="create_force")
    end

    defp open_issues(ws) do
      Issue
      |> Ash.Query.filter(workspace_id == ^ws.id and status in [:open, :in_progress])
      |> Ash.read!()
    end
  end

  describe "tracker mirror" do
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

      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      view
      |> form("#task-new-form", %{
        "task" => %{"title" => "mirror-fails", "workspace_id" => ws.id}
      })
      |> render_submit()

      {_path, flash} = assert_redirect(view)

      assert flash["error"] =~ "tracker mirror failed"
      assert flash["error"] =~ "Re-link with"
      refute flash["info"]

      # The issue is still durable — only the mirror failed.
      [task] = Issue |> Ash.Query.filter(title == "mirror-fails") |> Ash.read!()
      assert is_nil(task.tracker_ref)
    end
  end
end
