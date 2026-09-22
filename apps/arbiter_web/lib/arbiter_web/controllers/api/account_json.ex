defmodule ArbiterWeb.Api.AccountJSON do
  @moduledoc """
  Render functions for `Arbiter.Accounts.ProviderAccount` and friends.

  `show` includes the account's credentials (kind/fingerprint/active only —
  **never** the secret value, per P11's acceptance bar) and attached
  workspaces, so `arb account show <slug>` is a single round trip.
  """

  require Ash.Query

  alias Arbiter.Accounts.{ProviderAccount, ProviderCredential, WorkspaceProviderAccount}

  def index(%{accounts: accounts}), do: %{data: Enum.map(accounts, &data/1)}

  def show(%{account: account}), do: data(account, detailed?: true)

  def attach(%{link: link}), do: link_data(link)

  def credential(%{credential: credential}), do: credential_data(credential)

  def data(%ProviderAccount{} = account, opts \\ []) do
    base = %{
      id: account.id,
      provider: account.provider,
      slug: account.slug,
      label: account.label,
      plan: account.plan,
      provider_account_ref: account.provider_account_ref,
      provider_org_ref: account.provider_org_ref,
      identity_source: account.identity_source,
      identity_verified_at: iso(account.identity_verified_at),
      max_concurrent: account.max_concurrent,
      quota_config: account.quota_config || %{},
      enabled: account.enabled,
      merged_into_id: account.merged_into_id,
      inserted_at: iso(account.inserted_at),
      updated_at: iso(account.updated_at)
    }

    if Keyword.get(opts, :detailed?, false) do
      base
      |> Map.put(:credentials, Enum.map(credentials_for(account.id), &credential_data/1))
      |> Map.put(:workspaces, Enum.map(links_for(account.id), &link_data/1))
    else
      base
    end
  end

  # Fingerprint/kind/active only — the secret is never selected here at all
  # (`ProviderCredential.secret` is `public? false`, write-only via `:create`).
  defp credential_data(%ProviderCredential{} = credential) do
    %{
      id: credential.id,
      kind: credential.kind,
      env_var: credential.env_var,
      fingerprint: String.slice(credential.fingerprint, 0, 12),
      active: credential.active,
      scopes: credential.scopes,
      created_at: iso(credential.created_at),
      retired_at: iso(credential.retired_at)
    }
  end

  defp link_data(%WorkspaceProviderAccount{} = link) do
    %{
      id: link.id,
      workspace_id: link.workspace_id,
      provider: link.provider,
      provider_account_id: link.provider_account_id,
      share: link.share
    }
  end

  defp credentials_for(account_id) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.read!()
  end

  defp links_for(account_id) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.read!()
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
