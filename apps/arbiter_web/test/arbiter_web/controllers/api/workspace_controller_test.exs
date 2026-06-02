defmodule ArbiterWeb.Api.WorkspaceControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Beads.Workspace

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "POST /api/workspaces" do
    test "creates a workspace", %{conn: conn} do
      conn =
        post(conn, ~p"/api/workspaces", %{
          name: "new-ws",
          prefix: "nws",
          description: "test"
        })

      body = json_response(conn, 201)
      assert body["name"] == "new-ws"
      assert body["prefix"] == "nws"
      assert body["description"] == "test"
      assert is_binary(body["id"])
    end

    test "returns 422 on invalid prefix", %{conn: conn} do
      conn = post(conn, ~p"/api/workspaces", %{name: "x", prefix: "Bad-Prefix!"})
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end
  end

  describe "GET /api/workspaces/:id" do
    test "returns workspace", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "showme", prefix: "shw"})

      conn = get(conn, ~p"/api/workspaces/#{ws.id}")
      body = json_response(conn, 200)
      assert body["id"] == ws.id
      assert body["name"] == "showme"
    end

    test "returns 404 for missing", %{conn: conn} do
      bogus = "00000000-0000-0000-0000-000000000000"
      conn = get(conn, ~p"/api/workspaces/#{bogus}")
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/workspaces" do
    test "lists workspaces", %{conn: conn} do
      {:ok, _} = Ash.create(Workspace, %{name: "w1", prefix: "w1"})
      {:ok, _} = Ash.create(Workspace, %{name: "w2", prefix: "w2"})

      conn = get(conn, ~p"/api/workspaces")
      assert %{"data" => list} = json_response(conn, 200)
      assert length(list) >= 2
    end
  end

  describe "PATCH /api/workspaces/:id" do
    test "activates the GitHub tracker via config", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "to-activate", prefix: "act"})

      github_config = %{
        "tracker" => %{
          "type" => "github",
          "config" => %{
            "owner" => "ryanrborn",
            "repo" => "arbiter",
            "credentials_ref" => "env:GITHUB_TOKEN"
          }
        }
      }

      conn = patch(conn, ~p"/api/workspaces/#{ws.id}", %{config: github_config})

      body = json_response(conn, 200)
      assert body["id"] == ws.id
      assert body["config"]["tracker"]["type"] == "github"
      assert body["config"]["tracker"]["config"]["owner"] == "ryanrborn"
    end

    test "updates scalar fields", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "rename-me", prefix: "rnm"})

      conn = patch(conn, ~p"/api/workspaces/#{ws.id}", %{name: "renamed", description: "now set"})

      body = json_response(conn, 200)
      assert body["name"] == "renamed"
      assert body["description"] == "now set"
    end

    test "returns 422 on an invalid tracker type", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "bad-cfg", prefix: "bad"})

      conn =
        patch(conn, ~p"/api/workspaces/#{ws.id}", %{
          config: %{"tracker" => %{"type" => "bitbucket"}}
        })

      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end

    test "returns 404 for a missing workspace", %{conn: conn} do
      bogus = "00000000-0000-0000-0000-000000000000"
      conn = patch(conn, ~p"/api/workspaces/#{bogus}", %{name: "nope"})
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end

    test "PUT is also accepted", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "put-me", prefix: "put"})

      conn = put(conn, ~p"/api/workspaces/#{ws.id}", %{description: "via put"})
      assert json_response(conn, 200)["description"] == "via put"
    end
  end
end
