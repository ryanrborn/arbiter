defmodule Arbiter.Worker.Worktree do
  @moduledoc """
  Thin wrapper around `git worktree` for the Phase 4 worker orchestrator.

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

  # Mix envs that acolytes actually use. `test` is the minimum; `dev` is
  # included because some dispatched workers compile in dev mode.
  @seed_envs ~w(test dev)

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

    result =
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
            :ok = seed_compiled_deps(repo_path, path)
            {:ok, path}
          end
      end

    with {:ok, wt_path} <- result do
      _ = ensure_arbiter_exclude(wt_path)
      {:ok, wt_path}
    end
  end

  @doc """
  Create a **detached** worktree at `<worktree_root>/<sanitized_name>/`,
  checked out at the upstream tip of `base_branch` (`origin/<base_branch>`)
  with no branch of its own.

  Counterpart to `create/3` for dispatches whose deliverable is not a branch —
  `task`-type audits/spikes and reviews (bd-9r1tta). They previously ran
  straight from the *shared* local checkout, which on a developer machine is a
  human contributor's working directory: an arbitrary HEAD, arbitrarily many
  commits behind `origin`. An audit reading that tree reports the state of the
  world as of whenever the contributor last pulled, with full confidence and
  file:line citations — the fabricated "PHI encryption was never merged"
  finding this function exists to prevent.

  Same fetch-first guarantee as `create/3`: `origin` must exist, the fetch must
  succeed, and `origin/<base_branch>` must resolve, or the call errors rather
  than silently falling back to stale local state.

  Detached rather than branched on purpose: nothing here is meant to be
  committed or pushed, so there is no branch to leave behind and no way for an
  audit to accidentally commit onto one the merge path would pick up.

  Reads the source repo, writes only `.git/worktrees/<leaf>` and the new
  directory: the source checkout's HEAD, index, working tree, and unpushed
  commits are never touched.

  Idempotent, but NOT a no-op on re-provision: a directory already at the target
  path is **re-pointed** at the freshly-fetched `origin/<base_branch>` rather
  than reused as-is. Reusing it would re-open exactly the hole this function
  closes — the leaf is keyed to the bead, and a worktree outlives its run
  (`CleanupWorktree` removes it only on close, and skips a dirty one), so a
  re-dispatched audit would otherwise read the *first* dispatch's snapshot of
  upstream, however old it has since become. Nothing in a detached inspect
  checkout is meant to be preserved, so re-pointing clobbers nothing.

  Refuses (rather than re-pointing) if the existing directory is on a *branch* —
  that is someone else's worktree and may hold unpushed commits. A directory
  that is not a live worktree at all (metadata pruned, interrupted `worktree
  add`, plain leftover dir) is reclaimed and provisioned fresh.
  """
  @spec create_detached(path(), String.t(), String.t()) ::
          {:ok, path()} | {:error, error_reason()}
  def create_detached(_repo_path, "", _base_branch), do: {:error, :invalid_branch_name}
  def create_detached(_repo_path, nil, _base_branch), do: {:error, :invalid_branch_name}

  def create_detached(repo_path, name, base_branch)
      when is_binary(repo_path) and is_binary(name) and is_binary(base_branch) do
    path = worktree_path(name)

    result =
      if File.dir?(path) do
        refresh_or_recreate_detached(repo_path, path, base_branch)
      else
        add_detached(repo_path, path, base_branch)
      end

    with {:ok, wt_path} <- result do
      _ = ensure_arbiter_exclude(wt_path)
      {:ok, wt_path}
    end
  end

  @inspect_suffix "-inspect"

  @doc """
  The worktree name a *detached inspect* checkout for `base_name` uses.

  Deliberately distinct from the branch leaf `create/3` would use for the same
  bead (`<base_name>` vs `<base_name>#{@inspect_suffix}`). One bead can need
  both — an audit that is later re-filed as code work, or the
  `provision_worktree: true` escape hatch on a `task`-type bead — and sharing a
  leaf makes the two collide: `create/3` finds a detached HEAD there, reports
  "worktree exists … on a different branch", and the dispatch hard-fails until
  someone removes the directory by hand. Separate leaves also mean a path's
  *name* tells you whether it may hold work: a branch worktree can, an inspect
  checkout never does.

  `Issue.Changes.CleanupWorktree` reclaims both leaves on close, so the split
  does not leak worktrees.
  """
  @spec inspect_name(String.t()) :: String.t()
  def inspect_name(base_name) when is_binary(base_name), do: base_name <> @inspect_suffix

  @doc """
  The directory a detached inspect checkout for `base_name` lives at —
  `worktree_path(inspect_name(base_name))`.
  """
  @spec inspect_path(String.t()) :: path()
  def inspect_path(base_name) when is_binary(base_name),
    do: base_name |> inspect_name() |> worktree_path()

  @doc """
  Return `{:ok, true}` if the worktree at `path` has a detached HEAD (no branch),
  `{:ok, false}` if it is on a branch, `{:error, reason}` if `path` is not a
  readable git worktree.

  Lets callers distinguish a detached *inspect* checkout — which holds nothing
  worth preserving and is safe to re-point or throw away — from a branch
  worktree, which may hold unpushed commits (bd-9r1tta).
  """
  @spec detached?(path()) :: {:ok, boolean()} | {:error, error_reason()}
  def detached?(path) when is_binary(path) do
    with {:ok, branch} <- current_branch(path) do
      {:ok, branch == "HEAD"}
    end
  end

  # An existing directory at the inspect leaf: re-point it at current upstream if
  # it is the detached checkout we left there, reclaim-and-recreate if it is not a
  # live worktree at all, refuse if it is on a branch (not ours to clobber).
  defp refresh_or_recreate_detached(repo_path, path, base_branch) do
    case current_branch(path) do
      {:ok, "HEAD"} ->
        repoint_detached(repo_path, path, base_branch)

      {:ok, branch} ->
        {:error,
         {:git_failed,
          "worktree exists at #{path} on branch #{branch}, not a detached inspect " <>
            "checkout; refusing to re-point it (it may hold unpushed commits)"}}

      {:error, _} ->
        # The directory is not a live git worktree — git's metadata was pruned,
        # a `worktree add` was interrupted, or something left a plain directory
        # behind. Reclaim it (`cleanup/1` also drops any stale registration) and
        # provision fresh, rather than failing this bead's dispatch forever.
        _ = cleanup(path)
        add_detached(repo_path, path, base_branch)
    end
  end

  # `--force`: the tree is ours and disposable, so a scratch file a prior agent
  # left modified must not block the re-point. Same fetch-first guarantee as the
  # fresh path — the checkout target is the ref the fetch just advanced.
  defp repoint_detached(repo_path, path, base_branch) do
    with :ok <- ensure_origin_remote(repo_path),
         :ok <- fetch_origin_branch(repo_path, base_branch),
         :ok <- ensure_origin_ref(repo_path, base_branch),
         {:ok, _stdout} <-
           run_git(["checkout", "--detach", "--force", "origin/" <> base_branch], cd: path) do
      :ok = seed_compiled_deps(repo_path, path)
      {:ok, path}
    end
  end

  defp add_detached(repo_path, path, base_branch) do
    File.mkdir_p!(Path.dirname(path))

    with :ok <- ensure_origin_remote(repo_path),
         :ok <- fetch_origin_branch(repo_path, base_branch),
         :ok <- ensure_origin_ref(repo_path, base_branch),
         {:ok, _stdout} <- add_detached_git(repo_path, path, base_branch) do
      :ok = seed_compiled_deps(repo_path, path)
      {:ok, path}
    end
  end

  # A leaf still registered in `.git/worktrees` whose directory is gone makes
  # `worktree add` fail permanently ("is a missing but already registered
  # worktree"), which would strand every future dispatch of that bead. Prune the
  # stale registration once and retry.
  defp add_detached_git(repo_path, path, base_branch) do
    args = ["worktree", "add", "--detach", path, "origin/" <> base_branch]

    case run_git(args, cd: repo_path) do
      {:error, {:git_failed, msg}} = err ->
        if String.contains?(msg, "already registered") do
          _ = run_git(["worktree", "prune"], cd: repo_path)
          run_git(args, cd: repo_path)
        else
          err
        end

      other ->
        other
    end
  end

  # bd-bhrji9: `.arbiter/INBOX` (Arbiter.Messages.WorktreeDelivery) is written
  # into the worktree out-of-band, whenever a coordinator/sibling message
  # arrives — independent of, and not gated by, MCP config injection
  # (`Arbiter.MCP.inject_config?/0`). It never got the same `info/exclude`
  # protection bd-9q966y gave `.mcp.json`/`.gemini/`/`.codex/`, since it predates
  # that fix and lives in a different module entirely. Excluding it here, once
  # per worktree at creation, guarantees the entry exists before any message can
  # ever be delivered — regardless of MCP provider or whether config injection
  # is enabled. Best-effort: `add_to_git_exclude/2` already swallows its own
  # errors so a git hiccup never blocks worktree provisioning.
  @spec ensure_arbiter_exclude(path()) :: :ok
  defp ensure_arbiter_exclude(path),
    do: Arbiter.MCP.AgentConfig.add_to_git_exclude(path, [".arbiter/"])

  @doc """
  Refresh `repo_path`'s remote-tracking ref for `base_branch` from `origin`.

  Refs only: this updates `refs/remotes/origin/<base_branch>` and touches
  nothing else — not HEAD, not the index, not the working tree, not any local
  branch. Safe to call on a checkout a human is actively working in.

  For callers that must keep using a shared checkout as their cwd (local code
  review, which diffs against local branches) but still need `origin/<base>` to
  mean *current* upstream rather than whenever the contributor last pulled
  (bd-9r1tta).

  Returns `:ok` or `{:error, reason}`; callers generally treat it as
  best-effort.
  """
  @spec fetch_origin(path(), String.t()) :: :ok | {:error, error_reason()}
  def fetch_origin(repo_path, base_branch)
      when is_binary(repo_path) and is_binary(base_branch) do
    with :ok <- ensure_origin_remote(repo_path) do
      fetch_origin_branch(repo_path, base_branch)
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
          {:ok, _stdout} ->
            :ok = seed_compiled_deps(repo_path, path)
            {:ok, path}

          {:error, _} = err ->
            err
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

  # Top-level build-artifact paths that git may report as untracked even
  # though they should be ignored. `seed_compiled_deps/2` copies `deps` and
  # `_build/<env>/lib` into every per-task worktree (real `cp -a` copies, not
  # symlinks — see the "Why copy, not symlink" section on that function's
  # doc). A real `deps`/`_build` directory should already match the target
  # repo's own directory-only `/deps/` `/_build/` gitignore patterns, so
  # `git status --porcelain` shouldn't report them at all. These two entries
  # are belt-and-suspenders: if a target repo's `.gitignore` doesn't cover
  # them, or a partial/interrupted seed leaves an unexpected top-level entry,
  # an untracked `deps`/`_build` root must still not false-fail the commit
  # gate on genuinely-committed work — the inverse of the bug the gate exists
  # to catch. See bd-dg0gs6 / #172 (originally filed against a symlink-based
  # seed that was never actually implemented — see bd-6040y1).
  #
  # `.mcp.json` / `.gemini/` / `.codex/` are Arbiter-injected agent-config files
  # (see bd-9q966y). `.arbiter/` is the Admiral/coordinator mailbox delivery
  # directory (`Arbiter.Messages.WorktreeDelivery`, bd-bhrji9) — not a secret,
  # but equally an out-of-band Arbiter artifact that must never land in a
  # contributor commit. All four are gitignored via `info/exclude` (written by
  # `Arbiter.MCP.AgentConfig.write/3` / `add_to_git_exclude/2`, called from
  # `Arbiter.Worker.Worktree.create/3` for `.arbiter/`), so they should never
  # appear in `git status` output. Keeping them here is belt-and-suspenders: if
  # the exclude was not written, an untracked instance must not false-fail the
  # gate. The commit gate separately checks `has_injected_config_in_commits?/2`
  # to catch the harder case where one of these files was explicitly staged and
  # committed.
  @ignored_artifact_paths ~w(deps deps/ _build _build/ .hex .hex/ .mcp.json .gemini/ .codex/ .arbiter .arbiter/ .run-server.sh)

  @doc """
  Return `{:ok, true}` if the worktree at `path` has any uncommitted changes
  (staged, unstaged, or untracked), else `{:ok, false}`.

  Untracked build-artifact roots (`deps`, `_build`) are ignored — see
  `@ignored_artifact_paths` — so a worktree whose only "change" is an
  unexpected `deps`/`_build` root reads as clean.
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

  # Arbiter-injected paths that must NEVER appear in a committed diff. `.mcp.json`
  # / `.gemini/` / `.codex/` carry per-spawn bearer tokens (bd-9q966y); `.arbiter/`
  # is the coordinator/sibling mailbox delivery directory (bd-bhrji9) — not a
  # secret, but an out-of-band Arbiter artifact that must equally never reach a
  # contributor commit. Each entry is either a filename (exact match) or a
  # directory prefix (ends with "/", matches any path within it).
  @injected_config_patterns ~w(.mcp.json .gemini/ .codex/ .arbiter/)

  @doc """
  Return `{:ok, true}` if the branch's own committed diff (relative to its
  merge-base with `base_ref`, NOT a literal `base_ref..HEAD` two-dot diff)
  contains any Arbiter-injected path (`.mcp.json`, `.gemini/`, `.codex/`,
  `.arbiter/`), else `{:ok, false}`.

  These paths must NEVER appear in commits: the first three carry per-spawn
  bearer tokens; `.arbiter/` is the mailbox delivery directory. This check is the
  commit-gate backstop (bd-9q966y) for the case where `info/exclude` protection
  was bypassed and the file was explicitly staged and committed.

  Uses `merge_base/2` (bd-4ltc3e) rather than diffing straight against
  `base_ref`'s current tip: a literal `base_ref..HEAD` diff also picks up
  files that changed on `base_ref` itself after the branch was cut. If
  `base_ref` later gained its own (unrelated) commit touching one of these
  paths, every branch forked before it would false-trip on a diff it never
  produced — exactly what a reviewer's `base...HEAD` (three-dot) compare
  avoids. Fails open on any git error so a transient hiccup does not strand
  a completion.
  """
  @spec has_injected_config_in_commits?(path(), String.t()) ::
          {:ok, boolean()} | {:error, error_reason()}
  def has_injected_config_in_commits?(path, base_ref \\ "main") when is_binary(path) do
    with base when is_binary(base) <- merge_base(path, base_ref),
         {:ok, output} <- run_git(["diff", "--name-only", base <> "..HEAD", "--"], cd: path) do
      changed = String.split(output, "\n", trim: true)
      found? = Enum.any?(changed, &injected_config_path?/1)
      {:ok, found?}
    else
      _ -> {:ok, false}
    end
  end

  defp injected_config_path?(file) do
    Enum.any?(@injected_config_patterns, fn pat ->
      if String.ends_with?(pat, "/"),
        do: String.starts_with?(file, pat) or file == String.trim_trailing(pat, "/"),
        else: file == pat
    end)
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
      review gate / merger must NOT see it (the per-task branch HEAD does
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
  Bring the worktree's current branch up to date with `target_branch` by
  fetching `origin/<target_branch>` and merging it into the branch.

  Run before a code review so the reviewer sees the branch against the CURRENT
  target tip rather than the (possibly older) base it was cut from. When the
  target advances mid-run, an un-updated branch makes the target's unrelated
  commits look like the branch's own work — the bd-ased52 false-reject. Merging
  (rather than rebasing) keeps history append-only, so a branch with an
  already-open PR does not need a force-push.

  Returns:

    * `{:ok, :up_to_date}` — `origin/<target>` was already an ancestor of HEAD;
      nothing to merge.
    * `{:ok, :merged}` — `origin/<target>` merged cleanly into the branch.
    * `{:error, {:conflict, %{files: [path], output: raw}}}` — the merge hit
      textual conflicts; the merge was ABORTED so the worktree is left clean on
      the branch's own HEAD (never half-merged). The caller must NOT review a
      conflicted branch — it should escalate for resolution (mirrors #97).
    * `{:error, reason}` — `origin` is missing, the fetch failed, or git failed
      for another reason. Callers should treat this as fail-open (proceed
      without the update); a merge-base diff still isolates the branch's own
      changes.
  """
  @spec update_from_target(path(), String.t()) ::
          {:ok, :up_to_date | :merged}
          | {:error, {:conflict, %{files: [String.t()], output: String.t()}} | error_reason()}
  def update_from_target(path, target_branch)
      when is_binary(path) and is_binary(target_branch) do
    ref = "origin/" <> target_branch

    with :ok <- ensure_origin_remote(path),
         :ok <- fetch_origin_branch(path, target_branch),
         :ok <- ensure_origin_ref(path, target_branch) do
      merge_target(path, ref)
    end
  end

  # Merge `ref` (origin/<target>) into the current branch. If `ref` is already
  # an ancestor of HEAD there is nothing to do. On a conflicted merge, capture
  # the conflicting paths (while the index still holds them), abort, and report
  # the conflict — never leave the worktree half-merged.
  defp merge_target(path, ref) do
    case run_git(["merge-base", "--is-ancestor", ref, "HEAD"], cd: path) do
      {:ok, _} ->
        {:ok, :up_to_date}

      {:error, _not_ancestor} ->
        case run_git(["merge", "--no-edit", ref], cd: path) do
          {:ok, _} -> {:ok, :merged}
          {:error, {:git_failed, output}} -> abort_merge(path, output)
        end
    end
  end

  defp abort_merge(path, output) do
    conflicts =
      case run_git(["diff", "--name-only", "--diff-filter=U"], cd: path) do
        {:ok, out} -> String.split(out, "\n", trim: true)
        {:error, _} -> []
      end

    _ = run_git(["merge", "--abort"], cd: path)

    if conflicts == [] do
      # A non-conflict merge failure (e.g. local changes would be overwritten);
      # surface as a generic git error so the caller fails open.
      {:error, {:git_failed, output}}
    else
      {:error, {:conflict, %{files: conflicts, output: output}}}
    end
  end

  @doc """
  Fetch the task branch from origin and fast-forward the local checkout if it
  is behind the remote tip.

  Call this BEFORE computing the merge-base or head_sha so the ReviewGate
  always sees the commits the implementer pushed, even when the local worktree
  was somehow left behind (e.g. commits made in a different git context and
  pushed directly to `origin/<branch>` without updating the local ref).

  Returns:

    * `{:ok, :up_to_date}` — local HEAD already matches `origin/<branch>`.
    * `{:ok, :synced}` — local branch fast-forwarded to `origin/<branch>`.
    * `{:error, reason}` — fetch failed, the remote ref does not exist, or the
      local branch has diverged from the remote (not a fast-forward). Callers
      should treat this as fail-open and proceed; the merge-base diff still
      isolates the branch's own changes if origin/<branch> is unreachable.
  """
  @spec sync_from_origin(path(), String.t()) ::
          {:ok, :up_to_date | :synced} | {:error, error_reason()}
  def sync_from_origin(path, branch)
      when is_binary(path) and is_binary(branch) do
    with :ok <- ensure_origin_remote(path),
         :ok <- fetch_origin_branch(path, branch),
         :ok <- ensure_origin_ref(path, branch) do
      ref = "origin/" <> branch

      case run_git(["merge-base", "--is-ancestor", "HEAD", ref], cd: path) do
        {:ok, _} ->
          # HEAD is an ancestor of origin/<branch> — local is at or behind remote.
          # Check if HEAD == remote tip (already up to date) or behind (need ff).
          case run_git(["rev-parse", "HEAD"], cd: path) do
            {:ok, local_sha} ->
              case run_git(["rev-parse", ref], cd: path) do
                {:ok, remote_sha} when local_sha == remote_sha ->
                  {:ok, :up_to_date}

                {:ok, _remote_sha} ->
                  # Local is behind remote — fast-forward.
                  case run_git(["merge", "--ff-only", ref], cd: path) do
                    {:ok, _} -> {:ok, :synced}
                    {:error, _} = err -> err
                  end

                {:error, _} = err ->
                  err
              end

            {:error, _} = err ->
              err
          end

        {:error, _} ->
          # HEAD is NOT an ancestor of origin/<branch> — branches have diverged
          # or origin/<branch> is a different line. Do not force-reset; fail so
          # the caller can proceed without the sync (fail-open at call site).
          {:error,
           {:git_failed,
            "local branch `#{branch}` has diverged from origin/#{branch}; cannot fast-forward"}}
      end
    end
  end

  @doc """
  Return the SHA of the merge-base (fork point) between the worktree's HEAD and
  `target_branch`, preferring the fetched `origin/<target>` ref and falling
  back to the local `<target>` ref.

  The merge-base is the commit the branch was cut from. Diffing
  `<merge_base>..HEAD` shows ONLY the branch's own changes — even when the
  target advanced after the branch was cut, and even after `update_from_target/2`
  merged the target in (the merge-base then equals the target tip). This is the
  diff a reviewer must use to avoid mis-attributing the target's later commits
  to the branch (bd-ased52). Returns `nil` if neither ref resolves or git fails.
  """
  @spec merge_base(path(), String.t()) :: String.t() | nil
  def merge_base(path, target_branch)
      when is_binary(path) and is_binary(target_branch) do
    Enum.find_value(["origin/" <> target_branch, target_branch], fn ref ->
      case run_git(["merge-base", ref, "HEAD"], cd: path) do
        {:ok, out} ->
          case String.trim(out) do
            "" -> nil
            sha -> sha
          end

        {:error, _} ->
          nil
      end
    end)
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

  @doc """
  Seed the worktree's `deps/` and `_build/<env>/lib/` with the fetched and
  pre-compiled dependencies from `source_repo`, so acolytes can run `mix
  test` without a `mix deps.get` network fetch or a full dep recompile.

  ## Why copy, not symlink

  Symlinks into the source repo's `deps`/`_build` are live write-through
  paths: a `mix deps.get`, a `mix.lock` bump, or a dep recompile inside the
  worktree would write straight into the source repo's shared directories —
  corrupting live artifacts (bd-cwov25) or, worse, racing against every other
  worktree concurrently dispatched against the same source repo. Copying
  gives the worktree full ownership of its deps; the source repo is never
  touched again.

  ## Implementation

  Uses `cp -a --reflink=auto` — a correct full copy on ext4, and automatically
  a near-free CoW block-level copy on btrfs/xfs if the host ever migrates.

  ## Excluded dirs

  `arbiter`, `arbiter_web`, `arbiter_cli` are skipped from the `_build` copy —
  they must compile fresh per-branch in the worktree so cross-branch
  contamination is impossible (bd-cwov25). All other compiled deps in
  `_build/<env>/lib/` are copied. `deps/` itself needs no such filter: it
  only ever contains fetched dependencies, never the umbrella apps.

  ## Envs seeded

  Both `test` and `dev` `_build` envs are seeded (acolytes use `test`; some
  dispatched workers compile in `dev`). `deps/` is env-independent and seeded
  once. A missing source dir is silently skipped so this function is safe to
  call on a repo that has never been compiled or had deps fetched.

  Best-effort: failures are swallowed so a seeding issue never blocks
  worktree provisioning.
  """
  @spec seed_compiled_deps(path(), path()) :: :ok
  def seed_compiled_deps(source_repo, worktree_path)
      when is_binary(source_repo) and is_binary(worktree_path) do
    seed_deps_dir(source_repo, worktree_path)

    Enum.each(@seed_envs, fn env ->
      source_lib = Path.join([source_repo, "_build", env, "lib"])
      dest_lib = Path.join([worktree_path, "_build", env, "lib"])

      if File.dir?(source_lib) do
        File.mkdir_p!(dest_lib)

        source_lib
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join([source_repo, "deps", &1])))
        |> Enum.each(fn dep ->
          source_dep = Path.join(source_lib, dep)
          dest_dep = Path.join(dest_lib, dep)

          unless File.exists?(dest_dep) do
            System.cmd("cp", ["-a", "--reflink=auto", source_dep, dest_dep],
              stderr_to_stdout: true
            )
          end
        end)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  # Copy each top-level deps/<dep> dir from source_repo into worktree_path,
  # skipping any that already exist in the destination. Mirrors the _build
  # copy loop above, minus the deps/<name> existence filter (not applicable —
  # deps/ IS the set of fetched dependencies).
  defp seed_deps_dir(source_repo, worktree_path) do
    source_deps = Path.join(source_repo, "deps")
    dest_deps = Path.join(worktree_path, "deps")

    if File.dir?(source_deps) do
      File.mkdir_p!(dest_deps)

      source_deps
      |> File.ls!()
      |> Enum.each(fn dep ->
        source_dep = Path.join(source_deps, dep)
        dest_dep = Path.join(dest_deps, dep)

        unless File.exists?(dest_dep) do
          System.cmd("cp", ["-a", "--reflink=auto", source_dep, dest_dep], stderr_to_stdout: true)
        end
      end)
    end
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
