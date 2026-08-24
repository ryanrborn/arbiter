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
          | :no_branch
          | {:fetch_failed, non_neg_integer(), String.t()}
          | {:rev_parse_failed, non_neg_integer(), String.t()}
          | {:worktree_failed, non_neg_integer(), String.t()}

  @default_prefix "ext-review"

  @typedoc """
  What `provision_branch/3` hands back, plus the caller-supplied context that
  travels with it (`Arbiter.Worker.Dispatch` adds `:branch` / `:base_branch`
  so the review prompt can name what is checked out and what to diff against).
  """
  @type branch_checkout :: %{
          required(:path) => String.t(),
          required(:head_sha) => String.t(),
          optional(:branch) => String.t(),
          optional(:base_branch) => String.t() | nil
        }

  @doc """
  Fetch `head_sha` from `repo_path`'s `origin` remote and check it out,
  detached, into a fresh throwaway worktree. Returns `{:ok, path}` on
  success.

  Best-effort by design: any git failure (unreachable SHA, no `origin`
  remote, `repo_path` not a git repo) returns `{:error, reason}` rather than
  raising, so the caller can fall back to the Tier-1 diff-only path.

  Options:

    * `:prefix` — names the throwaway worktree leaf (default `"ext-review"`).
      Lets a second caller (the internal reviewer, bd-199giy) leave a
      distinguishable breadcrumb under the worktree root.
  """
  @spec provision(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, reason()}
  def provision(repo_path, head_sha, opts \\ [])
  def provision(nil, _head_sha, _opts), do: {:error, :no_repo_path}
  def provision("", _head_sha, _opts), do: {:error, :no_repo_path}
  def provision(_repo_path, nil, _opts), do: {:error, :no_head_sha}
  def provision(_repo_path, "", _opts), do: {:error, :no_head_sha}

  def provision(repo_path, head_sha, opts)
      when is_binary(repo_path) and is_binary(head_sha) do
    with :ok <- fetch_ref(repo_path, head_sha) do
      add_detached(repo_path, head_sha, opts)
    end
  end

  @doc """
  Branch-flavored `provision/3`: fetch `branch` from `repo_path`'s `origin`
  remote, resolve the fetched tip, and check *that commit* out detached into a
  fresh throwaway worktree. Returns `{:ok, %{path: path, head_sha: sha}}`.

  This is the shape the **internal** reviewer needs (bd-199giy). A dispatched
  worker's work lives on a named per-task branch, not on a forge PR ref, and
  the coordinator's shared checkout may be many commits behind it — so the
  branch name is the only handle the reviewer has, and its current *origin*
  tip (not the local remote-tracking ref, which may be stale) is the commit to
  review.

  Detached rather than `git worktree add <branch>`: the implementer's own
  worktree usually already has that branch checked out, and git refuses to
  check the same branch out twice. Detaching also makes it structurally
  impossible for the reviewer to advance the branch.

  `origin` is consulted first and wins: the shared checkout's own copy of the
  branch may be many commits stale, and the remote is what the merge queue and
  the PR will be judged against. A branch `origin` has never seen falls back to
  the local ref — the Direct (local-merge) strategy's shape, where a task
  branch is never pushed at all and the local ref *is* the truth.

  Best-effort with the same contract as `provision/3`: every failure (no
  `origin` and no local ref, `repo_path` not a git repo) returns
  `{:error, reason}` so the caller can fall back to the diff-only path.
  """
  @spec provision_branch(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, %{path: String.t(), head_sha: String.t()}} | {:error, reason()}
  def provision_branch(repo_path, branch, opts \\ [])
  def provision_branch(nil, _branch, _opts), do: {:error, :no_repo_path}
  def provision_branch("", _branch, _opts), do: {:error, :no_repo_path}
  def provision_branch(_repo_path, nil, _opts), do: {:error, :no_branch}
  def provision_branch(_repo_path, "", _opts), do: {:error, :no_branch}

  def provision_branch(repo_path, branch, opts)
      when is_binary(repo_path) and is_binary(branch) do
    with {:ok, sha} <- branch_head_sha(repo_path, branch),
         {:ok, path} <- add_detached(repo_path, sha, opts) do
      {:ok, %{path: path, head_sha: sha}}
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

  defp add_detached(repo_path, head_sha, opts) do
    path = worktree_path(head_sha, Keyword.get(opts, :prefix, @default_prefix))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- worktree_add(repo_path, path, head_sha) do
      {:ok, path}
    end
  end

  defp worktree_path(head_sha, prefix) do
    root = Application.get_env(:arbiter, :worktree_root, "/home/rborn/dev/arbiter-worktrees")
    leaf = "#{prefix}-#{String.slice(head_sha, 0, 12)}-#{System.unique_integer([:positive])}"
    Path.join(root, leaf)
  end

  # `--no-tags` and a single named ref (a SHA or a branch name) keep the fetch
  # minimal — we only need this one commit, not the whole ref namespace. Either
  # way the fetched tip lands in `FETCH_HEAD`.
  defp fetch_ref(repo_path, ref) do
    case System.cmd("git", ["-C", repo_path, "fetch", "--no-tags", "origin", ref],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:fetch_failed, code, String.trim(output)}}
    end
  end

  # origin first, local ref second. The fetch error is what surfaces when both
  # fail — it names the remote lookup, which is the one the caller cares about
  # (a branch nobody has pushed and nobody has locally is simply not there).
  defp branch_head_sha(repo_path, branch) do
    case fetch_ref(repo_path, branch) do
      :ok ->
        rev_parse(repo_path, "FETCH_HEAD")

      {:error, fetch_error} ->
        case rev_parse(repo_path, "refs/heads/#{branch}^{commit}") do
          {:ok, sha} -> {:ok, sha}
          {:error, _} -> {:error, fetch_error}
        end
    end
  end

  defp rev_parse(repo_path, ref) do
    case System.cmd("git", ["-C", repo_path, "rev-parse", ref], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:rev_parse_failed, code, String.trim(output)}}
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
