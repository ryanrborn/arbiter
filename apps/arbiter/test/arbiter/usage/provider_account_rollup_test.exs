defmodule Arbiter.Usage.ProviderAccountRollupTest do
  @moduledoc """
  Provider accounts P10 (`docs/provider-account-design.md` §8, bd-icwk2k):
  `Usage.summarize(by: :provider_account)` and its `:provider_account_id`
  filter read `usage_events.provider_account_id` directly (P9,
  `apps/arbiter/lib/arbiter/usage/event.ex`) instead of the pre-P9
  workspace-join approximation.

  The falsifiable claim this pins: a `source: :probe` or `:preflight` row
  carries no `workspace_id` but always carries `provider_account_id` (§8), so
  it must show up in `arb usage --by account` / `--account <slug>` — dropping
  it is exactly the under-reporting bias bd-adyhvn measured (unmetered probes
  consume window percentage without contributing ledger dollars).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Usage
  alias Arbiter.Usage.Event

  defp account!(provider \\ :claude) do
    n = System.unique_integer([:positive])

    Ash.create!(ProviderAccount, %{
      provider: provider,
      slug: "p10-acct-#{n}",
      label: "P10 account #{n}"
    })
  end

  defp task_event!(account_id, ws_id, cost) do
    Ash.create!(Event, %{
      task_id: "bd-p10-#{System.unique_integer([:positive])}",
      source: :task,
      workspace_id: ws_id,
      provider_account_id: account_id,
      step: :work,
      provider: "claude",
      cost_usd: cost,
      occurred_at: DateTime.utc_now()
    })
  end

  defp probe_event!(account_id, cost, source \\ :preflight) do
    Ash.create!(Event, %{
      task_id: nil,
      source: source,
      workspace_id: nil,
      provider_account_id: account_id,
      step: :other,
      provider: "claude",
      cost_usd: cost,
      occurred_at: DateTime.utc_now()
    })
  end

  describe "group_events(:provider_account) reads the column directly (P9+)" do
    test "a probe row with no workspace_id is grouped under its account" do
      account = account!()
      probe_event!(account.id, 0.02, :preflight)

      assert {:ok, rows} = Usage.summarize(by: :provider_account)
      row = Enum.find(rows, &(&1.group == account.id))
      assert row.rows == 1
      assert_in_delta row.total_cost_usd, 0.02, 0.0001
    end

    test "task and probe rows on the same account both contribute to the total" do
      account = account!()
      task_event!(account.id, "ws-fake-1", 1.0)
      probe_event!(account.id, 0.5, :preflight)
      probe_event!(account.id, 0.25, :probe)

      assert {:ok, rows} = Usage.summarize(by: :provider_account)
      row = Enum.find(rows, &(&1.group == account.id))
      assert row.rows == 3
      assert_in_delta row.total_cost_usd, 1.75, 0.0001
    end

    test "a row with no provider_account_id lands in the (none) sentinel" do
      probe_event!(nil, 1.0, :preflight)

      assert {:ok, rows} = Usage.summarize(by: :provider_account)
      assert Enum.any?(rows, &(&1.group == "(none)"))
    end

    test "rows on another account are not counted" do
      mine = account!()
      theirs = account!()
      probe_event!(mine.id, 1.0)
      probe_event!(theirs.id, 9.0)

      assert {:ok, rows} = Usage.summarize(by: :provider_account)
      mine_row = Enum.find(rows, &(&1.group == mine.id))
      theirs_row = Enum.find(rows, &(&1.group == theirs.id))
      assert_in_delta mine_row.total_cost_usd, 1.0, 0.0001
      assert_in_delta theirs_row.total_cost_usd, 9.0, 0.0001
    end
  end

  describe ":provider_account_id filter reads the column directly (P9+)" do
    test "restricting to one account includes its probe rows and drops others'" do
      mine = account!()
      theirs = account!()
      task_event!(mine.id, "ws-fake-2", 1.0)
      probe_event!(mine.id, 0.5)
      probe_event!(theirs.id, 9.0)

      assert {:ok, rows} =
               Usage.summarize(by: :provider_account, provider_account_id: mine.id)

      assert [%{group: group, rows: 2, total_cost_usd: cost}] = rows
      assert group == mine.id
      assert_in_delta cost, 1.5, 0.0001
    end

    test "the filter also narrows other groupings (e.g. :source) to the account" do
      mine = account!()
      theirs = account!()
      probe_event!(mine.id, 0.5, :preflight)
      probe_event!(theirs.id, 9.0, :preflight)

      assert {:ok, rows} = Usage.summarize(by: :source, provider_account_id: mine.id)
      assert [%{group: "preflight", rows: 1}] = rows
    end
  end
end
