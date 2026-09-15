defmodule ArbiterWeb.Api.DependencyControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Dependency, Issue, Workspace}

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

    # bd-apj0gq — the REST surface used to be the *unvalidated* one, and it is
    # the one `arb dep add` / `arb create --deps` route through. It now goes
    # through `Arbiter.Tasks.Dependencies` and gets the same guards as MCP.
    test "rejects endpoints in different workspaces, naming both", %{conn: conn, a: a} do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "dep-other-ws", prefix: "dow"})
      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other_ws.id})

      conn =
        post(conn, ~p"/api/dependencies", %{
          from_issue_id: a.id,
          to_issue_id: foreign.id,
          type: "blocks"
        })

      assert %{"error" => %{"message" => message}} = json_response(conn, 400)
      assert message =~ "dep-test-ws"
      assert message =~ "dep-other-ws"
      assert Dependency |> Ash.read!() |> Enum.empty?()
    end

    test "rejects an edge that would close a gating cycle", %{conn: conn, a: a, b: b} do
      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: b.id, to_issue_id: a.id, type: :depends_on})

      conn =
        post(conn, ~p"/api/dependencies", %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: "depends_on"
        })

      assert %{"error" => %{"message" => message}} = json_response(conn, 400)
      assert message =~ "cycle"
      assert message =~ a.id
      assert message =~ b.id
    end

    test "rejects an unknown edge type", %{conn: conn, a: a, b: b} do
      conn =
        post(conn, ~p"/api/dependencies", %{
          from_issue_id: a.id,
          to_issue_id: b.id,
          type: "nonsense"
        })

      assert %{"error" => %{"message" => message}} = json_response(conn, 400)
      assert message =~ "nonsense"
    end

    test "reports an unknown endpoint as not found", %{conn: conn, a: a} do
      conn =
        post(conn, ~p"/api/dependencies", %{
          from_issue_id: a.id,
          to_issue_id: "bd-nope",
          type: "blocks"
        })

      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end

    test "re-evaluates auto_close for a parent_of parent", %{conn: conn, ws: ws, a: a} do
      {:ok, parent} =
        Ash.create(Issue, %{title: "epic", workspace_id: ws.id, auto_close: true})

      {:ok, child} = Ash.update(a, %{}, action: :close)

      conn =
        post(conn, ~p"/api/dependencies", %{
          from_issue_id: parent.id,
          to_issue_id: child.id,
          type: "parent_of"
        })

      assert json_response(conn, 201)
      assert Ash.get!(Issue, parent.id).status == :closed
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
