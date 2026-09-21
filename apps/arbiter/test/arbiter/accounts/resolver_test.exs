defmodule Arbiter.Accounts.ResolverTest do
  @moduledoc """
  P5: the workspace → provider-account hop the quota tables are keyed by
  (`docs/provider-account-design.md` §3.3, §6).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, Resolver, WorkspaceProviderAccount}
  alias Arbiter.Tasks.Workspace

  defp workspace!(name), do: Ash.create!(Workspace, %{name: name})

  defp account!(provider, slug),
    do: Ash.create!(ProviderAccount, %{provider: provider, slug: slug})

  defp link!(ws, provider, account) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: provider,
      provider_account_id: account.id
    })
  end

  describe "account_id/2" do
    test "reads the join row, per provider" do
      ws = workspace!("res-a")
      claude = account!(:claude, "res-claude")
      codex = account!(:codex, "res-codex")
      link!(ws, :claude, claude)
      link!(ws, :codex, codex)

      assert Resolver.account_id(ws.id, "claude") == claude.id
      assert Resolver.account_id(ws.id, "codex") == codex.id
      assert Resolver.account_id(ws.id, "gemini_cli") == nil
    end

    test "does not create anything when there is no join row" do
      ws = workspace!("res-b")
      assert Resolver.account_id(ws.id, "claude") == nil
      assert Ash.read!(ProviderAccount) == []
    end

    test "is nil for a non-uuid workspace reference" do
      assert Resolver.account_id("not-a-uuid", "claude") == nil
      assert Resolver.account_id(nil, "claude") == nil
    end
  end

  describe "ensure_account_id/2" do
    test "returns the existing join row's account" do
      ws = workspace!("res-c")
      account = account!(:claude, "res-existing")
      link!(ws, :claude, account)

      assert {:ok, id} = Resolver.ensure_account_id(ws.id, "claude")
      assert id == account.id
      assert length(Ash.read!(ProviderAccount)) == 1
    end

    test "adopts the provider's sole existing account and links the workspace" do
      ws = workspace!("res-d")
      account = account!(:claude, "personal-max")

      assert {:ok, id} = Resolver.ensure_account_id(ws.id, "claude")
      assert id == account.id
      assert Resolver.account_id(ws.id, "claude") == account.id
      assert length(Ash.read!(ProviderAccount)) == 1
    end

    test "mints a default account when the provider has none" do
      ws = workspace!("res-e")

      assert {:ok, id} = Resolver.ensure_account_id(ws.id, "claude")

      assert [%ProviderAccount{id: ^id, provider: :claude, slug: "default"}] =
               Ash.read!(ProviderAccount)
    end

    test "two workspaces on a provider with no account land on the same minted account" do
      a = workspace!("res-f")
      b = workspace!("res-g")

      assert {:ok, id_a} = Resolver.ensure_account_id(a.id, "claude")
      assert {:ok, id_b} = Resolver.ensure_account_id(b.id, "claude")
      assert id_a == id_b
      assert length(Ash.read!(ProviderAccount)) == 1
    end

    test "does not adopt an ambiguous provider — mints its own default instead" do
      ws = workspace!("res-h")
      account!(:claude, "work")
      account!(:claude, "personal")

      assert {:ok, id} = Resolver.ensure_account_id(ws.id, "claude")
      minted = Enum.find(Ash.read!(ProviderAccount), &(&1.id == id))
      assert minted.slug == "default"
    end

    test "never adopts a parked account" do
      ws = workspace!("res-i")

      {:ok, parked} =
        Ash.create(ProviderAccount, %{provider: :claude, slug: "parked", enabled: false})

      assert {:ok, id} = Resolver.ensure_account_id(ws.id, "claude")
      refute id == parked.id
    end

    test "errors for an unknown provider" do
      ws = workspace!("res-j")
      assert {:error, _} = Resolver.ensure_account_id(ws.id, "nope")
    end
  end

  describe "workspaces/1" do
    test "lists every workspace on the account, by name" do
      account = account!(:claude, "shared")
      a = workspace!("vstim")
      b = workspace!("default")
      c = workspace!("emricare")
      other = workspace!("unlinked")
      for ws <- [a, b, c], do: link!(ws, :claude, account)

      names = account.id |> Resolver.workspaces() |> Enum.map(& &1.name)
      assert names == ["default", "emricare", "vstim"]
      refute other.name in names
    end

    test "is empty for an unknown account" do
      assert Resolver.workspaces(Ash.UUID.generate()) == []
      assert Resolver.workspaces(nil) == []
    end
  end

  describe "account_ids/1" do
    test "maps every linked provider of a workspace to its account" do
      ws = workspace!("res-k")
      claude = account!(:claude, "k-claude")
      gemini = account!(:gemini_cli, "k-gemini")
      link!(ws, :claude, claude)
      link!(ws, :gemini_cli, gemini)

      assert Resolver.account_ids(ws.id) == %{
               "claude" => claude.id,
               "gemini_cli" => gemini.id
             }
    end
  end

  describe "get/1" do
    test "loads the account row" do
      account = account!(:claude, "res-get")
      assert %ProviderAccount{slug: "res-get"} = Resolver.get(account.id)
      assert Resolver.get(Ash.UUID.generate()) == nil
      assert Resolver.get(nil) == nil
    end
  end
end
