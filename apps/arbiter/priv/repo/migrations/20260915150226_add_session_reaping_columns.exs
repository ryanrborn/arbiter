defmodule Arbiter.Repo.Migrations.AddSessionReapingColumns do
  @moduledoc """
  Phase 10 of `docs/browser-hosted-coordinator-sessions.md` (bd-3qkbch): the
  two columns the idle-deadline sweep needs on `sessions`.

    * `keep_alive` — the operator's pin against the idle-TTL sweep (§4.6 item
      2). Defaults `false`, so a session is reapable unless someone deliberately
      opts it out.
    * `last_turn_at` — a turn (a JSONL rollover, a usage event) is activity
      distinct from a client merely being attached. Alongside `last_client_at`
      (already a column, phase 1), the reaper takes the newer of the two as
      "last activity"; a session with neither uses `started_at`.

  Hand-written, matching every other `sessions` migration in this file's
  history — this repo's committed `priv/resource_snapshots` have drifted, so
  `mix ash.codegen` tries to catch up several unrelated resources at once.
  """

  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :keep_alive, :boolean, null: false, default: false
      add :last_turn_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:sessions) do
      remove :keep_alive
      remove :last_turn_at
    end
  end
end
