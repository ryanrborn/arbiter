defmodule Arbiter.Mergers.Direct do
  @moduledoc """
  The direct merger. Executes a local `git merge --no-ff` immediately — no
  merge request, no review gate. This is the current default strategy and the
  "personal project" path: the branch is integrated into the target the moment
  `open/4` is called.

  ## Required opt: `:repo_path`

  Unlike a hosted forge, `Direct` operates on a local checkout, so `open/4`
  needs to know which repository (the rig path) to run inside. Pass it via the
  `opts` map:

      Direct.open("feature/bd-1qx1nt", "Merge bd-1qx1nt", "", %{
        repo_path: "/path/to/rig",
        target_branch: "main"
      })

  `:target_branch` defaults to `"main"` when omitted.

  ## Callback semantics

    * `open/4` — checks out `target_branch` and runs `git merge --no-ff
      <branch>` in `repo_path`. Returns `{:ok, "direct:" <> branch}`. The
      merge commit message is `title` when given, otherwise git's default.
    * `get/1` — always `{:ok, %{status: :merged}}`; once `open/4` succeeds the
      branch is already integrated, so there is no other state to report.
    * `merge/1`, `close/1`, `add_comment/2`, `request_review/2` — no-ops
      returning `:ok` (there is no MR to act on).
    * `link_for/1` — returns an empty string (no web UI).

  ## Conflict handling — never leave the canonical tree broken

  `open/4` operates on the *canonical* checkout (the rig), and the live Phoenix
  server compiles from that same working tree. A conflicted `git merge` would
  otherwise leave the tree half-merged and conflict-markered — uncompilable —
  and the running server can no longer hot-reload (incident bd-1rhyla: a
  conflicted auto-merge wedged the beam and took the fleet down).

  So a failed merge is made *atomic*: `open/4` captures the conflicting paths,
  then runs `git merge --abort` to restore the clean, compilable tree before
  returning. A genuine conflict returns

      {:error, {:merge_conflict, %{branch: branch, files: [path, ...], output: raw_git_output}}}

  so the caller (the polecat lifecycle) can escalate to the Admiral inbox with
  the conflicting files and park the bead for rebase — without ever marking it
  merged. Any other (non-conflict) git failure still returns
  `{:error, {:git_failed, output}}`, and the abort runs defensively regardless
  (a no-op when no merge is in progress).
  """

  @behaviour Arbiter.Mergers.Merger

  @impl true
  def open(branch, title, _description, opts)
      when is_binary(branch) and is_map(opts) do
    case Map.get(opts, :repo_path) do
      path when is_binary(path) ->
        target = Map.get(opts, :target_branch) || "main"

        with {:ok, _} <- run_git(["checkout", target], path) do
          case run_git(["merge", "--no-ff"] ++ message_args(title) ++ [branch], path) do
            {:ok, _} -> {:ok, "direct:" <> branch}
            {:error, {:git_failed, output}} -> abort_failed_merge(path, branch, output)
          end
        end

      _ ->
        {:error, :no_repo_path}
    end
  end

  @impl true
  def get(_mr_ref), do: {:ok, %{status: :merged}}

  @impl true
  def merge(_mr_ref), do: :ok

  @impl true
  def close(_mr_ref), do: :ok

  @impl true
  def add_comment(_mr_ref, _body), do: :ok

  @impl true
  def request_review(_mr_ref, _reviewers), do: :ok

  @impl true
  def link_for(_mr_ref), do: ""

  # ---- helpers ----

  # A merge failed. Capture the conflicting paths (while the index still holds
  # them), then `git merge --abort` to restore a clean, compilable tree — the
  # canonical checkout the live server compiles from must never be left
  # half-merged. The abort is best-effort and a no-op when no merge is in
  # progress (e.g. the branch didn't exist), so it's safe to always run.
  defp abort_failed_merge(path, branch, output) do
    conflicts = conflicting_files(path)
    _ = run_git(["merge", "--abort"], path)

    if conflicts == [] do
      {:error, {:git_failed, output}}
    else
      {:error, {:merge_conflict, %{branch: branch, files: conflicts, output: output}}}
    end
  end

  # Unmerged paths (those with conflict markers), per git's diff filter. Must be
  # read BEFORE `git merge --abort`, which clears the conflicted index.
  defp conflicting_files(path) do
    case run_git(["diff", "--name-only", "--diff-filter=U"], path) do
      {:ok, output} -> output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      {:error, _} -> []
    end
  end

  defp message_args(title) when is_binary(title) and title != "", do: ["-m", title]
  defp message_args(_), do: ["--no-edit"]

  defp run_git(args, cd) do
    case System.cmd("git", args, stderr_to_stdout: true, cd: cd) do
      {output, 0} -> {:ok, output}
      {output, _nonzero} -> {:error, {:git_failed, String.trim(output)}}
    end
  rescue
    e in ErlangError ->
      # `System.cmd` raises if git isn't on PATH.
      {:error, {:git_failed, Exception.message(e)}}
  end
end
