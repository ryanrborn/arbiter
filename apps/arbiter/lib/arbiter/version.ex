defmodule Arbiter.Version do
  @moduledoc """
  Version and git metadata for the Arbiter application.

  In release builds without git at runtime, all fields are captured at compile
  time, so a deployed instance carries an exact record of what it was built from.

  In dev installs (where git is available), `app_version` and `git_sha` are
  computed at runtime to ensure they always reflect the current state, even
  after a `git pull` that adds new tags or commits without a full recompile.
  """

  @git_dir_root Path.expand("../../../../", __DIR__)

  # Compile-time version as fallback for release builds without git at runtime
  @app_version_compiled (case System.cmd("git", ["describe", "--tags", "--abbrev=0"],
                                cd: @git_dir_root,
                                stderr_to_stdout: true
                              ) do
                           {tag, 0} -> tag |> String.trim() |> String.trim_leading("v")
                           _ -> Mix.Project.config()[:version]
                         end)

  # ── git-ref tracking (forces recompile on git pull) ──────────────────────
  # Without these @external_resource declarations Mix considers this file
  # unchanged after a pull and skips recompilation, leaving @git_sha frozen
  # at pre-pull values. (Note: @app_version_compiled is a fallback; the runtime
  # app_version() function always reflects current git state.)
  #
  # `Path.join(project_root, ".git")` only resolves the real git-dir for a
  # plain clone. In a `git worktree` checkout (how every Arbiter worker
  # operates — see CLAUDE.md), `.git` is a *file* containing a `gitdir:`
  # pointer, not a directory: `File.read/1` on a path built by joining onto
  # it fails (ENOTDIR), so `@git_ref_path` silently resolved to `nil` and
  # only `packed-refs` (if present) was ever tracked. A commit that lands as
  # a loose ref — the common case — then went undetected, leaving `git_sha`
  # stamped with whatever commit was checked out when this module last
  # compiled. Asking git itself for `--git-dir` / `--git-common-dir` resolves
  # correctly in both a plain clone and a worktree.

  @git_dir (case System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-dir"],
                   cd: @git_dir_root,
                   stderr_to_stdout: true
                 ) do
              {out, 0} -> String.trim(out)
              _ -> nil
            end)

  @git_common_dir (case System.cmd(
                          "git",
                          ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                          cd: @git_dir_root,
                          stderr_to_stdout: true
                        ) do
                     {out, 0} -> String.trim(out)
                     _ -> nil
                   end)

  @git_head_path if @git_dir, do: Path.join(@git_dir, "HEAD")

  if @git_head_path do
    @external_resource @git_head_path
  end

  # HEAD is a symbolic ref ("ref: refs/heads/branch") whose target commit
  # lives as a loose ref (or in packed-refs) under the *common* dir, shared
  # by every worktree — not under the worktree-specific git-dir above.
  @git_ref_path (case {@git_common_dir, @git_head_path && File.read(@git_head_path)} do
                   {common_dir, {:ok, "ref: " <> ref}} when is_binary(common_dir) ->
                     candidate = Path.join(common_dir, String.trim(ref))
                     if File.exists?(candidate), do: candidate, else: nil

                   _ ->
                     nil
                 end)

  if @git_ref_path do
    @external_resource @git_ref_path
  end

  @git_packed_refs_path if @git_common_dir, do: Path.join(@git_common_dir, "packed-refs")

  if @git_packed_refs_path && File.exists?(@git_packed_refs_path) do
    @external_resource @git_packed_refs_path
  end

  # ── compile-time stamp ────────────────────────────────────────────────────
  # Capture the git SHA at compile time so OTP release builds (which have no
  # live git process at runtime) still report a real ref. Falls back to
  # "unknown" only when git is genuinely unavailable.
  {sha_raw, sha_rc} =
    System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: @git_dir_root, stderr_to_stdout: true)

  @git_sha if sha_rc == 0, do: String.trim(sha_raw), else: "unknown"

  @built_at DateTime.utc_now() |> DateTime.to_iso8601()

  @doc """
  App version from git tags.

  When git is available at runtime, returns the current tag-based version. This ensures
  dev installs always report the correct version even after a `git pull` that adds new
  tags. In release builds without git at runtime, returns the compile-time version.
  """
  def app_version do
    case System.cmd("git", ["describe", "--tags", "--abbrev=0"],
           cd: @git_dir_root,
           stderr_to_stdout: true
         ) do
      {tag, 0} -> tag |> String.trim() |> String.trim_leading("v")
      _ -> @app_version_compiled
    end
  rescue
    _error -> @app_version_compiled
  end

  @doc """
  Short git SHA.

  When git is available at runtime, returns the current HEAD SHA. This ensures
  dev installs always report the correct SHA even if the compile-time version is stale.
  In release builds without git at runtime, returns the compile-time SHA.
  """
  def git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"],
           cd: @git_dir_root,
           stderr_to_stdout: true
         ) do
      {sha, 0} -> String.trim(sha)
      _ -> @git_sha
    end
  rescue
    _error -> @git_sha
  end

  @doc "ISO-8601 UTC timestamp when this module was compiled."
  def built_at, do: @built_at
end
