defmodule GtElixirWeb.Api.IssueControllerTest do
  use GtElixirWeb.ConnCase, async: false

  alias GtElixir.Beads.{Dependency, Issue, Workspace}

  setup %{conn: conn} do
    {:ok, ws} = Ash.create(Workspace, %{name: "api-test-ws", prefix: "api"})
    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  describe "POST /api/issues" do
    test "creates issue with valid attrs", %{conn: conn, ws: ws} do
      conn =
        post(conn, ~p"/api/issues", %{
          title: "first",
          workspace_id: ws.id,
          priority: 1,
          issue_type: "bug"
        })

      assert %{
               "id" => id,
               "title" => "first",
               "status" => "open",
               "priority" => 1,
               "issue_type" => "bug",
               "workspace_id" => ws_id
             } = json_response(conn, 201)

      assert String.starts_with?(id, "api-")
      assert ws_id == ws.id
    end

    test "returns 422 with validation_error on missing title", %{conn: conn, ws: ws} do
      conn = post(conn, ~p"/api/issues", %{workspace_id: ws.id})

      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end
  end

  describe "GET /api/issues/:id" do
    test "returns the issue as a bare object", %{conn: conn, ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "show me", workspace_id: ws.id})

      conn = get(conn, ~p"/api/issues/#{issue.id}")

      body = json_response(conn, 200)
      assert body["id"] == issue.id
      assert body["title"] == "show me"
      assert body["status"] == "open"
    end

    test "returns 404 for missing issue", %{conn: conn} do
      conn = get(conn, ~p"/api/issues/api-doesnotexist")
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/issues" do
    test "lists all issues wrapped in data", %{conn: conn, ws: ws} do
      {:ok, _i1} = Ash.create(Issue, %{title: "a", workspace_id: ws.id})
      {:ok, _i2} = Ash.create(Issue, %{title: "b", workspace_id: ws.id})

      conn = get(conn, ~p"/api/issues")
      assert %{"data" => list} = json_response(conn, 200)
      assert length(list) == 2
    end

    test "filters by status", %{conn: conn, ws: ws} do
      {:ok, open_issue} = Ash.create(Issue, %{title: "still open", workspace_id: ws.id})
      {:ok, will_close} = Ash.create(Issue, %{title: "to close", workspace_id: ws.id})
      {:ok, _closed} = Ash.update(will_close, %{}, action: :close)

      conn = get(conn, ~p"/api/issues?status=open")
      assert %{"data" => list} = json_response(conn, 200)
      assert Enum.any?(list, &(&1["id"] == open_issue.id))
      refute Enum.any?(list, &(&1["id"] == will_close.id))
    end

    test "filters by workspace_id", %{conn: conn, ws: ws} do
      {:ok, ws2} = Ash.create(Workspace, %{name: "other", prefix: "oth"})
      {:ok, mine} = Ash.create(Issue, %{title: "mine", workspace_id: ws.id})
      {:ok, _other} = Ash.create(Issue, %{title: "other", workspace_id: ws2.id})

      conn = get(conn, ~p"/api/issues?workspace_id=#{ws.id}")
      assert %{"data" => list} = json_response(conn, 200)
      assert Enum.all?(list, &(&1["workspace_id"] == ws.id))
      assert Enum.any?(list, &(&1["id"] == mine.id))
    end

    test "returns 400 for unknown status value", %{conn: conn} do
      conn = get(conn, ~p"/api/issues?status=zzzzz_not_an_atom_zzzzz")
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end
  end

  describe "PATCH /api/issues/:id" do
    test "updates allowed fields", %{conn: conn, ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "before", workspace_id: ws.id})

      conn = patch(conn, ~p"/api/issues/#{issue.id}", %{title: "after", priority: 0})

      body = json_response(conn, 200)
      assert body["title"] == "after"
      assert body["priority"] == 0
    end

    test "ignores workspace_id (immutable post-create)", %{conn: conn, ws: ws} do
      {:ok, ws2} = Ash.create(Workspace, %{name: "other", prefix: "oth"})
      {:ok, issue} = Ash.create(Issue, %{title: "stay-put", workspace_id: ws.id})

      conn = patch(conn, ~p"/api/issues/#{issue.id}", %{title: "renamed", workspace_id: ws2.id})

      body = json_response(conn, 200)
      assert body["workspace_id"] == ws.id
    end

    test "returns 404 on missing", %{conn: conn} do
      conn = patch(conn, ~p"/api/issues/api-nope", %{title: "x"})
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "POST /api/issues/:id/close" do
    test "closes an open issue", %{conn: conn, ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "close me", workspace_id: ws.id})

      conn = post(conn, ~p"/api/issues/#{issue.id}/close", %{reason: "done"})

      body = json_response(conn, 200)
      assert body["status"] == "closed"
      refute is_nil(body["closed_at"])
    end

    test "returns 422 closing an already-closed issue", %{conn: conn, ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "x", workspace_id: ws.id})
      {:ok, closed} = Ash.update(issue, %{}, action: :close)

      conn = post(conn, ~p"/api/issues/#{closed.id}/close")
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end
  end

  describe "POST /api/issues/:id/reopen" do
    test "reopens a closed issue", %{conn: conn, ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "reopen me", workspace_id: ws.id})
      {:ok, closed} = Ash.update(issue, %{}, action: :close)

      conn = post(conn, ~p"/api/issues/#{closed.id}/reopen")

      body = json_response(conn, 200)
      assert body["status"] == "open"
      assert is_nil(body["closed_at"])
    end

    test "returns 422 reopening an already-open issue", %{conn: conn, ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "x", workspace_id: ws.id})

      conn = post(conn, ~p"/api/issues/#{issue.id}/reopen")
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end
  end

  describe "GET /api/issues/ready" do
    test "returns only open issues with no open blockers", %{conn: conn, ws: ws} do
      {:ok, blocker} = Ash.create(Issue, %{title: "blocker", workspace_id: ws.id})
      {:ok, blocked} = Ash.create(Issue, %{title: "blocked", workspace_id: ws.id})
      {:ok, free} = Ash.create(Issue, %{title: "free", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: blocked.id,
          to_issue_id: blocker.id,
          type: :depends_on
        })

      conn = get(conn, ~p"/api/issues/ready")
      assert %{"data" => list} = json_response(conn, 200)
      ids = Enum.map(list, & &1["id"])

      # blocker has no incoming gating deps from itself, it's ready;
      # blocked is gated by an open issue, NOT ready.
      assert blocker.id in ids
      assert free.id in ids
      refute blocked.id in ids
    end
  end
end
