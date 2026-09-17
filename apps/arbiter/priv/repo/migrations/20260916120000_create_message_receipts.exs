defmodule Arbiter.Repo.Migrations.CreateMessageReceipts do
  @moduledoc """
  bd-8akewg: per-reader read state for the shared coordinator mailbox.

  `messages.read_at` / `messages.cleared_at` were a single pair of timestamps on
  a queue every browser session and the sessionless coordinator read from, so
  the first poller consumed everybody else's mail. This table moves that state
  onto the (message, reader) pair — see `Arbiter.Messages.MessageReceipt`.

  The data migration preserves the operator's current triage state by minting a
  receipt for the shared `"coordinator"` reader from every row that already
  carries a `read_at` or a `cleared_at`. Sessions start with no receipts, which
  *is* the unread state; their `inserted_at` floor (the session's own start) is
  what keeps a new session from being handed the archive.

  Written by hand rather than via `mix ash.codegen`, matching the
  `create_sessions` / `create_provider_accounts` precedent: this repo's
  committed `priv/resource_snapshots` have drifted from several hand-written
  migrations, so a codegen run tries to "catch up" every drifted resource at
  once. This migration is scoped to the one new table and ships **without** a
  matching `priv/resource_snapshots/repo/message_receipts` snapshot; a future
  `mix ash.codegen` will therefore re-emit a `create table(:message_receipts)`
  that should be discarded as an already-applied no-op rather than run.
  """

  use Ecto.Migration

  # SQLite has no uuid4(); this composes one from randomblob in the canonical
  # textual form every other id column in this database already stores.
  @uuid4 """
  lower(
    hex(randomblob(4)) || '-' ||
    hex(randomblob(2)) || '-4' ||
    substr(hex(randomblob(2)), 2) || '-' ||
    substr('89ab', abs(random()) % 4 + 1, 1) ||
    substr(hex(randomblob(2)), 2) || '-' ||
    hex(randomblob(6))
  )
  """

  def up do
    create table(:message_receipts, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true

      # Deliberately not a foreign key: `messages` rows are only ever destroyed
      # by `Message.hard_purge/2`, which deletes the matching receipts itself,
      # and SQLite's FK rebuild dance is exactly the churn the sessions
      # migration called out.
      add :message_id, :uuid, null: false

      # "coordinator" (every sessionless reader, sharing one identity) or
      # "session:<session_id>".
      add :reader_ref, :text, null: false

      add :read_at, :utc_datetime_usec
      add :cleared_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:message_receipts, [:message_id, :reader_ref],
             name: "message_receipts_unique_message_reader_index"
           )

    create index(:message_receipts, [:reader_ref, :cleared_at])

    # Backfill: the operator's existing triage state becomes the sessionless
    # coordinator reader's receipts. `inserted_at`/`updated_at` are copied from
    # the message so the backfilled rows carry no fabricated "now".
    execute """
    INSERT INTO message_receipts
      (id, message_id, reader_ref, read_at, cleared_at, inserted_at, updated_at)
    SELECT
      #{@uuid4},
      m.id,
      'coordinator',
      m.read_at,
      m.cleared_at,
      m.inserted_at,
      m.updated_at
    FROM messages m
    WHERE m.to_ref IN ('coordinator', 'admiral')
      AND (m.read_at IS NOT NULL OR m.cleared_at IS NOT NULL)
    """
  end

  def down do
    drop table(:message_receipts)
  end
end
