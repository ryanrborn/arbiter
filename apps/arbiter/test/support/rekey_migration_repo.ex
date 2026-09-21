defmodule Arbiter.RekeyMigrationRepo do
  @moduledoc """
  A throwaway SQLite repo the P5 quota re-key migration is run against
  (`Arbiter.Quota.RekeyMigrationTest`).

  The migration's backfill and collapse are raw SQL over the **pre**-P5
  schema, which no longer exists on `Arbiter.Repo` once the suite's own
  migrations have run — so the only way to exercise that SQL is against a
  database still in the old shape. This repo is started per test with its own
  file, seeded with the pre-P5 tables, and thrown away afterwards.
  """
  use Ecto.Repo, otp_app: :arbiter, adapter: Ecto.Adapters.SQLite3
end
