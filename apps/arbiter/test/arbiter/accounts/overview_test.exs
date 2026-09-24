defmodule Arbiter.Accounts.OverviewTest do
  @moduledoc """
  The read model behind `/providers` (bd-cb86s4): one row per provider account
  with its workspaces, credentials, live concurrency, quota, credential health
  and 30-day usage.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.{Overview, ProviderAccount}
  alias Arbiter.Agents.{AuthHold, Claude, Codex, CredentialWatchdog, Gemini}
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event
  alias Arbiter.Worker.Registry, as: WorkerRegistry
  alias Arbiter.Worker.StopReason

  defp workspace!(name), do: Ash.create!(Workspace, %{name: name, prefix: "ov"})

  defp account!(provider, slug, attrs \\ %{}),
    do: Ash.create!(ProviderAccount, Map.merge(%{provider: provider, slug: slug}, attrs))

  defp event!(account, attrs) do
    base = %{
      task_id: "bd-ov-#{System.unique_integer([:positive])}",
      source: :task,
      repo: "arbiter",
      workspace_id: "ws-ov",
      step: :work,
      provider_account_id: account.id,
      occurred_at: DateTime.utc_now()
    }

    Ash.create!(Event, Map.merge(base, attrs))
  end

  defp row(rows, account), do: Enum.find(rows, &(&1.account.id == account.id))

  # A private AuthHold + CredentialWatchdog pair, so nothing here touches the
  # application singletons (same shape as `Arbiter.Agents.AuthHoldTest`).
  defp start_pair do
    {:ok, watchdog} =
      start_supervised(%{
        id: make_ref(),
        start:
          {CredentialWatchdog, :start_link,
           [[name: nil, enabled: false, adapters: [Claude, Codex]]]}
      })

    {:ok, hold} =
      start_supervised(%{
        id: make_ref(),
        start: {AuthHold, :start_link, [[name: nil, credential_watchdog: watchdog]]}
      })

    :ok = CredentialWatchdog.set_auth_hold(hold, watchdog)
    {hold, watchdog}
  end

  defp auth_reason do
    %StopReason{
      category: :auth_expired,
      summary: "API Error: 401",
      remediation: "Re-authenticate",
      exit_status: 1,
      signal: nil
    }
  end

  describe "list/1 — the account rows" do
    test "one row per non-merged account, with its attached workspaces by name" do
      ws = workspace!("ov-attached")
      account = account!(:claude, "ov-main", %{max_concurrent: 3})
      from = account!(:claude, "ov-merged-away")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id, share: 2)
      {:ok, _} = Accounts.merge_accounts(from.id, account.id)

      rows = Overview.list()

      assert %{account: %{slug: "ov-main", max_concurrent: 3}, workspaces: [link]} =
               row(rows, account)

      assert link.workspace_id == ws.id
      assert link.workspace_name == "ov-attached"
      assert link.share == 2
      refute row(rows, from)
    end

    test "credentials are active-only metadata — the secret is never on the row" do
      account = account!(:claude, "ov-creds")

      {:ok, _} =
        Accounts.rotate_credential(account.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "sk-ant-oat01-first"
        })

      {:ok, _} =
        Accounts.rotate_credential(account.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "sk-ant-oat01-second"
        })

      assert %{credentials: [credential]} = row(Overview.list(), account)
      assert credential.kind == :oauth_token
      assert credential.env_var == "CLAUDE_CODE_OAUTH_TOKEN"
      assert byte_size(credential.fingerprint) == 12
      refute Map.has_key?(credential, :secret)
      refute Map.has_key?(credential, :encrypted_secret)
      refute inspect(credential) =~ "sk-ant-oat01"
    end

    test "live count is the registry-derived Concurrency.live_count/1" do
      ws = workspace!("ov-live")
      account = account!(:claude, "ov-live", %{max_concurrent: 4})
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)

      test = self()

      pid =
        spawn(fn ->
          {:ok, _} = Registry.register(WorkerRegistry, "ov-fake-worker", nil)
          :ok = WorkerRegistry.put_dispatch("ov-fake-worker", ws.id, "claude")
          send(test, :registered)
          receive do: (:stop -> :ok)
        end)

      assert_receive :registered
      on_exit(fn -> send(pid, :stop) end)

      assert %{live_count: 1, max_concurrent: 4} = row(Overview.list(), account)
    end

    test "quota views carry the account's gate policy, for the paced-gate pace math" do
      account = account!(:claude, "ov-quota", %{quota_config: %{"threshold_mode" => "paced"}})

      Ash.create!(
        AnthropicQuota,
        %{
          provider_account_id: account.id,
          provider: "claude",
          captured_at: DateTime.utc_now(),
          utilization_5h: 0.4,
          reset_5h_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        action: :record_oauth_snapshot
      )

      assert %{quotas: [view]} = row(Overview.list(), account)
      assert view.provider == "claude"
      assert view.utilization_5h == 0.4
      assert %{policy: {%ProviderAccount{id: id}, nil}, enforcing?: true} = view.gate_policy
      assert id == account.id
    end
  end

  describe "list/1 — 30-day usage and cost" do
    test "sums the account's last 30 days of usage and prices it" do
      account = account!(:claude, "ov-cost")
      other = account!(:claude, "ov-cost-other")
      event!(account, %{provider: "claude", cost_usd: 1.25, tokens_in: 100, tokens_out: 50})
      event!(account, %{provider: "claude", cost_usd: 0.75, tokens_in: 10, tokens_out: 5})

      event!(account, %{
        provider: "claude",
        cost_usd: 99.0,
        occurred_at: DateTime.add(DateTime.utc_now(), -31 * 86_400, :second)
      })

      event!(other, %{provider: "claude", cost_usd: 7.0})

      assert %{usage: usage} = row(Overview.list(), account)
      assert usage.rows == 2
      assert usage.tokens == 165
      assert_in_delta usage.cost_usd, 2.0, 1.0e-9
      assert usage.priced?
    end

    test "an account with no usage on a priced provider reads $0, not n/a" do
      account = account!(:codex, "ov-idle")
      assert %{usage: %{rows: 0, cost_usd: +0.0, priced?: true}} = row(Overview.list(), account)
    end

    test "an unpriced provider reads n/a (nil cost), with or without usage" do
      idle = account!(:antigravity, "ov-agy-idle")
      busy = account!(:antigravity, "ov-agy-busy")
      event!(busy, %{provider: "gemini", cost_usd: nil, tokens_in: 10, tokens_out: 1})

      rows = Overview.list()
      assert %{usage: %{rows: 0, cost_usd: nil, priced?: false}} = row(rows, idle)
      assert %{usage: %{rows: 1, cost_usd: nil, priced?: false}} = row(rows, busy)
    end
  end

  describe "list/1 — credential health" do
    test "an account with no active credential is :no_credential" do
      account = account!(:claude, "ov-bare")
      {hold, watchdog} = start_pair()

      assert %{health: %{state: :no_credential}} =
               row(Overview.list(auth_hold: hold, watchdog: watchdog), account)
    end

    test "an open auth hold on the provider's adapter wins over a present credential" do
      account = account!(:claude, "ov-held")

      {:ok, _} =
        Accounts.rotate_credential(account.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "sk-ant-oat01-held"
        })

      {hold, watchdog} = start_pair()
      assert %{health: %{state: :ok}} = row(Overview.list(auth_hold: hold, watchdog: watchdog), account)

      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :opened = AuthHold.record_death(Claude, auth_reason(), hold)
      _ = :sys.get_state(watchdog)

      assert %{health: %{state: :auth_hold, auth_hold: %{deaths: 2}}} =
               row(Overview.list(auth_hold: hold, watchdog: watchdog), account)
    end

    test "a watchdog expiry without a hold reads :expired" do
      account = account!(:codex, "ov-expired")
      {hold, watchdog} = start_pair()
      CredentialWatchdog.mark_expired(Codex, auth_reason(), watchdog, :periodic_probe)
      _ = :sys.get_state(watchdog)

      assert %{health: %{state: :expired}} =
               row(Overview.list(auth_hold: hold, watchdog: watchdog), account)
    end

    test "gemini_cli and antigravity accounts read the shared Gemini adapter" do
      assert Overview.adapter(:gemini_cli) == Gemini
      assert Overview.adapter(:antigravity) == Gemini
      assert Overview.adapter(:claude) == Claude
      assert Overview.adapter(:codex) == Codex
    end

    test "last probe is the account's most recent preflight/probe usage row" do
      account = account!(:claude, "ov-probed")
      at = DateTime.add(DateTime.utc_now(), -600, :second)
      event!(account, %{provider: "claude", source: :preflight, task_id: nil, occurred_at: at})
      event!(account, %{provider: "claude", source: :task})

      assert %{health: %{last_probe_at: last}} = row(Overview.list(), account)
      assert DateTime.diff(last, at) == 0
    end
  end
end
