defmodule ArbiterWeb.PageControllerTest do
  use ArbiterWeb.ConnCase

  test "GET /about (PageController moved here when DashboardLive took /)", %{conn: conn} do
    conn = get(conn, ~p"/about")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end
end
