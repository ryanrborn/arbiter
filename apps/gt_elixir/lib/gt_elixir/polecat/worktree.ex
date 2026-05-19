defmodule GtElixir.Polecat.Worktree do
  @moduledoc """
  Thin wrapper around `git worktree` for the Phase 4 polecat orchestrator.

  Each function shells out to the local `git` CLI via `System.cmd/3` and
  normalizes results into tagged tuples (`{:ok, _}` / `{:error, _}`).

  ## Worktree root

  Worktrees are created under a configurable root directory. By default this
  is `/home/rborn/dev/gt-elixir-worktrees`; override via:

      config :gt_elixir, :worktree_root, "/some/other/dir"

  or at runtime with `Application.put_env/3` (tests rely on this).

  The branch name is mapped to a directory leaf by replacing `/` with `-`,
  so `feature/gte-009-worktree` lives at
  `<root>/feature-gte-009-worktree`.

  ## Design notes

  * `create/3` and `cleanup/1` are idempotent — re-running either with the
    same inputs is a no-op rather than an error.
  * `cleanup/1` does NOT delete the branch; branch lifecycle is the caller's
    concern.
  * `has_uncommitted?/1` returns `{:ok, boolean}` (not a raw bool) so callers
    have a consistent shape and we can add metadata later without breaking
    them.
  """

  @default_root "/home/rborn/dev/gt-elixir-worktrees"

  @typedoc "Absolute path to a git repository or worktree."
  @type path :: String.t()

  @typedoc "Reason returned in `{:error, reason}` tuples."
  @type error_reason ::
          :invalid_branch_name
          | :invalid_path
          | {:git_failed, String.t()}
          | {:not_a_git_repo, path()}

  @doc """
  Create a worktree at `<worktree_root>/<sanitized_branch_name>/` checked out
  on `branch_name`, branching from `base_branch`.

  Idempotent: if the target directory already exists and is on the requested
  branch, returns `{:ok, path}` without re-invoking git.
  """
  @spec create(path(), String.t(), String.t()) :: {:ok, path()} | {:error, error_reason()}
  def create(_repo_path, "", _base_branch), do: {:error, :invalid_branch_name}
  def create(_repo_path, nil, _base_branch), do: {:error, :invalid_branch_name}

  def create(repo_path, branch_name, base_branch)
      when is_binary(repo_path) and is_binary(branch_name) and is_binary(base_branch) do
    path = worktree_path(branch_name)

    cond do
      File.dir?(path) ->
        case current_branch(path) do
          {:ok, ^branch_name} ->
            {:ok, path}

          {:ok, _other} ->
            {:error, {:git_failed, "worktree exists at #{path} on a different branch"}}

          {:error, _} = err ->
            err
        end

      true ->
        File.mkdir_p!(Path.dirname(path))

        case run_git(["worktree", "add", path, "-b", branch_name, base_branch], cd: repo_path) do
          {:ok, _stdout} -> {:ok, path}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Remove the worktree rooted at `worktree_path`.

  Idempotent: returns `:ok` whether or not the worktree existed. Uses
  `git worktree remove --force` first so dirty worktrees are still cleaned up;
  follows with a best-effort `File.rm_rf/1` on the leaf dir to handle the case
  where git's metadata is already gone.
  """
  @spec cleanup(path()) :: :ok | {:error, error_reason()}
  def cleanup(worktree_path) when is_binary(worktree_path) do
    # Try to ask git nicely first. We don't know the parent repo from just
    # the worktree path, so we run `git -C <worktree>` which lets git itself
    # walk up to its parent repo via the gitdir link file.
    _ = run_git(["worktree", "remove", "--force", worktree_path], cd: worktree_path)

    # Whether or not git succeeded (it won't if the worktree was never created,
    # or was already removed but the dir lingered), make sure the directory is
    # gone on disk.
    case File.rm_rf(worktree_path) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, {:git_failed, "rm_rf failed: #{inspect(reason)}"}}
    end
  end

  def cleanup(_), do: {:error, :invalid_path}

  @doc """
  Return the current branch name for the worktree at `path`.
  """
  @spec current_branch(path()) :: {:ok, String.t()} | {:error, error_reason()}
  def current_branch(path) when is_binary(path) do
    case run_git(["rev-parse", "--abbrev-ref", "HEAD"], cd: path) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Return `{:ok, true}` if the worktree at `path` has any uncommitted changes
  (staged, unstaged, or untracked), else `{:ok, false}`.
  """
  @spec has_uncommitted?(path()) :: {:ok, boolean()} | {:error, error_reason()}
  def has_uncommitted?(path) when is_binary(path) do
    case run_git(["status", "--porcelain"], cd: path) do
      {:ok, ""} -> {:ok, false}
      {:ok, output} -> {:ok, String.trim(output) != ""}
      {:error, _} = err -> err
    end
  end

  @doc """
  Push the worktree at `path` to a remote.

  ## Options

    * `:remote` — remote name (default `"origin"`).
    * `:set_upstream` — when `true`, passes `-u` to git push.
    * `:branch` — explicit branch ref to push; defaults to the worktree's
      current branch.
  """
  @spec push(path(), keyword()) :: {:ok, String.t()} | {:error, error_reason()}
  def push(path, opts \\ []) when is_binary(path) and is_list(opts) do
    remote = Keyword.get(opts, :remote, "origin")
    set_upstream = Keyword.get(opts, :set_upstream, false)

    with {:ok, branch} <- resolve_branch(path, opts) do
      args =
        ["push"] ++
          if(set_upstream, do: ["-u"], else: []) ++
          [remote, branch]

      run_git(args, cd: path)
    end
  end

  @doc """
  Compute the directory a worktree for `branch_name` lives at.

  Public so callers (and tests) can predict the path without invoking git.
  """
  @spec worktree_path(String.t()) :: path()
  def worktree_path(branch_name) when is_binary(branch_name) do
    root = Application.get_env(:gt_elixir, :worktree_root, @default_root)
    leaf = String.replace(branch_name, "/", "-")
    Path.join(root, leaf)
  end

  # ---- internals ----------------------------------------------------------

  defp resolve_branch(path, opts) do
    case Keyword.get(opts, :branch) do
      nil -> current_branch(path)
      branch when is_binary(branch) -> {:ok, branch}
    end
  end

  defp run_git(args, opts) do
    cd = Keyword.get(opts, :cd)

    cond do
      is_binary(cd) and not File.dir?(cd) ->
        {:error, {:git_failed, "cwd does not exist: #{cd}"}}

      true ->
        case System.cmd("git", args, stderr_to_stdout: true, cd: cd) do
          {output, 0} -> {:ok, output}
          {output, _nonzero} -> {:error, {:git_failed, String.trim(output)}}
        end
    end
  rescue
    e in ErlangError ->
      # `System.cmd` raises if git isn't on PATH.
      {:error, {:git_failed, Exception.message(e)}}
  end
end
