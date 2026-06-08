defmodule ArbiterWeb.Api.ConvoyControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Beads.{Convoy, ConvoyMembership, Issue, Workspace}

  setup %{conn: conn} do
    {:ok, ws} = Ash.create(Workspace, %{name: "cv-test-ws", prefix: "cvt"})
    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  describe "POST /api/convoys" do
    test "creates a convoy", %{conn: conn, ws: ws} do
      conn = post(conn, ~p"/api/convoys", %{title: "batch one", workspace_id: ws.id})

      body = json_response(conn, 201)
      assert body["title"] == "batch one"
      assert body["status"] == "open"
      assert body["lifecycle"] == "system_managed"
      assert body["member_ids"] == []
      assert body["total_issues"] == 0
      assert body["closed_issues"] == 0
    end

    test "returns 422 on missing title", %{conn: conn, ws: ws} do
      conn = post(conn, ~p"/api/convoys", %{workspace_id: ws.id})
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end
  end

  describe "GET /api/convoys" do
    test "lists convoys scoped to a workspace", %{conn: conn, ws: ws} do
      {:ok, _other_ws} = Ash.create(Workspace, %{name: "cv-other-ws", prefix: "cvo"})
      {:ok, c1} = Ash.create(Convoy, %{title: "one", workspace_id: ws.id})
      {:ok, c2} = Ash.create(Convoy, %{title: "two", workspace_id: ws.id})

      conn = get(conn, ~p"/api/convoys?workspace_id=#{ws.id}")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      assert Enum.sort(ids) == Enum.sort([c1.id, c2.id])
    end

    test "lists all convoys when no workspace filter is given", %{conn: conn, ws: ws} do
      {:ok, _c} = Ash.create(Convoy, %{title: "one", workspace_id: ws.id})

      conn = get(conn, ~p"/api/convoys")
      body = json_response(conn, 200)
      assert is_list(body["data"])
      assert length(body["data"]) >= 1
    end
  end

  describe "GET /api/convoys/:id" do
    test "returns the convoy with member ids + aggregates", %{conn: conn, ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "x", workspace_id: ws.id})
      {:ok, i1} = Ash.create(Issue, %{title: "a", workspace_id: ws.id})
      {:ok, i2} = Ash.create(Issue, %{title: "b", workspace_id: ws.id})
      {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i1.id})
      {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i2.id})
      {:ok, _} = Ash.update(i1, %{}, action: :close)

      conn = get(conn, ~p"/api/convoys/#{c.id}")

      body = json_response(conn, 200)
      assert body["id"] == c.id
      assert Enum.sort(body["member_ids"]) == Enum.sort([i1.id, i2.id])
      assert body["total_issues"] == 2
      assert body["closed_issues"] == 1
    end

    test "returns 404 for missing convoy", %{conn: conn} do
      conn = get(conn, ~p"/api/convoys/cvt-cv-doesnotexist")
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "POST /api/convoys/:id/close" do
    test "closes the convoy with a reason", %{conn: conn, ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "closeme", workspace_id: ws.id, lifecycle: :owned})

      conn = post(conn, ~p"/api/convoys/#{c.id}/close", %{reason: "shipped"})

      body = json_response(conn, 200)
      assert body["status"] == "closed"
      assert body["closed_reason"] == "shipped"
      refute is_nil(body["closed_at"])
    end
  end

  describe "POST /api/convoys/:id/members" do
    test "adds a member and returns the convoy with updated aggregates", %{conn: conn, ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "c", workspace_id: ws.id})
      {:ok, i} = Ash.create(Issue, %{title: "a", workspace_id: ws.id})

      conn = post(conn, ~p"/api/convoys/#{c.id}/members", %{issue_id: i.id})

      body = json_response(conn, 200)
      assert body["member_ids"] == [i.id]
      assert body["total_issues"] == 1
      assert body["closed_issues"] == 0
    end

    test "is idempotent on the (convoy_id, issue_id) unique index", %{conn: conn, ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "c", workspace_id: ws.id})
      {:ok, i} = Ash.create(Issue, %{title: "a", workspace_id: ws.id})

      _ = post(conn, ~p"/api/convoys/#{c.id}/members", %{issue_id: i.id})
      conn = post(conn, ~p"/api/convoys/#{c.id}/members", %{issue_id: i.id})

      body = json_response(conn, 200)
      assert body["member_ids"] == [i.id]
      assert body["total_issues"] == 1
    end

    test "returns 404 for a missing convoy", %{conn: conn, ws: ws} do
      {:ok, i} = Ash.create(Issue, %{title: "a", workspace_id: ws.id})

      conn = post(conn, ~p"/api/convoys/cvt-cv-nope/members", %{issue_id: i.id})
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end

    test "returns 400 when issue_id is missing", %{conn: conn, ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "c", workspace_id: ws.id})

      conn = post(conn, ~p"/api/convoys/#{c.id}/members", %{})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end
  end

  describe "DELETE /api/convoys/:id/members/:issue_id" do
    test "removes a member and returns the convoy", %{conn: conn, ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "c", workspace_id: ws.id})
      {:ok, i} = Ash.create(Issue, %{title: "a", workspace_id: ws.id})
      {:ok, _} = Ash.create(ConvoyMembership, %{convoy_id: c.id, issue_id: i.id})

      conn = delete(conn, ~p"/api/convoys/#{c.id}/members/#{i.id}")

      body = json_response(conn, 200)
      assert body["member_ids"] == []
      assert body["total_issues"] == 0
    end

    test "is idempotent when the member is absent", %{conn: conn, ws: ws} do
      {:ok, c} = Ash.create(Convoy, %{title: "c", workspace_id: ws.id})
      {:ok, i} = Ash.create(Issue, %{title: "a", workspace_id: ws.id})

      conn = delete(conn, ~p"/api/convoys/#{c.id}/members/#{i.id}")

      body = json_response(conn, 200)
      assert body["member_ids"] == []
    end

    test "returns 404 for a missing convoy", %{conn: conn} do
      conn = delete(conn, ~p"/api/convoys/cvt-cv-nope/members/cvt-001")
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end
end
