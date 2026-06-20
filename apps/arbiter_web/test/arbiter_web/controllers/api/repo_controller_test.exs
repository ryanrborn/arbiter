defmodule ArbiterWeb.Api.RepoControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Workspace

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "GET /api/repos" do
    test "returns a JSON list of repos", %{conn: conn} do
      conn = get(conn, ~p"/api/repos")
      assert %{"data" => data} = json_response(conn, 200)
      assert is_list(data)

      for repo <- data do
        assert Map.has_key?(repo, "name")
        assert Map.has_key?(repo, "path")
        assert Map.has_key?(repo, "source")
        assert Map.has_key?(repo, "workers")
        assert Map.has_key?(repo, "worktrees")
      end
    end

    test "surfaces a workspace's configured repo_paths", %{conn: conn} do
      {:ok, _ws} =
        Ash.create(Workspace, %{
          name: "repo-ws",
          prefix: "rpw",
          config: %{"repo_paths" => %{"alpha" => "/tmp/does-not-exist-alpha"}}
        })

      conn = get(conn, ~p"/api/repos")
      assert %{"data" => data} = json_response(conn, 200)

      alpha = Enum.find(data, &(&1["name"] == "alpha"))
      assert alpha
      assert alpha["path"] == "/tmp/does-not-exist-alpha"
      assert alpha["source"] == "repo-ws"
      assert is_integer(alpha["workers"])
      assert is_integer(alpha["worktrees"])
    end

    test "surfaces a workspace's legacy rig_paths with compat fallback", %{conn: conn} do
      {:ok, _ws} =
        Ash.create(Workspace, %{
          name: "rig-compat-ws",
          prefix: "rcw",
          config: %{"rig_paths" => %{"beta" => "/tmp/does-not-exist-beta"}}
        })

      conn = get(conn, ~p"/api/repos")
      assert %{"data" => data} = json_response(conn, 200)

      beta = Enum.find(data, &(&1["name"] == "beta"))
      assert beta
      assert beta["path"] == "/tmp/does-not-exist-beta"
      assert beta["source"] == "rig-compat-ws"
    end

    test "responds with JSON, not an HTML 404", %{conn: conn} do
      conn = get(conn, ~p"/api/repos")
      assert json_response(conn, 200)
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end
  end
end
