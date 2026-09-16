defmodule Arbiter.Repo.Migrations.AddSessionName do
  @moduledoc """
  bd-o2vtsz: an operator-supplied (or later, Claude-derived) display name for a
  session — nullable, since most rows will fall back to the ai-title ladder
  (`Arbiter.Sessions.DisplayName`) rather than carry one.

  Hand-written for the same reason its neighbours in this file are (see
  `create_sessions`'s moduledoc): this repo's committed `priv/resource_snapshots`
  have drifted from several hand-written migrations, so `mix ash.codegen` tries
  to catch up every drifted resource at once.
  """

  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :name, :text
    end
  end

  def down do
    alter table(:sessions) do
      remove :name
    end
  end
end
