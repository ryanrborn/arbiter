defmodule ArbiterWeb.WorkerIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Worker

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.bead_id)
    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "pi-#{System.unique_integer([:positive])}", prefix: "pix"})

    {:ok, ws: ws}
  end

  test "empty state when no acolytes are active", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workers")
    assert html =~ ~s(id="workers-empty")
  end

  test "lists an active acolyte with its workspace, linking to detail", %{conn: conn, ws: ws} do
    {:ok, bead} = Ash.create(Issue, %{title: "active-worker", workspace_id: ws.id})
    {:ok, _pid} = Worker.start(bead_id: bead.id, repo: "test/repo", workspace_id: ws.id)

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ ~s(id="workers")
    assert html =~ bead.id
    assert html =~ ws.name
    assert html =~ ~s(href="/workers/#{bead.id}")
  end

  test "live: stopping an acolyte removes it via PubSub", %{conn: conn, ws: ws} do
    {:ok, bead} = Ash.create(Issue, %{title: "soon-stopped", workspace_id: ws.id})
    {:ok, _pid} = Worker.start(bead_id: bead.id, repo: "test/repo", workspace_id: ws.id)

    {:ok, view, _html} = live(conn, ~p"/workers")
    assert render(view) =~ bead.id

    Worker.stop(bead.id)
    Process.sleep(150)

    refute render(view) =~ bead.id
  end
end
