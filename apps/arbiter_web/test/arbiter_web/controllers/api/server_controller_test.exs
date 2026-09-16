defmodule ArbiterWeb.Api.ServerControllerTest do
  @moduledoc """
  bd-1c4pg3: `arb server doctor` needs a way to ask a (possibly remote, via
  ARB_HOST) server what it's actually bound to, since the CLI has no
  filesystem/OS access of its own to inspect the listening socket.
  """
  use ArbiterWeb.ConnCase, async: true

  test "GET /api/server/bind_address reports loopback for the default 127.0.0.1 bind", %{
    conn: conn
  } do
    original = Application.get_env(:arbiter_web, ArbiterWeb.Endpoint)
    http = Keyword.put(original[:http] || [], :ip, {127, 0, 0, 1})
    Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, Keyword.put(original, :http, http))
    on_exit(fn -> Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, original) end)

    resp = conn |> get("/api/server/bind_address") |> json_response(200)

    assert resp["ip"] == "127.0.0.1"
    assert resp["loopback"] == true
  end

  test "GET /api/server/bind_address reports non-loopback for an overridden 0.0.0.0 bind", %{
    conn: conn
  } do
    original = Application.get_env(:arbiter_web, ArbiterWeb.Endpoint)
    http = Keyword.put(original[:http] || [], :ip, {0, 0, 0, 0})
    Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, Keyword.put(original, :http, http))
    on_exit(fn -> Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, original) end)

    resp = conn |> get("/api/server/bind_address") |> json_response(200)

    assert resp["ip"] == "0.0.0.0"
    assert resp["loopback"] == false
  end
end
