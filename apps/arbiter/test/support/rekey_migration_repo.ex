defmodule Arbiter.RekeyMigrationRepo do
  @moduledoc """
  A throwaway SQLite repo a migration's own SQL is run against —
  `Arbiter.Quota.RekeyMigrationTest` (P5's quota re-key) and
  `Arbiter.Accounts.MaxConcurrentMigrationTest` (P8's ceiling opt-in).

  A migration's raw SQL runs over a schema that no longer exists on
  `Arbiter.Repo` once the suite's own migrations have run — so the only way to
  exercise it is against a database still in the old shape. This repo is
  started per test with its own file, seeded by that test with whatever tables
  the migration touches, and thrown away afterwards.
  """
  use Ecto.Repo, otp_app: :arbiter, adapter: Ecto.Adapters.SQLite3
end
