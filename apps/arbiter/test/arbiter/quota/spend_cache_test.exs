defmodule Arbiter.Quota.SpendCacheTest do
  # async: false — a shared, process-independent ETS cache (this module's
  # whole point) would otherwise leak between concurrently-sandboxed tests.
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Quota.SpendCache
  alias Arbiter.Usage.Event

  setup do
    SpendCache.invalidate()
    :ok
  end

  defp query_count(fun) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      ref,
      [:arbiter, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(parent, {:query, ref}) end,
      nil
    )

    fun.()

    count =
      Stream.repeatedly(fn ->
        receive do
          {:query, ^ref} -> :hit
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> length()

    :telemetry.detach(ref)
    count
  end

  test "account_totals/0 and workspace_totals/0 memoize the aggregate until invalidate/0" do
    account = Ash.create!(Arbiter.Accounts.ProviderAccount, %{provider: :claude, slug: "cache-a"})

    Ash.create!(Event, %{
      step: :work,
      provider: "claude",
      provider_account_id: account.id,
      workspace_id: "ws-cache-a",
      cost_usd: 1.0,
      occurred_at: DateTime.utc_now()
    })

    assert_in_delta SpendCache.account_totals()[account.id]["claude"], 1.0, 0.0001
    assert_in_delta SpendCache.workspace_totals()["ws-cache-a"]["claude"], 1.0, 0.0001

    # A second read of the same totals costs no query — served from the cache.
    assert query_count(fn -> SpendCache.account_totals() end) == 0
    assert query_count(fn -> SpendCache.workspace_totals() end) == 0
  end

  test "invalidate/0 forces the next read to recompute" do
    account = Ash.create!(Arbiter.Accounts.ProviderAccount, %{provider: :claude, slug: "cache-b"})

    Ash.create!(Event, %{
      step: :work,
      provider: "claude",
      provider_account_id: account.id,
      cost_usd: 2.0,
      occurred_at: DateTime.utc_now()
    })

    assert_in_delta SpendCache.account_totals()[account.id]["claude"], 2.0, 0.0001

    SpendCache.invalidate()
    assert query_count(fn -> SpendCache.account_totals() end) > 0
  end

  test "inserting a usage event invalidates the cache automatically (bd-4p6pw7)" do
    account = Ash.create!(Arbiter.Accounts.ProviderAccount, %{provider: :claude, slug: "cache-c"})

    # Warm the cache before the event this test cares about exists.
    assert SpendCache.account_totals()[account.id] == nil

    Ash.create!(Event, %{
      step: :work,
      provider: "claude",
      provider_account_id: account.id,
      cost_usd: 5.0,
      occurred_at: DateTime.utc_now()
    })

    assert_in_delta SpendCache.account_totals()[account.id]["claude"], 5.0, 0.0001
  end

  test "Quota.provider_spend/1 and workspace_spend/1 issue no query on a warm cache (bd-4p6pw7)" do
    ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "spend-cache-hook"})
    {:ok, account_id} = Quota.ensure_account_id(ws.id, "claude")

    Ash.create!(Event, %{
      step: :work,
      provider: "claude",
      provider_account_id: account_id,
      workspace_id: ws.id,
      cost_usd: 1.0,
      occurred_at: DateTime.utc_now()
    })

    # Warm the cache once (the "cold mount").
    Quota.provider_spend(account_id)
    Quota.workspace_spend(ws.id)

    # A repeat mount within the TTL — the top-bar hook's steady state — reads
    # no query at all.
    assert query_count(fn -> Quota.provider_spend(account_id) end) == 0
    assert query_count(fn -> Quota.workspace_spend(ws.id) end) == 0
  end

  # bd-4p6pw7's own before/after: `provider_spend/1` and `workspace_spend/1`
  # used to call `Arbiter.Usage.summarize/1` (still here, unchanged — the
  # "before" scan this reproduces is the exact code path they ran, not a
  # simulation of it) once per account and once per workspace. Ten accounts
  # each metering three workspaces — the same order of magnitude as
  # bd-91rxi7's measured "46 queries, one per account/view/workspace" on the
  # live install — cost 20 full-ledger scans the old way; the cached
  # aggregate this task adds costs 2 on a cold cache and 0 on a warm one.
  test "quota-hook-shaped fixture: pre-fix per-entity scans vs. the cached aggregate" do
    accounts =
      for n <- 1..10,
          do: Ash.create!(Arbiter.Accounts.ProviderAccount, %{provider: :claude, slug: "fx-#{n}"})

    workspaces = for n <- 1..3, do: Ash.create!(Arbiter.Tasks.Workspace, %{name: "fx-ws-#{n}"})

    for account <- accounts, ws <- workspaces do
      Ash.create!(Event, %{
        step: :work,
        provider: "claude",
        provider_account_id: account.id,
        workspace_id: ws.id,
        cost_usd: 1.0,
        occurred_at: DateTime.utc_now()
      })
    end

    since = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    before_count =
      query_count(fn ->
        for account <- accounts do
          Arbiter.Usage.summarize(by: :provider, since: since, provider_account_id: account.id)
        end

        for ws <- workspaces do
          Arbiter.Usage.summarize(by: :provider, since: since, workspace_id: ws.id)
        end
      end)

    SpendCache.invalidate()

    cold_count =
      query_count(fn ->
        for account <- accounts, do: Quota.provider_spend(account.id)
        for ws <- workspaces, do: Quota.workspace_spend(ws.id)
      end)

    warm_count =
      query_count(fn ->
        for account <- accounts, do: Quota.provider_spend(account.id)
        for ws <- workspaces, do: Quota.workspace_spend(ws.id)
      end)

    assert before_count == 13
    assert cold_count == 2
    assert warm_count == 0
    assert cold_count <= 3
  end
end
