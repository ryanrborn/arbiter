defmodule Arbiter.Accounts.WorkspaceProviderAccountTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, workspace} = Ash.create(Workspace, %{name: "wpa-test"})
    {:ok, account_a} = Ash.create(ProviderAccount, %{provider: :claude, slug: "account-a"})
    {:ok, account_b} = Ash.create(ProviderAccount, %{provider: :claude, slug: "account-b"})
    %{workspace: workspace, account_a: account_a, account_b: account_b}
  end

  describe "create" do
    test "links a workspace to an account for a provider", %{
      workspace: workspace,
      account_a: account
    } do
      assert {:ok, link} =
               Ash.create(WorkspaceProviderAccount, %{
                 workspace_id: workspace.id,
                 provider: :claude,
                 provider_account_id: account.id
               })

      assert link.workspace_id == workspace.id
      assert link.provider_account_id == account.id
      assert link.share == nil
    end

    test "rejects a second account for the same workspace + provider", %{
      workspace: workspace,
      account_a: account_a,
      account_b: account_b
    } do
      assert {:ok, _} =
               Ash.create(WorkspaceProviderAccount, %{
                 workspace_id: workspace.id,
                 provider: :claude,
                 provider_account_id: account_a.id
               })

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(WorkspaceProviderAccount, %{
                 workspace_id: workspace.id,
                 provider: :claude,
                 provider_account_id: account_b.id
               })
    end

    test "allows the same workspace to point at different accounts for different providers", %{
      workspace: workspace,
      account_a: claude_account
    } do
      {:ok, codex_account} = Ash.create(ProviderAccount, %{provider: :codex, slug: "codex-a"})

      assert {:ok, _} =
               Ash.create(WorkspaceProviderAccount, %{
                 workspace_id: workspace.id,
                 provider: :claude,
                 provider_account_id: claude_account.id
               })

      assert {:ok, _} =
               Ash.create(WorkspaceProviderAccount, %{
                 workspace_id: workspace.id,
                 provider: :codex,
                 provider_account_id: codex_account.id
               })
    end

    test "allows the same account to be shared by multiple workspaces", %{account_a: account} do
      {:ok, ws1} = Ash.create(Workspace, %{name: "wpa-shared-1"})
      {:ok, ws2} = Ash.create(Workspace, %{name: "wpa-shared-2"})

      assert {:ok, _} =
               Ash.create(WorkspaceProviderAccount, %{
                 workspace_id: ws1.id,
                 provider: :claude,
                 provider_account_id: account.id
               })

      assert {:ok, _} =
               Ash.create(WorkspaceProviderAccount, %{
                 workspace_id: ws2.id,
                 provider: :claude,
                 provider_account_id: account.id
               })
    end
  end
end
