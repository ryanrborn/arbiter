defmodule ArbiterWeb.Api.VersionControllerTest do
  use ArbiterWeb.ConnCase, async: true

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "GET /api/version" do
    test "returns version fields", %{conn: conn} do
      conn = get(conn, ~p"/api/version")
      assert body = json_response(conn, 200)

      assert is_binary(body["version"])
      assert is_binary(body["sha"])
      assert is_binary(body["built_at"])
      assert is_binary(body["booted_at"])
    end

    test "booted_at is a valid ISO-8601 timestamp", %{conn: conn} do
      conn = get(conn, ~p"/api/version")
      body = json_response(conn, 200)

      assert {:ok, _dt, _} = DateTime.from_iso8601(body["booted_at"])
    end

    test "built_at is a valid ISO-8601 timestamp", %{conn: conn} do
      conn = get(conn, ~p"/api/version")
      body = json_response(conn, 200)

      assert {:ok, _dt, _} = DateTime.from_iso8601(body["built_at"])
    end

    test "sha reflects the current HEAD, not a stale compile-time value", %{conn: conn} do
      {expected_sha, 0} =
        System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true)

      conn = get(conn, ~p"/api/version")
      body = json_response(conn, 200)

      assert body["sha"] == String.trim(expected_sha)
    end
  end
end
