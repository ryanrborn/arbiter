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

  # ── git-ref tracking (forces recompile on git pull) ──────────────────────
  # Mirrors ArbiterCli.Version — without these @external_resource declarations
  # Mix considers this file unchanged after a pull and skips recompilation,
  # leaving @git_sha frozen at the pre-pull commit.
  @git_dir Path.expand("../../../../", __DIR__) |> Path.join(".git")
  @git_head_path Path.join(@git_dir, "HEAD")
  @external_resource @git_head_path

  @git_ref_path (case File.read(@git_head_path) do
                   {:ok, "ref: " <> ref} ->
                     candidate = Path.join(@git_dir, String.trim(ref))
                     if File.exists?(candidate), do: candidate, else: nil

                   _ ->
                     nil
                 end)

  if @git_ref_path do
    @external_resource @git_ref_path
  end

  @git_packed_refs_path Path.join(@git_dir, "packed-refs")

  if File.exists?(@git_packed_refs_path) do
    @external_resource @git_packed_refs_path
  end

  # ── compile-time stamp ────────────────────────────────────────────────────
  # Capture the git SHA at compile time so OTP release builds (which have no
  # live git process at runtime) still report a real ref. Falls back to
  # "unknown" only when git is genuinely unavailable (e.g. a Docker scratch
  # build with no VCS tooling).
  {sha_raw, sha_rc} = System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true)
  @git_sha if sha_rc == 0, do: String.trim(sha_raw), else: "unknown"

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
