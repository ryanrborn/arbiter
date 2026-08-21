defmodule Arbiter.Loop.Apply.RepoDoc do
  @moduledoc """
  The `:repo_doc_patch` **side effect**: rung 2 of the destination ladder
  (Amendment D). A repo-scoped lesson lands as a patch to that repo's
  `CLAUDE.md`, applied through the normal PR path — not a direct table write,
  since the target is a file humans also edit.

      Worktree.create/3       an isolated branch to commit into
      RepoDocPatch.upsert/4   owns the delimited managed section, so a human
                              edit and an Arbiter edit never clobber each other
      Mergers.for_workspace/1 opens the PR the way any other change would be

  Split out of `Arbiter.Loop` (bd-3b7svv): this was the largest single slice of
  the apply path, and its pure decisions — which repo, which path, which cap,
  what the commit and PR say — are worth pinning without provisioning a git
  repo per assertion.
  """

  alias Arbiter.Loop.{PendingWrite, RepoDocPatch}
  alias Arbiter.Mergers
  alias Arbiter.Tasks.{RepoConfig, Workspace}
  alias Arbiter.Worker.Worktree

  # bd-1cusio: this write path is scoped to a repo's CLAUDE.md, not arbitrary
  # files — any payload-supplied override is ignored so no proposal can steer
  # `File.write/2` outside the file this feature exists to patch.
  @doc_path "CLAUDE.md"
  @default_cap_bytes 4_000

  @doc """
  Run the `:repo_doc_patch` side effect against an already-resolved workspace:
  find the repo's checkout, provision a worktree, patch the managed section,
  commit, and open the merge request. Returns `:ok` or an operator-facing
  error tuple.

  The caller (`Arbiter.Loop.Apply`) owns reading the payload and loading the
  workspace, so nothing here touches Ash.
  """
  @spec run(PendingWrite.t(), Workspace.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, {atom(), String.t()}}
  def run(%PendingWrite{} = row, %Workspace{} = ws, repo, lesson, attribution) do
    with {:ok, {repo_path, target_branch}} <- resolve_target(ws, repo) do
      in_worktree(ws, repo, repo_path, target_branch, row, lesson, attribution)
    end
  end

  @doc "The repo this proposal patches, or the gap that stops it."
  @spec repo(PendingWrite.t()) :: {:ok, String.t()} | {:error, {:unmapped, String.t()}}
  def repo(%PendingWrite{repo: repo}) when is_binary(repo) and repo != "", do: {:ok, repo}

  def repo(_row) do
    {:error,
     {:unmapped,
      "this proposal names no repo: CLAUDE.md needs a repo-scoped finding to know which " <>
        "repo's file to patch — attribute the finding to a repo before proposing it"}}
  end

  @doc """
  Map `repo` onto `{local_path, target_branch}` using the workspace's
  `repo_paths`. An unregistered repo is a gap the operator must close in
  config, not a failure to retry.
  """
  @spec resolve_target(Workspace.t(), String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, {:unmapped, String.t()}}
  def resolve_target(%Workspace{config: config}, repo) do
    paths = Map.get(config || %{}, "repo_paths") || %{}

    case RepoConfig.find_entry(paths, repo) do
      nil ->
        {:error,
         {:unmapped, "repo #{inspect(repo)} is not registered in this workspace's repo_paths"}}

      entry ->
        case RepoConfig.repo_path_from_config(entry) do
          nil ->
            {:error, {:unmapped, "repo #{inspect(repo)}'s repo_paths entry has no path"}}

          path ->
            {:ok, {path, RepoConfig.repo_target_from_config(entry) || "main"}}
        end
    end
  end

  @doc """
  The repo-relative file this path patches. Always `CLAUDE.md` — see
  bd-1cusio: the payload is untrusted and cannot redirect the write.
  """
  @spec doc_path(map()) :: String.t()
  def doc_path(_payload), do: @doc_path

  @doc "The managed section's byte cap: a positive integer override, else 4_000."
  @spec cap_bytes(map()) :: pos_integer()
  def cap_bytes(payload) do
    case Map.get(payload, "cap_bytes") do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_cap_bytes
    end
  end

  @doc "Commit subject/body for the patch, naming anything the cap evicted."
  @spec commit_message(PendingWrite.t(), [String.t()], String.t()) :: String.t()
  def commit_message(row, [], attribution),
    do: "#{row.gist}\n\nApplied-by: #{attribution}"

  def commit_message(row, removed, attribution) do
    "#{row.gist}\n\n" <>
      "Evicted (over the CLAUDE.md size cap): #{Enum.join(removed, ", ")}\n\n" <>
      "Applied-by: #{attribution}"
  end

  @doc "Merge-request body for the patch, quoting the lesson and any evictions."
  @spec pr_description(PendingWrite.t(), String.t(), [String.t()]) :: String.t()
  def pr_description(row, lesson, removed) do
    base =
      "Repo-scoped lesson from the loop pass (bd-9j2g3x), applied as proposal `#{row.id}`.\n\n#{lesson}"

    case removed do
      [] ->
        base

      _ ->
        base <>
          "\n\n**Evicted to stay under the CLAUDE.md size cap:** #{Enum.join(removed, ", ")}"
    end
  end

  # ---- worktree-scoped work ------------------------------------------------

  defp in_worktree(ws, repo, repo_path, target_branch, row, lesson, attribution) do
    branch = "loop/repo-doc-patch-#{row.id}"

    case Worktree.create(repo_path, branch, target_branch) do
      {:ok, worktree_path} ->
        result =
          write_and_open(
            ws,
            repo,
            repo_path,
            target_branch,
            worktree_path,
            branch,
            row,
            lesson,
            attribution
          )

        _ = Worktree.cleanup(worktree_path)
        result

      {:error, reason} ->
        {:error,
         {:invalid, "could not provision a worktree for #{repo_path}: #{inspect(reason)}"}}
    end
  end

  defp write_and_open(
         ws,
         repo,
         repo_path,
         target_branch,
         worktree_path,
         branch,
         row,
         lesson,
         attribution
       ) do
    doc_path = doc_path(row.payload)
    file_path = Path.join(worktree_path, doc_path)
    current = read(file_path)
    cap_bytes = cap_bytes(row.payload)

    with {:ok, %{content: new_content, removed: removed}} <-
           RepoDocPatch.upsert(current, row.fingerprint, lesson, cap_bytes: cap_bytes),
         :ok <- File.write(file_path, new_content),
         :ok <- commit(worktree_path, doc_path, commit_message(row, removed, attribution)),
         :ok <- Mergers.prepare_with_repo(ws, repo),
         adapter <- Mergers.for_workspace(ws),
         :ok <- maybe_push(adapter, worktree_path),
         {:ok, _mr_ref} <-
           Mergers.open_with_retry(
             adapter,
             branch,
             row.gist,
             pr_description(row, lesson, removed),
             %{repo_path: repo_path, target_branch: target_branch}
           ) do
      :ok
    else
      {:error, {:entry_too_large, cap_bytes}} ->
        {:error,
         {:invalid,
          "this lesson (#{byte_size(lesson)} bytes) alone exceeds the #{cap_bytes}-byte CLAUDE.md section cap"}}

      {:error, :invalid_entry_text} ->
        {:error,
         {:invalid,
          "this lesson must be a single line with no arbiter:begin/end markers " <>
            "(CLAUDE.md entries are rendered one per line)"}}

      {:error, reason} ->
        {:error, {:invalid, inspect(reason)}}
    end
  end

  defp read(file_path) do
    case File.read(file_path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp commit(worktree_path, doc_path, message) do
    with {_, 0} <- System.cmd("git", ["add", doc_path], cd: worktree_path, stderr_to_stdout: true),
         {_, 0} <-
           System.cmd("git", ["commit", "-m", message], cd: worktree_path, stderr_to_stdout: true) do
      :ok
    else
      {output, _status} -> {:error, {:git_commit_failed, output}}
    end
  end

  # `Direct` operates on the canonical repo's own refs (no remote), so pushing
  # would just fail against whatever `origin` the local checkout has — or has
  # none at all. Every remote-backed adapter needs the branch pushed first.
  defp maybe_push(Mergers.Direct, _worktree_path), do: :ok

  defp maybe_push(_adapter, worktree_path) do
    case Worktree.push(worktree_path, set_upstream: true) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:git_push_failed, reason}}
    end
  end
end
