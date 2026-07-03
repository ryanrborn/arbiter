defmodule ArbiterCli.ClientTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Client

  test "GET success returns decoded JSON body" do
    stub_get("/api/issues/x", %{"id" => "x", "title" => "T"})
    assert {:ok, %{"id" => "x", "title" => "T"}} = Client.get("/api/issues/x")
  end

  test "GET 404 returns Client.Error with status and message" do
    stub_get(
      "/api/issues/missing",
      %{"error" => %{"type" => "not_found", "message" => "resource not found"}},
      404
    )

    assert {:error, %Client.Error{kind: :http, status: 404, message: "resource not found"}} =
             Client.get("/api/issues/missing")
  end

  test "POST 422 returns Client.Error with details" do
    stub_post(
      "/api/issues",
      %{
        "error" => %{
          "type" => "validation_error",
          "message" => "validation failed",
          "details" => %{"errors" => [%{"field" => "title", "message" => "is required"}]}
        }
      },
      422
    )

    assert {:error, %Client.Error{kind: :http, status: 422}} =
             Client.post("/api/issues", %{"title" => ""})
  end

  test "connection refused yields :connection_refused with hint" do
    stub_transport_error(:get, "/api/workspaces", :econnrefused)

    assert {:error, %Client.Error{kind: :connection_refused, hint: hint}} =
             Client.get("/api/workspaces")

    assert hint =~ "mix phx.server"
  end

  test "401 without ARB_TOKEN yields clear hint" do
    stub_get("/api/issues/x", %{}, 401)

    assert {:error, %Client.Error{kind: :http, status: 401, hint: hint}} =
             Client.get("/api/issues/x")

    assert hint =~ "ARB_TOKEN"
    assert hint =~ "mint"
  end

  test "401 with JSON error yields clear hint + message" do
    stub_get(
      "/api/issues/x",
      %{"error" => %{"type" => "unauthorized", "message" => "invalid token"}},
      401
    )

    assert {:error,
            %Client.Error{
              kind: :http,
              status: 401,
              message: "invalid token",
              hint: hint
            }} =
             Client.get("/api/issues/x")

    assert hint =~ "ARB_TOKEN"
    assert hint =~ "mint"
  end

  describe "base_url/0" do
    test "defaults to localhost:4848" do
      System.delete_env("ARB_HOST")
      assert Client.base_url() == "http://127.0.0.1:4848"
    end

    test "honors ARB_HOST" do
      System.put_env("ARB_HOST", "http://example.test:9999")
      assert Client.base_url() == "http://example.test:9999"
      System.delete_env("ARB_HOST")
    end
  end

  describe "Authorization header with ARB_TOKEN" do
    test "includes Authorization header when ARB_TOKEN is set" do
      System.put_env("ARB_TOKEN", "test-token-123")

      stub_routes([
        {
          {"get", "/api/test"},
          fn conn ->
            auth = Plug.Conn.get_req_header(conn, "authorization")

            if auth == ["Bearer test-token-123"] do
              conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"ok" => true})
            else
              conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "no auth header"})
            end
          end
        }
      ])

      assert {:ok, %{"ok" => true}} = Client.get("/api/test")
      System.delete_env("ARB_TOKEN")
    end

    test "omits Authorization header when ARB_TOKEN is unset" do
      System.delete_env("ARB_TOKEN")

      stub_routes([
        {
          {"get", "/api/test"},
          fn conn ->
            auth = Plug.Conn.get_req_header(conn, "authorization")

            if auth == [] do
              conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"ok" => true})
            else
              conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "unexpected auth"})
            end
          end
        }
      ])

      assert {:ok, %{"ok" => true}} = Client.get("/api/test")
    end
  end
end
