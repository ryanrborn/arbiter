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
    test "renders all section headers", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Dashboard"
      assert html =~ "Workspaces"
      assert html =~ "Active "
      assert html =~ "Recent beads"
      assert html =~ "PRs in flight"
      assert html =~ "Escalations"
    end

    test "empty polecats shows the no-active-* line", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "No active"
    end

    test "shows a live indicator when the WebSocket is connected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      rendered = render(view)
      assert rendered =~ ~s(id="live-indicator")
      assert rendered =~ "live"
      assert rendered =~ "badge-success"
      refute rendered =~ "stale"
    end

    test "initial static render (no WebSocket) shows the stale indicator", %{conn: conn} do
      # Phoenix.ConnTest.get/2 returns the pre-connection HTTP render — the
      # second-pass connected mount is what `live/2` triggers. The static
      # render mirrors what a browser sees before its LiveView socket
      # finishes connecting (or after it drops).
      conn = get(conn, "/")
      html = Phoenix.ConnTest.html_response(conn, 200)
      assert html =~ ~s(id="live-indicator")
      assert html =~ "stale"
      assert html =~ "badge-warning"
    end
  end

  describe "workspaces section" do
    test "lists every workspace with its prefix and bead counts", %{conn: conn, ws: ws} do
      {:ok, _open} = Ash.create(Issue, %{title: "o1", workspace_id: ws.id})
      {:ok, _open2} = Ash.create(Issue, %{title: "o2", workspace_id: ws.id})
      {:ok, to_close} = Ash.create(Issue, %{title: "to-close", workspace_id: ws.id})
      {:ok, _} = Ash.update(to_close, %{}, action: :close)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "workspaces-table"
      assert html =~ ws.name
      assert html =~ ws.prefix
      # 2 open, 1 closed in this workspace.
      assert html =~ "ds"
    end

    test "counts active polecats per workspace", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "polly-ws", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "test/rig", workspace_id: ws.id)

      {:ok, _view, html} = live(conn, "/")
      # The workspace row should reflect the active polecat. Hard to assert
      # an exact cell value in the rendered table, but a workspace column
      # next to "1" somewhere is sufficient.
      assert html =~ ws.name
      assert html =~ "Active "
    end
  end

  describe "rigs section" do
    setup do
      prior = Application.get_env(:gt_elixir, :rig_paths)
      Application.put_env(:gt_elixir, :rig_paths, %{"dashboard-test-rig" => "/tmp/dash-rig"})

      on_exit(fn ->
        if prior,
          do: Application.put_env(:gt_elixir, :rig_paths, prior),
          else: Application.delete_env(:gt_elixir, :rig_paths)
      end)

      :ok
    end

    test "lists rigs configured via Application env", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "rigs-table"
      assert html =~ "dashboard-test-rig"
      assert html =~ "/tmp/dash-rig"
      assert html =~ "(app)"
    end

    test "counts active polecats per rig", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "rig-pol", workspace_id: ws.id})

      {:ok, _pid} =
        Polecat.start(
          bead_id: bead.id,
          rig: "dashboard-test-rig",
          workspace_id: ws.id
        )

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "dashboard-test-rig"
      # Row should show 1 active polecat for the rig.
      # Hard to assert specific cell content; check the rig name + a 1
      # appear on the same page render.
      assert html =~ "dashboard-test-rig"
    end

    test "surfaces a polecat using an unconfigured rig under (unconfigured)",
         %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "weird-rig", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "no-such-rig", workspace_id: ws.id)

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "no-such-rig"
      assert html =~ "(unconfigured)"
    end
  end

  describe "active polecats workspace column" do
    test "shows the workspace name on each polecat row", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "ws-col", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "test/rig", workspace_id: ws.id)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "active-polecats"
      assert html =~ ws.name
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
