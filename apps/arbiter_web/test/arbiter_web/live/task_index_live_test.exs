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

  describe "create" do
    test "the New button links to the standalone /tasks/new create screen",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "/tasks/new"

      {:ok, _new_view, new_html} = live(conn, ~p"/tasks/new")
      assert new_html =~ "Create an issue"
    end
  end

  describe "text search" do
    test "an id substring hits, case-insensitively", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "unrelated title", workspace_id: ws.id})
      {:ok, _other} = Ash.create(Issue, %{title: "noise", workspace_id: ws.id})

      substring = task.id |> String.slice(4, 3) |> String.upcase()

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{q: substring}}")

      assert html =~ task.id
      refute html =~ "noise"
    end

    test "a title substring hits, case-insensitively", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "Frobnicate the Widget", workspace_id: ws.id})
      {:ok, _other} = Ash.create(Issue, %{title: "totally different", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{q: "widget"}}")

      assert html =~ task.id
      refute html =~ "totally different"
    end

    test "a query with no matches renders the empty state naming the search",
         %{conn: conn, ws: ws} do
      {:ok, _task} = Ash.create(Issue, %{title: "present", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{q: "zzz-nope-zzz"}}")

      assert html =~ ~s(id="tasks-empty")
      assert html =~ "zzz-nope-zzz"
    end

    test "search paginates correctly across many matches", %{conn: conn, ws: ws} do
      for n <- 1..30 do
        {:ok, _} = Ash.create(Issue, %{title: "match-#{n}", workspace_id: ws.id})
      end

      {:ok, _} = Ash.create(Issue, %{title: "no-hit-here", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{q: "match-"}}")

      assert html =~ "30 total"
      assert html =~ "1 / 2"
      refute html =~ "no-hit-here"
    end

    test "a literal % in the search term is not treated as a wildcard", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "100% done", workspace_id: ws.id})
      {:ok, _other} = Ash.create(Issue, %{title: "unrelated title", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{q: "100%"}}")

      assert html =~ task.id
      refute html =~ "unrelated title"
    end
  end

  describe "filters" do
    test "status filter includes awaiting_verification", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "parked-for-verification", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{}, action: :await_verification)
      {:ok, _open} = Ash.create(Issue, %{title: "still-open", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{status: :awaiting_verification}}")

      assert html =~ task.id
      refute html =~ "still-open"
    end

    test "workspace filter narrows to one workspace", %{conn: conn, ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "other-#{System.unique_integer([:positive])}",
          prefix: "oth"
        })

      {:ok, task} = Ash.create(Issue, %{title: "in-target-ws", workspace_id: ws.id})
      {:ok, _other} = Ash.create(Issue, %{title: "in-other-ws", workspace_id: other_ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{workspace: ws.id}}")

      assert html =~ task.id
      refute html =~ "in-other-ws"
    end

    test "type filter narrows to one issue_type", %{conn: conn, ws: ws} do
      {:ok, bug} =
        Ash.create(Issue, %{title: "a-bug", workspace_id: ws.id, issue_type: :bug})

      {:ok, _chore} =
        Ash.create(Issue, %{title: "a-chore", workspace_id: ws.id, issue_type: :chore})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{type: :bug}}")

      assert html =~ bug.id
      refute html =~ "a-chore"
    end

    test "priority filter narrows to one priority", %{conn: conn, ws: ws} do
      {:ok, p0} = Ash.create(Issue, %{title: "top-priority", workspace_id: ws.id, priority: 0})
      {:ok, _p3} = Ash.create(Issue, %{title: "low-priority", workspace_id: ws.id, priority: 3})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{priority: 0}}")

      assert html =~ p0.id
      refute html =~ "low-priority"
    end

    test "difficulty filter narrows to one difficulty", %{conn: conn, ws: ws} do
      {:ok, d3} = Ash.create(Issue, %{title: "d3-task", workspace_id: ws.id, difficulty: 3})
      {:ok, _d1} = Ash.create(Issue, %{title: "d1-task", workspace_id: ws.id, difficulty: 1})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{difficulty: 3}}")

      assert html =~ d3.id
      refute html =~ "d1-task"
    end

    test "difficulty filter's 'unrated' option matches nil difficulty", %{conn: conn, ws: ws} do
      {:ok, unrated} = Ash.create(Issue, %{title: "no-difficulty", workspace_id: ws.id})

      {:ok, _rated} =
        Ash.create(Issue, %{title: "has-difficulty", workspace_id: ws.id, difficulty: 2})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{difficulty: "none"}}")

      assert html =~ unrated.id
      refute html =~ "has-difficulty"
    end

    test "stage filter narrows Backlog (refined: false)", %{conn: conn, ws: ws} do
      {:ok, backlog} =
        Ash.create(Issue, %{title: "in-backlog", workspace_id: ws.id, issue_type: :task})

      {:ok, ready} =
        Ash.create(Issue, %{title: "in-ready", workspace_id: ws.id, issue_type: :task})

      {:ok, _ready} = Ash.update(ready, %{}, action: :promote_to_ready)

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{stage: :backlog}}")

      assert html =~ backlog.id
      refute html =~ "in-ready"
    end

    test "stage filter narrows Ready (refined: true)", %{conn: conn, ws: ws} do
      {:ok, _backlog} =
        Ash.create(Issue, %{title: "in-backlog", workspace_id: ws.id, issue_type: :task})

      {:ok, ready} =
        Ash.create(Issue, %{title: "in-ready", workspace_id: ws.id, issue_type: :task})

      {:ok, ready} = Ash.update(ready, %{}, action: :promote_to_ready)

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{stage: :ready}}")

      assert html =~ ready.id
      refute html =~ "in-backlog"
    end

    test "repo filter narrows to one repo", %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "in-tonic", workspace_id: ws.id, repo: "org/tonic"})

      {:ok, _other} =
        Ash.create(Issue, %{title: "in-apex", workspace_id: ws.id, repo: "org/apex"})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{repo: "org/tonic"}}")

      assert html =~ task.id
      refute html =~ "in-apex"
    end

    test "parent-epic filter narrows to an epic's children", %{conn: conn, ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "the-epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, other_epic} =
        Ash.create(Issue, %{title: "another-epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, child} = Ash.create(Issue, %{title: "epic-child", workspace_id: ws.id})
      {:ok, other_child} = Ash.create(Issue, %{title: "other-epic-child", workspace_id: ws.id})

      {:ok, _dep} =
        Ash.create(Arbiter.Tasks.Dependency, %{
          from_issue_id: epic.id,
          to_issue_id: child.id,
          type: :parent_of
        })

      {:ok, _dep2} =
        Ash.create(Arbiter.Tasks.Dependency, %{
          from_issue_id: other_epic.id,
          to_issue_id: other_child.id,
          type: :parent_of
        })

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{epic: epic.id}}")

      assert html =~ child.id
      refute html =~ "other-epic-child"
    end

    test "parent-epic filter's 'no parent' option excludes parented issues",
         %{conn: conn, ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "the-epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, child} = Ash.create(Issue, %{title: "has-a-parent", workspace_id: ws.id})
      {:ok, orphan} = Ash.create(Issue, %{title: "no-parent-here", workspace_id: ws.id})

      {:ok, _dep} =
        Ash.create(Arbiter.Tasks.Dependency, %{
          from_issue_id: epic.id,
          to_issue_id: child.id,
          type: :parent_of
        })

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{epic: "none"}}")

      assert html =~ orphan.id
      refute html =~ "has-a-parent"
    end

    test "parent-epic filter's 'no parent' option shows everything when no dependency rows exist at all",
         %{conn: conn, ws: ws} do
      {:ok, orphan} = Ash.create(Issue, %{title: "only-orphan-around", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{epic: "none"}}")

      assert html =~ orphan.id
    end

    test "a three-way filter combination (status + type + priority) is AND'd",
         %{conn: conn, ws: ws} do
      {:ok, target} =
        Ash.create(Issue, %{
          title: "matches-all-three",
          workspace_id: ws.id,
          issue_type: :bug,
          priority: 1
        })

      {:ok, _wrong_type} =
        Ash.create(Issue, %{
          title: "wrong-type",
          workspace_id: ws.id,
          issue_type: :chore,
          priority: 1
        })

      {:ok, _wrong_priority} =
        Ash.create(Issue, %{
          title: "wrong-priority",
          workspace_id: ws.id,
          issue_type: :bug,
          priority: 3
        })

      {:ok, wrong_status} =
        Ash.create(Issue, %{
          title: "wrong-status",
          workspace_id: ws.id,
          issue_type: :bug,
          priority: 1
        })

      {:ok, _} = Ash.update(wrong_status, %{}, action: :close)

      {:ok, _view, html} =
        live(conn, ~p"/tasks?#{%{status: :open, type: :bug, priority: 1}}")

      assert html =~ target.id
      refute html =~ "wrong-type"
      refute html =~ "wrong-priority"
      refute html =~ "wrong-status"
    end
  end

  describe "sorting" do
    test "sort=priority orders P0 before P4", %{conn: conn, ws: ws} do
      {:ok, low} = Ash.create(Issue, %{title: "low-pri", workspace_id: ws.id, priority: 4})
      {:ok, high} = Ash.create(Issue, %{title: "high-pri", workspace_id: ws.id, priority: 0})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{sort: :priority}}")

      assert String.contains?(html, high.id) and String.contains?(html, low.id)
      assert index_of(html, high.id) < index_of(html, low.id)
    end

    test "sort=difficulty orders D0 before D5", %{conn: conn, ws: ws} do
      {:ok, hard} = Ash.create(Issue, %{title: "d5-task", workspace_id: ws.id, difficulty: 5})
      {:ok, easy} = Ash.create(Issue, %{title: "d0-task", workspace_id: ws.id, difficulty: 0})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{sort: :difficulty}}")

      assert index_of(html, easy.id) < index_of(html, hard.id)
    end

    test "sort=difficulty pushes unrated issues to the end, not the start", %{
      conn: conn,
      ws: ws
    } do
      {:ok, unrated} = Ash.create(Issue, %{title: "unrated-task", workspace_id: ws.id})
      {:ok, easy} = Ash.create(Issue, %{title: "d0-task", workspace_id: ws.id, difficulty: 0})
      {:ok, hard} = Ash.create(Issue, %{title: "d5-task", workspace_id: ws.id, difficulty: 5})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{sort: :difficulty}}")

      assert index_of(html, easy.id) < index_of(html, hard.id)
      assert index_of(html, hard.id) < index_of(html, unrated.id)
    end

    test "sort=created orders newest-created first", %{conn: conn, ws: ws} do
      {:ok, first} = Ash.create(Issue, %{title: "created-first", workspace_id: ws.id})
      {:ok, second} = Ash.create(Issue, %{title: "created-second", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{sort: :created}}")

      assert index_of(html, second.id) < index_of(html, first.id)
    end

    test "sort=updated (default) orders most-recently-updated first", %{conn: conn, ws: ws} do
      {:ok, stale} = Ash.create(Issue, %{title: "stale-task", workspace_id: ws.id})
      {:ok, fresh} = Ash.create(Issue, %{title: "fresh-task", workspace_id: ws.id})
      {:ok, _} = Ash.update(stale, %{title: "stale-task-touched"}, action: :update)

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{sort: :updated}}")

      assert index_of(html, stale.id) < index_of(html, fresh.id)
    end

    defp index_of(html, needle) do
      {pos, _len} = :binary.match(html, needle)
      pos
    end
  end

  describe "URL-persisted state" do
    test "every filter, search, sort and page param round-trips through a reload",
         %{conn: conn, ws: ws} do
      {:ok, target} =
        Ash.create(Issue, %{
          title: "round-trip-me",
          workspace_id: ws.id,
          issue_type: :bug,
          priority: 1,
          difficulty: 2,
          repo: "org/tonic"
        })

      params = %{
        q: "round-trip",
        workspace: ws.id,
        type: :bug,
        priority: 1,
        difficulty: 2,
        repo: "org/tonic",
        sort: :priority,
        page: 1
      }

      {:ok, _view, html} = live(conn, ~p"/tasks?#{params}")
      assert html =~ target.id

      # Simulate a reload with the exact same URL.
      {:ok, _view2, html2} = live(conn, ~p"/tasks?#{params}")
      assert html2 =~ target.id
    end

    test "changing a filter resets the page to 1", %{conn: conn, ws: ws} do
      for n <- 1..30 do
        {:ok, _} = Ash.create(Issue, %{title: "page-task-#{n}", workspace_id: ws.id})
      end

      {:ok, view, _html} = live(conn, ~p"/tasks?#{%{page: 2}}")

      html =
        view
        |> form("#tasks-filter-form", %{"type" => "bug"})
        |> render_change()

      assert_patch(view, ~p"/tasks?#{%{page: 1, type: :bug}}")
      refute html =~ ~s(href="/tasks?page=2)
    end

    test "changing a filter via the form preserves the currently-active status tab", %{
      conn: conn,
      ws: ws
    } do
      {:ok, open_bug} =
        Ash.create(Issue, %{title: "open-bug", workspace_id: ws.id, issue_type: :bug})

      {:ok, closed_bug} =
        Ash.create(Issue, %{title: "closed-bug", workspace_id: ws.id, issue_type: :bug})

      {:ok, _} = Ash.update(closed_bug, %{}, action: :close)

      {:ok, view, _html} = live(conn, ~p"/tasks?#{%{status: :open}}")

      html =
        view
        |> form("#tasks-filter-form", %{"type" => "bug"})
        |> render_change()

      assert_patch(view, ~p"/tasks?#{%{page: 1, status: :open, type: :bug}}")
      assert html =~ open_bug.id
      refute html =~ closed_bug.id
    end
  end

  describe "clear filters" do
    test "the clear-filters control resets to defaults", %{conn: conn, ws: ws} do
      {:ok, matching} =
        Ash.create(Issue, %{title: "matches-filter", workspace_id: ws.id, priority: 1})

      {:ok, other} =
        Ash.create(Issue, %{title: "other-priority", workspace_id: ws.id, priority: 3})

      {:ok, view, html} = live(conn, ~p"/tasks?#{%{priority: 1}}")
      assert html =~ ~s(id="tasks-clear-filters")
      refute html =~ other.id

      html = view |> element("#tasks-clear-filters") |> render_click()

      assert html =~ matching.id
      assert html =~ other.id
      refute html =~ ~s(id="tasks-clear-filters")
    end

    test "the empty state names the active filters", %{conn: conn, ws: ws} do
      {:ok, _task} = Ash.create(Issue, %{title: "present", workspace_id: ws.id, priority: 2})

      {:ok, _view, html} = live(conn, ~p"/tasks?#{%{priority: 0}}")

      assert html =~ ~s(id="tasks-empty")
      assert html =~ "priority: P0"
    end
  end
end
