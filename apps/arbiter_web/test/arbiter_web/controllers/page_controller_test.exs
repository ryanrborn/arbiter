defmodule ArbiterWeb.PageControllerTest do
  use ArbiterWeb.ConnCase

  test "GET /about (PageController moved here when DashboardLive took /)", %{conn: conn} do
    conn = get(conn, ~p"/about")
    assert html_response(conn, 200) =~ "Arbiter"
  end

  test "GET /about displays Arbiter version and git SHA", %{conn: conn} do
    conn = get(conn, ~p"/about")
    html = html_response(conn, 200)

    assert html =~ Arbiter.Version.app_version()
    assert html =~ Arbiter.Version.git_sha()
  end
end
