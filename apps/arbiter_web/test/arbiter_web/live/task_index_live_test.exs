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
end
