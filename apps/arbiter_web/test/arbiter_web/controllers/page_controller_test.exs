defmodule ArbiterWeb.PageControllerTest do
  use ArbiterWeb.ConnCase

  test "GET /about (PageController moved here when DashboardLive took /)", %{conn: conn} do
    conn = get(conn, ~p"/about")
    assert html_response(conn, 200) =~ "Arbiter"
  end
end
