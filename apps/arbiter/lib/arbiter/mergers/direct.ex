defmodule Arbiter.Mergers.Direct do
  @moduledoc """
  The direct merger. Executes a local `git merge --no-ff` immediately — no
  merge request, no review gate. This is the current default strategy and the
  "personal project" path: the branch is integrated into the target the moment
  `open/4` is called.

  ## Required opt: `:repo_path`

  Unlike a hosted forge, `Direct` operates on a local checkout, so `open/4`
  needs to know which repository (the repo path) to run inside. Pass it via the
  `opts` map:

      Direct.open("feature/bd-1qx1nt", "Merge bd-1qx1nt", "", %{
        repo_path: "/path/to/repo",
        target_branch: "main"
      })

  `:target_branch` defaults to `"main"` when omitted.

  ## mr_ref format

  The opaque `mr_ref` produced by `open/4` encodes the branch, repo path, and
  target branch as a `"|"`-delimited string so that callbacks that receive only
  the ref can perform local git operations without additional opts:

      "direct:<branch>|<repo_path>|<target_branch>"

  Callers must treat the format as opaque. `branch_from_ref/1` decodes the
  branch name when needed.

  ## Callback semantics

    * `open/4` — checks out `target_branch` and runs `git merge --no-ff
      <branch>` in `repo_path`. Returns `{:ok, ref}` where `ref` encodes the
      branch, repo path, and target branch. The merge commit message is `title`
      when given, otherwise git's default.
    * `update_branch/1` — rebases the working branch forward onto its base
      (`git checkout <branch>` then `git rebase <target_branch>` inside
      `repo_path`). Returns `:ok` on success or
      `{:error, {:rebase_conflict, %{branch:, base:, files:, output:}}}` on a
      conflict (the rebase is aborted so the tree stays clean). Returns
      `{:error, :no_repo_path}` when the ref doesn't carry a repo path (e.g.
      an old-format or hand-constructed ref).
    * `get/1` — always `{:ok, %{status: :merged}}`; once `open/4` succeeds the
      branch is already integrated, so there is no other state to report.
    * `merge/1`, `close/1`, `add_comment/2`, `request_review/2` — no-ops
      returning `:ok` (there is no MR to act on).
    * `link_for/1` — returns an empty string (no web UI).

  ## Optional callbacks not implemented

  `reply_to_review_comment/4` — `Direct` has no remote forge and no concept
  of threaded review comments, so this optional callback is not exported.
  Callers guard with `function_exported?/3` before calling it.

  `list_open_review_threads/1` and `list_open/0` are also not implemented for
  the same reason: there is no MR or forge thread surface.

  ## Review callbacks

  `Direct` has no MR to comment on and no forge UI to host a review. For
  the `Arbiter.Workflows.CodeReview` adapter path it implements:

    * `get_diff/2` — runs `git diff <base>..<branch>` in `opts[:repo_path]`,
      where `<branch>` is decoded from the `mr_ref` (the canonical
      `"direct:<branch>"` form, or a bare branch name as a fallback).
      `:target_branch` in opts overrides the base; default is `"main"`.
    * `post_inline_comment/3` — appends a per-finding section to a local
      Markdown review file under `opts[:repo_path]/reviews/<branch>.md`,
      mirroring the `LocalMode` format the `:local` workflow path uses.
    * `submit_review/4` — rewrites the verdict line in the same review file.

  This keeps "direct" reviews reproducible artifacts — the review is a
  file in the repo, with the same shape `:local` mode produces — while
  letting the workflow stay adapter-shaped.

  ## Conflict handling — never leave the canonical tree broken

  `open/4` operates on the *canonical* checkout (the repo), and the live Phoenix
  server compiles from that same working tree. A conflicted `git merge` would
  otherwise leave the tree half-merged and conflict-markered — uncompilable —
  and the running server can no longer hot-reload (incident bd-1rhyla: a
  conflicted auto-merge wedged the beam and took the fleet down).

  So a failed merge is made *atomic*: `open/4` captures the conflicting paths,
  then runs `git merge --abort` to restore the clean, compilable tree before
  returning. A genuine conflict returns

      {:error, {:merge_conflict, %{branch: branch, files: [path, ...], output: raw_git_output}}}

  so the caller (the worker lifecycle) can escalate to the Admiral inbox with
  the conflicting files and park the task for rebase — without ever marking it
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
            {:ok, _} ->
              with {:ok, _} <- run_git(["push", "origin", target], path) do
                {:ok, encode_ref(branch, path, target)}
              end

            {:error, {:git_failed, output}} ->
              abort_failed_merge(path, branch, output)
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

  # No forge, no PR-side review surface — there is never human review feedback
  # to ingest, so the MergeQueue's auto-revise path is a no-op here (bd-95lsjb).
  @impl true
  def list_review_feedback(_mr_ref),
    do: {:ok, %{changes_requested: false, latest_review_id: nil, feedback: []}}

  # Rebase the working branch forward onto its base. A Direct repo is a real
  # local git repo; keeping the branch current with main is meaningful.
  # The repo path and target branch are decoded from the mr_ref (they are
  # encoded there by open/4). Returns {:error, :no_repo_path} for hand-crafted
  # or old-format refs that don't carry the path.
  @impl true
  def update_branch(mr_ref) when is_binary(mr_ref) do
    case ref_params(mr_ref) do
      {branch, repo_path, target} when is_binary(repo_path) ->
        target_branch = target || "main"

        with {:ok, _} <- run_git(["checkout", branch], repo_path) do
          case run_git(["rebase", target_branch], repo_path) do
            {:ok, _} ->
              :ok

            {:error, {:git_failed, output}} ->
              abort_failed_rebase(repo_path, branch, target_branch, output)
          end
        end

      {_branch, nil, _} ->
        {:error, :no_repo_path}
    end
  end

  # ---- Review callbacks ----

  @impl true
  def get_diff(mr_ref, opts) when is_binary(mr_ref) and is_map(opts) do
    case Map.get(opts, :repo_path) do
      path when is_binary(path) ->
        branch = branch_from_ref(mr_ref)
        base = Map.get(opts, :target_branch) || "main"

        case run_git(["diff", "#{base}..#{branch}"], path) do
          {:ok, output} -> {:ok, output}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :no_repo_path}
    end
  end

  @impl true
  def post_inline_comment(mr_ref, finding, opts)
      when is_binary(mr_ref) and is_map(finding) and is_map(opts) do
    case Map.get(opts, :repo_path) do
      path when is_binary(path) ->
        branch = branch_from_ref(mr_ref)
        file_path = review_file_path(path, branch)
        File.mkdir_p!(Path.dirname(file_path))
        ensure_header(file_path, branch, Map.get(opts, :task))
        File.write!(file_path, render_finding(finding), [:append])
        {:ok, %{path: file_path}}

      _ ->
        {:error, :no_repo_path}
    end
  end

  @impl true
  def submit_review(mr_ref, verdict, body, opts)
      when is_binary(mr_ref) and verdict in [:approve, :request_changes] and is_map(opts) do
    case Map.get(opts, :repo_path) do
      path when is_binary(path) ->
        branch = branch_from_ref(mr_ref)
        file_path = review_file_path(path, branch)
        File.mkdir_p!(Path.dirname(file_path))
        ensure_header(file_path, branch, Map.get(opts, :task))
        rewrite_verdict(file_path, verdict, body)
        {:ok, %{path: file_path, verdict: verdict}}

      _ ->
        {:error, :no_repo_path}
    end
  end

  # ---- helpers ----

  # Encode the three fields the adapter needs for local git operations into the
  # opaque mr_ref. Uses "|" as a delimiter ("|" is not a valid git refname
  # character and does not appear in well-formed Unix paths on this platform).
  defp encode_ref(branch, repo_path, target_branch),
    do: "direct:#{branch}|#{repo_path}|#{target_branch}"

  # Decode all three fields from a ref produced by encode_ref/3.
  # Gracefully handles the old single-field format ("direct:<branch>") and bare
  # branch names (no "direct:" prefix) that callers may pass in tests.
  defp ref_params("direct:" <> rest) do
    case String.split(rest, "|", parts: 3) do
      [branch, repo_path, target] -> {branch, repo_path, target}
      [branch] -> {branch, nil, nil}
      _ -> {rest, nil, nil}
    end
  end

  defp ref_params(other), do: {other, nil, nil}

  defp branch_from_ref(ref) do
    {branch, _repo, _target} = ref_params(ref)
    branch
  end

  defp review_file_path(repo_path, branch) do
    leaf = String.replace(branch, "/", "-") <> ".md"
    Path.join([repo_path, "reviews", leaf])
  end

  defp ensure_header(file_path, branch, task) do
    unless File.exists?(file_path) do
      File.write!(file_path, render_header(branch, task))
    end
  end

  defp render_header(branch, task) do
    task_line =
      case task do
        %{id: id, title: title} -> "**Task:** #{id} — #{title}"
        %{"id" => id, "title" => title} -> "**Task:** #{id} — #{title}"
        _ -> "**Task:** (none)"
      end

    """
    # Code review: #{branch}

    #{task_line}
    **Mode:** direct
    **Verdict (pending):** _to be set in submit_review_

    ## Findings

    """
  end

  defp render_finding(%{severity: sev, file: file, line: line, message: msg}) do
    """
    ### #{file}:#{line} — #{Atom.to_string(sev)}
    #{msg}

    """
  end

  defp rewrite_verdict(file_path, verdict, body) do
    contents = File.read!(file_path)
    label = verdict_label(verdict)

    rewritten =
      String.replace(
        contents,
        ~r/^\*\*Verdict.*$/m,
        "**Verdict:** #{label}",
        global: false
      )

    final =
      if is_binary(body) and body != "" do
        rewritten <> "\n## Summary\n\n#{body}\n"
      else
        rewritten
      end

    File.write!(file_path, final)
  end

  defp verdict_label(:approve), do: "APPROVE"
  defp verdict_label(:request_changes), do: "REQUEST_CHANGES"

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

  # A rebase failed. Capture conflicting paths then abort so the tree stays
  # clean. Same safety invariant as abort_failed_merge/3 — the canonical
  # checkout must never be left in a partially-applied state.
  defp abort_failed_rebase(path, branch, base, output) do
    conflicts = conflicting_files(path)
    _ = run_git(["rebase", "--abort"], path)

    if conflicts == [] do
      {:error, {:git_failed, output}}
    else
      {:error,
       {:rebase_conflict, %{branch: branch, base: base, files: conflicts, output: output}}}
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
