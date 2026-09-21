defmodule Arbiter.Quota.AccountWideHoldTest do
  @moduledoc """
  Provider accounts P7 (`docs/provider-account-design.md` §4.2, §4.4): the
  quota hold is account-wide, with no opt-in flag.

  Three properties are pinned here:

    1. **The hold is account-wide.** Two workspaces metered under one
       exhausted account are *both* held. The bug this phase closes is
       `default` holding while `vstim` keeps dispatching against the very
       same exhausted budget (§4.2).
    2. **Thresholds are `min(account, workspace)`.** The account carries the
       default; a workspace may tighten it and may never loosen it.
    3. **Overage spend sums by account.** `windowed_spend/2` aggregates every
       workspace metered under the account, because the plan whose cap was
       passed is the account's.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Overage
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage
  alias Arbiter.Usage.Event
  alias Arbiter.Workflows.QuotaGate

  defp workspace!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Ash.create!(
      Workspace,
      Map.merge(%{name: "p7-ws-#{n}", prefix: "p7w#{n}"}, attrs)
    )
  end

  defp account!(quota_config \\ %{}) do
    n = System.unique_integer([:positive])

    Ash.create!(ProviderAccount, %{
      provider: :claude,
      slug: "p7-acct-#{n}",
      label: "P7 account #{n}",
      quota_config: quota_config
    })
  end

  defp link!(%Workspace{} = ws, %ProviderAccount{} = account) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })
  end

  defp exhausted_snapshot!(%ProviderAccount{} = account) do
    Ash.create!(AnthropicQuota, %{
      provider_account_id: account.id,
      provider: "claude",
      utilization_5h: 0.99,
      status_5h: "rejected",
      captured_at: DateTime.utc_now()
    })
  end

  defp usage_event!(ws_id, cost, provider \\ "claude") do
    Ash.create!(Event, %{
      workspace_id: ws_id,
      task_id: "bd-p7-#{System.unique_integer([:positive])}",
      step: :work,
      provider: provider,
      cost_usd: cost,
      occurred_at: DateTime.utc_now()
    })
  end

  defp codex_account!() do
    n = System.unique_integer([:positive])

    Ash.create!(ProviderAccount, %{
      provider: :codex,
      slug: "p7-codex-#{n}",
      label: "P7 codex account #{n}"
    })
  end

  defp link_codex!(%Workspace{} = ws, %ProviderAccount{} = account) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :codex,
      provider_account_id: account.id
    })
  end

  describe "QuotaGate callback — keyed by the provider account (§5 row 22)" do
    test "both workspaces on one exhausted account are held" do
      account = account!()
      a = workspace!()
      b = workspace!()
      link!(a, account)
      link!(b, account)
      exhausted_snapshot!(account)

      assert QuotaGate.Default.quota_headroom(account.id, workspace_id: a.id) == 0
      assert QuotaGate.Default.quota_headroom(account.id, workspace_id: b.id) == 0
    end

    test "a healthy account holds neither workspace" do
      account = account!()
      a = workspace!()
      b = workspace!()
      link!(a, account)
      link!(b, account)

      Ash.create!(AnthropicQuota, %{
        provider_account_id: account.id,
        provider: "claude",
        utilization_5h: 0.10,
        status_5h: "allowed",
        captured_at: DateTime.utc_now()
      })

      assert QuotaGate.Default.quota_headroom(account.id, workspace_id: a.id) == :unlimited
      assert QuotaGate.Default.quota_headroom(account.id, workspace_id: b.id) == :unlimited
    end

    test "an unknown account fails open" do
      assert QuotaGate.Default.quota_headroom(nil, []) == :unlimited
      assert QuotaGate.Default.quota_headroom("", []) == :unlimited
    end

    test "a :continue workspace still defers to the dispatch seam" do
      account = account!()
      ws = workspace!(%{config: %{"quota" => %{"on_exhaustion" => "continue"}}})
      link!(ws, account)
      exhausted_snapshot!(account)

      assert QuotaGate.Default.quota_headroom(account.id, workspace_id: ws.id) == :unlimited
    end

    test "a workspace's stricter threshold holds it while the account's own default would not" do
      account = account!(%{"throttle_threshold" => 0.90})
      strict = workspace!(%{config: %{"quota" => %{"throttle_threshold" => 0.50}}})
      relaxed = workspace!()
      link!(strict, account)
      link!(relaxed, account)

      Ash.create!(AnthropicQuota, %{
        provider_account_id: account.id,
        provider: "claude",
        utilization_5h: 0.60,
        status_5h: "allowed",
        captured_at: DateTime.utc_now()
      })

      assert QuotaGate.Default.quota_headroom(account.id, workspace_id: strict.id) == 0
      assert QuotaGate.Default.quota_headroom(account.id, workspace_id: relaxed.id) == :unlimited
    end
  end

  describe "threshold resolution is min(account, workspace) (§4.2)" do
    test "the account default applies when the workspace sets nothing" do
      account = account!(%{"throttle_threshold" => 0.70})
      assert Gate.threshold({account, workspace!()}) == 0.70
    end

    test "a stricter workspace override tightens the account default" do
      account = account!(%{"throttle_threshold" => 0.90})
      ws = workspace!(%{config: %{"quota" => %{"throttle_threshold" => 0.50}}})
      assert Gate.threshold({account, ws}) == 0.50
    end

    test "a looser workspace override does not take effect" do
      account = account!(%{"throttle_threshold" => 0.50})
      ws = workspace!(%{config: %{"quota" => %{"throttle_threshold" => 0.95}}})
      assert Gate.threshold({account, ws}) == 0.50
    end

    test "weekly_threshold takes the stricter of account and workspace" do
      account = account!(%{"weekly_threshold" => 0.90})
      stricter = workspace!(%{config: %{"quota" => %{"weekly_threshold" => 0.70}}})
      looser = workspace!(%{config: %{"quota" => %{"weekly_threshold" => 0.99}}})

      assert Gate.weekly_threshold({account, stricter}) == 0.70
      assert Gate.weekly_threshold({account, looser}) == 0.90
    end

    test "weekly_warning_policy can be tightened to :hold but never loosened to :ignore" do
      holding = account!(%{"weekly_warning_policy" => "hold"})
      ignoring = account!(%{"weekly_warning_policy" => "ignore"})
      ws_ignore = workspace!(%{config: %{"quota" => %{"weekly_warning_policy" => "ignore"}}})
      ws_hold = workspace!(%{config: %{"quota" => %{"weekly_warning_policy" => "hold"}}})

      # the workspace cannot relax the account's :hold
      assert Gate.weekly_warning_policy({holding, ws_ignore}) == :hold
      # the workspace may tighten the account's :ignore
      assert Gate.weekly_warning_policy({ignoring, ws_hold}) == :hold
      assert Gate.weekly_warning_policy({ignoring, ws_ignore}) == :ignore
    end

    test "a workspace-only install keeps its own override verbatim" do
      ws = workspace!(%{config: %{"quota" => %{"throttle_threshold" => 0.95}}})
      assert Gate.threshold(ws) == 0.95
      assert Gate.threshold({nil, ws}) == 0.95
    end

    test "an account-only policy applies with no workspace at all" do
      assert Gate.threshold({account!(%{"throttle_threshold" => 0.40}), nil}) == 0.40
    end
  end

  describe "over_cap?/2 reads the account's snapshot against the merged policy" do
    test "the account's stricter throttle_threshold holds a workspace that sets none" do
      account = account!(%{"throttle_threshold" => 0.50})
      ws = workspace!()

      quota =
        Ash.create!(AnthropicQuota, %{
          provider_account_id: account.id,
          provider: "claude",
          utilization_5h: 0.60,
          status_5h: "allowed",
          captured_at: DateTime.utc_now()
        })

      assert Gate.over_cap?(quota, {account, ws})
      refute Gate.over_cap?(quota, {nil, ws})
    end
  end

  describe "Overage.windowed_spend/2 sums by account (§5 row 9)" do
    test "spend from every workspace on the account aggregates into one figure" do
      account = account!()
      a = workspace!()
      b = workspace!()
      link!(a, account)
      link!(b, account)

      usage_event!(a.id, 1.25)
      usage_event!(b.id, 2.75)

      assert_in_delta Overage.windowed_spend(account, nil), 4.0, 0.0001
      assert_in_delta Overage.windowed_spend(account.id, nil), 4.0, 0.0001
    end

    test "spend on another account is not counted" do
      account = account!()
      other = account!()
      mine = workspace!()
      theirs = workspace!()
      link!(mine, account)
      link!(theirs, other)

      usage_event!(mine.id, 1.0)
      usage_event!(theirs.id, 9.0)

      assert_in_delta Overage.windowed_spend(account, nil), 1.0, 0.0001
    end

    test "a workspace's spend on its *other* provider account is not counted" do
      # Observed on the live install: one workspace is metered under a Claude
      # account and a Codex account at once. Narrowing the ledger to "this
      # account's workspaces" therefore still sweeps in the other account's
      # spend — the Codex account reported $125 of Claude spend. The account
      # a row belongs to is decided per event, by its provider.
      claude = account!()
      codex = codex_account!()
      ws = workspace!()
      link!(ws, claude)
      link_codex!(ws, codex)

      usage_event!(ws.id, 100.0, "claude")
      usage_event!(ws.id, 7.0, "openai")

      assert_in_delta Overage.windowed_spend(codex, nil), 7.0, 0.0001
      assert_in_delta Overage.windowed_spend(claude, nil), 100.0, 0.0001
    end

    test "an unknown account spends nothing rather than raising" do
      assert Overage.windowed_spend(nil, nil) == 0.0
      assert Overage.windowed_spend("not-an-account", nil) == 0.0
    end
  end

  describe "Usage.summarize(by: :provider_account)" do
    test "groups rows by the account their workspace is metered under" do
      account = account!()
      a = workspace!()
      b = workspace!()
      link!(a, account)
      link!(b, account)

      usage_event!(a.id, 1.0)
      usage_event!(b.id, 2.0)

      assert {:ok, rows} = Usage.summarize(by: :provider_account)
      row = Enum.find(rows, &(&1.group == account.id))
      assert row.rows == 2
      assert_in_delta row.total_cost_usd, 3.0, 0.0001
    end

    test "restricting to one account drops every other account's rows" do
      account = account!()
      other = account!()
      mine = workspace!()
      theirs = workspace!()
      link!(mine, account)
      link!(theirs, other)

      usage_event!(mine.id, 1.0)
      usage_event!(theirs.id, 9.0)

      assert {:ok, rows} = Usage.summarize(by: :provider_account, provider_account_id: account.id)
      assert [%{group: group, rows: 1}] = rows
      assert group == account.id
    end

    test "restricting to one account returns only that account's group" do
      claude = account!()
      codex = codex_account!()
      ws = workspace!()
      link!(ws, claude)
      link_codex!(ws, codex)

      usage_event!(ws.id, 100.0, "claude")
      usage_event!(ws.id, 7.0, "openai")

      assert {:ok, [%{group: group, rows: 1, total_cost_usd: cost}]} =
               Usage.summarize(by: :provider_account, provider_account_id: codex.id)

      assert group == codex.id
      assert_in_delta cost, 7.0, 0.0001
    end

    test "a row with no recorded provider falls back to the workspace's default provider" do
      # `usage_events.provider` is nullable, and pre-P7 `windowed_spend/2`
      # counted every row the workspace had regardless of provider. Dropping
      # such a row from the account rollup would silently under-report
      # overage and suppress the alert, so it is attributed to the account
      # the workspace actually dispatches on — the same provider the gate
      # reads the snapshot for.
      account = account!()
      ws = workspace!()
      link!(ws, account)

      Ash.create!(Event, %{
        workspace_id: ws.id,
        task_id: "bd-p7-noprov",
        step: :work,
        provider: nil,
        cost_usd: 3.0,
        occurred_at: DateTime.utc_now()
      })

      assert {:ok, [%{group: group, rows: 1}]} =
               Usage.summarize(by: :provider_account, provider_account_id: account.id)

      assert group == account.id
      assert_in_delta Overage.windowed_spend(account, nil), 3.0, 0.0001
    end

    test "a row whose workspace has no account lands in the (none) sentinel" do
      usage_event!(workspace!().id, 1.0)

      assert {:ok, rows} = Usage.summarize(by: :provider_account)
      assert Enum.any?(rows, &(&1.group == "(none)"))
    end

    test ":provider_account is an acceptable grouping" do
      assert :provider_account in Usage.acceptable_groupings()
    end
  end
end
