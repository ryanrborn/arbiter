defmodule ArbiterWeb.Api.DependencyControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Beads.{Dependency, Issue, Workspace}

  setup %{conn: conn} do
    {:ok, ws} = Ash.create(Workspace, %{name: "dep-test-ws", prefix: "dpt"})
    {:ok, a} = Ash.create(Issue, %{title: "a", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "b", workspace_id: ws.id})

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws, a: a, b: b}
  end

  describe "POST /api/dependencies" do
    test "creates an edge", %{conn: conn, a: a, b: b} do
      conn =
        post(conn, ~p"/api/dependencies", %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: "blocks"
        })

      body = json_response(conn, 201)
      assert body["from_issue_id"] == a.id
      assert body["to_issue_id"] == b.id
      assert body["type"] == "blocks"
    end

    test "returns 422 on self-reference", %{conn: conn, a: a} do
      conn =
        post(conn, ~p"/api/dependencies", %{
          from_issue_id: a.id,
          to_issue_id: a.id,
          type: "blocks"
        })

      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end
  end

  describe "DELETE /api/dependencies/:from/:to" do
    test "deletes all edges between pair when no type given", %{conn: conn, a: a, b: b} do
      {:ok, _} = Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :blocks})

      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :relates_to})

      conn = delete(conn, ~p"/api/dependencies/#{a.id}/#{b.id}")
      assert response(conn, 204)

      # Both edges gone
      assert [] =
               Dependency
               |> Ash.Query.do_filter(from_issue_id: a.id, to_issue_id: b.id)
               |> Ash.read!()
    end

    test "deletes only the matching type when ?type=", %{conn: conn, a: a, b: b} do
      {:ok, _} = Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :blocks})

      {:ok, kept} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :relates_to})

      conn = delete(conn, ~p"/api/dependencies/#{a.id}/#{b.id}?type=blocks")
      assert response(conn, 204)

      remaining =
        Dependency
        |> Ash.Query.do_filter(from_issue_id: a.id, to_issue_id: b.id)
        |> Ash.read!()

      assert [%{id: id}] = remaining
      assert id == kept.id
    end

    test "returns 404 when no matching edges", %{conn: conn, a: a, b: b} do
      conn = delete(conn, ~p"/api/dependencies/#{a.id}/#{b.id}")
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end
end
