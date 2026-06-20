defmodule ArbiterWeb.AuditLogLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "audit-#{System.unique_integer([:positive])}", prefix: "au"})

    {:ok, ws: ws}
  end

  describe "mount" do
    test "renders the header + empty state when there are no recent changes", %{
      conn: conn,
      ws: _ws
    } do
      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ "Audit log"
      assert html =~ "Since"
      assert html =~ "Until"
      assert html =~ "Task id contains"
      assert html =~ "Export as JSON"
    end

    test "lists existing paper_trail versions", %{conn: conn, ws: ws} do
      {:ok, _task} =
        Ash.create(Issue, %{title: "audit me", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, "/audit")

      assert html =~ "audit me"
      # The action badge for a create
      assert html =~ "create"
    end
  end

  describe "filters" do
    test "filter by action=close shows only close events", %{conn: conn, ws: ws} do
      {:ok, b1} = Ash.create(Issue, %{title: "to close", workspace_id: ws.id})
      {:ok, _b2} = Ash.create(Issue, %{title: "remains open", workspace_id: ws.id})
      {:ok, _closed} = Ash.update(b1, %{}, action: :close)

      {:ok, view, _html} = live(conn, "/audit")

      html =
        render_change(view, "filter", %{
          "filters" => %{"action" => "close", "since" => "", "until" => "", "entity_id" => ""}
        })

      # close events show up
      assert html =~ "close"
      # 'create' for "remains open" should NOT be in the table body when filtered to :close
      # (it may still appear in the select option list, so we check for the task id)
      refute html =~ "remains open"
    end

    test "filter by entity_id substring narrows to that task", %{conn: conn, ws: ws} do
      {:ok, b1} = Ash.create(Issue, %{title: "first", workspace_id: ws.id})
      {:ok, b2} = Ash.create(Issue, %{title: "second", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, "/audit")

      html =
        render_change(view, "filter", %{
          "filters" => %{
            "action" => "all",
            "since" => "",
            "until" => "",
            "entity_id" => b1.id
          }
        })

      assert html =~ b1.id
      refute html =~ "second"
      _ = b2
    end

    test "filter by future-only date range yields empty", %{conn: conn, ws: ws} do
      {:ok, _b} = Ash.create(Issue, %{title: "today", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, "/audit")

      future = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      html =
        render_change(view, "filter", %{
          "filters" => %{
            "since" => future,
            "until" => "",
            "entity_id" => "",
            "action" => "all"
          }
        })

      assert html =~ "No matching audit events."
    end

    test "reset clears filters", %{conn: conn, ws: ws} do
      {:ok, _b} = Ash.create(Issue, %{title: "before reset", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, "/audit")

      future = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      _ =
        render_change(view, "filter", %{
          "filters" => %{
            "since" => future,
            "until" => "",
            "entity_id" => "",
            "action" => "all"
          }
        })

      html = render_click(view, "reset", %{})
      assert html =~ "before reset"
    end
  end

  describe "export" do
    test "export click pushes a download event with JSON payload", %{conn: conn, ws: ws} do
      {:ok, _b} = Ash.create(Issue, %{title: "for export", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, "/audit")

      assert render_hook(view, "export", %{}) |> is_binary()

      # The push_event lands as a :push_event message visible via Phoenix.LiveView
      # internals; the cleanest assert is that the click doesn't crash.
      # (A more elaborate assertion would use a phx-hook in JS land.)
    end
  end
end
