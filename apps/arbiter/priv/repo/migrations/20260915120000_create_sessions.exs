defmodule Arbiter.Repo.Migrations.CreateSessions do
  @moduledoc """
  Phase 1 of `docs/browser-hosted-coordinator-sessions.md` (bd-bpt0ag):
  creates `sessions`, the durable identity of a browser-hosted coordinator
  session whose processes live outside the BEAM in a transient systemd user
  scope. Field list is RFC §7.4 item 4.

  `Arbiter.Usage.Event.session_id` references a row **by string** — the
  provider-side session id — deliberately, per §7.4 item 4 ("no FK churn"):
  the ledger's key is the JSONL basename the CLI chose, a session can roll
  through several of those, and the metering that writes those rows shipped
  first (bd-be804c). So there is no foreign key here, and
  `provider_session_id` is indexed instead.

  Written by hand rather than via `mix ash.codegen`, matching the
  `create_provider_accounts` and `create_review_coverage` precedents: this
  repo's committed `priv/resource_snapshots` have already drifted from several
  hand-written migrations, so a codegen run tries to "catch up" every drifted
  resource at once (including a `graph_members` FK rebuild SQLite cannot do).
  This migration is scoped to the one new table, and — like
  `create_review_coverage` — ships **without** a matching
  `priv/resource_snapshots/repo/sessions` snapshot, so a future `mix
  ash.codegen` will detect `Arbiter.Sessions.Session` as new and emit another
  `create table(:sessions)`; that migration should be discarded as an
  already-applied no-op rather than run.
  """

  use Ecto.Migration

  def up do
    create table(:sessions, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true

      # Which agent CLI runs in the pane. The launch command itself is behind
      # Arbiter.Sessions.Provider, so a second provider is an adapter.
      add :provider, :text, null: false

      # NULLABLE ON PURPOSE: nil means a cross-workspace session, which is the
      # coordinator's normal shape (RFC decision 6).
      add :workspace_id, :text

      # The OS handles, derived from `id` — systemd unit name and tmux socket.
      # Stored so a row stays self-describing if the naming scheme changes.
      add :scope_unit, :text, null: false
      add :tmux_socket, :text, null: false

      # CLAUDE_CONFIG_DIR (§9.1); null until provisioning lands in phase 3.
      add :config_dir, :text
      add :cwd, :text, null: false

      # The CURRENT provider-side session id (§7.5 rollover), i.e. the JSONL
      # basename. This is the string usage_events.session_id joins on.
      add :provider_session_id, :text

      # §8.1: seeded_credentials (mode B, the Amendment 2 default) or
      # oauth_token (mode A, revocable, no Remote Control).
      add :auth_mode, :text, null: false
      add :remote_control, :boolean, null: false

      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :last_client_at, :utc_datetime_usec

      # starting | running | ended, plus why it ended — §4.6 requires the
      # adoption sweep to record a reason rather than silently flipping rows.
      add :status, :text, null: false
      add :end_reason, :text

      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    # One row per scope, enforced rather than merely implied by the id.
    create unique_index(:sessions, [:scope_unit], name: "sessions_scope_unit_index")

    # The adoption sweep's read ("every row that isn't ended") and the list view.
    create index(:sessions, [:status], name: "sessions_status_index")

    # The ledger join and the rollover lookup.
    create index(:sessions, [:provider_session_id],
             name: "sessions_provider_session_id_index"
           )
  end

  def down do
    drop_if_exists unique_index(:sessions, [:scope_unit], name: "sessions_scope_unit_index")
    drop_if_exists index(:sessions, [:status], name: "sessions_status_index")

    drop_if_exists index(:sessions, [:provider_session_id],
                     name: "sessions_provider_session_id_index"
                   )

    drop table(:sessions)
  end
end
