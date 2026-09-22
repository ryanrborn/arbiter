defmodule Arbiter.Accounts.CredentialsTest do
  @moduledoc """
  `account_oauth_usage_token/1` (P6, `docs/provider-account-design.md` §5
  row 10 / §9) — the account's own credential for authenticating
  `/api/oauth/usage`, deliberately keyed on `kind == :cli_credentials_file`
  rather than `env_var`, since a `:oauth_token` row under
  `CLAUDE_CODE_OAUTH_TOKEN` is a `worker_env` token that cannot authenticate
  this endpoint (bd-4fbpto, PR #1607).
  """
  use Arbiter.DataCase, async: true

  alias Arbiter.Accounts.Credentials
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential

  defp account!(slug \\ "cred-acct") do
    Ash.create!(ProviderAccount, %{provider: :claude, slug: slug})
  end

  test "returns the decrypted secret of the account's active cli_credentials_file credential" do
    account = account!()

    Ash.create!(ProviderCredential, %{
      provider_account_id: account.id,
      kind: :cli_credentials_file,
      env_var: "CLAUDE_CODE_OAUTH_TOKEN",
      fingerprint: "fp-1",
      secret: "the-secret-token"
    })

    assert Credentials.account_oauth_usage_token(account.id) == {:ok, "the-secret-token"}
  end

  test "ignores an oauth_token-kind credential under the same env_var" do
    account = account!()

    Ash.create!(ProviderCredential, %{
      provider_account_id: account.id,
      kind: :oauth_token,
      env_var: "CLAUDE_CODE_OAUTH_TOKEN",
      fingerprint: "fp-2",
      secret: "worker-env-token"
    })

    assert Credentials.account_oauth_usage_token(account.id) == :none
  end

  test "ignores a retired cli_credentials_file credential" do
    account = account!()

    {:ok, credential} =
      Ash.create(ProviderCredential, %{
        provider_account_id: account.id,
        kind: :cli_credentials_file,
        env_var: "CLAUDE_CODE_OAUTH_TOKEN",
        fingerprint: "fp-3",
        secret: "retired-token"
      })

    Ash.update!(credential, %{}, action: :retire)

    assert Credentials.account_oauth_usage_token(account.id) == :none
  end

  test ":none for an account with no credentials at all" do
    account = account!()
    assert Credentials.account_oauth_usage_token(account.id) == :none
  end

  test ":none for a nil or blank account id" do
    assert Credentials.account_oauth_usage_token(nil) == :none
    assert Credentials.account_oauth_usage_token("") == :none
  end
end
