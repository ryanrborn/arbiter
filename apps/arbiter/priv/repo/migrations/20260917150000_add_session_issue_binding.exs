defmodule Arbiter.Repo.Migrations.AddSessionIssueBinding do
  @moduledoc """
  bd-1lszsc: a session may be bound to one issue — the **refine session** of
  epic bd-cksar2, launched from a Backlog issue's Refine action.

  The partial unique index is the whole "at most one live refine session per
  issue" rule, expressed where a concurrent double-click cannot get around it.
  A read-then-launch check alone is a TOCTOU window: two clicks a few
  milliseconds apart both see "no session" and both launch. Here, the second
  insert simply fails and `Arbiter.Sessions.Refine.open/2` re-reads and hands
  back the winner.

  `WHERE status != 'ended'` is what makes it *live*: ending a session drops its
  row out of the index, so an issue whose refine session was killed can be
  refined again — and the whole history of its previous ones stays on the
  table.

  Hand-written for the same reason its neighbours are (see `create_sessions`'s
  moduledoc): this repo's committed `priv/resource_snapshots` have drifted from
  several hand-written migrations, so `mix ash.codegen` tries to catch up every
  drifted resource at once.
  """

  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :issue_id, :text
    end

    create index(:sessions, [:issue_id])

    create unique_index(:sessions, [:issue_id],
             name: :sessions_live_issue_binding_index,
             where: "issue_id IS NOT NULL AND status != 'ended'"
           )
  end

  def down do
    drop index(:sessions, [:issue_id], name: :sessions_live_issue_binding_index)
    drop index(:sessions, [:issue_id])

    alter table(:sessions) do
      remove :issue_id
    end
  end
end
