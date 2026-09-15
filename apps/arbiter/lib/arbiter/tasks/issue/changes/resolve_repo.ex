defmodule Arbiter.Tasks.Issue.Changes.ResolveRepo do
  @moduledoc """
  bd-9dwbvt: bind every new issue to a repo at creation time.

  Runs on `:create` only, and delegates the whole policy to
  `Arbiter.Tasks.IssueRepo.resolve/2`: an explicit repo (canonicalized onto
  the configured `repo_paths` key it matches), else the workspace's only repo,
  else its `default_repo`, else a validation error on the `:repo` field naming
  the configured keys.

  Every creation path — `task_create`, `arb issue create` (via
  `POST /api/issues`), `tracker_claim` / `arb issue claim`, `tracker_sync`'s
  auto-claim, the dashboard create form, PRPatrol follow-ups and
  ExternalReview engagements — goes through `Ash.create(Issue, …)`, so this
  one hook covers all of them rather than each re-deriving the rule.

  `:update` is deliberately NOT hooked. Clearing or repointing the repo on an
  existing issue stays possible — it is how an operator fixes a stale
  assignment — and dispatch already refuses loudly (`{:repo_not_found, _}`)
  rather than silently picking another repo.
  """

  use Ash.Resource.Change

  alias Arbiter.Tasks.IssueRepo
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, &resolve/1)
  end

  defp resolve(changeset) do
    workspace_id = Changeset.get_attribute(changeset, :workspace_id)
    explicit = Changeset.get_attribute(changeset, :repo)

    case IssueRepo.resolve(workspace_id, explicit) do
      {:ok, nil} ->
        changeset

      {:ok, repo} ->
        Changeset.force_change_attribute(changeset, :repo, repo)

      {:error, reason} ->
        Changeset.add_error(changeset, field: :repo, message: IssueRepo.describe_error(reason))
    end
  end
end
