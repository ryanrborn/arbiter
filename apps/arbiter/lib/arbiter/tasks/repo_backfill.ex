defmodule Arbiter.Tasks.RepoBackfill do
  @moduledoc """
  One-shot, idempotent backfill of `repo` onto issues filed before
  `Arbiter.Tasks.Issue.Changes.ResolveRepo` started binding one at creation
  (bd-9dwbvt).

  For each workspace, every issue whose `repo` is null is set to the repo
  `Arbiter.Tasks.IssueRepo` resolves for that workspace with no explicit repo:
  its only configured repo, or its `default_repo`. A workspace where neither
  exists — no `repo_paths` at all, or several repos and no `default_repo` — is
  **left alone** and reported with its null-repo count, so the operator can set
  `default_repo` and re-run.

  ## Why a mix task and not a data migration

  The value to write is not derivable from the database schema alone: it comes
  from each workspace's `config` JSON *combined with* the install-wide
  `:repo_paths` application env and whether each configured path is usable on
  this host. That is runtime, host-local state a schema migration has no
  business reading — and the answer legitimately changes when an operator edits
  the config, which is exactly why this has to be re-runnable rather than a
  one-way `up/0`. It is also reversible-by-inspection: a dry run prints
  everything it would write before anything is written.

  Idempotent by construction: it only ever selects rows with a null `repo`, so
  a second run has nothing to select and writes nothing.

  Runs through `Ash.update/2` rather than a bulk SQL update so every row keeps
  its paper-trail version, and closed issues are included — historical rows are
  precisely what per-repo cost estimation reads.
  """

  require Ash.Query

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.IssueRepo
  alias Arbiter.Tasks.Workspace

  @type report :: %{
          workspace_id: String.t(),
          workspace_name: String.t(),
          resolved_repo: String.t() | nil,
          null_repo_count: non_neg_integer(),
          issue_ids: [String.t()],
          updated: non_neg_integer(),
          left_null: non_neg_integer(),
          errors: [{String.t(), String.t()}]
        }

  @doc """
  Per-workspace plan of what the backfill would do. Pure read — no writes.

  Every workspace appears, including ones with nothing to do, so the printed
  report is a complete picture of where null repos remain.
  """
  @spec plan() :: [report()]
  def plan do
    Workspace
    |> Ash.read!()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&plan_workspace/1)
  end

  @doc """
  Apply a `plan/0`. Returns the same reports with `:updated` / `:errors`
  filled in.
  """
  @spec apply!([report()]) :: [report()]
  def apply!(plan) when is_list(plan), do: Enum.map(plan, &apply_workspace/1)

  @doc """
  Total issues still carrying a null repo after (or before) a run — the number
  the post-deploy check reads.
  """
  @spec remaining_null_count([report()]) :: non_neg_integer()
  def remaining_null_count(reports), do: Enum.sum(Enum.map(reports, & &1.left_null))

  # ---- internals -----------------------------------------------------------

  defp plan_workspace(%Workspace{} = ws) do
    ids = null_repo_issue_ids(ws.id)

    resolved =
      case IssueRepo.resolve(ws.id, nil) do
        {:ok, repo} when is_binary(repo) -> repo
        _ -> nil
      end

    %{
      workspace_id: ws.id,
      workspace_name: ws.name,
      resolved_repo: resolved,
      null_repo_count: length(ids),
      issue_ids: if(resolved, do: ids, else: []),
      updated: 0,
      left_null: if(resolved, do: 0, else: length(ids)),
      errors: []
    }
  end

  defp null_repo_issue_ids(ws_id) do
    Issue
    |> Ash.Query.filter(workspace_id == ^ws_id and is_nil(repo))
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp apply_workspace(%{resolved_repo: nil} = report), do: report

  defp apply_workspace(%{resolved_repo: repo, issue_ids: ids} = report) do
    {updated, errors} =
      Enum.reduce(ids, {0, []}, fn id, {ok, errors} ->
        case set_repo(id, repo) do
          :ok -> {ok + 1, errors}
          {:error, message} -> {ok, [{id, message} | errors]}
        end
      end)

    %{
      report
      | updated: updated,
        errors: Enum.reverse(errors),
        left_null: report.null_repo_count - updated
    }
  end

  defp set_repo(id, repo) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, _} <- Ash.update(issue, %{repo: repo}) do
      :ok
    else
      {:error, error} -> {:error, Exception.message(error)}
    end
  end
end
