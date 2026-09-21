defmodule Arbiter.Repo.Migrations.RekeyQuotaTablesToProviderAccount do
  @moduledoc """
  Phase P5 of `docs/provider-account-design.md` (§6, bd-3yokey): re-key
  `anthropic_quotas`, `codex_quotas` and `cloud_code_quotas` from
  `(workspace_id, provider)` to `(provider_account_id, provider)`.

  The gate, the budget and the cap have to live on the same object; until
  this migration the quota snapshot was the odd one out, so three workspaces
  sharing one Anthropic plan carried three independent snapshots of the same
  account-wide figures.

  ## Order of operations, per table

    1. `ALTER TABLE … ADD COLUMN provider_account_id` — nullable, so the
       backfill has somewhere to land.
    2. Backfill from `workspace_provider_accounts`: a straight join, because
       the existing key `(workspace_id, provider)` *is* that table's key
       (§3.3).
    3. Provision for whatever the join missed. An install that has never run
       `mix arbiter.accounts.migrate` has no join rows at all, and a quota
       row with no account has nowhere to go — so every leftover
       `(workspace_id, provider)` is linked, following
       `Arbiter.Accounts.Resolver`'s rule: the provider's sole enabled
       account if there is exactly one, otherwise a single shared `default`
       account per provider. One account per provider, never one per
       workspace, which is the duplication this phase removes.
    4. Collapse duplicates through `Arbiter.Quota.Rekey` — **per column
       group** for `anthropic_quotas` (header columns from the newest
       `captured_at`, oauth columns from the newest `oauth_captured_at`),
       whole-newest-row for the two single-writer tables.
    5. Rebuild the table without `workspace_id` and with
       `provider_account_id NOT NULL`, then create the new unique index.
       SQLite has no `ALTER COLUMN`, so the identity flip is a rebuild.

  ## `down`

  Reversible in shape, lossy in fact, and deliberately so: the collapse in
  step 4 is not invertible, and one account fans back out to N workspaces.
  `down` re-derives a single `workspace_id` per row from the join table (the
  alphabetically-first linked workspace) and drops rows whose account has no
  workspace left. These tables are caches of the latest reading, not time
  series, so a probe cycle repopulates them either way.
  """

  use Ecto.Migration

  alias Arbiter.Quota.Rekey

  @anthropic_columns ~w(
    id workspace_id provider utilization_5h reset_5h_at status_5h utilization_7d
    reset_7d_at status_7d representative_claim overage_status captured_at
    inserted_at updated_at per_model_utilization extra_usage oauth_utilization_5h
    oauth_utilization_7d oauth_captured_at capture_source
  )

  @codex_columns ~w(
    id workspace_id provider plan session_used_percent session_reset_at
    weekly_used_percent weekly_reset_at limit_reached captured_at inserted_at
    updated_at
  )

  @cloud_code_columns ~w(
    id workspace_id provider plan message used_percent reset_at snapshot
    captured_at inserted_at updated_at
  )

  @tables [
    {"anthropic_quotas", @anthropic_columns, :per_column_group},
    {"codex_quotas", @codex_columns, :newest_row},
    {"cloud_code_quotas", @cloud_code_columns, :newest_row}
  ]

  def up do
    for {table, columns, collapse} <- @tables do
      add_column(table)
      backfill(table)
      provision_missing(table)
      backfill(table)
      drop_unkeyable(table)
      collapse_duplicates(table, columns, collapse)
      rebuild_keyed_by_account(table, columns)
    end
  end

  def down do
    for {table, columns, _collapse} <- @tables, do: rebuild_keyed_by_workspace(table, columns)
  end

  # ---- step 1 ------------------------------------------------------------

  defp add_column(table) do
    sql("ALTER TABLE #{table} ADD COLUMN provider_account_id TEXT")
  end

  # ---- step 2 ------------------------------------------------------------

  defp backfill(table) do
    sql("""
    UPDATE #{table}
       SET provider_account_id = (
             SELECT wpa.provider_account_id
               FROM workspace_provider_accounts wpa
              WHERE wpa.workspace_id = #{table}.workspace_id
                AND wpa.provider = #{table}.provider
           )
     WHERE provider_account_id IS NULL
    """)
  end

  # ---- step 3 ------------------------------------------------------------

  defp provision_missing(table) do
    %{rows: rows} =
      repo().query!(
        "SELECT DISTINCT workspace_id, provider FROM #{table} WHERE provider_account_id IS NULL"
      )

    for [workspace_id, provider] <- rows,
        workspace_exists?(workspace_id),
        account_id = account_for(provider) do
      link(workspace_id, provider, account_id)
    end
  end

  # `workspace_id` is a free-text column with no FK, so a row may name a
  # workspace that has since been deleted. `workspace_provider_accounts`
  # *does* have the FK, so linking such a row would fail the insert — skip it
  # and let step 4's `drop_unkeyable/1` remove the orphan.
  defp workspace_exists?(workspace_id) do
    %{rows: rows} =
      repo().query!("SELECT 1 FROM workspaces WHERE id = ?1 LIMIT 1", [workspace_id])

    rows != []
  end

  defp account_for(provider) do
    case sole_enabled_account(provider) do
      nil -> default_account(provider)
      id -> id
    end
  end

  defp sole_enabled_account(provider) do
    %{rows: rows} =
      repo().query!(
        "SELECT id FROM provider_accounts WHERE provider = ?1 AND enabled = 1 LIMIT 2",
        [provider]
      )

    case rows do
      [[id]] -> id
      _ -> nil
    end
  end

  defp default_account(provider) do
    %{rows: rows} =
      repo().query!(
        "SELECT id FROM provider_accounts WHERE provider = ?1 AND slug = 'default' LIMIT 1",
        [provider]
      )

    case rows do
      [[id]] ->
        id

      [] ->
        id = Ecto.UUID.generate()
        now = timestamp()

        repo().query!(
          """
          INSERT INTO provider_accounts
                 (id, provider, slug, label, identity_source, quota_config, enabled,
                  inserted_at, updated_at)
          VALUES (?1, ?2, 'default', ?3, 'operator', '{}', 1, ?4, ?4)
          """,
          [id, provider, "Default #{provider} account", now]
        )

        id
    end
  end

  defp link(workspace_id, provider, account_id) do
    repo().query!(
      """
      INSERT OR IGNORE INTO workspace_provider_accounts
             (id, workspace_id, provider, provider_account_id)
      VALUES (?1, ?2, ?3, ?4)
      """,
      [Ecto.UUID.generate(), workspace_id, provider, account_id]
    )
  end

  # Anything still unkeyed names a workspace that no longer exists (or a
  # provider `provider_accounts` does not model). It cannot be represented
  # under the new identity and these tables are caches, so drop it.
  defp drop_unkeyable(table) do
    sql("DELETE FROM #{table} WHERE provider_account_id IS NULL")
  end

  # ---- step 4 ------------------------------------------------------------

  defp collapse_duplicates(table, columns, collapse) do
    all = columns ++ ["provider_account_id"]
    %{rows: rows} = repo().query!("SELECT #{Enum.join(all, ", ")} FROM #{table}")

    keys = Enum.map(all, &String.to_atom/1)

    collapsed =
      rows
      |> Enum.map(&(keys |> Enum.zip(&1) |> Map.new()))
      |> Enum.group_by(&{&1.provider_account_id, &1.provider})
      |> Enum.map(fn {_key, group} -> collapse_group(group, collapse) end)

    repo().query!("DELETE FROM #{table}")

    placeholders = all |> Enum.with_index(1) |> Enum.map_join(", ", fn {_c, i} -> "?#{i}" end)

    for row <- collapsed do
      repo().query!(
        "INSERT INTO #{table} (#{Enum.join(all, ", ")}) VALUES (#{placeholders})",
        Enum.map(keys, &Map.get(row, &1))
      )
    end
  end

  defp collapse_group(group, :per_column_group), do: Rekey.collapse_anthropic(group)
  defp collapse_group(group, :newest_row), do: Rekey.collapse_newest(group)

  # ---- step 5 ------------------------------------------------------------

  defp rebuild_keyed_by_account(table, columns) do
    kept = Enum.reject(columns, &(&1 == "workspace_id")) ++ ["provider_account_id"]

    sql("DROP INDEX IF EXISTS #{table}_workspace_provider_index")
    sql("ALTER TABLE #{table} RENAME TO #{table}_pre_p5")
    sql(create_sql(table, kept, "provider_account_id TEXT NOT NULL"))

    sql("""
    INSERT INTO #{table} (#{Enum.join(kept, ", ")})
    SELECT #{Enum.join(kept, ", ")} FROM #{table}_pre_p5
    """)

    sql("DROP TABLE #{table}_pre_p5")

    sql("""
    CREATE UNIQUE INDEX #{table}_account_provider_index
        ON #{table} (provider_account_id, provider)
    """)
  end

  defp rebuild_keyed_by_workspace(table, columns) do
    kept = Enum.reject(columns, &(&1 == "workspace_id"))
    copied = Enum.reject(kept, &(&1 == "id"))

    sql("DROP INDEX IF EXISTS #{table}_account_provider_index")
    sql("ALTER TABLE #{table} RENAME TO #{table}_p5")
    sql(create_sql(table, columns, "workspace_id TEXT NOT NULL"))

    sql("""
    INSERT INTO #{table} (id, workspace_id, #{Enum.join(copied, ", ")})
    SELECT p5.id,
           (SELECT wpa.workspace_id
              FROM workspace_provider_accounts wpa
              JOIN workspaces w ON w.id = wpa.workspace_id
             WHERE wpa.provider_account_id = p5.provider_account_id
               AND wpa.provider = p5.provider
             ORDER BY w.name
             LIMIT 1),
           #{Enum.map_join(copied, ", ", &"p5.#{&1}")}
      FROM #{table}_p5 p5
     WHERE EXISTS (
             SELECT 1 FROM workspace_provider_accounts wpa
              WHERE wpa.provider_account_id = p5.provider_account_id
                AND wpa.provider = p5.provider
           )
    """)

    sql("DROP TABLE #{table}_p5")

    sql("""
    CREATE UNIQUE INDEX #{table}_workspace_provider_index
        ON #{table} (workspace_id, provider)
    """)
  end

  # The column list is fixed per table, so the `CREATE TABLE` is spelled out
  # here rather than reconstructed from `sqlite_master`, which would carry
  # the old index/constraint text along with it.
  defp create_sql(table, columns, key_column) do
    body =
      columns
      |> Enum.reject(&(&1 in ["id", "workspace_id", "provider_account_id"]))
      |> Enum.map(&"#{&1} #{column_type(table, &1)}")

    """
    CREATE TABLE #{table} (
      id TEXT NOT NULL PRIMARY KEY,
      #{key_column},
      #{Enum.join(body, ",\n      ")}
    )
    """
  end

  @not_null ~w(provider captured_at inserted_at updated_at)

  defp column_type(_table, column) do
    base =
      cond do
        column in ~w(utilization_5h utilization_7d oauth_utilization_5h oauth_utilization_7d
                     session_used_percent weekly_used_percent used_percent) ->
          "REAL"

        column == "limit_reached" ->
          "BOOLEAN"

        true ->
          "TEXT"
      end

    if column in @not_null, do: base <> " NOT NULL", else: base
  end

  # `Ecto.Migration.execute/1` *queues* its command and only runs it at the
  # end of `up`/`down`, which would put every DDL statement after the
  # `repo().query!` reads this migration interleaves with them. Everything
  # here therefore goes through the repo directly, in written order.
  defp sql(statement), do: repo().query!(statement)

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_naive()
  end
end
