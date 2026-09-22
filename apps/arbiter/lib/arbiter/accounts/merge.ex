defmodule Arbiter.Accounts.Merge do
  @moduledoc """
  `arb account merge <from-slug> --into <into-slug>` (§2.5, P11 —
  `docs/provider-account-design.md`).

  The operationally critical operation in the provider-accounts design: the
  operator created two account rows and later realised they are one plan.
  Per §2.5's table, exactly:

    * `usage_events.provider_account_id` — re-pointed `from -> into`. This is
      *why* historical cost rollups become correct retroactively with no
      re-derivation step — the account id lives on the event, not on a
      materialised rollup (the design rule §2.5 and §6 both insist on).
    * `provider_credentials` — rows move across and stay distinct. If both
      accounts have an *active* credential of the same `kind`, the `from`
      side's is retired first (`ProviderCredential` allows only one active
      row per `(account, kind)`) — its history still moves, just no longer
      live.
    * `anthropic_quotas` / `codex_quotas` / `cloud_code_quotas` — collapsed on
      `(provider_account_id, provider)`, freshest wins, per-column-group for
      `anthropic_quotas` (§6) via `Arbiter.Quota.Rekey`.
    * `workspace_provider_accounts` — re-pointed. A workspace can only ever
      have one row per `(workspace_id, provider)`, so `from` and `into` can
      never both be linked from the same workspace — no conflict is possible.
    * the `from` row — soft-deleted: `merged_into_id` set, `enabled: false`.

  All of it runs inside one `Arbiter.Repo` transaction — a `merge` either
  fully lands or fully doesn't.
  """

  import Ecto.Query
  require Ash.Query

  alias Arbiter.Accounts
  alias Arbiter.Accounts.{ProviderAccount, ProviderCredential}
  alias Arbiter.Quota.Rekey
  alias Arbiter.Repo

  @anthropic_columns ~w(
    utilization_5h reset_5h_at status_5h utilization_7d reset_7d_at status_7d
    representative_claim overage_status captured_at capture_source
    per_model_utilization extra_usage oauth_utilization_5h oauth_utilization_7d
    oauth_captured_at inserted_at updated_at
  )a

  @codex_columns ~w(
    plan session_used_percent session_reset_at weekly_used_percent
    weekly_reset_at limit_reached captured_at inserted_at updated_at
  )a

  @cloud_code_columns ~w(
    plan message used_percent reset_at snapshot captured_at inserted_at
    updated_at
  )a

  @doc """
  Merge `from_ref` into `into_ref` (both accepted by
  `Arbiter.Accounts.get_account/1`). Returns `{:ok, into_account}` on
  success, `{:error, reason}` otherwise — including `:same_account` and
  `:provider_mismatch` (merging across providers makes no sense: the quota
  tables and `workspace_provider_accounts` are provider-specific).
  """
  @spec merge(String.t(), String.t()) :: {:ok, ProviderAccount.t()} | {:error, term()}
  def merge(from_ref, into_ref) do
    with {:ok, from_account} <- Accounts.get_account(from_ref),
         {:ok, into_account} <- Accounts.get_account(into_ref),
         :ok <- validate(from_account, into_account) do
      run(from_account, into_account)
    end
  end

  defp validate(%{id: id}, %{id: id}), do: {:error, :same_account}
  defp validate(%{provider: p}, %{provider: p}), do: :ok
  defp validate(_from, _into), do: {:error, :provider_mismatch}

  defp run(from_account, into_account) do
    Repo.transaction(fn ->
      repoint_usage_events(from_account.id, into_account.id)
      move_credentials(from_account.id, into_account.id)
      collapse_quota(from_account, into_account.id)
      repoint_workspace_links(from_account.id, into_account.id)
      soft_delete!(from_account, into_account.id)
    end)
  rescue
    error -> {:error, error}
  end

  # ---- usage_events --------------------------------------------------------

  defp repoint_usage_events(from_id, into_id) do
    Repo.update_all(
      from(e in "usage_events", where: e.provider_account_id == ^from_id),
      set: [provider_account_id: into_id]
    )

    :ok
  end

  # ---- provider_credentials -------------------------------------------------

  defp move_credentials(from_id, into_id) do
    from_active_kinds = active_kinds(from_id)
    into_active_kinds = active_kinds(into_id)
    conflicting = MapSet.intersection(from_active_kinds, into_active_kinds)

    from_id
    |> credentials_for()
    |> Enum.each(fn credential ->
      credential =
        if credential.active and MapSet.member?(conflicting, credential.kind) do
          Ash.update!(credential, %{}, action: :retire)
        else
          credential
        end

      Ash.update!(credential, %{provider_account_id: into_id}, action: :reassign_account)
    end)

    :ok
  end

  defp credentials_for(account_id) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.read!()
  end

  defp active_kinds(account_id) do
    account_id
    |> credentials_for()
    |> Enum.filter(& &1.active)
    |> MapSet.new(& &1.kind)
  end

  # ---- quota tables (§6) ----------------------------------------------------

  defp collapse_quota(%{provider: :claude, id: from_id}, into_id),
    do:
      collapse_table(
        "anthropic_quotas",
        @anthropic_columns,
        &Rekey.collapse_anthropic/1,
        from_id,
        into_id,
        "claude"
      )

  defp collapse_quota(%{provider: :codex, id: from_id}, into_id),
    do:
      collapse_table(
        "codex_quotas",
        @codex_columns,
        &Rekey.collapse_newest/1,
        from_id,
        into_id,
        "codex"
      )

  defp collapse_quota(%{provider: provider, id: from_id}, into_id)
       when provider in [:gemini_cli, :antigravity] do
    collapse_table(
      "cloud_code_quotas",
      @cloud_code_columns,
      &Rekey.collapse_newest/1,
      from_id,
      into_id,
      to_string(provider)
    )
  end

  # Mirrors the P5 migration's collapse (`Arbiter.Repo.Migrations.RekeyQuotaTablesToProviderAccount`):
  # read both candidate rows raw, collapse in Elixir via the same pure
  # `Arbiter.Quota.Rekey` rules, delete, reinsert. Raw SQL (not the Ash
  # actions) because the merged row must land under a fixed id we control and
  # the two accounts' rows must be read together atomically.
  defp collapse_table(table, columns, collapse_fun, from_id, into_id, provider) do
    cols = ["id", "provider_account_id", "provider"] ++ Enum.map(columns, &to_string/1)
    col_list = Enum.join(cols, ", ")

    %{rows: rows} =
      Repo.query!(
        "SELECT #{col_list} FROM #{table} WHERE provider_account_id IN (?1, ?2) AND provider = ?3",
        [from_id, into_id, provider]
      )

    case rows do
      [] ->
        :ok

      [_single] ->
        Repo.query!(
          "UPDATE #{table} SET provider_account_id = ?1 WHERE provider_account_id = ?2 AND provider = ?3",
          [into_id, from_id, provider]
        )

        :ok

      [_ | _] = rows ->
        keys = Enum.map(cols, &String.to_atom/1)
        maps = Enum.map(rows, &(keys |> Enum.zip(&1) |> Map.new()))
        merged = collapse_fun.(maps) |> Map.put(:updated_at, timestamp())

        Repo.query!(
          "DELETE FROM #{table} WHERE provider_account_id IN (?1, ?2) AND provider = ?3",
          [from_id, into_id, provider]
        )

        insert_cols = ["id", "provider_account_id", "provider"] ++ Enum.map(columns, &to_string/1)

        placeholders =
          insert_cols |> Enum.with_index(1) |> Enum.map_join(", ", fn {_c, i} -> "?#{i}" end)

        values =
          [Ecto.UUID.generate(), into_id, provider] ++ Enum.map(columns, &Map.get(merged, &1))

        Repo.query!(
          "INSERT INTO #{table} (#{Enum.join(insert_cols, ", ")}) VALUES (#{placeholders})",
          values
        )

        :ok
    end
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_naive()
  end

  # ---- workspace_provider_accounts ------------------------------------------

  # A workspace can have at most one row per (workspace_id, provider)
  # (`WorkspaceProviderAccount`'s `workspace_provider` identity), and `from`/
  # `into` share a provider (validated above) — so no workspace can already be
  # linked to both, and this plain re-point can never collide.
  defp repoint_workspace_links(from_id, into_id) do
    Repo.query!(
      "UPDATE workspace_provider_accounts SET provider_account_id = ?1 WHERE provider_account_id = ?2",
      [into_id, from_id]
    )

    :ok
  end

  # ---- the `from` row --------------------------------------------------------

  defp soft_delete!(from_account, into_id) do
    from_account
    |> Ash.Changeset.for_update(:update, %{merged_into_id: into_id, enabled: false})
    |> Ash.update!()

    {:ok, into_account} = Accounts.get_account(into_id)
    into_account
  end
end
