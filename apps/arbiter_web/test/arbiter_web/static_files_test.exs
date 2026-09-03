defmodule ArbiterWeb.StaticFilesTest do
  use ArbiterWeb.ConnCase

  describe "GET /favicon.ico" do
    test "returns 200 OK", %{conn: conn} do
      conn = get(conn, "/favicon.ico")
      assert conn.status == 200
    end

    test "returns image/x-icon content type", %{conn: conn} do
      conn = get(conn, "/favicon.ico")
      assert get_resp_header(conn, "content-type") |> List.first() =~ "image"
    end
  end
end
