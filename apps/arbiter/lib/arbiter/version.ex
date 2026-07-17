defmodule Arbiter.Version do
  @moduledoc """
  Compile-time version stamp for the Arbiter application.

  All fields are captured at compile time, so any deployed Arbiter instance
  carries an exact record of what it was built from.

  `.git/HEAD` and the branch ref it points to are declared as
  `@external_resource` so Mix recompiles this module — and re-captures the
  SHA — whenever `git pull` moves the branch tip to a new commit.
  """

  @app_version Mix.Project.config()[:version]

  # ── git-ref tracking (forces recompile on git pull) ──────────────────────
  # Without these @external_resource declarations Mix considers this file
  # unchanged after a pull and skips recompilation, leaving @git_sha frozen
  # at the pre-pull commit.
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
  # "unknown" only when git is genuinely unavailable.
  {sha_raw, sha_rc} = System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true)
  @git_sha if sha_rc == 0, do: String.trim(sha_raw), else: "unknown"

  @built_at DateTime.utc_now() |> DateTime.to_iso8601()

  @doc "App version from mix.exs at compile time."
  def app_version, do: @app_version

  @doc "Short git SHA at compile time."
  def git_sha, do: @git_sha

  @doc "ISO-8601 UTC timestamp when this module was compiled."
  def built_at, do: @built_at
end
