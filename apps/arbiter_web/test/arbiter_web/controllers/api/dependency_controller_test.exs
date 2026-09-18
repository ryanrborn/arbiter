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

  describe "GET /api/dependencies" do
    test "lists every edge in the workspace, with both endpoints' status/priority", %{
      conn: conn,
      ws: ws,
      a: a,
      b: b
    } do
      {:ok, _} =
        Ash.update(a, %{priority: 1}, action: :update)

      {:ok, dep} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :conflicts_with})

      conn = get(conn, ~p"/api/dependencies", workspace_id: ws.id)

      assert %{"data" => [row]} = json_response(conn, 200)
      assert row["id"] == dep.id
      assert row["type"] == "conflicts_with"
      assert row["from"]["id"] == a.id
      assert row["from"]["status"]
      assert row["from"]["priority"] == 1
      assert row["to"]["id"] == b.id
      assert row["to"]["status"]
    end

    test "filters by type", %{conn: conn, ws: ws, a: a, b: b} do
      {:ok, _} = Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :blocks})

      {:ok, kept} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :relates_to})

      conn = get(conn, ~p"/api/dependencies", workspace_id: ws.id, type: "relates_to")

      assert %{"data" => [row]} = json_response(conn, 200)
      assert row["id"] == kept.id
    end

    test "requires workspace_id or issue_id", %{conn: conn} do
      conn = get(conn, ~p"/api/dependencies")
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end

    test "rejects a workspace_id/issue_id pair that don't match, naming both", %{
      conn: conn,
      a: a
    } do
      {:ok, other_ws} = Ash.create(Workspace, %{name: "dep-other-ws2", prefix: "dow2"})

      conn = get(conn, ~p"/api/dependencies", workspace_id: other_ws.id, issue_id: a.id)

      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end

    # bd-1defgu acceptance #7: reproduces the investigation that motivated this
    # ticket — "which `conflicts_with` pairs have both sides open?" used to
    # require opening the production SQLite file by hand. 24 seeded
    # `conflicts_with` edges (21 closed↔closed, 3 with one side open), and one
    # `blocks` edge that must NOT show up when filtering by type. A single
    # `GET /api/dependencies?type=conflicts_with` has to return all 24, each
    # carrying both sides' status, so "is there a live pair" is answerable
    # from this one response without a second lookup.
    test "a single GET ?type=conflicts_with returns every conflicts_with edge, both sides' status included",
         %{conn: conn, ws: ws, a: a, b: b} do
      {:ok, _} = Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :blocks})

      closed_closed_pairs =
        for n <- 1..21 do
          {:ok, x} = Ash.create(Issue, %{title: "closed-x-#{n}", workspace_id: ws.id})
          {:ok, y} = Ash.create(Issue, %{title: "closed-y-#{n}", workspace_id: ws.id})
          {:ok, x} = Ash.update(x, %{}, action: :close)
          {:ok, y} = Ash.update(y, %{}, action: :close)

          {:ok, dep} =
            Ash.create(Dependency, %{
              from_issue_id: x.id,
              to_issue_id: y.id,
              type: :conflicts_with
            })

          dep.id
        end

      open_closed_pairs =
        for n <- 1..3 do
          {:ok, x} = Ash.create(Issue, %{title: "open-x-#{n}", workspace_id: ws.id})
          {:ok, y} = Ash.create(Issue, %{title: "closed-y2-#{n}", workspace_id: ws.id})
          {:ok, y} = Ash.update(y, %{}, action: :close)

          {:ok, dep} =
            Ash.create(Dependency, %{
              from_issue_id: x.id,
              to_issue_id: y.id,
              type: :conflicts_with
            })

          dep.id
        end

      conflict_ids = closed_closed_pairs ++ open_closed_pairs
      assert length(conflict_ids) == 24

      conn = get(conn, ~p"/api/dependencies", workspace_id: ws.id, type: "conflicts_with")

      %{"data" => rows} = json_response(conn, 200)
      assert length(rows) == 24

      returned_ids = Enum.map(rows, & &1["id"]) |> Enum.sort()
      assert returned_ids == Enum.sort(conflict_ids)

      assert Enum.all?(rows, fn row -> row["from"]["status"] && row["to"]["status"] end)

      live_pairs =
        Enum.count(rows, fn row ->
          row["from"]["status"] == "open" or row["to"]["status"] == "open"
        end)

      assert live_pairs == 3
    end
  end

  describe "GET /api/dependencies/:issue_id" do
    test "returns the issue's edges in both directions", %{conn: conn, ws: ws, a: a, b: b} do
      {:ok, c} = Ash.create(Issue, %{title: "c", workspace_id: ws.id})

      {:ok, dep1} =
        Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :depends_on})

      {:ok, dep2} =
        Ash.create(Dependency, %{from_issue_id: c.id, to_issue_id: a.id, type: :parent_of})

      # unrelated, must not appear
      {:ok, _} =
        Ash.create(Dependency, %{from_issue_id: b.id, to_issue_id: c.id, type: :relates_to})

      conn = get(conn, ~p"/api/dependencies/#{a.id}")

      assert %{"data" => rows} = json_response(conn, 200)
      ids = Enum.map(rows, & &1["id"]) |> Enum.sort()
      assert ids == Enum.sort([dep1.id, dep2.id])
    end

    test "404s for an unknown issue", %{conn: conn} do
      conn = get(conn, ~p"/api/dependencies/bd-nope")
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end
end
