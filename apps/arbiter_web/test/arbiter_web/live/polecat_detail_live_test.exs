defmodule ArbiterWeb.PolecatDetailLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Polecat

  setup do
    for snap <- Polecat.list_children() do
      Polecat.stop(snap.bead_id)
    end

    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "pd-ws-#{System.unique_integer([:positive])}", prefix: "pd"})

    {:ok, ws: ws}
  end

  describe "GET /polecats/:bead_id" do
    test "renders the snapshot for a running polecat", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-test", workspace_id: ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "test/rig")
      :ok = Polecat.report(pid, :output_lines, ["hello", "world", "arb done"])

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")

      assert html =~ bead.id
      assert html =~ "test/rig"
      assert html =~ "hello"
      assert html =~ "arb done"
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
        Arbiter.PubSub,
        "polecat:" <> bead.id,
        {:polecat_output, bead.id, "fresh-line"}
      )

      # Polecat's meta won't actually contain the line because we only
      # broadcast — but the LiveView still re-reads the snapshot on the
      # event. So let's seed the output_lines via report/3 and then
      # broadcast to trigger the refresh.
      :ok = Polecat.report(pid, :output_lines, ["fresh-line"])

      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        "polecat:" <> bead.id,
        {:polecat_output, bead.id, "fresh-line"}
      )

      assert render(view) =~ "fresh-line"
    end

    test "shows the workspace context when the bead exists", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-ws", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "r")

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")
      assert html =~ "Workspace:"
      assert html =~ ws.name
    end

    test "Stop button kills the polecat and redirects to /", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-stop", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "r")

      {:ok, view, html} = live(conn, ~p"/polecats/#{bead.id}")
      assert html =~ "Stop polecat"

      result = render_click(view, "stop")

      # push_navigate emits a {:live_redirect, ...} return from render_click.
      assert {:error, {:live_redirect, %{to: "/"}}} = result
      assert Polecat.whereis(bead.id) == nil
    end

    test "no Stop button when the polecat is :completed", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-done", workspace_id: ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "r")
      :ok = Polecat.advance(pid, :design)
      :ok = Polecat.complete(pid, :done)

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")
      refute html =~ "Stop polecat"
    end

    test "renders the workflow step bar when a MachineState exists",
         %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-wf", workspace_id: ws.id})
      {:ok, _pid} = Polecat.start(bead_id: bead.id, rig: "r")

      {:ok, _machine_id} =
        Arbiter.Workflows.Machine.attach(Arbiter.Workflows.Work, bead.id, %{
          bead_id: bead.id,
          worktree_path: nil,
          rig: "r"
        })

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")

      assert html =~ "Workflow:"
      # Work's first step is :load_context.
      assert html =~ "load_context"
      assert html =~ "submit"
    end

    test "a claude-driven polecat shows live activity, not frozen workflow steps",
         %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "pd-claude", workspace_id: ws.id})
      {:ok, pid} = Polecat.start(bead_id: bead.id, rig: "r")

      # Even with a MachineState attached (slung polecats always have one), a
      # claude-driven run must NOT show the never-advancing fixed steps — it
      # shows the live activity derived from the stream instead. See bd-c919xj.
      {:ok, _machine_id} =
        Arbiter.Workflows.Machine.attach(Arbiter.Workflows.Work, bead.id, %{
          bead_id: bead.id,
          worktree_path: nil,
          rig: "r"
        })

      :ok = Polecat.advance(pid, :claude)
      :ok = Polecat.report(pid, :claude_session, true)
      :ok = Polecat.report(pid, :activity, "running tests")

      {:ok, _view, html} = live(conn, ~p"/polecats/#{bead.id}")

      assert html =~ "Live activity"
      assert html =~ "running tests"
      # The misleading frozen workflow card + fixed steps are suppressed.
      refute html =~ "Workflow:"
      refute html =~ "load_context"
    end
  end
end
