defmodule ArbiterWeb.TaskDetailParentBannerTest do
  @moduledoc """
  bd-38of5i / design bd-2s901b §7 — the "↳ Part of <epic>" banner under a
  child issue's title.

  The banner is the full-size render of the same `ArbiterWeb.ParentLink` the
  board draws as a compact chip (covered in
  `ArbiterWeb.ParentLinkTest`); this file covers it in place on the page,
  including the four edge cases and the sibling position.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "pb-#{System.unique_integer([:positive])}", prefix: "pbt"})

    {:ok, ws: ws}
  end

  defp issue(ws, title, attrs \\ %{}) do
    {:ok, issue} = Ash.create(Issue, Map.merge(%{title: title, workspace_id: ws.id}, attrs))
    issue
  end

  defp close(issue) do
    {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)
    closed
  end

  defp banner(id), do: ~s(#task-parents [data-role="parent-banner"][data-parent="#{id}"])

  test "a child shows a linked banner naming its epic and its progress", %{conn: conn, ws: ws} do
    epic = issue(ws, "Browser coordinator sessions", %{issue_type: :epic})
    child = issue(ws, "the terminal channel")
    sibling = issue(ws, "the transport")

    {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
    {:ok, _} = Dependencies.add(epic.id, sibling.id, :parent_of)
    close(sibling)

    {:ok, view, html} = live(conn, "/tasks/#{child.id}")

    assert has_element?(view, banner(epic.id))
    assert has_element?(view, ~s(#{banner(epic.id)} a[href="/tasks/#{epic.id}"]))
    assert html =~ "Part of"
    assert html =~ "Browser coordinator sessions"
    assert html =~ "1/2 closed"
  end

  test "an issue with no parent shows no banner", %{conn: conn, ws: ws} do
    child = issue(ws, "an orphan of no epic")

    {:ok, view, _html} = live(conn, "/tasks/#{child.id}")

    refute has_element?(view, ~s([data-role="parent-banner"]))
  end

  # Edge case 1 — stacked, most recently updated first.
  test "two parents stack, the most recently updated one first", %{conn: conn, ws: ws} do
    older = issue(ws, "Older epic", %{issue_type: :epic})
    newer = issue(ws, "Newer epic", %{issue_type: :epic})
    child = issue(ws, "a child of two")

    {:ok, _} = Dependencies.add(older.id, child.id, :parent_of)
    {:ok, _} = Dependencies.add(newer.id, child.id, :parent_of)
    {:ok, older} = Ash.update(older, %{title: "Older epic, renamed"})

    {:ok, view, html} = live(conn, "/tasks/#{child.id}")

    assert has_element?(view, banner(older.id))
    assert has_element?(view, banner(newer.id))
    assert :binary.match(html, older.id) < :binary.match(html, newer.id)
  end

  # Edge case 2 — a plain task with subtasks: same shape, no epic chrome.
  test "a non-epic parent reads 'Child of' and shows no progress", %{conn: conn, ws: ws} do
    parent = issue(ws, "Split the importer", %{issue_type: :task})
    child = issue(ws, "step one")

    {:ok, _} = Dependencies.add(parent.id, child.id, :parent_of)

    {:ok, view, html} = live(conn, "/tasks/#{child.id}")

    assert has_element?(view, banner(parent.id))
    assert html =~ "Child of"
    refute has_element?(view, ~s(#{banner(parent.id)} [data-role="parent-progress"]))
  end

  # Edge case 3 — a closed epic: still true, so still shown, muted and done.
  test "a closed epic is marked closed and reads n/n closed ✓", %{conn: conn, ws: ws} do
    epic = issue(ws, "Wave one", %{issue_type: :epic})
    child = issue(ws, "the only child")

    {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
    close(child)
    close(epic)

    {:ok, view, html} = live(conn, "/tasks/#{child.id}")

    assert has_element?(view, ~s(#{banner(epic.id)}[data-closed="true"]))
    assert html =~ "1/1 closed ✓"
  end

  # Edge case 4 — the parent lives in another workspace.
  test "a cross-workspace parent gets a workspace tag and marker", %{conn: conn, ws: ws} do
    {:ok, other} =
      Ash.create(Workspace, %{name: "vstim-#{System.unique_integer([:positive])}", prefix: "vsp"})

    epic = issue(other, "Candle store", %{issue_type: :epic})
    child = issue(ws, "a child across the line")

    {:ok, _} =
      Ash.create(Dependency, %{from_issue_id: epic.id, to_issue_id: child.id, type: :parent_of})

    {:ok, view, html} = live(conn, "/tasks/#{child.id}")

    assert has_element?(view, ~s(#{banner(epic.id)} [data-role="cross-workspace-marker"]))
    assert html =~ "workspace: #{other.name}"
  end

  describe "the sibling position" do
    test "shows when the siblings form one depends_on chain", %{conn: conn, ws: ws} do
      epic = issue(ws, "Three in a row", %{issue_type: :epic})
      [a, b, c] = for t <- ~w(first second third), do: issue(ws, t)

      for child <- [a, b, c], do: {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
      {:ok, _} = Dependencies.add(b.id, a.id, :depends_on)
      {:ok, _} = Dependencies.add(c.id, b.id, :depends_on)

      {:ok, view, html} = live(conn, "/tasks/#{b.id}")

      assert has_element?(view, ~s(#{banner(epic.id)} [data-role="parent-position"]))
      assert html =~ "2 of 3"
    end

    test "is omitted rather than faked when the order is ambiguous", %{conn: conn, ws: ws} do
      epic = issue(ws, "Unordered", %{issue_type: :epic})
      [a, b, c] = for t <- ~w(first second third), do: issue(ws, t)

      for child <- [a, b, c], do: {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
      {:ok, _} = Dependencies.add(b.id, a.id, :depends_on)

      {:ok, view, html} = live(conn, "/tasks/#{b.id}")

      assert has_element?(view, banner(epic.id))
      refute has_element?(view, ~s([data-role="parent-position"]))
      refute html =~ " of 3"
    end
  end

  test "the banner repaints when the parent's children change", %{conn: conn, ws: ws} do
    epic = issue(ws, "Live rollup", %{issue_type: :epic})
    child = issue(ws, "watch me")
    sibling = issue(ws, "close me")

    {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
    {:ok, _} = Dependencies.add(epic.id, sibling.id, :parent_of)

    {:ok, view, html} = live(conn, "/tasks/#{child.id}")
    assert html =~ "0/2 closed"

    close(sibling)

    assert render(view) =~ "1/2 closed"
  end
end
