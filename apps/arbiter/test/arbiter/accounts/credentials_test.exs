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

  # Reviewer finding 3 on bd-3j92yv: this function bypassed the module's own
  # enabled-only invariant (see the moduledoc) — a parked account's
  # credential must supply nothing here, same as it does everywhere else in
  # this module, or a poll keeps authenticating with a grant the operator
  # explicitly took out of service.
  test ":none for a parked (disabled) account, even with an active credential" do
    account = account!("cred-parked")
    {:ok, account} = Ash.update(account, %{enabled: false}, action: :update)

    Ash.create!(ProviderCredential, %{
      provider_account_id: account.id,
      kind: :cli_credentials_file,
      env_var: "CLAUDE_CODE_OAUTH_TOKEN",
      fingerprint: "fp-parked",
      secret: "parked-token"
    })

    assert Credentials.account_oauth_usage_token(account.id) == :none
  end

  # Reviewer finding 4 on bd-3j92yv floated a "two active cli_credentials_file
  # rows on one account" mid-rotation window. `provider_credentials_unique_
  # active_index` (a partial unique index on `(provider_account_id, kind)
  # where active = true`, `provider_credential.ex:38-44`) makes that state
  # unreachable today: a second `:create` with `active: true` for a kind the
  # account already has an active row for raises `has already been taken`
  # (confirmed by literally attempting it here — see the PR discussion for
  # bd-3j92yv). `account_oauth_usage_token/1` still picks the newest active
  # row by `created_at` (see the moduledoc) as cheap, harmless
  # future-proofing in case a later `:rotate` action changes that invariant,
  # but there is no reachable state today for a regression test to exercise.
end
