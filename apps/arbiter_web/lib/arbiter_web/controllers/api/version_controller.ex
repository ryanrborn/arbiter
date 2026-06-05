defmodule ArbiterWeb.Api.VersionController do
  @moduledoc """
  GET /api/version — server version stamp.

  Returns the app version, git SHA, build timestamp, and boot timestamp so
  `arb version` can compare them against the installed CLI escript and flag
  drift.
  """

  use ArbiterWeb, :controller

  @app_version Mix.Project.config()[:version]
  @built_at DateTime.utc_now() |> DateTime.to_iso8601()

  def show(conn, _params) do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    booted_at =
      DateTime.utc_now()
      |> DateTime.add(-div(uptime_ms, 1000), :second)
      |> DateTime.to_iso8601()

    json(conn, %{
      version: @app_version,
      sha: Application.get_env(:arbiter_web, :runtime_git_sha, "unknown"),
      built_at: @built_at,
      booted_at: booted_at
    })
  end
end
