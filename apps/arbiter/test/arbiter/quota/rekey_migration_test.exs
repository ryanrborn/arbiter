defmodule Arbiter.Quota.RekeyMigrationTest do
  @moduledoc """
  End-to-end proof of the P5 re-key migration's own SQL
  (`docs/provider-account-design.md` §6): the join backfill, the provisioning
  fallback for an install that never ran `mix arbiter.accounts.migrate`, the
  per-column-group collapse, and the identity flip.

  Run against a throwaway database still in the **pre**-P5 shape — the suite's
  own `Arbiter.Repo` is already migrated, so it cannot exercise this.
  """
  use ExUnit.Case, async: false

  alias Arbiter.RekeyMigrationRepo, as: Repo

  @migration_id 20_260_921_120_000
  @migration_file "priv/repo/migrations/20260921120000_rekey_quota_tables_to_provider_account.exs"

  setup_all do
    # Migrations live in `priv` and are not compiled into the app, so the
    # module has to be loaded before `Ecto.Migrator` can be handed it. Mix
    # runs each umbrella app's tests from that app's own directory.
    [{module, _}] = Code.require_file(@migration_file, File.cwd!())
    {:ok, migration: module}
  end

  setup %{migration: migration} do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbiter_rekey_#{Arbiter.TestDbPartition.suffix()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    pid = start_supervised!({Repo, database: path, pool_size: 1, log: false})
    on_exit(fn -> for f <- [path, path <> "-wal", path <> "-shm"], do: File.rm(f) end)

    create_pre_p5_schema()

    {:ok, repo: pid, migration: migration, path: path}
  end

  describe "backfill through workspace_provider_accounts" do
    test "three workspaces on one account collapse to one row", %{migration: migration} do
      account = uuid()
      insert_account(account, "claude", "personal-max")

      for {name, util} <- [{"default", 0.24}, {"emricare", 0.22}, {"vstim", 0.21}] do
        ws = uuid()
        insert_workspace(ws, name)
        link(ws, "claude", account)
        insert_anthropic(ws, captured_at: "2026-09-20 06:2#{trunc(util * 10)}:00", utilization_5h: util)
      end

      migrate!(migration)

      assert [[^account, _]] = query("SELECT provider_account_id, provider FROM anthropic_quotas")
    end

    test "a workspace with no join row is provisioned onto the provider's sole account", %{
      migration: migration
    } do
      account = uuid()
      insert_account(account, "claude", "personal-max")

      ws = uuid()
      insert_workspace(ws, "unlinked")
      insert_anthropic(ws, captured_at: "2026-09-20 06:00:00", utilization_5h: 0.5)

      migrate!(migration)

      assert [[^account]] = query("SELECT provider_account_id FROM anthropic_quotas")

      assert [[^account]] =
               query("SELECT provider_account_id FROM workspace_provider_accounts WHERE workspace_id = '#{ws}'")
    end

    test "an install with no accounts at all mints one shared default per provider", %{
      migration: migration
    } do
      for name <- ["a", "b"] do
        ws = uuid()
        insert_workspace(ws, name)
        insert_anthropic(ws, captured_at: "2026-09-20 06:00:0#{byte_size(name)}", utilization_5h: 0.5)
        insert_codex(ws, captured_at: "2026-09-20 06:00:00")
      end

      migrate!(migration)

      assert [["claude", "default"], ["codex", "default"]] =
               query("SELECT provider, slug FROM provider_accounts ORDER BY provider")

      assert [[1]] = query("SELECT count(*) FROM anthropic_quotas")
      assert [[1]] = query("SELECT count(*) FROM codex_quotas")
    end

    test "a row naming a deleted workspace is dropped rather than blocking the re-key", %{
      migration: migration
    } do
      live = uuid()
      insert_workspace(live, "live")
      insert_anthropic(live, captured_at: "2026-09-20 06:00:00", utilization_5h: 0.5)
      insert_anthropic(uuid(), captured_at: "2026-09-20 06:00:00", utilization_5h: 0.9)

      migrate!(migration)

      assert [[1]] = query("SELECT count(*) FROM anthropic_quotas")
      assert [[0.5]] = query("SELECT utilization_5h FROM anthropic_quotas")
    end
  end

  describe "per-column-group collapse (§6)" do
    test "keeps the freshest header block and the freshest oauth block, from different rows", %{
      migration: migration
    } do
      account = uuid()
      insert_account(account, "claude", "personal-max")

      fresh_header = uuid()
      insert_workspace(fresh_header, "header-ws")
      link(fresh_header, "claude", account)

      insert_anthropic(fresh_header,
        captured_at: "2026-09-20 10:00:00",
        utilization_5h: 0.91,
        status_5h: "allowed",
        capture_source: "oauth_poll",
        oauth_captured_at: "2026-09-18 01:00:00",
        oauth_utilization_5h: 0.11,
        per_model_utilization: ~s({"sonnet":0.1})
      )

      fresh_oauth = uuid()
      insert_workspace(fresh_oauth, "oauth-ws")
      link(fresh_oauth, "claude", account)

      insert_anthropic(fresh_oauth,
        captured_at: "2026-09-19 10:00:00",
        utilization_5h: 0.10,
        status_5h: "stale",
        capture_source: "headers",
        oauth_captured_at: "2026-09-20 23:00:00",
        oauth_utilization_5h: 0.71,
        per_model_utilization: ~s({"opus":0.77})
      )

      migrate!(migration)

      assert [
               [
                 0.91,
                 "allowed",
                 "oauth_poll",
                 "2026-09-20 10:00:00",
                 0.71,
                 ~s({"opus":0.77}),
                 "2026-09-20 23:00:00"
               ]
             ] =
               query("""
               SELECT utilization_5h, status_5h, capture_source, captured_at,
                      oauth_utilization_5h, per_model_utilization, oauth_captured_at
                 FROM anthropic_quotas
               """)
    end

    test "single-writer tables take the whole newest row", %{migration: migration} do
      account = uuid()
      insert_account(account, "codex", "work")

      old = uuid()
      insert_workspace(old, "old")
      link(old, "codex", account)
      insert_codex(old, captured_at: "2026-09-18 10:00:00", plan: "plus")

      new = uuid()
      insert_workspace(new, "new")
      link(new, "codex", account)
      insert_codex(new, captured_at: "2026-09-20 10:00:00", plan: "pro")

      migrate!(migration)

      assert [["pro"]] = query("SELECT plan FROM codex_quotas")
    end
  end

  describe "identity flip" do
    test "workspace_id is gone and (provider_account_id, provider) is unique", %{
      migration: migration
    } do
      account = uuid()
      insert_account(account, "claude", "solo")
      ws = uuid()
      insert_workspace(ws, "solo-ws")
      link(ws, "claude", account)
      insert_anthropic(ws, captured_at: "2026-09-20 06:00:00", utilization_5h: 0.5)

      migrate!(migration)

      for table <- ~w(anthropic_quotas codex_quotas cloud_code_quotas) do
        columns = query("SELECT name FROM pragma_table_info('#{table}')") |> List.flatten()
        refute "workspace_id" in columns
        assert "provider_account_id" in columns

        indexes = query("SELECT name FROM pragma_index_list('#{table}')") |> List.flatten()
        assert "#{table}_account_provider_index" in indexes
      end

      assert_raise Exqlite.Error, fn ->
        Repo.query!(
          "INSERT INTO anthropic_quotas (id, provider_account_id, provider, captured_at, inserted_at, updated_at) " <>
            "VALUES (?1, ?2, 'claude', '2026-09-20 06:00:00', '2026-09-20 06:00:00', '2026-09-20 06:00:00')",
          [uuid(), account]
        )
      end
    end

    test "down restores workspace_id from the join table", %{migration: migration} do
      account = uuid()
      insert_account(account, "claude", "solo")
      ws = uuid()
      insert_workspace(ws, "solo-ws")
      link(ws, "claude", account)
      insert_anthropic(ws, captured_at: "2026-09-20 06:00:00", utilization_5h: 0.5)

      migrate!(migration)
      Ecto.Migrator.down(Repo, @migration_id, migration, log: false)

      assert [[^ws, 0.5]] = query("SELECT workspace_id, utilization_5h FROM anthropic_quotas")

      columns = query("SELECT name FROM pragma_table_info('anthropic_quotas')") |> List.flatten()
      refute "provider_account_id" in columns
    end
  end

  # ---- helpers -----------------------------------------------------------

  defp migrate!(migration), do: Ecto.Migrator.up(Repo, @migration_id, migration, log: false)

  defp query(sql), do: Repo.query!(sql).rows

  defp uuid, do: Ecto.UUID.generate()

  defp insert_account(id, provider, slug) do
    Repo.query!(
      """
      INSERT INTO provider_accounts (id, provider, slug, identity_source, quota_config, enabled,
                                     inserted_at, updated_at)
      VALUES (?1, ?2, ?3, 'operator', '{}', 1, '2026-09-01 00:00:00', '2026-09-01 00:00:00')
      """,
      [id, provider, slug]
    )
  end

  defp insert_workspace(id, name) do
    Repo.query!("INSERT INTO workspaces (id, name) VALUES (?1, ?2)", [id, name])
  end

  defp link(workspace_id, provider, account_id) do
    Repo.query!(
      "INSERT INTO workspace_provider_accounts (id, workspace_id, provider, provider_account_id) VALUES (?1, ?2, ?3, ?4)",
      [uuid(), workspace_id, provider, account_id]
    )
  end

  defp insert_anthropic(workspace_id, opts) do
    Repo.query!(
      """
      INSERT INTO anthropic_quotas
             (id, workspace_id, provider, utilization_5h, status_5h, capture_source, captured_at,
              per_model_utilization, extra_usage, oauth_utilization_5h, oauth_captured_at,
              inserted_at, updated_at)
      VALUES (?1, ?2, 'claude', ?3, ?4, ?5, ?6, ?7, '{}', ?8, ?9,
              '2026-09-01 00:00:00', '2026-09-01 00:00:00')
      """,
      [
        uuid(),
        workspace_id,
        Keyword.get(opts, :utilization_5h),
        Keyword.get(opts, :status_5h),
        Keyword.get(opts, :capture_source),
        Keyword.fetch!(opts, :captured_at),
        Keyword.get(opts, :per_model_utilization, "{}"),
        Keyword.get(opts, :oauth_utilization_5h),
        Keyword.get(opts, :oauth_captured_at)
      ]
    )
  end

  defp insert_codex(workspace_id, opts) do
    Repo.query!(
      """
      INSERT INTO codex_quotas (id, workspace_id, provider, plan, captured_at, inserted_at, updated_at)
      VALUES (?1, ?2, 'codex', ?3, ?4, '2026-09-01 00:00:00', '2026-09-01 00:00:00')
      """,
      [uuid(), workspace_id, Keyword.get(opts, :plan, "plus"), Keyword.fetch!(opts, :captured_at)]
    )
  end

  # The pre-P5 shape, verbatim from the create migrations these three tables
  # were born in, plus the P1 account tables the backfill joins through.
  defp create_pre_p5_schema do
    [
      "CREATE TABLE workspaces (id TEXT NOT NULL PRIMARY KEY, name TEXT)",
      """
      CREATE TABLE provider_accounts (
        id TEXT NOT NULL PRIMARY KEY, provider TEXT NOT NULL, slug TEXT NOT NULL, label TEXT,
        plan TEXT, provider_account_ref TEXT, provider_org_ref TEXT, identity_source TEXT NOT NULL,
        identity_verified_at TEXT, max_concurrent INTEGER, quota_config TEXT, enabled BOOLEAN NOT NULL,
        merged_into_id TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL)
      """,
      "CREATE UNIQUE INDEX provider_accounts_provider_slug_index ON provider_accounts (provider, slug)",
      """
      CREATE TABLE workspace_provider_accounts (
        id TEXT NOT NULL PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL,
        provider_account_id TEXT NOT NULL, share INTEGER)
      """,
      "CREATE UNIQUE INDEX workspace_provider_accounts_workspace_provider_index ON workspace_provider_accounts (workspace_id, provider)",
      """
      CREATE TABLE anthropic_quotas (
        id TEXT NOT NULL PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL,
        utilization_5h REAL, reset_5h_at TEXT, status_5h TEXT, utilization_7d REAL, reset_7d_at TEXT,
        status_7d TEXT, representative_claim TEXT, overage_status TEXT, captured_at TEXT NOT NULL,
        inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL, per_model_utilization TEXT,
        extra_usage TEXT, oauth_utilization_5h REAL, oauth_utilization_7d REAL,
        oauth_captured_at TEXT, capture_source TEXT)
      """,
      "CREATE UNIQUE INDEX anthropic_quotas_workspace_provider_index ON anthropic_quotas (workspace_id, provider)",
      """
      CREATE TABLE codex_quotas (
        id TEXT NOT NULL PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL, plan TEXT,
        session_used_percent REAL, session_reset_at TEXT, weekly_used_percent REAL,
        weekly_reset_at TEXT, limit_reached BOOLEAN, captured_at TEXT NOT NULL,
        inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL)
      """,
      "CREATE UNIQUE INDEX codex_quotas_workspace_provider_index ON codex_quotas (workspace_id, provider)",
      """
      CREATE TABLE cloud_code_quotas (
        id TEXT NOT NULL PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL, plan TEXT,
        message TEXT, used_percent REAL, reset_at TEXT, snapshot TEXT, captured_at TEXT NOT NULL,
        inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL)
      """,
      "CREATE UNIQUE INDEX cloud_code_quotas_workspace_provider_index ON cloud_code_quotas (workspace_id, provider)"
    ]
    |> Enum.each(&Repo.query!/1)
  end
end
