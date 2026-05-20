defmodule GtElixirWeb.DashboardLiveTest do
  use GtElixirWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias GtElixir.Beads.{Issue, Workspace}
  alias GtElixir.Polecat

  setup do
    # Polecats are supervised at the VM level — prior tests in the umbrella
    # may have left children running. Stop them so the dashboard's "active
    # polecats" section starts in a known empty state.
    for snap <- Polecat.list_children() do
      Polecat.stop(snap.bead_id)
    end

    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "dash-#{System.unique_integer([:positive])}", prefix: "ds"})

    {:ok, ws: ws}
  end

  describe "mount" do
    test "renders all four section headers", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Dashboard"
      assert html =~ "Active "
      assert html =~ "Recent beads"
      assert html =~ "PRs in flight"
      assert html =~ "Escalations"
    end

    test "empty polecats shows the no-active-* line", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "No active"
    end
  end

  describe "recent beads section" do
    test "existing beads are rendered", %{conn: conn, ws: ws} do
      {:ok, _b} = Ash.create(Issue, %{title: "i-am-on-the-dashboard", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "i-am-on-the-dashboard"
    end

    test "creating a new bead pushes a PubSub update", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, "/")

      # Sanity: bead doesn't exist yet
      refute render(view) =~ "newly-created-bead-title"

      {:ok, _b} = Ash.create(Issue, %{title: "newly-created-bead-title", workspace_id: ws.id})

      # The LiveView receives `{:bead_lifecycle, :created, _}` and re-renders.
      assert render(view) =~ "newly-created-bead-title"
    end

    test "creating a new bead via the REST API also pushes a PubSub update",
         %{conn: conn, ws: ws} do
      # Regression for bd-97ijhk — the original report was that `bd create`
      # (which posts to POST /api/issues) did not update an open dashboard.
      # If the test above passes but this one fails, the API controller is
      # bypassing the broadcast somehow.
      {:ok, view, _html} = live(conn, "/")

      refute render(view) =~ "via-rest-api-title"

      post_conn =
        Phoenix.ConnTest.build_conn()
        |> post(~p"/api/issues", %{title: "via-rest-api-title", workspace_id: ws.id})

      assert post_conn.status == 201

      assert render(view) =~ "via-rest-api-title"
    end

    test "closing a bead pushes a PubSub update and the new status renders", %{
      conn: conn,
      ws: ws
    } do
      {:ok, b} = Ash.create(Issue, %{title: "to-close-on-dashboard", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, "/")
      assert render(view) =~ "to-close-on-dashboard"

      {:ok, _closed} = Ash.update(b, %{}, action: :close)

      html = render(view)
      assert html =~ "to-close-on-dashboard"
      assert html =~ "closed"
    end
  end

  describe "active polecats section" do
    test "starting a polecat shows it; stopping removes it", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "polecat-bead", workspace_id: ws.id})

      {:ok, view, _html} = live(conn, "/")
      # Sanity: before starting, the Active Polecats section shows the empty
      # message (the bead may still appear in "Recent beads" — that's fine).
      assert render(view) =~ "No active"

      {:ok, _pid} =
        Polecat.start(bead_id: bead.id, rig: "test/rig", workspace_id: ws.id)

      # PubSub fires :started — re-render now lists the polecat in the
      # active table (count goes from 0 to 1, and the empty message is gone).
      html = render(view)
      assert html =~ "Active Polecats (1)"
      refute html =~ "No active polecats"

      Polecat.stop(bead.id)
      # Allow time for terminate's broadcast to propagate
      Process.sleep(150)

      html = render(view)
      assert html =~ "Active Polecats (0)"
      assert html =~ "No active polecats"
    end
  end

  describe "PRs in flight + escalations" do
    test "empty placeholders render", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "No refineries running"
      assert html =~ "No escalations"
    end
  end
end
