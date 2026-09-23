defmodule Arbiter.Quota.ProviderSpendTest do
  @moduledoc """
  Provider accounts P10 (`docs/provider-account-design.md` §8, bd-icwk2k):
  `Quota.provider_spend/1` is the account total `arb quota --account` prints.

  Pre-P9 it summed `workspace_spend/1` over the account's workspaces, which
  by construction excludes probe/pre-flight rows (`workspace_id: nil`) —
  exactly the under-reporting bias bd-adyhvn measured (unmetered probes
  consume window percentage without contributing ledger dollars). Now that
  `usage_events.provider_account_id` is a real column (P9), the account total
  must be read straight off it so those rows count.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  defp workspace!(name \\ "default") do
    Ash.create!(Workspace, %{name: name})
  end

  defp account!(provider \\ :claude) do
    n = System.unique_integer([:positive])
    Ash.create!(ProviderAccount, %{provider: provider, slug: "spend-#{n}", label: "acct #{n}"})
  end

  defp task_event!(account_id, ws_id, provider, cost) do
    Ash.create!(Event, %{
      task_id: "bd-spend-#{System.unique_integer([:positive])}",
      source: :task,
      step: :work,
      provider: provider,
      provider_account_id: account_id,
      workspace_id: ws_id,
      cost_usd: cost,
      occurred_at: DateTime.utc_now()
    })
  end

  defp preflight_event!(account_id, provider, cost) do
    Ash.create!(Event, %{
      task_id: nil,
      source: :preflight,
      step: :other,
      provider: provider,
      provider_account_id: account_id,
      workspace_id: nil,
      cost_usd: cost,
      occurred_at: DateTime.utc_now()
    })
  end

  describe "provider_spend/1" do
    test "sums task spend across every workspace metered under the account" do
      account = account!()
      a = workspace!("a")
      b = workspace!("b")
      task_event!(account.id, a.id, "claude", 1.0)
      task_event!(account.id, b.id, "claude", 2.0)

      spend = Quota.provider_spend(account.id)
      assert_in_delta spend["claude"], 3.0, 0.0001
    end

    test "includes probe/pre-flight rows, which carry no workspace_id (§8)" do
      account = account!()
      ws = workspace!()
      task_event!(account.id, ws.id, "claude", 1.0)
      preflight_event!(account.id, "claude", 0.5)

      spend = Quota.provider_spend(account.id)
      assert_in_delta spend["claude"], 1.5, 0.0001
    end

    test "an account with only probe spend still reports it" do
      account = account!()
      preflight_event!(account.id, "claude", 0.25)

      spend = Quota.provider_spend(account.id)
      assert_in_delta spend["claude"], 0.25, 0.0001
    end

    test "another account's spend is not counted" do
      mine = account!()
      theirs = account!()
      preflight_event!(mine.id, "claude", 1.0)
      preflight_event!(theirs.id, "claude", 9.0)

      spend = Quota.provider_spend(mine.id)
      assert_in_delta spend["claude"], 1.0, 0.0001
    end

    test "a nil account spends nothing rather than summing the whole ledger" do
      preflight_event!(account!().id, "claude", 5.0)
      assert Quota.provider_spend(nil) == %{}
    end
  end
end
