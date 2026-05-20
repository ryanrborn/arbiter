defmodule GtElixirWeb.PolecatDetailLiveTest do
  use GtElixirWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias GtElixir.Beads.{Issue, Workspace}
  alias GtElixir.Polecat

  setup do
    for snap <- Polecat.list_children() do
      Polecat.stop(snap.bead_id)
    end

    Process.sleep(50)

    {:ok, ws} = Ash.create(Workspace, %{name: "pd-ws-#{System.unique_integer([:positive])}", prefix: "pd"})
    {:ok, ws: ws}
  end

  describe "GET /polecats/:bead_id" do
    test "renders the snapshot for a running polecat", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-test", workspace_id: ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "test/rig")
      :ok = Polecat.report(pid, :output_lines, ["hello", "world", "gt done"])

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")

      assert html =~ bead.id
      assert html =~ "test/rig"
      assert html =~ "hello"
      assert html =~ "gt done"
    end

    test "tells the user when no polecat is registered", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/polecats/no-such-bead")
      assert html =~ "No polecat registered"
    end

    test "updates live when the polecat receives new output", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-live", workspace_id: ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "r")

      {:ok, view, html} = live(conn, ~p"/polecats/#{bead.id}")
      refute html =~ "fresh-line"

      # Push an output line via the same PubSub topic the polecat would use.
      Phoenix.PubSub.broadcast(
        GtElixir.PubSub,
        "polecat:" <> bead.id,
        {:polecat_output, bead.id, "fresh-line"}
      )

      # Polecat's meta won't actually contain the line because we only
      # broadcast — but the LiveView still re-reads the snapshot on the
      # event. So let's seed the output_lines via report/3 and then
      # broadcast to trigger the refresh.
      :ok = Polecat.report(pid, :output_lines, ["fresh-line"])

      Phoenix.PubSub.broadcast(
        GtElixir.PubSub,
        "polecat:" <> bead.id,
        {:polecat_output, bead.id, "fresh-line"}
      )

      assert render(view) =~ "fresh-line"
    end
  end
end
