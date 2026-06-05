defmodule ArbiterCli.Version do
  @moduledoc """
  Compile-time version stamp embedded into the arb escript.

  All fields are captured when `mix escript.build` runs, so an installed
  `arb` binary carries an exact record of what it was built from.
  """

  @app_version Mix.Project.config()[:version]

  {sha_raw, sha_rc} = System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true)
  @git_sha if sha_rc == 0, do: String.trim(sha_raw), else: "unknown"

  {dirty_raw, _} = System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true)
  @git_dirty String.trim(dirty_raw) != ""

  @built_at DateTime.utc_now() |> DateTime.to_iso8601()

  @doc "App version from mix.exs at build time."
  def app_version, do: @app_version

  @doc "Short git SHA at build time, suffixed with `*` when the tree was dirty."
  def git_sha, do: if(@git_dirty, do: "#{@git_sha}*", else: @git_sha)

  @doc "Raw short git SHA without the dirty flag."
  def git_sha_clean, do: @git_sha

  @doc "ISO-8601 UTC timestamp when the escript was built."
  def built_at, do: @built_at

  @doc "True when the working tree was dirty at build time."
  def dirty?, do: @git_dirty
end
