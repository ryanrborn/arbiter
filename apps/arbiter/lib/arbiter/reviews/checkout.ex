defmodule Arbiter.Reviews.Checkout do
  @moduledoc """
  Provision a throwaway git worktree at a PR's head commit for agentic
  external review (Tier 2, bd-6onexk).

  `Arbiter.Reviews.ExternalReview` previously ran entirely against the forge:
  the diff came from the merge adapter, and any cross-file context came from
  `ConsumerTrace` grepping whatever the *shared* repo checkout happened to be
  on — not the PR's actual head (bd-5xsp25's documented limitation). This
  module gives the reviewer a real, disposable checkout at the PR's head
  commit, so it (and `ConsumerTrace`) can see the repo as the PR actually
  left it.

  ## Why not `Arbiter.Worker.Worktree.create/3` / `attach/2`

  Both of those name a **branch** — `create/3` mints a new one from a base,
  `attach/2` checks out an existing one. An external PR's head commit is not
  guaranteed to be resolvable as a local branch name (forge PR refs like
  `refs/pull/N/head` aren't fetched by default, and a bare PR number carries
  no branch name at all) — the one thing every merge adapter *can* hand back
  is the head SHA (`adapter.get/1`). So this fetches and checks out that SHA
  directly, in a detached worktree, rather than reusing the branch-oriented
  helpers.

  ## Lifecycle

  Always throwaway: nothing is meant to write into this checkout (the
  reviewer gets read-only tool access — see `Arbiter.Workflows.CodeReview.Checks`),
  so `teardown/1` always force-removes it rather than checking for dirty state.
  """

  require Logger

  alias Arbiter.Worker.Worktree

  @type reason ::
          :no_repo_path
          | :no_head_sha
          | {:fetch_failed, non_neg_integer(), String.t()}
          | {:worktree_failed, non_neg_integer(), String.t()}

  @doc """
  Fetch `head_sha` from `repo_path`'s `origin` remote and check it out,
  detached, into a fresh throwaway worktree. Returns `{:ok, path}` on
  success.

  Best-effort by design: any git failure (unreachable SHA, no `origin`
  remote, `repo_path` not a git repo) returns `{:error, reason}` rather than
  raising, so the caller can fall back to the Tier-1 diff-only path.
  """
  @spec provision(String.t() | nil, String.t() | nil) :: {:ok, String.t()} | {:error, reason()}
  def provision(nil, _head_sha), do: {:error, :no_repo_path}
  def provision("", _head_sha), do: {:error, :no_repo_path}
  def provision(_repo_path, nil), do: {:error, :no_head_sha}
  def provision(_repo_path, ""), do: {:error, :no_head_sha}

  def provision(repo_path, head_sha) when is_binary(repo_path) and is_binary(head_sha) do
    path = worktree_path(head_sha)

    with :ok <- fetch_sha(repo_path, head_sha),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- worktree_add(repo_path, path, head_sha) do
      {:ok, path}
    end
  end

  @doc """
  Remove a worktree provisioned by `provision/2`. Idempotent and best-effort:
  a missing/never-provisioned path, or a git failure, still returns `:ok` —
  teardown never fails the review that called it. `nil` is a no-op (the
  common case when no checkout was provisioned in the first place).
  """
  @spec teardown(String.t() | nil) :: :ok
  def teardown(nil), do: :ok

  def teardown(path) when is_binary(path) do
    case Worktree.cleanup(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Reviews.Checkout: teardown failed for #{path}: #{inspect(reason)}")
        :ok
    end
  end

  # ---- internals -------------------------------------------------------

  defp worktree_path(head_sha) do
    root = Application.get_env(:arbiter, :worktree_root, "/home/rborn/dev/arbiter-worktrees")
    leaf = "ext-review-#{String.slice(head_sha, 0, 12)}-#{System.unique_integer([:positive])}"
    Path.join(root, leaf)
  end

  # `--no-tags` and a single named SHA keep the fetch minimal — we only need
  # this one commit, not the whole ref namespace.
  defp fetch_sha(repo_path, head_sha) do
    case System.cmd("git", ["-C", repo_path, "fetch", "--no-tags", "origin", head_sha],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:fetch_failed, code, String.trim(output)}}
    end
  end

  defp worktree_add(repo_path, path, head_sha) do
    case System.cmd("git", ["-C", repo_path, "worktree", "add", "--detach", path, head_sha],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:worktree_failed, code, String.trim(output)}}
    end
  end
end
