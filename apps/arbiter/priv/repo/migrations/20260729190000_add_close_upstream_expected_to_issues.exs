defmodule Arbiter.Repo.Migrations.AddCloseUpstreamExpectedToIssues do
  @moduledoc """
  Adds `issues.close_upstream_expected` (bd-bsco7f): what a close *meant* for
  the linked tracker issue.

  `close_upstream` is an argument on the `:close` action, so it does not
  survive the action. `Tasks.Claim`'s drift check therefore inferred the intent
  from `pr_ref`'s presence, which is blind to a close that landed work outside
  the merger — a bug fixed by hand or as a drive-by ships no PR, so a *failed*
  upstream propagation on it was indistinguishable from a findings-only
  investigation whose ticket is supposed to stay open.

  Nullable with no backfill, deliberately: `NULL` means "closed before the
  intent was recorded", and the drift check keeps using the `pr_ref` proxy for
  those rows. Backfilling a `true` would retroactively flag every historical
  findings-only close — exactly the false drift bd-83ojwi removed.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add(:close_upstream_expected, :boolean)
    end
  end

  def down do
    alter table(:issues) do
      remove(:close_upstream_expected)
    end
  end
end
