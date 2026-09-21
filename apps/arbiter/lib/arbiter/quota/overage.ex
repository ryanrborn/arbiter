defmodule Arbiter.Quota.Overage do
  @moduledoc """
  Overage-spend accounting for `:continue`-mode dispatch (bd-7cd38f).

  When a workspace dispatches past the Anthropic plan cap (see
  `Arbiter.Quota.Gate.Continue`), we account the overage as the **provider
  account's** spend over the current 5h window, read straight from the
  token-cost ledger (`Arbiter.Usage.summarize/1`). This is the zero-migration
  v1 approach from the bd-3qcd8y design: a windowed sum of `cost_usd`, not a
  per-request tag.

  The sum is `by: :provider_account` since P7
  (`docs/provider-account-design.md` §5 row 9) — the plan that was exhausted
  is the account's, so every workspace metered under it contributes to the
  overage figure, and the window comes from the account's snapshot.

  The window is `[reset_5h_at - 5h, now]` — i.e. spend since the current 5h
  window opened. When the snapshot carries no `reset_5h_at`, we fall back to the
  trailing 5 hours from now.
  """

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Usage

  @five_hours_seconds 5 * 60 * 60

  @doc """
  The **account's** total spend (USD) over the current 5h window — the figure
  the overage indicator and alert threshold compare against. Returns `0.0` on
  any read error so accounting never disrupts dispatch.

  Keyed by the provider account since P7 (§5 row 9): the plan whose cap was
  passed is the account's, so the spend that ran past it is every workspace's
  on that account, not just the one whose dispatch happened to trip the gate.
  Accepts a `ProviderAccount`, a bare account id, or anything else (which
  spends `0.0`).
  """
  @spec windowed_spend(
          ProviderAccount.t() | String.t() | nil,
          Snapshot.t() | AnthropicQuota.t() | map() | nil
        ) :: float()
  def windowed_spend(account, quota) do
    case account_id(account) do
      nil ->
        0.0

      id ->
        case Usage.summarize(by: :provider_account, since: window_start(quota), provider_account_id: id) do
          {:ok, rows} -> Enum.reduce(rows, 0.0, fn r, acc -> acc + (r.total_cost_usd || 0.0) end)
          _ -> 0.0
        end
    end
  rescue
    _ -> 0.0
  end

  defp account_id(%ProviderAccount{id: id}), do: id
  defp account_id(id) when is_binary(id) and id != "", do: id
  defp account_id(_), do: nil

  @doc """
  Start of the current 5h window as a `DateTime`. Derived from the snapshot's
  primary-window reset (the window opens 5h before it resets); falls back to
  `now - 5h`.

  Accepts a normalized `Arbiter.Quota.Gate.Snapshot` (any provider) as well as a
  raw `AnthropicQuota` row. The 5h span is Anthropic's; for Codex / Google —
  which have no paid-overage passthrough — this is only ever the accounting
  window for the alert figure, so the trailing-5h approximation is deliberate.
  """
  @spec window_start(Snapshot.t() | AnthropicQuota.t() | nil) :: DateTime.t()
  def window_start(%AnthropicQuota{reset_5h_at: %DateTime{} = reset}) do
    DateTime.add(reset, -@five_hours_seconds, :second)
  end

  def window_start(%Snapshot{reset_at: %DateTime{} = reset}) do
    DateTime.add(reset, -@five_hours_seconds, :second)
  end

  def window_start(_quota) do
    DateTime.add(DateTime.utc_now(), -@five_hours_seconds, :second)
  end
end
