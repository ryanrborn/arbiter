defmodule ArbiterWeb.Api.VersionController do
  @moduledoc """
  GET /api/version — server version stamp.

  Returns the app version, git SHA, build timestamp, and boot timestamp so
  `arb version` can compare them against the installed CLI escript and flag
  drift.
  """

  use ArbiterWeb, :controller

  @app_version Mix.Project.config()[:version]

  {sha_raw, sha_rc} = System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true)
  @git_sha if sha_rc == 0, do: String.trim(sha_raw), else: "unknown"

  @built_at DateTime.utc_now() |> DateTime.to_iso8601()

  def show(conn, _params) do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    booted_at =
      DateTime.utc_now()
      |> DateTime.add(-div(uptime_ms, 1000), :second)
      |> DateTime.to_iso8601()

    json(conn, %{
      version: @app_version,
      sha: @git_sha,
      built_at: @built_at,
      booted_at: booted_at
    })
  end
end
