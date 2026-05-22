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

  describe "base_url/0" do
    test "defaults to localhost:4000" do
      System.delete_env("ARB_HOST")
      assert Client.base_url() == "http://127.0.0.1:4000"
    end

    test "honors ARB_HOST" do
      System.put_env("ARB_HOST", "http://example.test:9999")
      assert Client.base_url() == "http://example.test:9999"
      System.delete_env("ARB_HOST")
    end
  end
end
