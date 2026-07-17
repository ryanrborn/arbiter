defmodule ArbiterWeb.Api.VersionController do
  @moduledoc """
  GET /api/version — server version stamp.

  Returns the app version, git SHA, build timestamp, and boot timestamp so
  `arb version` can compare them against the installed CLI escript and flag
  drift.
  """

  use ArbiterWeb, :controller

  def show(conn, _params) do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    booted_at =
      DateTime.utc_now()
      |> DateTime.add(-div(uptime_ms, 1000), :second)
      |> DateTime.to_iso8601()

    json(conn, %{
      version: Arbiter.Version.app_version(),
      sha: Arbiter.Version.git_sha(),
      built_at: Arbiter.Version.built_at(),
      booted_at: booted_at
    })
  end
end
