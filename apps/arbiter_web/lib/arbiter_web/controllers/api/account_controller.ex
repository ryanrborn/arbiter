defmodule ArbiterWeb.Api.AccountController do
  @moduledoc """
  REST endpoints for `Arbiter.Accounts.ProviderAccount` (P11,
  `docs/provider-account-design.md` §2.5). Backs the `arb account` CLI.

  Routes:

    * `GET    /api/accounts`            — :index (optional `?provider=`, `?include_merged=true`)
    * `POST   /api/accounts`            — :create
    * `GET    /api/accounts/:ref`       — :show   (`:ref` — uuid, `provider:slug`, or bare slug)
    * `POST   /api/accounts/:ref/attach`  — :attach (`workspace_id`, `provider`, optional `share`)
    * `POST   /api/accounts/:ref/rotate`  — :rotate (`kind`, `env_var`, `secret`, optional `scopes`)
    * `POST   /api/accounts/:ref/merge`   — :merge  (`into` — the surviving account ref)

  `:ref` resolution is `Arbiter.Accounts.get_account/1` — a bare slug that
  matches more than one provider's account is rejected as ambiguous.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Accounts

  action_fallback ArbiterWeb.Api.FallbackController

  def index(conn, params) do
    with {:ok, opts} <- provider_filter(params) do
      opts = Keyword.put(opts, :include_merged, truthy?(Map.get(params, "include_merged")))
      render(conn, :index, accounts: Accounts.list_accounts(opts))
    end
  end

  defp provider_filter(params) do
    case Map.get(params, "provider") do
      nil ->
        {:ok, []}

      provider ->
        case Accounts.parse_provider(provider) do
          {:ok, p} -> {:ok, [provider: p]}
          :error -> {:error, {:invalid_request, "unknown provider"}}
        end
    end
  end

  defp truthy?(v), do: v in ["true", "1", true]

  def show(conn, %{"ref" => ref}) do
    with {:ok, account} <- ref |> Accounts.get_account() |> friendly() do
      render(conn, :show, account: account)
    end
  end

  def create(conn, params) do
    attrs =
      Map.take(params, [
        "provider",
        "slug",
        "label",
        "plan",
        "provider_account_ref",
        "provider_org_ref",
        "max_concurrent",
        "quota_config",
        "enabled"
      ])

    with {:ok, account} <- attrs |> Accounts.create_account() |> friendly() do
      conn
      |> put_status(:created)
      |> render(:show, account: account)
    end
  end

  def attach(conn, %{"ref" => ref} = params) do
    with {:ok, workspace_id} <- require_param(params, "workspace_id"),
         {:ok, provider} <- require_param(params, "provider"),
         {:ok, link} <-
           Accounts.attach_workspace(workspace_id, provider, ref, share_opts(params))
           |> friendly() do
      conn
      |> put_status(:created)
      |> render(:attach, link: link)
    end
  end

  # `share` is only forwarded when the caller actually sent it — an absent
  # key must leave an existing share untouched (Accounts.attach_workspace/4),
  # not clobber it back to nil.
  defp share_opts(params) do
    case Map.get(params, "share") do
      nil -> []
      share -> [share: share]
    end
  end

  def rotate(conn, %{"ref" => ref} = params) do
    attrs = Map.take(params, ["kind", "env_var", "secret", "scopes"])

    with {:ok, credential} <- ref |> Accounts.rotate_credential(attrs) |> friendly() do
      conn
      |> put_status(:created)
      |> render(:credential, credential: credential)
    end
  end

  def merge(conn, %{"ref" => ref} = params) do
    with {:ok, into} <- require_param(params, "into"),
         {:ok, account} <- ref |> Accounts.merge_accounts(into) |> friendly() do
      render(conn, :show, account: account)
    end
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, {:invalid_request, "missing required parameter: #{key}"}}
      "" -> {:error, {:invalid_request, "missing required parameter: #{key}"}}
      value -> {:ok, value}
    end
  end

  # Normalises the plain-atom/tuple error shapes `Arbiter.Accounts` returns
  # (never seen by `Ash.Error`) into the `{:invalid_request, message}` shape
  # `ArbiterWeb.Api.FallbackController` already renders as 400. `:not_found`
  # and `%Ash.Error.Invalid{}` pass through unchanged — the fallback handles
  # both directly.
  defp friendly({:ok, _} = ok), do: ok
  defp friendly({:error, :not_found} = err), do: err
  defp friendly({:error, %Ash.Error.Invalid{}} = err), do: err

  defp friendly({:error, :ambiguous}),
    do: {:error, {:invalid_request, "ambiguous account reference — use provider:slug"}}

  defp friendly({:error, :same_account}),
    do: {:error, {:invalid_request, "cannot merge an account into itself"}}

  defp friendly({:error, :provider_mismatch}),
    do: {:error, {:invalid_request, "cannot merge accounts across providers"}}

  defp friendly({:error, :already_merged}),
    do: {:error, {:invalid_request, "the account being merged has already been merged away"}}

  defp friendly({:error, :into_already_merged}),
    do:
      {:error,
       {:invalid_request, "cannot merge into an account that has already been merged away"}}

  defp friendly({:error, {:invalid_kind, kind}}),
    do: {:error, {:invalid_request, "unknown credential kind #{inspect(kind)}"}}

  defp friendly({:error, {:provider_mismatch, provider}}),
    do: {:error, {:invalid_request, "account belongs to provider #{provider}, not the one given"}}

  defp friendly({:error, {:invalid_provider, provider}}),
    do: {:error, {:invalid_request, "unknown provider #{inspect(provider)}"}}

  defp friendly({:error, {:merged_away, survivor_id}}),
    do: {:error, {:invalid_request, "account has been merged into #{survivor_ref(survivor_id)}"}}

  defp friendly({:error, {:missing, key}}),
    do: {:error, {:invalid_request, "missing required field: #{key}"}}

  defp friendly(other), do: other

  defp survivor_ref(survivor_id) do
    case Ash.get(Accounts.ProviderAccount, survivor_id) do
      {:ok, %{provider: provider, slug: slug}} -> "#{provider}:#{slug}"
      {:error, _} -> survivor_id
    end
  end
end
