defmodule Arbiter.Accounts do
  @moduledoc """
  Ash domain for provider accounts (`docs/provider-account-design.md`).

  Phases P1 (bd-4qa1iw), P2 (bd-77j2if) and P3 (bd-aiodva). P1 created the
  three tables; P2 added `Arbiter.Accounts.Migrate` — the plan-driven
  extraction that populates them out of each workspace's encrypted
  `worker_env` — and `Arbiter.Accounts.ProviderAccountMigrationBackup`, its
  undo record.

  P3 is §7.5's "Release N+1 — read flip": `Arbiter.Accounts.Credentials`
  reads these tables, and `Arbiter.Agents.Claude.ConfigDir` /
  `Arbiter.Worker.WorkerEnv` source provider credentials from it **when
  `enabled?/0` is true**. The flag still ships `false`, so by default nothing
  consults them and `workspaces.encrypted_worker_env` remains the source of
  truth for every spawn. The blob is untouched either way — flipping the flag
  back is the whole of the rollback. Deleting the old fallbacks is P4
  (bd-cblemv).

  `Arbiter.Accounts.Census` (P0) is a plain module, not a resource in this
  domain; it inspects `worker_env` read-only and emits the candidate plan
  `Arbiter.Accounts.Migrate` consumes.
  """

  use Ash.Domain

  require Ash.Query

  resources do
    resource Arbiter.Accounts.ProviderAccount
    resource Arbiter.Accounts.ProviderCredential
    resource Arbiter.Accounts.ProviderAccountMigrationBackup
    resource Arbiter.Accounts.WorkspaceProviderAccount
  end

  @doc """
  Whether the provider-account tables are the source of truth for credentials.

  §7.5's `:provider_accounts_enabled`. Ships `false`; flipping it is a config
  change rather than a deploy, in either direction.

  Consulted by `Arbiter.Agents.Claude.ConfigDir.oauth_token/1` (and therefore
  `env/1`) and `Arbiter.Worker.WorkerEnv.resolve/1` — P3's read flip. With it
  on, a workspace that still carries a provider credential in its
  `worker_env` but has no `workspace_provider_accounts` row raises
  `Arbiter.Accounts.MissingCredentialError` rather than dispatching a worker
  with no credential: run `mix arbiter.accounts.migrate` for that workspace
  first, or turn the flag back off.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:arbiter, :provider_accounts_enabled, false) == true

  alias Arbiter.Accounts.{
    Census,
    Merge,
    ProviderAccount,
    ProviderCredential,
    WorkspaceProviderAccount
  }

  alias Arbiter.Tasks.Workspace

  @doc """
  List accounts, ordered by provider then slug. Excludes merged-away rows
  (`merged_into_id` set) unless `:include_merged` is true — P11's `arb
  account list`.
  """
  @spec list_accounts(keyword()) :: [ProviderAccount.t()]
  def list_accounts(opts \\ []) do
    query = ProviderAccount |> Ash.Query.sort(provider: :asc, slug: :asc)

    query =
      case Keyword.get(opts, :provider) do
        nil -> query
        provider -> Ash.Query.filter(query, provider == ^provider)
      end

    if Keyword.get(opts, :include_merged, false) do
      Ash.read!(query)
    else
      query |> Ash.Query.filter(is_nil(merged_into_id)) |> Ash.read!()
    end
  end

  @doc """
  Resolve one account by, in order: a UUID id, a `"provider:slug"` ref, or a
  bare `slug` — which must be unambiguous (a slug is only unique *within* a
  provider, per `ProviderAccount`'s identity). Returns `{:error, :not_found}`
  or `{:error, :ambiguous}` (bare slug matching more than one provider).
  """
  @spec get_account(String.t()) :: {:ok, ProviderAccount.t()} | {:error, :not_found | :ambiguous}
  def get_account(ref) when is_binary(ref) do
    cond do
      uuid?(ref) -> fetch_by_id(ref)
      String.contains?(ref, ":") -> fetch_by_provider_slug(ref)
      true -> fetch_by_bare_slug(ref)
    end
  end

  defp fetch_by_id(id) do
    case Ash.get(ProviderAccount, id) do
      {:ok, account} -> {:ok, account}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp fetch_by_provider_slug(ref) do
    with [provider_str, slug] <- String.split(ref, ":", parts: 2),
         {:ok, provider} <- parse_provider(provider_str) do
      ProviderAccount
      |> Ash.Query.filter(provider == ^provider and slug == ^slug)
      |> Ash.read_one()
      |> case do
        {:ok, nil} -> {:error, :not_found}
        {:ok, account} -> {:ok, account}
        {:error, _} -> {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_by_bare_slug(slug) do
    ProviderAccount
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read!()
    |> case do
      [] -> {:error, :not_found}
      [account] -> {:ok, account}
      [_ | _] -> {:error, :ambiguous}
    end
  end

  @doc """
  Parse a provider string against the known set of provider atoms
  (`claude`, `codex`, `gemini_cli`, `antigravity`). Returns `:error` for
  anything else, whether or not that string happens to already be an atom
  elsewhere in the VM.
  """
  @spec parse_provider(String.t()) :: {:ok, atom()} | :error
  def parse_provider(str) do
    case str do
      s when s in ~w(claude codex gemini_cli antigravity) -> {:ok, String.to_existing_atom(s)}
      _ -> :error
    end
  end

  defp uuid?(str), do: match?({:ok, _}, Ecto.UUID.cast(str))

  @doc """
  Create a new `ProviderAccount` — `arb account create`. Operator-asserted
  identity (§2.4): no credential is required at creation time.
  """
  @spec create_account(map()) :: {:ok, ProviderAccount.t()} | {:error, term()}
  def create_account(attrs) when is_map(attrs), do: Ash.create(ProviderAccount, attrs)

  @doc """
  Attach a workspace to an account for a provider — `arb account attach
  <workspace> <provider> <slug> [--share N]`. Writes or updates the
  `(workspace_id, provider)` `WorkspaceProviderAccount` row (`ProviderAccount`
  ref resolved via `get_account/1`).

  `:share` is only touched when the caller explicitly passes it — a bare
  re-attach (no `--share`) leaves an existing share in place instead of
  clobbering it back to `nil`.
  """
  @spec attach_workspace(String.t(), atom() | String.t(), String.t(), keyword()) ::
          {:ok, WorkspaceProviderAccount.t()} | {:error, term()}
  def attach_workspace(workspace_id, provider, account_ref, opts \\ []) do
    with {:ok, provider} <- normalize_provider(provider),
         {:ok, _workspace} <- get_workspace(workspace_id),
         {:ok, account} <- get_account(account_ref),
         :ok <- ensure_not_merged_away(account),
         :ok <- ensure_provider_match(account, provider) do
      case existing_link(workspace_id, provider) do
        nil ->
          Ash.create(WorkspaceProviderAccount, %{
            workspace_id: workspace_id,
            provider: provider,
            provider_account_id: account.id,
            share: Keyword.get(opts, :share)
          })

        link ->
          attrs =
            %{provider_account_id: account.id}
            |> maybe_put_share(opts)

          link
          |> Ash.Changeset.for_update(:update, attrs)
          |> Ash.update()
      end
    end
  end

  defp maybe_put_share(attrs, opts) do
    if Keyword.has_key?(opts, :share) do
      Map.put(attrs, :share, Keyword.get(opts, :share))
    else
      attrs
    end
  end

  defp normalize_provider(provider) when is_atom(provider), do: {:ok, provider}

  defp normalize_provider(provider) when is_binary(provider) do
    case parse_provider(provider) do
      {:ok, p} -> {:ok, p}
      :error -> {:error, {:invalid_provider, provider}}
    end
  end

  defp ensure_provider_match(%{provider: p}, p), do: :ok

  defp ensure_provider_match(%{provider: account_provider}, _),
    do: {:error, {:provider_mismatch, account_provider}}

  defp ensure_not_merged_away(%{merged_into_id: nil}), do: :ok

  defp ensure_not_merged_away(%{merged_into_id: survivor_id}),
    do: {:error, {:merged_away, survivor_id}}

  defp existing_link(workspace_id, provider) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(workspace_id == ^workspace_id and provider == ^provider)
    |> Ash.read_one!()
  end

  @doc """
  Rotate an account's credential — `arb account rotate <slug>`. Inserts a new
  active `ProviderCredential` row and retires the previous active credential
  of the same `kind` (§2.5, §7.2 — rotation is an insert, never an update). A
  data operation, not automated rotation (§11's non-goals). Never logs or
  returns the secret in a loggable form: the caller gets back the created
  row, whose `secret` field is write-only and never serialized.
  """
  @spec rotate_credential(String.t(), map()) :: {:ok, ProviderCredential.t()} | {:error, term()}
  def rotate_credential(account_ref, attrs) when is_map(attrs) do
    with {:ok, account} <- get_account(account_ref),
         :ok <- ensure_not_merged_away(account),
         {:ok, secret} <- fetch_required(attrs, :secret),
         {:ok, raw_kind} <- fetch_required(attrs, :kind),
         {:ok, kind} <- parse_kind(raw_kind),
         {:ok, env_var} <- fetch_required(attrs, :env_var) do
      Arbiter.Repo.transaction(fn ->
        # Retire the current active credential of this kind *first* — the
        # partial unique index allows only one active row per
        # (account, kind), so the new insert would otherwise collide with it.
        retire_previous(account.id, kind)

        case Ash.create(ProviderCredential, %{
               provider_account_id: account.id,
               kind: kind,
               env_var: env_var,
               secret: secret,
               fingerprint: Census.fingerprint(secret),
               scopes: Map.get(attrs, :scopes) || Map.get(attrs, "scopes")
             }) do
          {:ok, credential} -> credential
          {:error, error} -> Arbiter.Repo.rollback(error)
        end
      end)
    end
  end

  @credential_kinds ~w(oauth_token api_key cli_credentials_file)

  defp parse_kind(kind)
       when is_atom(kind) and kind in [:oauth_token, :api_key, :cli_credentials_file],
       do: {:ok, kind}

  defp parse_kind(kind) when kind in @credential_kinds, do: {:ok, String.to_existing_atom(kind)}
  defp parse_kind(kind), do: {:error, {:invalid_kind, kind}}

  defp fetch_required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp retire_previous(account_id, kind) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account_id and kind == ^kind and active == true)
    |> Ash.read!()
    |> Enum.each(&Ash.update!(&1, %{}, action: :retire))
  end

  @doc """
  Merge `from_ref` into `into_ref` — `arb account merge <from-slug> --into
  <into-slug>` (§2.5). Transactional; see `Arbiter.Accounts.Merge` for the
  per-table re-point rules.
  """
  @spec merge_accounts(String.t(), String.t()) :: {:ok, ProviderAccount.t()} | {:error, term()}
  defdelegate merge_accounts(from_ref, into_ref), to: Merge, as: :merge

  @doc "Resolve a workspace by UUID id (`arb account attach`'s `<workspace>` arg)."
  @spec get_workspace(String.t()) :: {:ok, Workspace.t()} | {:error, :not_found}
  def get_workspace(id) do
    if uuid?(id) do
      case Ash.get(Workspace, id) do
        {:ok, workspace} -> {:ok, workspace}
        {:error, _} -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end
end
