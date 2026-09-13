defmodule Arbiter.Accounts.ProviderCredentialTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Accounts.{ProviderAccount, ProviderCredential}

  setup do
    {:ok, account} = Ash.create(ProviderAccount, %{provider: :claude, slug: "cred-test"})
    %{account: account}
  end

  describe "create" do
    test "stores the secret encrypted and decrypts it on read", %{account: account} do
      assert {:ok, credential} =
               Ash.create(ProviderCredential, %{
                 provider_account_id: account.id,
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 fingerprint: "deadbeef",
                 secret: "sk-ant-oat01-plaintext-token"
               })

      # The stored column holds ciphertext, never the plaintext token.
      assert is_binary(credential.encrypted_secret)
      refute credential.encrypted_secret =~ "sk-ant-oat01-plaintext-token"

      # The decrypt helper round-trips the plaintext.
      assert ProviderCredential.secret(credential) == "sk-ant-oat01-plaintext-token"

      # Re-reading from the DB decrypts the same value.
      assert {:ok, reloaded} = Ash.get(ProviderCredential, credential.id)
      assert is_binary(reloaded.encrypted_secret)
      refute reloaded.encrypted_secret =~ "sk-ant-oat01-plaintext-token"
      assert ProviderCredential.secret(reloaded) == "sk-ant-oat01-plaintext-token"
    end

    test "defaults active to true", %{account: account} do
      assert {:ok, credential} =
               Ash.create(ProviderCredential, %{
                 provider_account_id: account.id,
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 fingerprint: "abc123",
                 secret: "token"
               })

      assert credential.active == true
      assert credential.retired_at == nil
    end

    test "rejects a second active credential of the same kind on the same account", %{
      account: account
    } do
      assert {:ok, _} =
               Ash.create(ProviderCredential, %{
                 provider_account_id: account.id,
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 fingerprint: "fp1",
                 secret: "token-1"
               })

      assert {:error, _} =
               Ash.create(ProviderCredential, %{
                 provider_account_id: account.id,
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 fingerprint: "fp2",
                 secret: "token-2"
               })
    end

    test "allows two active credentials of different kinds on the same account", %{
      account: account
    } do
      assert {:ok, _} =
               Ash.create(ProviderCredential, %{
                 provider_account_id: account.id,
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 fingerprint: "fp1",
                 secret: "token-1"
               })

      assert {:ok, _} =
               Ash.create(ProviderCredential, %{
                 provider_account_id: account.id,
                 kind: :api_key,
                 env_var: "ANTHROPIC_API_KEY",
                 fingerprint: "fp2",
                 secret: "key-1"
               })
    end

    test "rotation: retiring the old credential then creating a new active one of the same kind succeeds",
         %{account: account} do
      assert {:ok, old} =
               Ash.create(ProviderCredential, %{
                 provider_account_id: account.id,
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 fingerprint: "fp-old",
                 secret: "token-old"
               })

      assert {:ok, retired} = old |> Ash.Changeset.for_update(:retire) |> Ash.update()
      assert retired.active == false
      assert %DateTime{} = retired.retired_at

      assert {:ok, new} =
               Ash.create(ProviderCredential, %{
                 provider_account_id: account.id,
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 fingerprint: "fp-new",
                 secret: "token-new"
               })

      assert new.active == true

      # Both rows persist — rotation is an insert, not an overwrite.
      assert {:ok, reloaded_old} = Ash.get(ProviderCredential, old.id)
      assert reloaded_old.active == false
      assert ProviderCredential.secret(reloaded_old) == "token-old"
      assert ProviderCredential.secret(new) == "token-new"
    end
  end

  describe "append-only" do
    test "there is no update action that can change the secret material" do
      resource = ProviderCredential

      update_actions =
        resource
        |> Ash.Resource.Info.actions()
        |> Enum.filter(&(&1.type == :update))

      for action <- update_actions do
        refute :secret in (action.accept || []),
               "#{action.name} must not accept :secret — credentials are append-only"

        refute :encrypted_secret in (action.accept || []),
               "#{action.name} must not accept :encrypted_secret — credentials are append-only"
      end
    end
  end
end
