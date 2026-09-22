defmodule Arbiter.AccountsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.{ProviderAccount, ProviderCredential, WorkspaceProviderAccount}
  alias Arbiter.Quota.{AnthropicQuota, CodexQuota, GoogleQuota, Rekey}
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  require Ash.Query

  defp create_workspace!(name) do
    {:ok, ws} = Ash.create(Workspace, %{name: name, prefix: "ac"})
    ws
  end

  defp create_account!(attrs) do
    {:ok, account} = Ash.create(ProviderAccount, attrs)
    account
  end

  defp create_anthropic_quota!(account_id, attrs \\ []) do
    base = %{
      provider_account_id: account_id,
      provider: "claude",
      captured_at: DateTime.utc_now()
    }

    {:ok, quota} =
      Ash.create(AnthropicQuota, Map.merge(base, Map.new(attrs)), action: :record_oauth_snapshot)

    quota
  end

  defp create_codex_quota!(account_id, attrs) do
    base = %{
      provider_account_id: account_id,
      provider: "codex",
      captured_at: DateTime.utc_now()
    }

    {:ok, quota} = Ash.create(CodexQuota, Map.merge(base, Map.new(attrs)), action: :upsert)
    quota
  end

  defp create_cloud_code_quota!(account_id, provider, attrs) do
    base = %{
      provider_account_id: account_id,
      provider: provider,
      captured_at: DateTime.utc_now()
    }

    {:ok, quota} = Ash.create(GoogleQuota, Map.merge(base, Map.new(attrs)), action: :upsert)
    quota
  end

  defp create_event!(attrs) do
    base = %{
      task_id: "bd-acct-#{System.unique_integer([:positive])}",
      source: :task,
      repo: "arbiter",
      workspace_id: "ws-acct",
      step: :work,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  describe "list_accounts/1" do
    test "lists accounts sorted by provider then slug, excluding merged-away rows" do
      create_account!(%{provider: :claude, slug: "b-account"})
      create_account!(%{provider: :claude, slug: "a-account"})
      merged = create_account!(%{provider: :claude, slug: "merged-away"})
      into = create_account!(%{provider: :claude, slug: "survivor"})

      merged
      |> Ash.Changeset.for_update(:update, %{merged_into_id: into.id, enabled: false})
      |> Ash.update!()

      slugs = Accounts.list_accounts() |> Enum.map(& &1.slug)

      assert slugs == ["a-account", "b-account", "survivor"]
    end

    test "filters by provider" do
      create_account!(%{provider: :claude, slug: "only-claude"})
      create_account!(%{provider: :codex, slug: "only-codex"})

      assert [%{slug: "only-claude"}] = Accounts.list_accounts(provider: :claude)
    end
  end

  describe "get_account/1" do
    test "resolves by uuid id" do
      account = create_account!(%{provider: :claude, slug: "by-id"})
      assert {:ok, found} = Accounts.get_account(account.id)
      assert found.id == account.id
    end

    test "resolves by provider:slug" do
      create_account!(%{provider: :claude, slug: "shared"})
      codex = create_account!(%{provider: :codex, slug: "shared"})

      assert {:ok, found} = Accounts.get_account("codex:shared")
      assert found.id == codex.id
    end

    test "resolves an unambiguous bare slug" do
      account = create_account!(%{provider: :claude, slug: "unique-slug"})
      assert {:ok, found} = Accounts.get_account("unique-slug")
      assert found.id == account.id
    end

    test "a bare slug shared across providers is ambiguous" do
      create_account!(%{provider: :claude, slug: "dup"})
      create_account!(%{provider: :codex, slug: "dup"})

      assert {:error, :ambiguous} = Accounts.get_account("dup")
    end

    test "unknown ref is not found" do
      assert {:error, :not_found} = Accounts.get_account("nope")
    end
  end

  describe "create_account/1" do
    test "creates a new account with no credential required" do
      assert {:ok, account} = Accounts.create_account(%{provider: :claude, slug: "fresh"})
      assert account.provider == :claude
      assert account.slug == "fresh"
      assert account.enabled == true
    end
  end

  describe "attach_workspace/4" do
    test "creates a workspace_provider_accounts row" do
      ws = create_workspace!("attach-ws-1")
      account = create_account!(%{provider: :claude, slug: "attach-acct"})

      assert {:ok, link} = Accounts.attach_workspace(ws.id, :claude, account.id, share: 2)
      assert link.workspace_id == ws.id
      assert link.provider == :claude
      assert link.provider_account_id == account.id
      assert link.share == 2
    end

    test "re-attaching the same workspace+provider updates the existing row" do
      ws = create_workspace!("attach-ws-2")
      account_a = create_account!(%{provider: :claude, slug: "attach-a"})
      account_b = create_account!(%{provider: :claude, slug: "attach-b"})

      assert {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account_a.id)
      assert {:ok, updated} = Accounts.attach_workspace(ws.id, :claude, account_b.id, share: 5)

      assert updated.provider_account_id == account_b.id
      assert updated.share == 5

      assert [_one] =
               WorkspaceProviderAccount
               |> Ash.Query.filter(workspace_id == ^ws.id and provider == :claude)
               |> Ash.read!()
    end

    test "rejects attaching to an account of a different provider" do
      ws = create_workspace!("attach-ws-3")
      account = create_account!(%{provider: :codex, slug: "codex-only"})

      assert {:error, {:provider_mismatch, :codex}} =
               Accounts.attach_workspace(ws.id, :claude, account.id)
    end
  end

  describe "rotate_credential/2" do
    test "inserts a new active credential and retires the previous one, never returning the secret in a loggable form" do
      account = create_account!(%{provider: :claude, slug: "rotate-acct"})

      assert {:ok, first} =
               Accounts.rotate_credential(account.id, %{
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 secret: "sk-first-secret"
               })

      assert first.active == true

      assert {:ok, second} =
               Accounts.rotate_credential(account.id, %{
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 secret: "sk-second-secret"
               })

      assert second.active == true
      assert second.id != first.id

      {:ok, reloaded_first} = Ash.get(ProviderCredential, first.id)
      assert reloaded_first.active == false
      assert reloaded_first.retired_at != nil

      # The struct never carries the plaintext secret back out.
      refute Map.has_key?(second, :secret) and is_binary(Map.get(second, :secret))
      inspected = inspect(second)
      refute inspected =~ "sk-first-secret"
      refute inspected =~ "sk-second-secret"
    end

    test "rotating a different kind does not retire the other kind's active credential" do
      account = create_account!(%{provider: :claude, slug: "rotate-multi-kind"})

      {:ok, oauth} =
        Accounts.rotate_credential(account.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "sk-oauth"
        })

      {:ok, _api_key} =
        Accounts.rotate_credential(account.id, %{
          kind: :api_key,
          env_var: "ANTHROPIC_API_KEY",
          secret: "sk-api-key"
        })

      {:ok, reloaded_oauth} = Ash.get(ProviderCredential, oauth.id)
      assert reloaded_oauth.active == true
    end
  end

  describe "merge_accounts/2 — §2.5 end-to-end" do
    setup do
      from_account = create_account!(%{provider: :claude, slug: "merge-from"})
      into_account = create_account!(%{provider: :claude, slug: "merge-into"})

      ws_from = create_workspace!("merge-ws-from")
      ws_into = create_workspace!("merge-ws-into")

      {:ok, _} = Accounts.attach_workspace(ws_from.id, :claude, from_account.id)
      {:ok, _} = Accounts.attach_workspace(ws_into.id, :claude, into_account.id)

      {:ok, from_cred} =
        Accounts.rotate_credential(from_account.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "sk-from-secret"
        })

      event_from =
        create_event!(%{
          provider_account_id: from_account.id,
          provider_credential_id: from_cred.id,
          cost_usd: 3.00,
          occurred_at: ~U[2026-01-01 00:00:00Z]
        })

      event_into =
        create_event!(%{
          provider_account_id: into_account.id,
          cost_usd: 5.00,
          occurred_at: ~U[2026-01-02 00:00:00Z]
        })

      %{
        from_account: from_account,
        into_account: into_account,
        ws_from: ws_from,
        ws_into: ws_into,
        from_cred: from_cred,
        event_from: event_from,
        event_into: event_into
      }
    end

    test "re-points usage_events, moves credentials distinctly, re-points workspace links, and soft-deletes the from row",
         %{
           from_account: from_account,
           into_account: into_account,
           ws_from: ws_from,
           ws_into: ws_into,
           from_cred: from_cred,
           event_from: event_from
         } do
      assert {:ok, result} = Accounts.merge_accounts(from_account.id, into_account.id)
      assert result.id == into_account.id

      # usage_events re-pointed from -> into
      {:ok, reloaded_event} = Ash.get(Event, event_from.id)
      assert reloaded_event.provider_account_id == into_account.id

      # provider_credentials moved across, staying distinct rows
      {:ok, reloaded_cred} = Ash.get(ProviderCredential, from_cred.id)
      assert reloaded_cred.provider_account_id == into_account.id

      # workspace_provider_accounts re-pointed
      {:ok, link_from} =
        WorkspaceProviderAccount
        |> Ash.Query.filter(workspace_id == ^ws_from.id and provider == :claude)
        |> Ash.read_one()

      assert link_from.provider_account_id == into_account.id

      {:ok, link_into} =
        WorkspaceProviderAccount
        |> Ash.Query.filter(workspace_id == ^ws_into.id and provider == :claude)
        |> Ash.read_one()

      assert link_into.provider_account_id == into_account.id

      # the from row is soft-deleted with merged_into_id set
      {:ok, reloaded_from} = Ash.get(ProviderAccount, from_account.id)
      assert reloaded_from.merged_into_id == into_account.id
      assert reloaded_from.enabled == false
    end

    test "historical usage_events cost rollups become correct retroactively, from a plain read-time aggregation",
         %{from_account: from_account, into_account: into_account} do
      # Before the merge: each account's own total only sees its own events.
      before_from = sum_cost(from_account.id)
      before_into = sum_cost(into_account.id)
      assert_in_delta before_from, 3.00, 0.001
      assert_in_delta before_into, 5.00, 0.001

      assert {:ok, _} = Accounts.merge_accounts(from_account.id, into_account.id)

      # After the merge: a plain read-time sum over usage_events for the
      # surviving account id now sees both, with no re-derivation step and no
      # stored rollup involved.
      after_into = sum_cost(into_account.id)
      assert_in_delta after_into, 8.00, 0.001
    end

    test "rejects merging accounts of different providers" do
      other = create_account!(%{provider: :codex, slug: "codex-other"})
      claude_account = create_account!(%{provider: :claude, slug: "claude-solo"})

      assert {:error, :provider_mismatch} = Accounts.merge_accounts(claude_account.id, other.id)
    end

    test "rejects merging an account into itself", %{from_account: from_account} do
      assert {:error, :same_account} = Accounts.merge_accounts(from_account.id, from_account.id)
    end

    test "rejects a merge before touching anything when the into ref does not resolve",
         %{from_account: from_account} do
      assert {:error, :not_found} = Accounts.merge_accounts(from_account.id, "does-not-exist")

      before = sum_cost(from_account.id)
      assert_in_delta before, 3.00, 0.001

      {:ok, reloaded_from} = Ash.get(ProviderAccount, from_account.id)
      assert reloaded_from.merged_into_id == nil
      assert reloaded_from.enabled == true
    end

    test "is transactional: an error midway through the transaction rolls back every table",
         %{
           from_account: from_account,
           into_account: into_account,
           ws_from: ws_from,
           from_cred: from_cred,
           event_from: event_from
         } do
      # Both accounts hold a quota row, so the merge's quota-collapse step
      # (which runs after usage_events and provider_credentials have already
      # been re-pointed inside the same transaction) actually executes.
      create_anthropic_quota!(from_account.id)
      create_anthropic_quota!(into_account.id)

      # Inject a real failure *inside* the transaction, past the two steps
      # that already ran — proving all-or-nothing, not just the up-front
      # ref-resolution guard.
      :meck.new(Rekey, [:passthrough])
      :meck.expect(Rekey, :collapse_anthropic, fn _rows -> raise "injected mid-merge failure" end)

      try do
        assert {:error, _reason} = Accounts.merge_accounts(from_account.id, into_account.id)
      after
        :meck.unload(Rekey)
      end

      # usage_events: still pointed at from
      {:ok, reloaded_event} = Ash.get(Event, event_from.id)
      assert reloaded_event.provider_account_id == from_account.id

      # provider_credentials: still owned by from
      {:ok, reloaded_cred} = Ash.get(ProviderCredential, from_cred.id)
      assert reloaded_cred.provider_account_id == from_account.id

      # anthropic_quotas: both rows survive, uncollapsed
      quota_rows =
        AnthropicQuota
        |> Ash.Query.filter(provider_account_id in [^from_account.id, ^into_account.id])
        |> Ash.read!()

      assert length(quota_rows) == 2

      # workspace_provider_accounts: still pointed at from
      {:ok, link_from} =
        WorkspaceProviderAccount
        |> Ash.Query.filter(workspace_id == ^ws_from.id and provider == :claude)
        |> Ash.read_one()

      assert link_from.provider_account_id == from_account.id

      # the from row: not soft-deleted
      {:ok, reloaded_from} = Ash.get(ProviderAccount, from_account.id)
      assert reloaded_from.merged_into_id == nil
      assert reloaded_from.enabled == true
    end
  end

  describe "merge_accounts/2 — quota collapse (§6)" do
    test "anthropic_quotas: collapses per column group, header cols from the newest captured_at, oauth cols from the newest oauth_captured_at" do
      from = create_account!(%{provider: :claude, slug: "quota-merge-from"})
      into = create_account!(%{provider: :claude, slug: "quota-merge-into"})

      # `from` has the fresher oauth block but the staler header.
      create_anthropic_quota!(from.id,
        captured_at: ~U[2026-01-01 00:00:00Z],
        utilization_5h: 0.1,
        oauth_captured_at: ~U[2026-01-05 00:00:00Z],
        oauth_utilization_5h: 0.9
      )

      create_anthropic_quota!(into.id,
        captured_at: ~U[2026-01-03 00:00:00Z],
        utilization_5h: 0.5,
        oauth_captured_at: ~U[2026-01-02 00:00:00Z],
        oauth_utilization_5h: 0.2
      )

      assert {:ok, _} = Accounts.merge_accounts(from.id, into.id)

      assert {:ok, merged} =
               AnthropicQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "claude")
               |> Ash.read_one()

      # header columns come from the newest `captured_at` row (into's)
      assert_in_delta merged.utilization_5h, 0.5, 0.001
      assert DateTime.compare(merged.captured_at, ~U[2026-01-03 00:00:00Z]) == :eq

      # oauth columns come from the newest `oauth_captured_at` row (from's)
      assert_in_delta merged.oauth_utilization_5h, 0.9, 0.001
      assert DateTime.compare(merged.oauth_captured_at, ~U[2026-01-05 00:00:00Z]) == :eq

      # exactly one row survives on (into.id, "claude")
      assert [_one] =
               AnthropicQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "claude")
               |> Ash.read!()
    end

    test "codex_quotas: collapses to the single newest row" do
      from = create_account!(%{provider: :codex, slug: "codex-merge-from"})
      into = create_account!(%{provider: :codex, slug: "codex-merge-into"})

      create_codex_quota!(from.id, captured_at: ~U[2026-01-05 00:00:00Z], plan: "from-plan")
      create_codex_quota!(into.id, captured_at: ~U[2026-01-01 00:00:00Z], plan: "into-plan")

      assert {:ok, _} = Accounts.merge_accounts(from.id, into.id)

      assert {:ok, merged} =
               CodexQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "codex")
               |> Ash.read_one()

      assert merged.plan == "from-plan"

      assert [_one] =
               CodexQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "codex")
               |> Ash.read!()
    end

    test "cloud_code_quotas (gemini_cli): collapses to the single newest row" do
      from = create_account!(%{provider: :gemini_cli, slug: "gemini-merge-from"})
      into = create_account!(%{provider: :gemini_cli, slug: "gemini-merge-into"})

      create_cloud_code_quota!(from.id, "gemini_cli",
        captured_at: ~U[2026-01-01 00:00:00Z],
        plan: "from-plan"
      )

      create_cloud_code_quota!(into.id, "gemini_cli",
        captured_at: ~U[2026-01-05 00:00:00Z],
        plan: "into-plan"
      )

      assert {:ok, _} = Accounts.merge_accounts(from.id, into.id)

      assert {:ok, merged} =
               GoogleQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "gemini_cli")
               |> Ash.read_one()

      assert merged.plan == "into-plan"

      assert [_one] =
               GoogleQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "gemini_cli")
               |> Ash.read!()
    end

    test "re-points a single quota row when only the from account has one" do
      from = create_account!(%{provider: :claude, slug: "quota-solo-from"})
      into = create_account!(%{provider: :claude, slug: "quota-solo-into"})

      create_anthropic_quota!(from.id, utilization_5h: 0.42)

      assert {:ok, _} = Accounts.merge_accounts(from.id, into.id)

      assert {:ok, merged} =
               AnthropicQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "claude")
               |> Ash.read_one()

      assert_in_delta merged.utilization_5h, 0.42, 0.001
    end
  end

  # A plain read-time aggregation over usage_events — not Usage.summarize/1's
  # workspace-approximation path (that's P9's job to make exact), a direct
  # query against the column merge/2 re-points.
  defp sum_cost(account_id) do
    Event
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.read!()
    |> Enum.reduce(0.0, fn ev, acc -> acc + (ev.cost_usd || 0.0) end)
  end
end
