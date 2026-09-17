defmodule Arbiter.Sessions.RepoCheckout do
  @moduledoc """
  The **read-only** repo checkout a refine session greps for grounding
  (bd-1lszsc, epic bd-cksar2).

  A refine session shapes one Backlog issue into a dispatchable ticket. Doing
  that well needs to *see* the code the issue talks about — which file holds
  the thing, whether the API it assumes still exists, what the surrounding
  conventions are. It does **not** need to build, test or change anything: that
  is the dispatched worker's job, and a refine token cannot dispatch one.

  So the checkout is deliberately the weakest thing that serves reading:

    * A **detached** `git worktree` at the tip of the repo's default branch.
      Detached rather than a named branch, for the same reason
      `Arbiter.Reviews.Checkout` detaches — the source repo usually already has
      that branch checked out (git refuses it twice), and a detached HEAD makes
      it structurally impossible for anything here to advance a branch.
    * Under the **session root** (`Arbiter.Sessions.Layout.repo_checkout_dir/1`),
      so it lives and dies with the session and is swept by the same teardown.
    * With **every write bit stripped**, directories included, so `mix`,
      `git commit`, a stray `Write` tool call and an editor's swap file all
      fail with `EACCES` rather than silently mutating a tree nobody will ever
      look at again.
    * Never the live primary checkout. `Arbiter.Sessions.Layout.outside_primary_checkout?/2`
      is asserted here as well as in `Arbiter.Sessions.Provisioning`, because
      this function takes a caller-supplied *source* repo path and the one
      mistake that matters — handing an agent the tree Phoenix is
      hot-reloading — has to be impossible from every direction.

  ## The branch tip is resolved locally, without a fetch

  `provision/4` resolves `<branch>` then `origin/<branch>` with `rev-parse`; it
  never fetches. A refine session is an interactive thing an operator is
  waiting on, and grounding does not need the newest commit on the forge — it
  needs the shape of the codebase. A network round trip (which can hang, prompt
  for credentials, or fail entirely while offline) buys nothing here and costs
  the operator the launch.

  ## Lifecycle

  `teardown/1` runs from `Arbiter.Sessions.mark_ended/2`, so every way a
  session ends — operator Kill, the agent exiting, the idle reaper, the
  adoption sweep finding a vanished scope — removes the checkout. It restores
  the write bits first: a read-only tree is one neither `git worktree remove`
  nor `File.rm_rf/1` can delete.
  """

  require Logger

  alias Arbiter.Config.Paths
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Session
  alias Arbiter.Worker.Worktree

  @type reason ::
          :no_repo_path
          | :no_branch
          | {:inside_primary_checkout, String.t(), String.t()}
          | {:rev_parse_failed, non_neg_integer(), String.t()}
          | {:worktree_failed, non_neg_integer(), String.t()}
          | {:chmod_failed, String.t(), atom()}

  @type checkout :: %{path: String.t(), head_sha: String.t(), repo_path: String.t()}

  @doc """
  Provision `session`'s read-only checkout of `repo_path` at the tip of
  `branch`. Returns `{:ok, %{path:, head_sha:, repo_path:}}`.

  Every failure is a named `{:error, reason}` — a refine session with no
  checkout is a working session whose instructions say there is none (see
  `Arbiter.Sessions.Instructions`'s refine variant), never a failed launch.

  Options:

    * `:primary_checkout` — override the live source tree the result is
      checked against (defaults to `Arbiter.Config.Paths.primary_checkout/0`).
  """
  @spec provision(Session.t(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, checkout()} | {:error, reason()}
  def provision(session, repo_path, branch, opts \\ [])
  def provision(%Session{}, nil, _branch, _opts), do: {:error, :no_repo_path}
  def provision(%Session{}, "", _branch, _opts), do: {:error, :no_repo_path}
  def provision(%Session{}, _repo_path, nil, _opts), do: {:error, :no_branch}
  def provision(%Session{}, _repo_path, "", _opts), do: {:error, :no_branch}

  def provision(%Session{id: id}, repo_path, branch, opts)
      when is_binary(repo_path) and is_binary(branch) do
    path = Layout.repo_checkout_dir(id)

    with :ok <- outside_primary_checkout(path, opts),
         {:ok, sha} <- branch_tip(repo_path, branch),
         :ok <- worktree_add(repo_path, path, sha),
         :ok <- make_read_only(path) do
      {:ok, %{path: path, head_sha: sha, repo_path: Path.expand(repo_path)}}
    end
  end

  @doc """
  Remove `session`'s checkout, if it has one. Idempotent, best-effort, and
  never fails a session teardown: a git failure or a half-removed directory is
  logged and swallowed.
  """
  @spec teardown(Session.t() | String.t()) :: :ok
  def teardown(%Session{id: id}), do: teardown(id)

  def teardown(id) when is_binary(id) do
    path = Layout.repo_checkout_dir(id)

    if File.exists?(path) do
      # Restore write before removing: `git worktree remove` and `rm -rf` both
      # need write permission on the *directories* they unlink entries from,
      # and `make_read_only/1` took it away from all of them.
      _ = restore_write(path)

      case Worktree.cleanup(path) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Sessions.RepoCheckout: teardown failed for #{path}: #{inspect(reason)}")

          :ok
      end
    else
      :ok
    end
  end

  # ---- internals ----------------------------------------------------------

  defp outside_primary_checkout(path, opts) do
    checkout = Keyword.get(opts, :primary_checkout, Paths.primary_checkout())

    if Layout.outside_primary_checkout?(path, checkout) do
      :ok
    else
      {:error,
       {:inside_primary_checkout, path,
        "refusing to provision a refine checkout at #{path} — it is inside the primary " <>
          "checkout #{checkout}, which is the one tree a session may never be handed"}}
    end
  end

  # The local ref first, `origin/<branch>` second. Neither is fetched: see the
  # moduledoc on why an interactive launch does not pay for a network round
  # trip it does not need.
  defp branch_tip(repo_path, branch) do
    case rev_parse(repo_path, "refs/heads/#{branch}^{commit}") do
      {:ok, sha} -> {:ok, sha}
      {:error, local_error} -> origin_tip(repo_path, branch, local_error)
    end
  end

  defp origin_tip(repo_path, branch, local_error) do
    case rev_parse(repo_path, "refs/remotes/origin/#{branch}^{commit}") do
      {:ok, sha} -> {:ok, sha}
      {:error, _} -> {:error, local_error}
    end
  end

  defp rev_parse(repo_path, ref) do
    case System.cmd("git", ["-C", repo_path, "rev-parse", ref], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:rev_parse_failed, code, String.trim(output)}}
    end
  rescue
    # `repo_path` comes from workspace config and may not exist at all, which
    # makes `System.cmd/3` raise rather than return a status.
    e in ErlangError -> {:error, {:rev_parse_failed, 1, Exception.message(e)}}
  end

  defp worktree_add(repo_path, path, sha) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case System.cmd("git", ["-C", repo_path, "worktree", "add", "--detach", path, sha],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, code} -> {:error, {:worktree_failed, code, String.trim(output)}}
      end
    end
  end

  # Strip write from everything, deepest entries first so a directory is still
  # writable while its own children are being changed. Files and directories
  # both: a writable directory is enough to create, rename and delete entries
  # inside it, which is most of what "the session must not write here" means.
  defp make_read_only(path) do
    path
    |> walk()
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case chmod_mask(entry, 0o555) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:chmod_failed, entry, reason}}}
      end
    end)
  end

  # The inverse, for teardown. Best-effort: anything that resists chmod is
  # reported by the removal that follows, not here.
  defp restore_write(path) do
    path
    |> walk()
    |> Enum.reverse()
    |> Enum.each(&chmod_or(&1, 0o200))
  end

  defp chmod_mask(entry, mask) do
    case File.lstat(entry) do
      {:ok, %File.Stat{type: :symlink}} -> :ok
      {:ok, %File.Stat{mode: mode}} -> File.chmod(entry, Bitwise.band(mode, mask))
      {:error, reason} -> {:error, reason}
    end
  end

  defp chmod_or(entry, add) do
    case File.lstat(entry) do
      {:ok, %File.Stat{type: :symlink}} -> :ok
      {:ok, %File.Stat{mode: mode}} -> File.chmod(entry, Bitwise.bor(mode, add))
      {:error, _} -> :ok
    end
  end

  # Depth-first, children before their parent, so the caller can chmod in list
  # order to lock down and in reverse order to open back up. Symlinks are
  # listed but never followed — `File.dir?/1` follows them, `File.lstat/1`
  # does not, and a symlink out of the tree is not this tree's to walk.
  defp walk(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        children =
          case File.ls(path) do
            {:ok, entries} -> Enum.flat_map(entries, &walk(Path.join(path, &1)))
            {:error, _} -> []
          end

        children ++ [path]

      {:ok, _stat} ->
        [path]

      {:error, _} ->
        []
    end
  end
end
