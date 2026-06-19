defmodule Arbiter.Polecat.Worktree do
  @moduledoc """
  Thin wrapper around `git worktree` for the Phase 4 polecat orchestrator.

  Each function shells out to the local `git` CLI via `System.cmd/3` and
  normalizes results into tagged tuples (`{:ok, _}` / `{:error, _}`).

  ## Worktree root

  Worktrees are created under a configurable root directory. By default this
  is `/home/rborn/dev/arbiter-worktrees`; override via:

      config :arbiter, :worktree_root, "/some/other/dir"

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

  @default_root "/home/rborn/dev/arbiter-worktrees"

  @typedoc "Absolute path to a git repository or worktree."
  @type path :: String.t()

  @typedoc "Reason returned in `{:error, reason}` tuples."
  @type error_reason ::
          :invalid_branch_name
          | :invalid_path
          | {:git_failed, String.t()}
          | {:not_a_git_repo, path()}
          | {:fetch_failed, String.t()}
          | {:missing_origin_remote, String.t()}
          | {:missing_origin_ref, String.t()}

  @doc """
  Create a worktree at `<worktree_root>/<sanitized_branch_name>/` checked out
  on `branch_name`, branching from the upstream tip of `base_branch`
  (`origin/<base_branch>`).

  Before creating the worktree, fetches `<base_branch>` from `origin` in
  `repo_path`, so every worker starts on current upstream regardless of the
  repo checkout's drift (stale local base, dirty working tree, or HEAD on an
  unrelated branch). If `origin` is not configured or the ref cannot be
  resolved after the fetch, the call aborts with a clear error rather than
  silently falling back to a stale local base.

  Idempotent: if the target directory already exists and is on the requested
  branch, returns `{:ok, path}` without re-invoking git (no fetch either, so
  re-provisioning a still-good worktree is cheap).
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

        with :ok <- ensure_origin_remote(repo_path),
             :ok <- fetch_origin_branch(repo_path, base_branch),
             :ok <- ensure_origin_ref(repo_path, base_branch),
             {:ok, _stdout} <-
               run_git(
                 ["worktree", "add", path, "-b", branch_name, "origin/" <> base_branch],
                 cd: repo_path
               ) do
          {:ok, path}
        end
    end
  end

  defp ensure_origin_remote(repo_path) do
    case run_git(["remote", "get-url", "origin"], cd: repo_path) do
      {:ok, _} ->
        :ok

      {:error, {:git_failed, msg}} ->
        {:error,
         {:missing_origin_remote,
          "repo at #{repo_path} has no `origin` remote configured; " <>
            "branching from a stale local base is unsafe. git: #{msg}"}}
    end
  end

  # Shallow `--no-tags` keeps the fetch fast — we only need the tip of the
  # target branch. `--prune` drops deleted remote refs so a renamed integration
  # branch doesn't leave a dangling `origin/<old>` that resolves but is stale.
  defp fetch_origin_branch(repo_path, base_branch) do
    case run_git(["fetch", "--no-tags", "--prune", "origin", base_branch], cd: repo_path) do
      {:ok, _} ->
        :ok

      {:error, {:git_failed, msg}} ->
        {:error,
         {:fetch_failed, "git fetch origin #{base_branch} failed in #{repo_path}: #{msg}"}}
    end
  end

  defp ensure_origin_ref(repo_path, base_branch) do
    ref = "refs/remotes/origin/" <> base_branch

    case run_git(["rev-parse", "--verify", "--quiet", ref], cd: repo_path) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error,
         {:missing_origin_ref,
          "origin/#{base_branch} does not resolve in #{repo_path} after fetch; " <>
            "refusing to branch from stale local state"}}
    end
  end

  @doc """
  Attach a worktree at `<worktree_root>/<sanitized_branch_name>/` to an
  **existing** branch — no `-b`, no new branch creation.

  Counterpart to `create/3`. Use it when you need a worktree checked out on
  a branch that already exists in the repo — typically because a remote PR
  was opened against it. The merge queue's conflict-resolver worker
  (`Arbiter.Workflows.MergeQueue.ConflictResolver`) is the primary caller: it
  rebases the existing PR branch in place, so it must NOT create a new
  branch that would shadow the PR's head ref.

  Idempotent on the same-branch path: if the target directory already exists
  and is on the requested branch, returns `{:ok, path}` without re-invoking
  git. If the directory exists on a different branch, returns
  `{:error, {:git_failed, _}}` rather than silently switching it.
  """
  @spec attach(path(), String.t()) :: {:ok, path()} | {:error, error_reason()}
  def attach(_repo_path, ""), do: {:error, :invalid_branch_name}
  def attach(_repo_path, nil), do: {:error, :invalid_branch_name}

  def attach(repo_path, branch_name)
      when is_binary(repo_path) and is_binary(branch_name) do
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

        case run_git(["worktree", "add", path, branch_name], cd: repo_path) do
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

  # Top-level build-artifact paths that git may report as untracked even though
  # they should be ignored. Per-bead worktrees symlink `deps` (and sometimes
  # `_build`) to a shared cache; the repo's directory-only `/deps/` `/_build/`
  # ignore patterns do NOT match a symlink, so `git status --porcelain` emits
  # `?? deps`. Counting that as "uncommitted" false-fails the commit gate on
  # genuinely-committed work — the inverse of the bug the gate exists to catch.
  # See bd-dg0gs6 / #172.
  @ignored_artifact_paths ~w(deps deps/ _build _build/)

  @doc """
  Return `{:ok, true}` if the worktree at `path` has any uncommitted changes
  (staged, unstaged, or untracked), else `{:ok, false}`.

  Untracked build-artifact roots (`deps`, `_build`) are ignored — see
  `@ignored_artifact_paths` — so a worktree whose only "change" is a leaked
  `deps` symlink reads as clean.
  """
  @spec has_uncommitted?(path()) :: {:ok, boolean()} | {:error, error_reason()}
  def has_uncommitted?(path) when is_binary(path) do
    case run_git(["status", "--porcelain"], cd: path) do
      {:ok, output} ->
        dirty? =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&artifact_entry?/1)
          |> Enum.any?()

        {:ok, dirty?}

      {:error, _} = err ->
        err
    end
  end

  # A porcelain line is `XY <path>` (two status chars, a space, then the path).
  # Returns true when the path is one of the known build-artifact roots, so the
  # caller can disregard a leaked `deps`/`_build` entry without masking real
  # untracked source files (e.g. `lib/deps_helper.ex` still counts).
  defp artifact_entry?(<<_status::binary-size(2), " ", rest::binary>>),
    do: String.trim(rest) in @ignored_artifact_paths

  defp artifact_entry?(_line), do: false

  @doc """
  Return `{:ok, true}` if the worktree's current branch has commits not
  present on `base_ref` (default `"main"`), else `{:ok, false}`.

  Counterpart to `has_uncommitted?/1`. Together they let a cleanup policy
  ask "is it safe to throw this worktree away?": safe means **no**
  uncommitted changes AND **no** commits-ahead-of-base. The latter
  matters for local-only repos where the worktree branch is the only
  copy of those commits.

  When the base ref doesn't resolve (e.g., the parent repo has no `main`),
  returns `{:ok, true}` to be safe — we'd rather skip cleanup than delete
  potentially-valuable commits.
  """
  @spec has_commits_ahead?(path(), String.t()) :: {:ok, boolean()} | {:error, error_reason()}
  def has_commits_ahead?(path, base_ref \\ "main") when is_binary(path) do
    case run_git(["rev-list", "--count", base_ref <> "..HEAD"], cd: path) do
      {:ok, count_str} ->
        case Integer.parse(String.trim(count_str)) do
          {0, _} -> {:ok, false}
          {n, _} when n > 0 -> {:ok, true}
          _ -> {:ok, true}
        end

      {:error, _} ->
        # Base ref doesn't exist or git failed — conservative: assume there
        # might be commits worth preserving.
        {:ok, true}
    end
  end

  @typedoc """
  Completion-readiness verdict from `completion_state/2`.

    * `:ready` — the worktree is clean AND the branch has commits ahead of base.
    * `:uncommitted` — the worktree has staged/unstaged/untracked changes (the
      "worker edited but forgot to commit" case bd-ofql8k targets).
    * `:no_commits` — the worktree is clean but the branch has no commits
      ahead of base (the "worker signalled done without doing any work" case).
  """
  @type completion :: :ready | :uncommitted | :no_commits

  @doc """
  Snapshot the worktree's completion-readiness against `base_ref` (default
  `"main"`): is it safe to hand off to the review gate / merger?

  Returns:

    * `{:ok, :ready}` — clean tree AND ≥1 commit ahead of `base_ref`.
    * `{:ok, :uncommitted}` — the worktree has uncommitted changes; the
      review gate / merger must NOT see it (the per-bead branch HEAD does
      not yet include those edits, so they're invisible to `git diff
      base..HEAD`). This is the bd-ofql8k root cause.
    * `{:ok, :no_commits}` — clean tree but the branch has no commits
      ahead of `base_ref`. Either no work was done, or commits landed
      somewhere else.
    * `{:error, reason}` — git couldn't be queried.

  `:uncommitted` wins over `:no_commits` when both apply: an edited-but-
  uncommitted worktree is the actionable signal ("commit it"), and the
  absence of commits is a downstream consequence of that.
  """
  @spec completion_state(path(), String.t()) ::
          {:ok, completion()} | {:error, error_reason()}
  def completion_state(path, base_ref \\ "main") when is_binary(path) do
    with {:ok, dirty?} <- has_uncommitted?(path),
         {:ok, ahead?} <- has_commits_ahead?(path, base_ref) do
      cond do
        dirty? -> {:ok, :uncommitted}
        not ahead? -> {:ok, :no_commits}
        true -> {:ok, :ready}
      end
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
    root = Application.get_env(:arbiter, :worktree_root, @default_root)
    leaf = String.replace(branch_name, "/", "-")
    Path.join(root, leaf)
  end

  @doc """
  List the linked worktrees attached to the repo at `repo_path`, excluding
  the main worktree.

  Each entry is a map with `:path` and `:branch`. Returns `[]` if the path
  isn't a git repo, git isn't on PATH, or anything else goes wrong — this
  is a "best effort" stat helper, not a strict API.
  """
  @spec list(path()) :: [%{path: path(), branch: String.t() | nil}]
  def list(repo_path) when is_binary(repo_path) do
    case run_git(["worktree", "list", "--porcelain"], cd: repo_path) do
      {:ok, output} ->
        output
        |> parse_worktree_list()
        # First entry is the main worktree; the user wants linked ones only.
        |> Enum.drop(1)

      {:error, _} ->
        []
    end
  end

  defp parse_worktree_list(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_worktree_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_worktree_block(block) do
    block
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, " ", parts: 2) do
        ["worktree", path] -> Map.put(acc, :path, path)
        ["branch", ref] -> Map.put(acc, :branch, strip_branch_ref(ref))
        _ -> acc
      end
    end)
    |> case do
      %{path: _} = entry -> Map.put_new(entry, :branch, nil)
      _ -> nil
    end
  end

  defp strip_branch_ref("refs/heads/" <> name), do: name
  defp strip_branch_ref(other), do: other

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
