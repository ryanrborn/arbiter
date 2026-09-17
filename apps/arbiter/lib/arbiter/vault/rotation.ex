defmodule Arbiter.Vault.Rotation do
  @moduledoc """
  Re-encrypts every `ash_cloak`-encrypted column under `Arbiter.Vault`'s
  current (`:default`) cipher, and verifies none remain on the retired one.

  Driven by `mix arbiter.rotate_cloak_key` — see `docs/cloak-key-rotation.md`
  for the operator runbook. This module does the row-by-row work; the Mix
  task is a thin CLI wrapper around `sweep!/0` and `verify/0`.

  Bypasses Ash actions entirely: this is an at-rest re-encryption of opaque
  ciphertext, not a domain write, so it reads/writes the raw
  `encrypted_<attr>` columns directly via `Ecto.Adapters.SQL` rather than
  going through resource actions (which don't accept those columns as
  arguments, and would fire changes/paper-trail hooks that don't apply here).

  ## Columns swept

  Every `ash_cloak` `cloak do` block in the app, found by grepping for it
  under `apps/arbiter/lib`:

    * `Arbiter.Tasks.Workspace` — `:secrets`, `:worker_env`
    * `Arbiter.Accounts.ProviderCredential` — `:secret`

  Add new entries to `@columns` here when a new resource grows a `cloak`
  block — nothing here discovers them automatically. A drift guard
  (`Arbiter.Vault.RotationTest` `"@columns matches every ash_cloak attribute
  in the app"`) derives the true set from `config :arbiter, :ash_domains` +
  `AshCloak.Info.cloak_attributes!/1` and fails if it disagrees with this
  list, so a forgotten column shows up as a test failure rather than as
  permanently undecryptable ciphertext after the old key is dropped.

  ## Safety

  Only counts and row ids ever reach `Mix.shell()` or a return value —
  decrypted plaintext lives strictly inside `rotate_row!/5` and is
  immediately re-encrypted, never logged or written to disk unencrypted.

  ## Concurrent writes

  Each row is re-encrypted with a compare-and-swap `UPDATE ... WHERE id = ?
  AND encrypted_<attr> = ?` against the exact ciphertext read in the sweep's
  snapshot `SELECT`. If a live write (e.g. a workspace secrets update) lands
  on the same row in between, the CAS matches zero rows, the row is counted
  under `:skipped_changed`, and it is left untouched rather than clobbered
  with a re-encryption of the stale value. The sweep is idempotent, so the
  operator re-runs `--sweep` to pick up anything reported as skipped.
  """

  alias Arbiter.Vault

  @columns [
    {Arbiter.Tasks.Workspace, "workspaces", :secrets},
    {Arbiter.Tasks.Workspace, "workspaces", :worker_env},
    {Arbiter.Accounts.ProviderCredential, "provider_credentials", :secret}
  ]

  @doc "The `{resource, table, attribute}` triples swept and verified. Exposed for the drift-guard test."
  @spec columns() :: [{module(), String.t(), atom()}]
  def columns, do: @columns

  @type sweep_report :: %{
          table: String.t(),
          column: String.t(),
          scanned: non_neg_integer(),
          rotated: non_neg_integer(),
          already_current: non_neg_integer(),
          skipped_changed: non_neg_integer()
        }

  @type verify_report :: %{table: String.t(), column: String.t(), retired: non_neg_integer()}

  @doc """
  Re-encrypts every row of every ash_cloak column under the vault's current
  cipher. Rows already tagged with the current cipher are left untouched, so
  this is safe to re-run (e.g. after an interrupted sweep). Returns one
  report per column.
  """
  @spec sweep!() :: [sweep_report()]
  def sweep! do
    Enum.map(@columns, &sweep_column!/1)
  end

  @doc """
  Counts rows still tagged with the retired cipher, per column. An empty
  list of nonzero counts (every `:retired` is `0`) means it is safe to drop
  `ARBITER_CLOAK_KEY_OLD` from the environment and redeploy.
  """
  @spec verify() :: [verify_report()]
  def verify do
    Enum.map(@columns, &verify_column/1)
  end

  defp sweep_column!({resource, table, attr}) do
    column = "encrypted_#{attr}"

    {rotated, already_current, skipped_changed} =
      table
      |> select_rows(column)
      |> Enum.reduce({0, 0, 0}, fn {id, raw}, {rotated, current, skipped} ->
        case rotate_row!(resource, table, column, id, raw) do
          :rotated -> {rotated + 1, current, skipped}
          :already_current -> {rotated, current + 1, skipped}
          :changed_under_us -> {rotated, current, skipped + 1}
        end
      end)

    %{
      table: table,
      column: column,
      scanned: rotated + already_current + skipped_changed,
      rotated: rotated,
      already_current: already_current,
      skipped_changed: skipped_changed
    }
  end

  defp verify_column({_resource, table, attr}) do
    column = "encrypted_#{attr}"

    retired_count =
      table
      |> select_rows(column)
      |> Enum.count(fn {_id, raw} -> tag_of(raw) == Vault.retired_tag() end)

    %{table: table, column: column, retired: retired_count}
  end

  defp rotate_row!(resource, table, column, id, raw) do
    if tag_of(raw) == Vault.current_tag() do
      :already_current
    else
      plaintext =
        raw
        |> Base.decode64!()
        |> Vault.decrypt!()
        |> Ash.Helpers.non_executable_binary_to_term()

      update_row!(table, column, id, raw, AshCloak.do_encrypt(resource, plaintext))
    end
  end

  defp tag_of(raw) do
    case raw |> Base.decode64!() |> Cloak.Tags.Decoder.decode() do
      %{tag: tag} -> tag
      :error -> nil
    end
  end

  defp select_rows(table, column) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Arbiter.Repo,
        "SELECT id, #{column} FROM #{table} WHERE #{column} IS NOT NULL",
        []
      )

    Enum.map(rows, fn [id, raw] -> {id, raw} end)
  end

  @doc """
  Compare-and-swap write: sets `column` to `new_value` only if it still
  holds `old_value` (the value read in the sweep's snapshot). Returns
  `:rotated` on success, `:changed_under_us` when the row moved in between —
  in which case it is left untouched rather than clobbered with a
  re-encryption of the stale value. Public for direct testing; used
  internally by `rotate_row!/5`.
  """
  @spec update_row!(String.t(), String.t(), term(), binary(), binary()) ::
          :rotated | :changed_under_us
  def update_row!(table, column, id, old_value, new_value) do
    # These columns are declared `:binary` (BLOB affinity), but a value's
    # actual SQLite storage class (TEXT vs BLOB) depends on how it was bound
    # at write time, not the column's declared type — Ecto's typed writes
    # bind :binary as BLOB, while a bare Elixir binary bound through raw SQL
    # (as this module and its tests do) binds as TEXT when it happens to be
    # valid text. SQLite never considers a TEXT value equal to a BLOB value
    # even with identical bytes, so both sides are CAST to BLOB here to
    # compare on raw bytes regardless of how each was originally stored.
    %{num_rows: n} =
      Ecto.Adapters.SQL.query!(
        Arbiter.Repo,
        "UPDATE #{table} SET #{column} = ?1 WHERE id = ?2 AND CAST(#{column} AS BLOB) = CAST(?3 AS BLOB)",
        [new_value, id, old_value]
      )

    if n == 1, do: :rotated, else: :changed_under_us
  end
end
