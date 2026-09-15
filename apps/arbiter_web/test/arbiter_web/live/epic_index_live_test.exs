defmodule ArbiterWeb.EpicIndexLiveTest do
  @moduledoc """
  bd-2wmxt5 — the `/epics` list: child-status breakdown, derived stuck chips,
  independent filters, sort, and live updates off the "tasks" topic.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "epx-#{n}", prefix: "epx#{n}"})
    {:ok, ws: ws}
  end

  defp epic(ws, title, attrs \\ %{}) do
    {:ok, e} =
      Ash.create(
        Issue,
        Map.merge(%{title: title, workspace_id: ws.id, issue_type: :epic}, attrs)
      )

    e
  end

  defp child(ws, epic, title, as) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id, issue_type: :task})

    issue =
      case as do
        :backlog -> issue
        :ready -> Ash.update!(issue, %{}, action: :promote_to_ready)
        :running -> Ash.update!(issue, %{status: :in_progress})
        :waiting -> Ash.update!(issue, %{}, action: :await_verification)
        :closed -> Ash.update!(issue, %{}, action: :close)
      end

    {:ok, _} = Dependencies.add(epic.id, issue.id, :parent_of)
    issue
  end

  describe "the list" do
    test "lists epics and nothing else", %{conn: conn, ws: ws} do
      e = epic(ws, "an-epic-row")
      {:ok, _plain} = Ash.create(Issue, %{title: "a-plain-issue", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, ~p"/epics")

      assert has_element?(view, "#epic-#{e.id}")
      assert render(view) =~ "an-epic-row"
      refute render(view) =~ "a-plain-issue"
    end

    test "a row links its title to the task detail page", %{conn: conn, ws: ws} do
      e = epic(ws, "linkable-epic")

      {:ok, view, _html} = live(conn, ~p"/epics")

      assert has_element?(view, ~s(#epic-#{e.id} a[href="/tasks/#{e.id}"]), "linkable-epic")
    end

    test "a row shows workspace, status, closed/total and the child breakdown",
         %{conn: conn, ws: ws} do
      e = epic(ws, "breakdown-epic")
      child(ws, e, "b1", :backlog)
      child(ws, e, "b2", :backlog)
      child(ws, e, "r1", :ready)
      child(ws, e, "run1", :running)
      child(ws, e, "w1", :waiting)
      child(ws, e, "c1", :closed)

      {:ok, view, _html} = live(conn, ~p"/epics")

      assert has_element?(view, "#epic-#{e.id}-workspace", ws.name)
      assert has_element?(view, "#epic-#{e.id}-status", "open")
      assert has_element?(view, "#epic-#{e.id}-progress", "1/6")

      breakdown = render(element(view, "#epic-#{e.id}-breakdown"))
      assert breakdown =~ "backlog"
      assert breakdown =~ "2"
      assert breakdown =~ "ready"
      assert breakdown =~ "running"
      assert breakdown =~ "waiting"
      assert breakdown =~ "closed"
    end

    test "an auto_close epic is marked, a manual one is not", %{conn: conn, ws: ws} do
      auto = epic(ws, "auto-epic", %{auto_close: true})
      manual = epic(ws, "manual-epic", %{auto_close: false})

      {:ok, view, _html} = live(conn, ~p"/epics")

      assert has_element?(view, "#epic-#{auto.id}-auto-close")
      refute has_element?(view, "#epic-#{manual.id}-auto-close")
    end

    test "a row shows the epic's age", %{conn: conn, ws: ws} do
      e = epic(ws, "aged-epic")

      {:ok, view, _html} = live(conn, ~p"/epics")

      assert has_element?(view, "#epic-#{e.id}-age")
    end

    test "no epics renders the empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/epics")
      assert has_element?(view, "#epics-empty")
    end
  end

  describe "stuck chips" do
    test "a child blocked by an open gating edge chips the epic as blocked",
         %{conn: conn, ws: ws} do
      e = epic(ws, "blocked-epic")
      blocked = child(ws, e, "blocked-child", :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "blocker", workspace_id: ws.id})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      quiet = epic(ws, "quiet-epic")
      child(ws, quiet, "unblocked-child", :running)

      {:ok, view, _html} = live(conn, ~p"/epics")

      assert has_element?(view, "#epic-#{e.id}-stuck-blocked_children")
      refute has_element?(view, "#epic-#{quiet.id}-stuck-blocked_children")
    end

    test "a child awaiting verification chips the epic", %{conn: conn, ws: ws} do
      e = epic(ws, "awaiting-epic")
      child(ws, e, "w1", :waiting)

      quiet = epic(ws, "quiet-epic")
      child(ws, quiet, "run1", :running)

      {:ok, view, _html} = live(conn, ~p"/epics")

      assert has_element?(view, "#epic-#{e.id}-stuck-awaiting_verification")
      refute has_element?(view, "#epic-#{quiet.id}-stuck-awaiting_verification")
    end

    test "zero running children with Ready work chips the epic as idle",
         %{conn: conn, ws: ws} do
      e = epic(ws, "idle-epic")
      child(ws, e, "r1", :ready)

      busy = epic(ws, "busy-epic")
      child(ws, busy, "r2", :ready)
      child(ws, busy, "run1", :running)

      {:ok, view, _html} = live(conn, ~p"/epics")

      assert has_element?(view, "#epic-#{e.id}-stuck-idle_with_ready_work")
      refute has_element?(view, "#epic-#{busy.id}-stuck-idle_with_ready_work")
    end
  end

  describe "filters" do
    test "defaults to open epics, hiding closed ones", %{conn: conn, ws: ws} do
      _open = epic(ws, "an-open-epic")
      closed = epic(ws, "a-closed-epic")
      Ash.update!(closed, %{}, action: :close)

      {:ok, view, _html} = live(conn, ~p"/epics")

      assert render(view) =~ "an-open-epic"
      refute render(view) =~ "a-closed-epic"
    end

    test "the closed tab shows only closed epics", %{conn: conn, ws: ws} do
      _open = epic(ws, "an-open-epic")
      closed = epic(ws, "a-closed-epic")
      Ash.update!(closed, %{}, action: :close)

      {:ok, view, _html} = live(conn, ~p"/epics?#{%{status: "closed"}}")

      assert render(view) =~ "a-closed-epic"
      refute render(view) =~ "an-open-epic"
    end

    test "the all tab shows both", %{conn: conn, ws: ws} do
      _open = epic(ws, "an-open-epic")
      closed = epic(ws, "a-closed-epic")
      Ash.update!(closed, %{}, action: :close)

      {:ok, view, _html} = live(conn, ~p"/epics?#{%{status: "all"}}")

      assert render(view) =~ "a-closed-epic"
      assert render(view) =~ "an-open-epic"
    end

    test "the workspace filter narrows to one workspace", %{conn: conn, ws: ws} do
      n = System.unique_integer([:positive])
      {:ok, other} = Ash.create(Workspace, %{name: "epy-#{n}", prefix: "epy#{n}"})

      _mine = epic(ws, "mine-epic")
      _theirs = epic(other, "theirs-epic")

      {:ok, view, _html} = live(conn, ~p"/epics?#{%{workspace: ws.id}}")

      assert render(view) =~ "mine-epic"
      refute render(view) =~ "theirs-epic"
    end

    test "the workspace select drives the filter", %{conn: conn, ws: ws} do
      n = System.unique_integer([:positive])
      {:ok, other} = Ash.create(Workspace, %{name: "epy-#{n}", prefix: "epy#{n}"})

      _mine = epic(ws, "mine-epic")
      _theirs = epic(other, "theirs-epic")

      {:ok, view, _html} = live(conn, ~p"/epics")
      assert render(view) =~ "theirs-epic"

      html =
        view
        |> form("#epics-filter-form", %{"workspace" => ws.id})
        |> render_change()

      assert html =~ "mine-epic"
      refute html =~ "theirs-epic"
    end

    test "has-blocked-children keeps only epics with a blocked child",
         %{conn: conn, ws: ws} do
      with_blocked = epic(ws, "blocked-epic")
      blocked = child(ws, with_blocked, "blocked-child", :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "blocker", workspace_id: ws.id})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      clear = epic(ws, "clear-epic")
      child(ws, clear, "clear-child", :running)

      {:ok, view, _html} = live(conn, ~p"/epics")
      assert render(view) =~ "clear-epic"

      {:ok, view, _html} = live(conn, ~p"/epics?#{%{blocked: "1"}}")

      assert render(view) =~ "blocked-epic"
      refute render(view) =~ "clear-epic"
    end

    test "the blocked filter is independent of the status filter", %{conn: conn, ws: ws} do
      closed_with_blocked = epic(ws, "closed-blocked-epic")
      blocked = child(ws, closed_with_blocked, "blocked-child", :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "blocker", workspace_id: ws.id})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)
      Ash.update!(closed_with_blocked, %{}, action: :close)

      {:ok, view, _html} = live(conn, ~p"/epics?#{%{blocked: "1"}}")
      refute render(view) =~ "closed-blocked-epic"

      {:ok, view, _html} = live(conn, ~p"/epics?#{%{blocked: "1", status: "all"}}")
      assert render(view) =~ "closed-blocked-epic"
    end
  end

  describe "sort" do
    test "the default sort puts stuck epics first", %{conn: conn, ws: ws} do
      calm = epic(ws, "zzz-calm-epic")
      child(ws, calm, "run1", :running)

      stuck = epic(ws, "aaa-stuck-epic")
      child(ws, stuck, "w1", :waiting)

      {:ok, view, _html} = live(conn, ~p"/epics")
      html = render(view)

      assert position(html, "aaa-stuck-epic") < position(html, "zzz-calm-epic")
    end

    test "unstuck epics fall back to latest child activity, then age",
         %{conn: conn, ws: ws} do
      older = epic(ws, "older-epic")
      child(ws, older, "old-child", :running)

      newer = epic(ws, "newer-epic")
      newer_child = child(ws, newer, "new-child", :running)
      Ash.update!(newer_child, %{title: "new-child touched"})

      {:ok, view, _html} = live(conn, ~p"/epics")
      html = render(view)

      assert position(html, "newer-epic") < position(html, "older-epic")
    end

    test "the sort dropdown offers age, % complete and title", %{conn: conn, ws: ws} do
      _e = epic(ws, "sortable-epic")

      {:ok, view, _html} = live(conn, ~p"/epics")
      options = render(element(view, "#epics-filter-sort"))

      assert options =~ "Age"
      assert options =~ "% complete"
      assert options =~ "Title"
    end

    test "sorting by title orders alphabetically regardless of stuckness",
         %{conn: conn, ws: ws} do
      stuck = epic(ws, "zzz-stuck-epic")
      child(ws, stuck, "w1", :waiting)
      _calm = epic(ws, "aaa-calm-epic")

      {:ok, view, _html} = live(conn, ~p"/epics?#{%{sort: "title"}}")
      html = render(view)

      assert position(html, "aaa-calm-epic") < position(html, "zzz-stuck-epic")
    end

    test "sorting by % complete puts the most-complete epic first", %{conn: conn, ws: ws} do
      behind = epic(ws, "behind-epic")
      child(ws, behind, "b1", :backlog)
      child(ws, behind, "b2", :backlog)

      ahead = epic(ws, "ahead-epic")
      child(ws, ahead, "c1", :closed)
      child(ws, ahead, "b3", :backlog)

      {:ok, view, _html} = live(conn, ~p"/epics?#{%{sort: "percent"}}")
      html = render(view)

      assert position(html, "ahead-epic") < position(html, "behind-epic")
    end

    test "sorting by age puts the oldest epic first", %{conn: conn, ws: ws} do
      first = epic(ws, "first-epic")
      second = epic(ws, "second-epic")

      assert DateTime.compare(first.created_at, second.created_at) != :gt

      {:ok, view, _html} = live(conn, ~p"/epics?#{%{sort: "age"}}")
      html = render(view)

      assert position(html, "first-epic") < position(html, "second-epic")
    end
  end

  describe "live updates" do
    test "a child's status change updates its epic's row", %{conn: conn, ws: ws} do
      e = epic(ws, "live-epic")
      c = child(ws, e, "live-child", :ready)

      {:ok, view, _html} = live(conn, ~p"/epics")
      assert has_element?(view, "#epic-#{e.id}-progress", "0/1")

      Ash.update!(c, %{}, action: :close)

      assert has_element?(view, "#epic-#{e.id}-progress", "1/1")
    end

    test "a child moving into awaiting_verification raises the stuck chip live",
         %{conn: conn, ws: ws} do
      e = epic(ws, "live-chip-epic")
      c = child(ws, e, "live-child", :running)

      {:ok, view, _html} = live(conn, ~p"/epics")
      refute has_element?(view, "#epic-#{e.id}-stuck-awaiting_verification")

      Ash.update!(c, %{}, action: :await_verification)

      assert has_element?(view, "#epic-#{e.id}-stuck-awaiting_verification")
    end

    test "a newly created epic appears live", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/epics")
      refute render(view) =~ "freshly-minted-epic"

      _e = epic(ws, "freshly-minted-epic")

      assert render(view) =~ "freshly-minted-epic"
    end
  end

  describe "nav badge" do
    test "the Epics nav entry counts open epics, not closed ones", %{conn: conn, ws: ws} do
      before = Arbiter.Tasks.open_epic_count()

      _a = epic(ws, "badge-epic-a")
      _b = epic(ws, "badge-epic-b")
      c = epic(ws, "badge-epic-c")
      Ash.update!(c, %{}, action: :close)

      {:ok, view, _html} = live(conn, ~p"/epics")

      assert has_element?(
               view,
               ~s(#top-nav a[href="/epics"] [data-role="nav-badge"]),
               to_string(before + 2)
             )
    end
  end

  describe "narrow layout" do
    test "a row stacks below the sm breakpoint and goes horizontal above it",
         %{conn: conn, ws: ws} do
      e = epic(ws, "narrow-epic")

      {:ok, view, _html} = live(conn, ~p"/epics")
      row = render(element(view, "#epic-#{e.id}"))

      assert row =~ "flex-col"
      assert row =~ "sm:flex-row"
    end

    test "the filter bar wraps rather than overflowing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/epics")

      assert render(element(view, "#epics-filter-form")) =~ "flex-wrap"
    end
  end

  defp position(html, needle) do
    case :binary.match(html, needle) do
      {at, _} -> at
      :nomatch -> flunk("#{needle} is not on the page")
    end
  end
end
