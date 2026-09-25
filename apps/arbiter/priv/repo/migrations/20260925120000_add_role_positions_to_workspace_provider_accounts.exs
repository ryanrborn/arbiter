defmodule Arbiter.Repo.Migrations.AddRolePositionsToWorkspaceProviderAccounts do
  @moduledoc """
  Per-role allowed accounts on the workspace → account join (bd-64apru).

  Two nullable integer columns: `implementer_position` / `reviewer_position`
  are the account's place in that role's preference order, `nil` meaning the
  account is not allowed for the role. No default and no backfill — every
  existing link starts outside both roles, so each workspace keeps resolving
  its providers from `agent.type` / `review_agent.type` exactly as today
  (`Arbiter.Accounts.ProviderSettings`). Safe to hot-run.
  """

  use Ecto.Migration

  def up do
    alter table(:workspace_provider_accounts) do
      add :implementer_position, :bigint
      add :reviewer_position, :bigint
    end
  end

  def down do
    alter table(:workspace_provider_accounts) do
      remove :implementer_position
      remove :reviewer_position
    end
  end
end
