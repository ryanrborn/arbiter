defmodule Arbiter.Accounts.Resolver do
  @moduledoc """
  The workspace → provider-account hop (`docs/provider-account-design.md`
  §3.3), read by the quota surfaces from P5 on.

  `Arbiter.Accounts.Credentials` answers "what credential does this spawn
  carry"; this module answers the plainer question the quota tables need
  now that they are keyed `(provider_account_id, provider)`: **which account
  is this workspace metered under for this provider?**

  ## Reads never create; writes ensure

  `account_id/2` is a pure read — a workspace with no join row resolves to
  `nil` and nothing is written. Quota *writes* cannot fail that way (the row
  has nowhere to go without an account), so `ensure_account_id/2` resolves or
  provisions, in three steps:

    1. the `workspace_provider_accounts` row, if there is one;
    2. the provider's **sole enabled** account, which is adopted and linked —
       this is the same "unambiguous install-wide" rule
       `Arbiter.Agents.Claude.ConfigDir.oauth_token/1` already applies to
       credentials, and it is what makes an install that never ran
       `mix arbiter.accounts.migrate` land all of its workspaces on the one
       account it actually has;
    3. otherwise a `default` account for that provider, minted once and
       shared by every workspace that reaches this step.

  Step 3 deliberately mints **one** account per provider rather than one per
  workspace: minting per workspace would reproduce exactly the
  one-row-per-workspace duplication P5 exists to remove. Where that guess is
  wrong — an operator really does run two accounts and has not linked them —
  `arb account attach` / `merge` (§2.5, P11) is the correction, and the quota
  rows follow the link.

  Provisioning never touches `provider_credentials`, so a minted account
  supplies no credential to any spawn: `Credentials.workspace_pairs/1` reads
  active credential rows, and a minted account has none. The link it writes
  is metering identity only.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Tasks.Workspace

  # The quota provider codes (`Arbiter.Quota.provider_code/1`) and the atoms
  # `ProviderAccount`/`WorkspaceProviderAccount` constrain `provider` to.
  # An explicit map rather than `String.to_existing_atom/1`, which would
  # happily accept any atom that exists anywhere in the VM.
  @providers %{
    "claude" => :claude,
    "codex" => :codex,
    "gemini_cli" => :gemini_cli,
    "antigravity" => :antigravity
  }

  @default_slug "default"

  @doc "The `ProviderAccount` atom for a quota provider code, or `nil`."
  @spec provider_atom(atom() | String.t() | nil) :: atom() | nil
  def provider_atom(provider) when is_atom(provider) and not is_nil(provider),
    do: provider_atom(Atom.to_string(provider))

  def provider_atom(provider) when is_binary(provider), do: Map.get(@providers, provider)
  def provider_atom(_), do: nil

  @doc """
  The account `workspace_id` is metered under for `provider`, or `nil` when
  the workspace has no join row for it. A pure read: nothing is created.
  """
  @spec account_id(String.t() | nil, atom() | String.t() | nil) :: String.t() | nil
  def account_id(workspace_id, provider) do
    with code when not is_nil(code) <- provider_atom(provider),
         ws_id when is_binary(ws_id) <- uuid(workspace_id),
         %WorkspaceProviderAccount{provider_account_id: id} <- link(ws_id, code) do
      id
    else
      _ -> nil
    end
  end

  @doc "`account_id/2`, loaded as the account row."
  @spec account(String.t() | nil, atom() | String.t() | nil) :: ProviderAccount.t() | nil
  def account(workspace_id, provider), do: workspace_id |> account_id(provider) |> get()

  @doc """
  Every provider this workspace is linked to, as
  `%{provider_code => account_id}`.
  """
  @spec account_ids(String.t() | nil) :: %{optional(String.t()) => String.t()}
  def account_ids(workspace_id) do
    case uuid(workspace_id) do
      nil ->
        %{}

      ws_id ->
        WorkspaceProviderAccount
        |> Ash.Query.filter(workspace_id == ^ws_id)
        |> Ash.read()
        |> case do
          {:ok, links} ->
            Map.new(links, &{Atom.to_string(&1.provider), &1.provider_account_id})

          _ ->
            %{}
        end
    end
  rescue
    _ -> %{}
  end

  @doc """
  The account to key a quota *write* for `workspace_id` / `provider` on,
  provisioning one if the install has never been through
  `mix arbiter.accounts.migrate` (see the moduledoc for the three steps).
  """
  @spec ensure_account_id(String.t() | nil, atom() | String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_account_id(workspace_id, provider) do
    with {:ok, code} <- fetch_provider(provider),
         {:ok, ws_id} <- fetch_uuid(workspace_id) do
      case account_id(ws_id, code) do
        id when is_binary(id) -> {:ok, id}
        nil -> provision(ws_id, code)
      end
    end
  end

  @doc "The account row, or `nil`."
  @spec get(String.t() | nil) :: ProviderAccount.t() | nil
  def get(account_id) when is_binary(account_id) do
    case Ash.get(ProviderAccount, account_id) do
      {:ok, account} -> account
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def get(_), do: nil

  @doc """
  Every workspace metered under `account_id`, sorted by name — the
  "N workspaces: default, emricare, vstim" breakdown §6's `arb quota` header
  prints.
  """
  @spec workspaces(String.t() | nil) :: [Workspace.t()]
  def workspaces(account_id) when is_binary(account_id) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.Query.load(:workspace)
    |> Ash.read()
    |> case do
      {:ok, links} ->
        links
        |> Enum.map(& &1.workspace)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.name)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  def workspaces(_), do: []

  @doc "The ids of `workspaces/1`."
  @spec workspace_ids(String.t() | nil) :: [String.t()]
  def workspace_ids(account_id), do: account_id |> workspaces() |> Enum.map(& &1.id)

  @doc """
  The account a workspace-less spawn (a probe/preflight round-trip, `usage.ex`
  §8) is metered under for `provider` — "a probe is issued *as* a credential",
  so unlike `account_id/2` this never answers `nil` just because there is no
  workspace to look a join row up on. Same rule `ensure_account_id/2` uses to
  provision (`adopt_or_mint/1`): the provider's sole enabled account when
  unambiguous, else the shared `default` account, minted on first call.

  Never writes a `workspace_provider_accounts` link — there is no workspace to
  link.
  """
  @spec account_id_for_probe(atom() | String.t() | nil) :: String.t() | nil
  def account_id_for_probe(provider) do
    with {:ok, code} <- fetch_provider(provider),
         {:ok, %ProviderAccount{id: id}} <- adopt_or_mint(code) do
      id
    else
      _ -> nil
    end
  end

  @doc """
  The account's sole active credential id, or `nil` when it has none, or more
  than one — an account may legitimately hold several active credentials of
  different kinds (§3.2), and picking one to stamp on a ledger row would be a
  guess. Mirrors the "carry nothing rather than guess" rule
  `Arbiter.Accounts.Credentials.install_credential/1` already applies to a
  workspace-less spawn's env var.
  """
  @spec credential_id(String.t() | nil) :: String.t() | nil
  def credential_id(account_id) when is_binary(account_id) do
    case active_credentials(account_id) do
      [%ProviderCredential{id: id}] -> id
      _ -> nil
    end
  end

  def credential_id(_), do: nil

  defp active_credentials(account_id) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account_id and active == true)
    |> Ash.read()
    |> case do
      {:ok, credentials} -> credentials
      _ -> []
    end
  end

  # ---- provisioning ------------------------------------------------------

  defp provision(ws_id, code) do
    with {:ok, account} <- adopt_or_mint(code),
         {:ok, _link} <- link_workspace(ws_id, code, account) do
      {:ok, account.id}
    end
  end

  # The provider's sole enabled account is unambiguous, so adopt it; anything
  # else (none, or several) gets the shared `default` account.
  defp adopt_or_mint(code) do
    case enabled_accounts(code) do
      [only] -> {:ok, only}
      _ -> default_account(code)
    end
  end

  defp enabled_accounts(code) do
    ProviderAccount
    |> Ash.Query.filter(provider == ^code and enabled == true)
    |> Ash.read()
    |> case do
      {:ok, accounts} -> accounts
      _ -> []
    end
  end

  defp default_account(code) do
    ProviderAccount
    |> Ash.Query.filter(provider == ^code and slug == ^@default_slug)
    |> Ash.read_one()
    |> case do
      {:ok, %ProviderAccount{} = account} ->
        {:ok, account}

      _ ->
        Ash.create(ProviderAccount, %{
          provider: code,
          slug: @default_slug,
          label: "Default #{code} account",
          identity_source: :operator
        })
    end
  end

  # A racing writer may have created the link between the read above and
  # here; re-read rather than fail the quota write on the unique index.
  defp link_workspace(ws_id, code, %ProviderAccount{} = account) do
    WorkspaceProviderAccount
    |> Ash.Changeset.for_create(:create, %{
      workspace_id: ws_id,
      provider: code,
      provider_account_id: account.id
    })
    |> Ash.create()
    |> case do
      {:ok, link} ->
        {:ok, link}

      {:error, error} ->
        case link(ws_id, code) do
          %WorkspaceProviderAccount{} = existing -> {:ok, existing}
          _ -> {:error, error}
        end
    end
  end

  defp link(ws_id, code) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(workspace_id == ^ws_id and provider == ^code)
    |> Ash.read_one()
    |> case do
      {:ok, %WorkspaceProviderAccount{} = link} -> link
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # A workspace id that is not a UUID cannot match a join row — every
  # `Arbiter.Tasks.Workspace` has a `uuid_v7_primary_key`. Answer without
  # asking the data layer, which would bury the miss in a page of filter
  # error.
  defp uuid(value) when is_binary(value) do
    case Ash.Type.UUID.cast_input(value, []) do
      {:ok, _} -> value
      _ -> nil
    end
  end

  defp uuid(_), do: nil

  defp fetch_provider(provider) do
    case provider_atom(provider) do
      nil -> {:error, {:unknown_provider, provider}}
      code -> {:ok, code}
    end
  end

  defp fetch_uuid(workspace_id) do
    case uuid(workspace_id) do
      nil -> {:error, {:invalid_workspace_id, workspace_id}}
      ws_id -> {:ok, ws_id}
    end
  end
end
