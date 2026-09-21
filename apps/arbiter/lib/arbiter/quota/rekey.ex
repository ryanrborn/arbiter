defmodule Arbiter.Quota.Rekey do
  @moduledoc """
  Duplicate-collapse rules for the P5 quota re-key
  (`docs/provider-account-design.md` §6).

  The three quota tables were keyed `(workspace_id, provider)` and are keyed
  `(provider_account_id, provider)` from P5 on. Several workspaces that share
  one provider account therefore collapse into a single row, and the
  migration has to decide which values survive.

  The snapshot tables are caches of the latest reading, not time series
  (`Arbiter.Quota.AnthropicQuota`), so freshest-wins loses nothing — **but
  freshest-what**. `anthropic_quotas` is written by two actions with disjoint
  `upsert_fields`, `:upsert` / `:record_oauth_snapshot` (header capture) and
  `:record_oauth_usage` (the narrow oauth layer), which is why the row has two
  independent timestamps. A newest-*row*-wins collapse silently discards a
  fresher oauth block written by the other action, so the collapse is **per
  column group**: header columns from the newest `captured_at`, oauth columns
  from the newest `oauth_captured_at`. `codex_quotas` and `cloud_code_quotas`
  have one writer each and take the whole newest row.

  These are pure functions over plain row maps so the migration and its test
  exercise exactly the same rule. `captured_at` values arrive as `DateTime`s
  from Ash and as strings from the migration's raw SQL read, so
  `compare_captured/2` accepts both.
  """

  @header_columns [
    :utilization_5h,
    :reset_5h_at,
    :status_5h,
    :utilization_7d,
    :reset_7d_at,
    :status_7d,
    :representative_claim,
    :overage_status,
    :captured_at,
    :capture_source
  ]

  @oauth_columns [
    :per_model_utilization,
    :extra_usage,
    :oauth_utilization_5h,
    :oauth_utilization_7d,
    :oauth_captured_at
  ]

  @doc "The `anthropic_quotas` columns written by the header-capture path."
  @spec header_columns() :: [atom()]
  def header_columns, do: @header_columns

  @doc "The `anthropic_quotas` columns written by the narrow oauth path."
  @spec oauth_columns() :: [atom()]
  def oauth_columns, do: @oauth_columns

  @doc """
  Collapse the `anthropic_quotas` rows that now share one
  `(provider_account_id, provider)` key into a single row, **per column
  group** (§6).

  Non-quota columns (`id`, `provider`, `provider_account_id`, timestamps not
  in either group) come from the header winner, which is the row the fleet
  would have been gating off.
  """
  @spec collapse_anthropic([map()]) :: map()
  def collapse_anthropic([row]), do: row

  def collapse_anthropic([_ | _] = rows) do
    header = newest_by(rows, :captured_at)
    oauth = newest_by(rows, :oauth_captured_at)

    header
    |> Map.merge(Map.take(header, present(header, @header_columns)))
    |> Map.merge(Map.take(oauth, present(oauth, @oauth_columns)))
  end

  @doc """
  Collapse rows for a single-writer table (`codex_quotas`,
  `cloud_code_quotas`): the whole newest-`captured_at` row wins.
  """
  @spec collapse_newest([map()]) :: map()
  def collapse_newest([row]), do: row
  def collapse_newest([_ | _] = rows), do: newest_by(rows, :captured_at)

  # The row with the greatest non-nil value of `key`. A row that has no
  # timestamp for that group never wins it — an absent oauth block must not
  # erase a present one just because its row is otherwise newer. Falls back to
  # the first row when no row has the timestamp at all, so the caller always
  # gets the full column set.
  defp newest_by([first | _] = rows, key) do
    rows
    |> Enum.filter(&(not is_nil(Map.get(&1, key))))
    |> case do
      [] -> first
      candidates -> Enum.reduce(candidates, &if(compare_captured(&1, &2, key) == :gt, do: &1, else: &2))
    end
  end

  defp compare_captured(a, b, key), do: compare_ts(Map.get(a, key), Map.get(b, key))

  defp compare_ts(nil, nil), do: :eq
  defp compare_ts(nil, _), do: :lt
  defp compare_ts(_, nil), do: :gt

  defp compare_ts(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)

  defp compare_ts(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: NaiveDateTime.compare(a, b)

  defp compare_ts(a, b) when is_binary(a) and is_binary(b) do
    case {parse_ts(a), parse_ts(b)} do
      {{:ok, pa}, {:ok, pb}} -> NaiveDateTime.compare(pa, pb)
      # Both are the same fixed-width format SQLite stores, so a lexical
      # comparison is a correct fallback for anything the parser rejects.
      _ -> cond_compare(a, b)
    end
  end

  defp compare_ts(a, b), do: cond_compare(a, b)

  defp parse_ts(<<_::binary>> = s) do
    case NaiveDateTime.from_iso8601(s) do
      {:ok, ndt} -> {:ok, ndt}
      _ -> :error
    end
  end

  defp cond_compare(a, b) when a > b, do: :gt
  defp cond_compare(a, b) when a < b, do: :lt
  defp cond_compare(_, _), do: :eq

  # Only overwrite a column group with keys the winner actually carries: a
  # row map read out of a narrower SELECT must not inject `nil`s for columns
  # the caller never asked for.
  defp present(row, columns), do: Enum.filter(columns, &Map.has_key?(row, &1))
end
