defmodule Arbiter.Repo.Migrations.RenameAdmiralRefToCoordinator do
  @moduledoc """
  Vernacular T2 (bd-byxj0d): rewrite the coordinator mailbox address literal on
  existing `messages` rows from the legacy `"admiral"` to the canonical
  `"coordinator"`.

  `"admiral"` is a persisted wire value, not a schema element — it lives in the
  free-form `to_ref` (recipient of reports sent *up*) and `from_ref` (the
  coordinator as sender of `:direction` messages) string columns. No column
  shape changes; this is a pure data rewrite.

  Producers now write `"coordinator"` and readers dual-read both literals
  (`Arbiter.Messages.Message.ref_variants/1`), so this migration is safe to run
  before or after the code rolls out. It is fully reversible — `down/0` restores
  the legacy literal so an older binary keeps working after a rollback.
  """

  use Ecto.Migration

  def up do
    execute("UPDATE messages SET to_ref = 'coordinator' WHERE to_ref = 'admiral'")
    execute("UPDATE messages SET from_ref = 'coordinator' WHERE from_ref = 'admiral'")
  end

  def down do
    execute("UPDATE messages SET to_ref = 'admiral' WHERE to_ref = 'coordinator'")
    execute("UPDATE messages SET from_ref = 'admiral' WHERE from_ref = 'coordinator'")
  end
end
