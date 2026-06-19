defmodule ArbiterWeb.BeadDetailLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Beads.{Dependency, Issue, Workspace}
  alias Arbiter.Polecat

  setup do
    for snap <- Polecat.list_children() do
      Polecat.stop(snap.bead_id)
    end

    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "bd-ws-#{System.unique_integer([:positive])}", prefix: "bdt"})

    {:ok, ws: ws}
  end

  describe "GET /beads/:id" do
    test "renders the bead with workspace, status, and history", %{conn: conn, ws: ws} do
      {:ok, bead} =
        Ash.create(Issue, %{
          title: "important thing",
          description: "do the thing",
          workspace_id: ws.id,
          priority: 1
        })

      {:ok, _view, html} = live(conn, ~p"/beads/#{bead.id}")

      assert html =~ bead.id
      assert html =~ "important thing"
      assert html =~ "do the thing"
      assert html =~ ws.name
      # History section shows the :create version.
      assert html =~ "History"
      assert html =~ "create"
    end

    test "renders blocked-by + blocks dependency sections", %{conn: conn, ws: ws} do
      {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: :blocks
        })

      {:ok, _view, html} = live(conn, ~p"/beads/#{a.id}")

      assert html =~ "Blocked by (1)"
      assert html =~ b.id
      assert html =~ "B"
    end

    test "shows polecat info inline when one is running", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "polly", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "test/rig")

      {:ok, _view, html} = live(conn, ~p"/beads/#{bead.id}")

      assert html =~ "Worker"
      assert html =~ "idle"
      assert html =~ "view full output"
    end

    # Regression for bd-bb9fev: a polecat snapshot without `:claude_session?`
    # used to crash render/1 with BadBooleanError because the strict `and`
    # operator rejected a nil left operand.
    test "renders when the polecat snapshot has no :claude_session? field",
         %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "no-claude", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "test/rig")

      {:ok, _view, html} = live(conn, ~p"/beads/#{bead.id}")
      assert html =~ bead.id
      assert html =~ "Worker"
    end

    test "tells the user when no polecat is running", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "lonely", workspace_id: ws.id})

      {:ok, _view, html} = live(conn, ~p"/beads/#{bead.id}")
      assert html =~ "No worker running"
      assert html =~ "arb sling"
    end

    test "404-ish state when bead doesn't exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/beads/bdt-doesnotexist")
      assert html =~ "not found"
    end

    test "re-renders when a relevant bead_lifecycle fires", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "transitioning", workspace_id: ws.id})

      {:ok, view, html} = live(conn, ~p"/beads/#{bead.id}")
      assert html =~ "open"

      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      assert render(view) =~ "in_progress"
    end
  end
end
