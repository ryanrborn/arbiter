defmodule Arbiter.Repo.Migrations.AddBridgeStatusToSessions do
  @moduledoc """
  bd-cdretj: `bridge_status` on `sessions` — a durable home for §8.3's
  bridge-verification result.

  `Arbiter.Sessions.BridgeVerification.verify/2` already polls a
  `remote_control: true` session's JSONL for a `bridge-session` record and,
  on timeout, calls `Arbiter.Sessions.broadcast_error/2`. That broadcast is
  fire-and-forget over `Phoenix.PubSub` (see `broadcast_error/2`'s own
  moduledoc): a session with no attached client when it fires never sees
  it, and an operator opening the session later gets a plain terminal with
  no indication the bridge never came up. `bridge_status` persists the
  outcome so a late attach can still show it.

  Hand-written, matching every other migration under
  `Arbiter.Sessions.Session` (see `create_sessions`'s moduledoc for why this
  repo does not run `mix ash.codegen`).
  """

  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :bridge_status, :text
    end
  end

  def down do
    alter table(:sessions) do
      remove :bridge_status
    end
  end
end
