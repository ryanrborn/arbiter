defmodule Arbiter.Repo.Migrations.AddSessionProvisioningColumns do
  @moduledoc """
  Phase 3 of `docs/browser-hosted-coordinator-sessions.md` (bd-aprlbb): the
  three columns per-session provisioning adds to `sessions`.

    * `root_dir` — the session's §9.1 scaffold directory. `config_dir` and
      `cwd` already exist; this is the parent holding them plus `CLAUDE.md`,
      `.mcp.json`, `memory/` and `transcript/`.
    * `can_dispatch` — §10.1's dispatch-recursion guardrail as a per-session
      pre-launch toggle. **Defaults to false**, which is the whole point.
    * `mcp_token_revoked_at` — the revocation handle for the per-session MCP
      scope token (§9.3). Scope tokens are stateless signed blobs with no
      revocation table, so `Arbiter.MCP.Scope.from_token/1` reads this column
      for any token carrying a `session_id` claim; ending or killing a session
      stamps it and the token stops verifying.

  Hand-written for the same reason `create_sessions` was (see its moduledoc):
  this repo's committed `priv/resource_snapshots` have drifted from several
  hand-written migrations, so a `mix ash.codegen` run tries to catch every
  drifted resource up at once. Scoped to the three columns; ships without a
  snapshot.

  `can_dispatch` is added with a server-side default so the existing phase-1
  rows backfill to the safe value rather than to NULL against a NOT NULL
  column.
  """

  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :root_dir, :text
      add :can_dispatch, :boolean, null: false, default: false
      add :mcp_token_revoked_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:sessions) do
      remove :root_dir
      remove :can_dispatch
      remove :mcp_token_revoked_at
    end
  end
end
