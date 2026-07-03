defmodule ArbiterWeb.Plugs.ApiAuthTest do
  use ArbiterWeb.ConnCase, async: true

  alias Arbiter.MCP.Scope

  # A stable API route we can hit to test auth without caring about business logic.
  @test_path "/api/version"

  defp loopback_conn(conn) do
    %{conn | remote_ip: {127, 0, 0, 1}}
  end

  defp loopback_ipv6_conn(conn) do
    %{conn | remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}
  end

  defp non_loopback_conn(conn) do
    %{conn | remote_ip: {10, 0, 0, 1}}
  end

  defp with_bearer(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "loopback requests" do
    test "IPv4 loopback passes without a token", %{conn: conn} do
      conn = conn |> loopback_conn() |> get(@test_path)
      assert conn.status == 200
    end

    test "IPv6 loopback passes without a token", %{conn: conn} do
      conn = conn |> loopback_ipv6_conn() |> get(@test_path)
      assert conn.status == 200
    end

    test "IPv4 loopback still passes with a valid token", %{conn: conn} do
      token = Scope.mint_coordinator(nil)
      conn = conn |> loopback_conn() |> with_bearer(token) |> get(@test_path)
      assert conn.status == 200
    end
  end

  describe "non-loopback without token" do
    test "returns 401 with no Authorization header", %{conn: conn} do
      conn = conn |> non_loopback_conn() |> get(@test_path)
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["error"]["message"])
    end

    test "returns 401 with a non-Bearer Authorization header", %{conn: conn} do
      conn =
        conn
        |> non_loopback_conn()
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> get(@test_path)

      assert conn.status == 401
    end
  end

  describe "non-loopback with invalid token" do
    test "returns 401 for a garbage token", %{conn: conn} do
      conn = conn |> non_loopback_conn() |> with_bearer("not-a-real-token") |> get(@test_path)
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["error"]["message"])
    end

    test "returns 401 for an expired token", %{conn: conn} do
      expired_token = Scope.mint_coordinator(nil, max_age: -1)
      conn = conn |> non_loopback_conn() |> with_bearer(expired_token) |> get(@test_path)
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "expired"
    end
  end

  describe "non-loopback with valid token" do
    test "coordinator token allows through", %{conn: conn} do
      token = Scope.mint_coordinator(nil)
      conn = conn |> non_loopback_conn() |> with_bearer(token) |> get(@test_path)
      assert conn.status == 200
    end
  end
end
