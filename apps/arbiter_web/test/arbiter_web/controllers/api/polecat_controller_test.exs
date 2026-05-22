defmodule ArbiterWeb.Api.PolecatControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Polecat

  setup %{conn: conn} do
    # Clean slate — other tests in the umbrella may have left polecats running.
    for snap <- Polecat.list_children() do
      Polecat.stop(snap.bead_id)
    end

    Process.sleep(50)

    {:ok, ws} = Ash.create(Workspace, %{name: "pol-ctrl-ws", prefix: "pc"})
    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  describe "GET /api/polecats/:bead_id" do
    test "returns the snapshot including output_lines for a running polecat",
         %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "show-me", workspace_id: ws.id})
      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "test/rig")

      # Simulate Claude output flowing through the polecat.
      :ok = Polecat.report(polecat_pid, :output_lines, ["hello", "world", "gt done"])

      conn = get(conn, ~p"/api/polecats/#{bead.id}")
      body = json_response(conn, 200)

      assert body["bead_id"] == bead.id
      assert body["rig"] == "test/rig"
      assert body["status"] in ["idle", "running", "awaiting", "completed", "failed"]
      assert body["output_lines"] == ["hello", "world", "gt done"]
    end

    test "returns 404 for an unknown bead_id", %{conn: conn} do
      conn = get(conn, ~p"/api/polecats/no-such-bead")
      assert json_response(conn, 404)
    end

    test "snapshot includes failure_reason when the polecat failed",
         %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "failed-pol", workspace_id: ws.id})
      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")

      :ok = Polecat.fail(polecat_pid, {:claude_crashed, "bad token"})

      conn = get(conn, ~p"/api/polecats/#{bead.id}")
      body = json_response(conn, 200)

      assert body["status"] == "failed"
      assert body["failure_reason"] =~ "claude_crashed"
    end
  end

  describe "POST /api/polecats/:bead_id/stop" do
    test "terminates a running polecat", %{conn: conn, ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "stop-me", workspace_id: ws.id})
      {:ok, polecat_pid} = Polecat.start(bead_id: bead.id, rig: "r")
      ref = Process.monitor(polecat_pid)

      conn = post(conn, ~p"/api/polecats/#{bead.id}/stop", %{})
      body = json_response(conn, 200)

      assert body["bead_id"] == bead.id
      assert body["stopped"] == true

      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000
      assert Polecat.whereis(bead.id) == nil
    end

    test "returns 404 for an unknown bead_id", %{conn: conn} do
      conn = post(conn, ~p"/api/polecats/no-such-bead/stop", %{})
      assert json_response(conn, 404)
    end
  end
end
