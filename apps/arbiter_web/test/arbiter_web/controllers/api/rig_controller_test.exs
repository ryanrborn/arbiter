defmodule ArbiterWeb.Api.RigControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Beads.Workspace

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "GET /api/rigs" do
    test "returns a JSON list of rigs", %{conn: conn} do
      conn = get(conn, ~p"/api/rigs")
      assert %{"data" => data} = json_response(conn, 200)
      assert is_list(data)

      for rig <- data do
        assert Map.has_key?(rig, "name")
        assert Map.has_key?(rig, "path")
        assert Map.has_key?(rig, "source")
        assert Map.has_key?(rig, "polecats")
        assert Map.has_key?(rig, "worktrees")
      end
    end

    test "surfaces a workspace's configured rig_paths", %{conn: conn} do
      {:ok, _ws} =
        Ash.create(Workspace, %{
          name: "rig-ws",
          prefix: "rgw",
          config: %{"rig_paths" => %{"alpha" => "/tmp/does-not-exist-alpha"}}
        })

      conn = get(conn, ~p"/api/rigs")
      assert %{"data" => data} = json_response(conn, 200)

      alpha = Enum.find(data, &(&1["name"] == "alpha"))
      assert alpha
      assert alpha["path"] == "/tmp/does-not-exist-alpha"
      assert alpha["source"] == "rig-ws"
      assert is_integer(alpha["polecats"])
      assert is_integer(alpha["worktrees"])
    end

    test "responds with JSON, not an HTML 404", %{conn: conn} do
      conn = get(conn, ~p"/api/rigs")
      assert json_response(conn, 200)
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end
  end
end
