defmodule ArbiterCli.Version do
  @moduledoc """
  Compile-time version stamp embedded into the arb escript.

  All fields are captured when `mix escript.build` runs, so an installed
  `arb` binary carries an exact record of what it was built from.

  `.git/HEAD` and the branch ref it points to are declared as
  `@external_resource` so Mix recompiles this module — and re-captures the
  SHA — whenever `git pull` moves the branch tip to a new commit.
  """

  @app_version (case System.get_env("RELEASE_VERSION") do
                  v when is_binary(v) and byte_size(v) > 0 ->
                    v |> String.trim() |> String.trim_leading("v")

                  _ ->
                    case System.cmd("git", ["describe", "--tags", "--abbrev=0"],
                           stderr_to_stdout: true
                         ) do
                      {tag, 0} -> tag |> String.trim() |> String.trim_leading("v")
                      _ -> "0.0.0"
                    end
                end)

  # ── git-ref tracking (forces recompile on git pull) ──────────────────────
  @git_dir Path.expand("../../../../", __DIR__) |> Path.join(".git")
  @git_head_path Path.join(@git_dir, "HEAD")
  @external_resource @git_head_path

  # Resolve and track the ref file that HEAD points to (e.g. refs/heads/main).
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

  # packed-refs is updated by git fetch/pull when refs are stored packed.
  @git_packed_refs_path Path.join(@git_dir, "packed-refs")

  if File.exists?(@git_packed_refs_path) do
    @external_resource @git_packed_refs_path
  end

  # ── compile-time stamp ────────────────────────────────────────────────────
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
