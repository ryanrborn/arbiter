defmodule Arbiter.Worker.PrimarySync do
  @moduledoc """
  Safe fast-forward of a repo's *primary* local checkout (the shared
  directory registered in a workspace's `repo_paths`/`rig_paths` config —
  not a worker's isolated worktree) to the current `origin/<base_branch>`.

  `Arbiter.Worker.Worktree.fetch_origin/2` already refreshes the
  `origin/<base>` remote-tracking ref in a primary checkout before
  dispatching work into it, but that's refs-only — it never touches the
  checkout's own local branch, HEAD, index, or working tree. So a human's
  `git log`/`git status` on that checkout keeps drifting further behind
  `origin/<base>` with every merge (bd-bqqnin).

  `fast_forward/2` closes that gap, but only when it can do so with zero
  risk to a human's in-progress work — mirroring `git pull --ff-only`:

    * the checkout must currently be *on* `base_branch`
    * the working tree must have no uncommitted changes (staged, unstaged,
      or untracked)
    * the local branch must be a strict ancestor of the new
      `origin/<base_branch>` (a true fast-forward, never a merge/rebase)

  Any other situation — dirty tree, different branch, diverged history —
  is skipped, not errored: this is a best-effort convenience, never a gate
  that should fail a merge or clobber a human's checkout.
  """

  alias Arbiter.Worker.Worktree

  @type path :: String.t()
  @type skip_reason ::
          :uncommitted_changes
          | :not_on_default_branch
          | :not_fast_forwardable

  @doc """
  Fast-forward `repo_path`'s local `base_branch` to `origin/base_branch`,
  iff that can be done as a safe, zero-risk fast-forward.

  Returns:

    * `:ok` — already up to date, or successfully fast-forwarded
    * `{:skipped, reason}` — left untouched; see `t:skip_reason/0`
    * `{:error, reason}` — a git operation itself failed (missing repo,
      missing `origin` remote, fetch failure, …)
  """
  @spec fast_forward(path(), String.t()) ::
          :ok | {:skipped, skip_reason()} | {:error, Worktree.error_reason()}
  def fast_forward(repo_path, base_branch)
      when is_binary(repo_path) and is_binary(base_branch) do
    with :ok <- Worktree.fetch_origin(repo_path, base_branch),
         {:ok, current} <- Worktree.current_branch(repo_path) do
      cond do
        current != base_branch ->
          {:skipped, :not_on_default_branch}

        true ->
          with_clean_tree(repo_path, base_branch)
      end
    end
  end

  defp with_clean_tree(repo_path, base_branch) do
    case Worktree.has_uncommitted?(repo_path) do
      {:ok, true} -> {:skipped, :uncommitted_changes}
      {:ok, false} -> merge_ff_only(repo_path, base_branch)
      {:error, _} = err -> err
    end
  end

  defp merge_ff_only(repo_path, base_branch) do
    case run_git(["merge", "--ff-only", "origin/" <> base_branch], cd: repo_path) do
      {:ok, _output} ->
        :ok

      {:error, {:git_failed, _msg}} ->
        # `--ff-only` refuses for any non-fast-forward reason (diverged
        # history, or local ahead of origin) — the only cases left once
        # we're already on a clean `base_branch` checkout.
        {:skipped, :not_fast_forwardable}
    end
  end

  # `Worktree`'s own git-runner is private, so mirror it here rather than
  # exporting an internal helper across module boundaries.
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
    e in ErlangError -> {:error, {:git_failed, Exception.message(e)}}
  end
end
