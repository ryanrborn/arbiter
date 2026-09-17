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
  block — nothing here discovers them automatically.

  ## Safety

  Only counts and row ids ever reach `Mix.shell()` or a return value —
  decrypted plaintext lives strictly inside `rotate_row!/5` and is
  immediately re-encrypted, never logged or written to disk unencrypted.
  """

  alias Arbiter.Vault

  @columns [
    {Arbiter.Tasks.Workspace, "workspaces", :secrets},
    {Arbiter.Tasks.Workspace, "workspaces", :worker_env},
    {Arbiter.Accounts.ProviderCredential, "provider_credentials", :secret}
  ]

  @type sweep_report :: %{
          table: String.t(),
          column: String.t(),
          scanned: non_neg_integer(),
          rotated: non_neg_integer(),
          already_current: non_neg_integer()
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

    {rotated, already_current} =
      table
      |> select_rows(column)
      |> Enum.reduce({0, 0}, fn {id, raw}, {rotated, current} ->
        case rotate_row!(resource, table, column, id, raw) do
          :rotated -> {rotated + 1, current}
          :already_current -> {rotated, current + 1}
        end
      end)

    %{
      table: table,
      column: column,
      scanned: rotated + already_current,
      rotated: rotated,
      already_current: already_current
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

      update_row!(table, column, id, AshCloak.do_encrypt(resource, plaintext))
      :rotated
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

  defp update_row!(table, column, id, new_value) do
    Ecto.Adapters.SQL.query!(
      Arbiter.Repo,
      "UPDATE #{table} SET #{column} = ?1 WHERE id = ?2",
      [new_value, id]
    )

    :ok
  end
end
