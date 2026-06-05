defmodule ArbiterWeb.PolecatIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Polecat

  setup do
    for snap <- Polecat.list_children(), do: Polecat.stop(snap.bead_id)
    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "pi-#{System.unique_integer([:positive])}", prefix: "pix"})

    {:ok, ws: ws}
  end

  test "empty state when no acolytes are active", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/polecats")
    assert html =~ ~s(id="polecats-empty")
  end

  test "lists an active acolyte with its workspace, linking to detail", %{conn: conn, ws: ws} do
    {:ok, bead} = Ash.create(Issue, %{title: "active-worker", workspace_id: ws.id})
    {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "test/rig", workspace_id: ws.id)

    {:ok, _view, html} = live(conn, ~p"/polecats")

    assert html =~ ~s(id="polecats")
    assert html =~ bead.id
    assert html =~ ws.name
    assert html =~ ~s(href="/polecats/#{bead.id}")
  end

  test "live: stopping an acolyte removes it via PubSub", %{conn: conn, ws: ws} do
    {:ok, bead} = Ash.create(Issue, %{title: "soon-stopped", workspace_id: ws.id})
    {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "test/rig", workspace_id: ws.id)

    {:ok, view, _html} = live(conn, ~p"/polecats")
    assert render(view) =~ bead.id

    Polecat.stop(bead.id)
    Process.sleep(150)

    refute render(view) =~ bead.id
  end
end
