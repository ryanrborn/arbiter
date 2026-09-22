defmodule Arbiter.Accounts.MaxConcurrentMigrationTest do
  @moduledoc """
  P8's migration (`docs/provider-account-design.md` §4.4): the account
  concurrency ceiling is **opt-in**. `provider_accounts.max_concurrent`
  migrates to `nil` — today's behaviour bit-for-bit — and the migration prints
  one advisory line per account so the operator can choose a number.

  Run against a throwaway database, like the P5 re-key migration test: the
  suite's own `Arbiter.Repo` has already been migrated and cannot exercise the
  migration's own SQL.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbiter.RekeyMigrationRepo, as: Repo

  @migration_id 20_260_922_120_000
  @migration_file "priv/repo/migrations/20260922120000_account_max_concurrent_opt_in.exs"

  setup_all do
    [{module, _}] = Code.require_file(@migration_file, File.cwd!())
    {:ok, migration: module}
  end

  setup %{migration: migration} do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbiter_p8_#{Arbiter.TestDbPartition.suffix()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Repo, database: path, pool_size: 1, log: false})
    on_exit(fn -> for f <- [path, path <> "-wal", path <> "-shm"], do: File.rm(f) end)

    create_schema()

    {:ok, migration: migration}
  end

  describe "the ceiling migrates to nil (§4.4)" do
    test "an account that arrived with a number is reset to nil", %{migration: migration} do
      insert_account(uuid(), "personal-max", 4)
      insert_account(uuid(), "work", nil)

      capture_io(fn -> migrate!(migration) end)

      assert query("SELECT max_concurrent FROM provider_accounts ORDER BY slug") == [[nil], [nil]]
    end

    test "a migrated install therefore imposes no ceiling at all", %{migration: migration} do
      id = uuid()
      insert_account(id, "personal-max", 12)
      ws = uuid()
      insert_workspace(ws, "default", 4)
      link(ws, "claude", id)

      capture_io(fn -> migrate!(migration) end)

      # The whole point of §4.4: `nil` here is what makes pre/post dispatch
      # throughput identical. `Arbiter.Accounts.Concurrency.account_headroom/2`
      # reads exactly this column and answers `:unlimited` for nil, which is
      # covered end-to-end in `Arbiter.Workflows.ConductorTest`.
      assert query("SELECT max_concurrent FROM provider_accounts") == [[nil]]
    end
  end

  describe "the advisory line" do
    test "reports the referencing workspaces and the total of their caps", %{
      migration: migration
    } do
      id = uuid()
      insert_account(id, "personal-max", nil)

      for {name, cap} <- [{"default", 4}, {"emricare", 4}, {"vstim", 4}] do
        ws = uuid()
        insert_workspace(ws, name, cap)
        link(ws, "claude", id)
      end

      out = capture_io(fn -> migrate!(migration) end)

      assert out =~
               "account `personal-max` is referenced by 3 workspaces whose caps total 12 " <>
                 "concurrent workers; consider `arb account set personal-max --max-concurrent N`"
    end

    test "a workspace with no explicit cap counts as the install-wide default", %{
      migration: migration
    } do
      id = uuid()
      insert_account(id, "unconfigured", nil)
      ws = uuid()
      insert_workspace(ws, "default", nil)
      link(ws, "claude", id)

      out = capture_io(fn -> migrate!(migration) end)

      system_max = Application.get_env(:arbiter, :conductor_system_max_concurrent, 16)

      assert out =~
               "account `unconfigured` is referenced by 1 workspaces whose caps total " <>
                 "#{system_max} concurrent workers"
    end

    test "one line per account, including an account nothing references", %{
      migration: migration
    } do
      insert_account(uuid(), "orphan-a", nil)
      insert_account(uuid(), "orphan-b", nil)

      out = capture_io(fn -> migrate!(migration) end)

      assert out =~ "account `orphan-a` is referenced by 0 workspaces whose caps total 0"
      assert out =~ "account `orphan-b` is referenced by 0 workspaces whose caps total 0"
    end

    test "an install with no accounts prints nothing and still succeeds", %{migration: migration} do
      out = capture_io(fn -> migrate!(migration) end)
      refute out =~ "consider `arb account set"
    end
  end

  describe "down/0" do
    test "is a no-op — there is nothing to restore", %{migration: migration} do
      insert_account(uuid(), "rollback", nil)

      capture_io(fn -> migrate!(migration) end)
      capture_io(fn -> Ecto.Migrator.down(Repo, @migration_id, migration, log: false) end)

      assert query("SELECT max_concurrent FROM provider_accounts") == [[nil]]
    end
  end

  # ---- helpers ------------------------------------------------------------

  defp migrate!(migration), do: Ecto.Migrator.up(Repo, @migration_id, migration, log: false)

  defp query(sql), do: Repo.query!(sql).rows

  defp uuid, do: Ecto.UUID.generate()

  defp insert_account(id, slug, max_concurrent) do
    Repo.query!(
      """
      INSERT INTO provider_accounts (id, provider, slug, identity_source, quota_config, enabled,
                                     max_concurrent, inserted_at, updated_at)
      VALUES (?1, 'claude', ?2, 'operator', '{}', 1, ?3, '2026-09-01 00:00:00', '2026-09-01 00:00:00')
      """,
      [id, slug, max_concurrent]
    )
  end

  defp insert_workspace(id, name, nil),
    do: Repo.query!("INSERT INTO workspaces (id, name, config) VALUES (?1, ?2, '{}')", [id, name])

  defp insert_workspace(id, name, max_concurrent) do
    config = Jason.encode!(%{"conductor" => %{"max_concurrent" => max_concurrent}})

    Repo.query!("INSERT INTO workspaces (id, name, config) VALUES (?1, ?2, ?3)", [
      id,
      name,
      config
    ])
  end

  defp link(workspace_id, provider, account_id) do
    Repo.query!(
      "INSERT INTO workspace_provider_accounts (id, workspace_id, provider, provider_account_id) VALUES (?1, ?2, ?3, ?4)",
      [uuid(), workspace_id, provider, account_id]
    )
  end

  defp create_schema do
    [
      "CREATE TABLE workspaces (id TEXT NOT NULL PRIMARY KEY, name TEXT, config TEXT)",
      """
      CREATE TABLE provider_accounts (
        id TEXT NOT NULL PRIMARY KEY, provider TEXT NOT NULL, slug TEXT NOT NULL, label TEXT,
        plan TEXT, provider_account_ref TEXT, provider_org_ref TEXT, identity_source TEXT NOT NULL,
        identity_verified_at TEXT, max_concurrent INTEGER, quota_config TEXT, enabled BOOLEAN NOT NULL,
        merged_into_id TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL)
      """,
      """
      CREATE TABLE workspace_provider_accounts (
        id TEXT NOT NULL PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL,
        provider_account_id TEXT NOT NULL, share INTEGER)
      """
    ]
    |> Enum.each(&Repo.query!/1)
  end
end
