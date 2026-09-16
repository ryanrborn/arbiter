defmodule ArbiterWeb.Api.ServerController do
  @moduledoc """
  Server health and status endpoints.

  Routes:
    * `GET /api/server/migrations` — check for pending database migrations
    * `GET /api/server/bind_address` — what address the HTTP listener is
      actually bound to (bd-1c4pg3). `arb server doctor` uses this to warn
      when a server — possibly remote, via `ARB_HOST` — is reachable
      off-loopback despite the dashboard's no-login auth model.
  """

  use ArbiterWeb, :controller

  def migrations(conn, _params) do
    case Arbiter.Migrations.count_pending() do
      {:ok, 0} ->
        json(conn, %{
          status: "ok",
          pending_count: 0
        })

      {:ok, count} ->
        json(conn, %{
          status: "warning",
          pending_count: count
        })

      {:error, reason} ->
        json(conn, %{
          status: "unknown",
          pending_count: nil,
          error: Atom.to_string(reason)
        })
    end
  end

  def bind_address(conn, _params) do
    ip =
      :arbiter_web
      |> Application.get_env(ArbiterWeb.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:ip)

    json(conn, %{
      ip: format_ip(ip),
      loopback: ArbiterWeb.Loopback.loopback?(ip)
    })
  end

  defp format_ip(nil), do: nil
  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
end
