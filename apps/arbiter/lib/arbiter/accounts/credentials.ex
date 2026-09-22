defmodule Arbiter.Accounts.Credentials do
  @moduledoc """
  The read side of the provider-account tables: "what credential does a spawn
  for this workspace carry?" (P3 / bd-aiodva,
  `docs/provider-account-design.md` §5 rows 15–18).

  P1 created the tables and P2 populated them; this module is the first thing
  in the running system that *reads* them. It is consulted only when
  `Arbiter.Accounts.enabled?/0` is true — its callers
  (`Arbiter.Agents.Claude.ConfigDir`, `Arbiter.Worker.WorkerEnv`) keep their
  pre-P3 path underneath the flag, which is what makes §7.5's Release N+1
  rollback a config change rather than a deploy.

  ## The read

  One join hop, exactly as §3.3 describes it: `workspace_provider_accounts`
  (`workspace_id` → account, one row per provider) → the account's **active**
  `provider_credentials` rows → each row's `env_var` and decrypted secret.
  The result is a list of `{env_var, secret}` pairs, which is the shape both
  callers already speak, so `Dispatch`'s spawn env is unchanged (§5 row 20) —
  only the *source* of the value moves.

  Accounts with `enabled: false` supply nothing: parking an account (§3.1) is
  how an operator takes it out of service, and a parked account silently
  continuing to authenticate workers would defeat that. Retired credentials
  supply nothing either — rotation is an insert plus a retire (§3.2), and only
  the active row is current.

  A workspace with no join row resolves to `[]` here. Whether that is benign
  or an operator error is the *caller's* judgement — it is an error only when
  the pre-P3 source would have answered with a credential, which is what
  `Arbiter.Accounts.MissingCredentialError` is for.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount

  @typedoc "An env var name and the credential material it carries."
  @type pair :: {String.t(), String.t()}

  @doc """
  Every active credential the workspace's provider accounts supply, as
  `{env_var, secret}` pairs — across *all* providers it is linked to, since a
  workspace may sit on a `claude` account and a `codex` account at once
  (§3.4).

  `[]` when the workspace has no join row, no enabled account, or no active
  credential. Best-effort: a read or decrypt failure logs and contributes no
  pair rather than raising into a spawn — the caller decides whether the
  absence is fatal.
  """
  @spec workspace_pairs(String.t() | nil) :: [pair()]
  def workspace_pairs(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    workspace_id
    |> account_ids()
    |> active_credentials()
    |> Enum.flat_map(&pair/1)
  end

  def workspace_pairs(_), do: []

  @doc """
  The workspace's active credential for `env_var` (e.g.
  `CLAUDE_CODE_OAUTH_TOKEN`), or `:none`.

  The env var *is* the lookup key rather than the provider: §3.2 puts
  `env_var` on the credential row precisely so a spawn env stays a projection
  with no provider `case` statement, and the allowlist
  (`Arbiter.Accounts.Census.credential_keys/0`) maps each var to exactly one
  provider anyway.
  """
  @spec workspace_credential(String.t() | nil, String.t()) :: {:ok, String.t()} | :none
  def workspace_credential(workspace_id, env_var) do
    case List.keyfind(workspace_pairs(workspace_id), env_var, 0) do
      {^env_var, secret} -> {:ok, secret}
      nil -> :none
    end
  end

  @doc """
  The account's own `/api/oauth/usage`-authenticating credential (P6,
  `docs/provider-account-design.md` §5 row 10 / §9).

  Deliberately keyed on `kind == :cli_credentials_file`, not `env_var` — a
  `:oauth_token` row under `CLAUDE_CODE_OAUTH_TOKEN` is a `worker_env` token,
  and bd-4fbpto found that shape cannot authenticate this endpoint at all
  (see PR #1607). Only the credentials-file-sourced secret can, so this is
  the one credential kind `Arbiter.Quota.capture_oauth_usage/2` reads.

  `:none` when the account has no active credential of that kind yet — a
  pre-migration install, or an account minted by `Resolver.ensure_account_id/2`
  with no credential attached — **or when the account itself is parked**
  (`enabled: false`, §3.1): this function is polled every `CloudProbe` cycle
  independent of any workspace, so it has to enforce the module's own
  enabled-only invariant (see the moduledoc) itself rather than relying on a
  workspace-side filter like `account_ids/1` upstream of it. The caller falls
  back to `Arbiter.Quota.OAuthUsage.fetch/1`'s own default (the operator's
  `.credentials.json` on disk) in either case, unchanged from pre-P6
  behavior.

  When an account has more than one active `:cli_credentials_file` row —
  the insert-new-then-retire-old window §3.2 documents mid-rotation — the
  most recently created one wins, so a rotation in progress authenticates
  with the incoming credential rather than an arbitrary pick that could land
  on the outgoing one or flap between the two across polls.
  """
  @spec account_oauth_usage_token(String.t() | nil) :: {:ok, String.t()} | :none
  def account_oauth_usage_token(account_id) when is_binary(account_id) and account_id != "" do
    if enabled_account?(account_id) do
      [account_id]
      |> active_credentials()
      |> Enum.filter(&(&1.kind == :cli_credentials_file))
      |> Enum.max_by(& &1.created_at, DateTime, fn -> nil end)
      |> case do
        nil -> :none
        credential -> pair(credential) |> extract_secret()
      end
    else
      :none
    end
  end

  def account_oauth_usage_token(_), do: :none

  defp enabled_account?(account_id) do
    case Ash.get(ProviderAccount, account_id) do
      {:ok, %ProviderAccount{enabled: true}} -> true
      _ -> false
    end
  end

  defp extract_secret([{_env_var, secret}]), do: {:ok, secret}
  defp extract_secret([]), do: :none

  @doc """
  The install-wide credential for `env_var`, **only when it is unambiguous**:
  the single distinct secret across every enabled account that has an active
  credential under that var.

  This is the account-sourced counterpart of `ConfigDir.oauth_token/1`'s step
  3 (bd-bw3466), and exists for the same reason: a spawn with genuinely no
  workspace in hand — the fleet-wide `CredentialWatchdog` probe, a quota
  probe, a workspace-less code-review check — has no join row to read and
  still shares the install-wide config dir. When the accounts disagree we
  answer `:none` and log, rather than picking one account's grant.
  """
  @spec install_credential(String.t()) :: {:ok, String.t()} | :none
  def install_credential(env_var) when is_binary(env_var) do
    secrets =
      all_enabled_account_ids()
      |> active_credentials()
      |> Enum.filter(&(&1.env_var == env_var))
      |> Enum.flat_map(&pair/1)
      |> Enum.map(fn {_var, secret} -> secret end)
      |> Enum.uniq()

    case secrets do
      [only] ->
        {:ok, only}

      [] ->
        :none

      many ->
        Logger.warning(
          "Arbiter.Accounts.Credentials: #{length(many)} distinct #{env_var} values are " <>
            "configured across provider accounts; a spawn with no workspace in hand carries " <>
            "none of them. Point the workspace-less call sites at an account, or keep one " <>
            "account per install for this credential."
        )

        :none
    end
  end

  defp pair(%ProviderCredential{env_var: env_var} = credential) do
    case ProviderCredential.secret(credential) do
      secret when is_binary(secret) and secret != "" ->
        [{env_var, secret}]

      _ ->
        Logger.warning(
          "Arbiter.Accounts.Credentials: credential #{credential.id} (#{env_var}) did not " <>
            "decrypt to a usable secret; it supplies nothing to this spawn"
        )

        []
    end
  rescue
    error ->
      Logger.warning(
        "Arbiter.Accounts.Credentials: credential #{credential.id} raised while decrypting: " <>
          Exception.format(:error, error)
      )

      []
  end

  # A workspace id that is not a UUID cannot match a join row — every
  # `Arbiter.Tasks.Workspace` has a `uuid_v7_primary_key`. Answer "no
  # accounts" without asking the data layer, which would reject the value and
  # bury a one-line miss in a page of Ash filter error.
  defp account_ids(ws_id) when is_binary(ws_id) do
    case Ash.Type.UUID.cast_input(ws_id, []) do
      {:ok, _uuid} -> read_account_ids(ws_id)
      _ -> []
    end
  end

  defp read_account_ids(ws_id) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(workspace_id == ^ws_id)
    |> Ash.Query.load(:provider_account)
    |> Ash.read()
    |> case do
      {:ok, links} ->
        for %WorkspaceProviderAccount{provider_account: %ProviderAccount{enabled: true, id: id}} <-
              links,
            do: id

      {:error, error} ->
        Logger.warning(
          "Arbiter.Accounts.Credentials: could not read workspace_provider_accounts for " <>
            "workspace #{ws_id}: #{inspect(error)}"
        )

        []
    end
  end

  defp all_enabled_account_ids do
    ProviderAccount
    |> Ash.Query.filter(enabled == true)
    |> Ash.read()
    |> case do
      {:ok, accounts} -> Enum.map(accounts, & &1.id)
      {:error, _error} -> []
    end
  end

  defp active_credentials([]), do: []

  defp active_credentials(account_ids) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id in ^account_ids and active == true)
    |> Ash.read()
    |> case do
      {:ok, credentials} ->
        credentials

      {:error, error} ->
        Logger.warning(
          "Arbiter.Accounts.Credentials: could not read provider_credentials: #{inspect(error)}"
        )

        []
    end
  end
end
