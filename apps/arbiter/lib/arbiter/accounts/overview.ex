defmodule Arbiter.Accounts.Overview do
  @moduledoc """
  The read model behind the `/providers` page (bd-cb86s4): one row per
  provider account, carrying everything the page shows about it.

    * `workspaces` — the `WorkspaceProviderAccount` links, with the
      workspace's name and `share`.
    * `credentials` — the account's **active** credentials, as metadata only
      (kind, env var, a 12-character fingerprint prefix, created_at). The
      encrypted column is never selected, so no row can carry the secret.
    * `live_count` / `max_concurrent` — `Arbiter.Accounts.Concurrency.live_count/1`,
      the registry-derived count the dispatch ceiling itself reads.
    * `quotas` — `Arbiter.Quota.list_latest/2`'s views for the account, each
      with the `gate_policy` (`Arbiter.Quota.gate_policy/2`) that the quota bar
      evaluates pace under, so a bar's utilization-vs-pace is the paced gate's
      own math, not a second definition of it.
    * `health` — credential health: `Arbiter.Agents.AuthHold` and
      `Arbiter.Agents.CredentialWatchdog` for the provider's adapter (both
      are per-*adapter*, not per-account, so every account on a provider
      shares that part), whether the account has an active credential at all,
      and the account's most recent probe/preflight `usage_events` row.
    * `usage` — the last 30 days of `usage_events` for the account: rows,
      tokens and cost. `cost_usd` is `nil` — rendered "n/a" — for a provider
      whose usage cannot be priced (Antigravity, a subscription metered by
      quota %), or whenever the ledger rows carry no cost at all; never folded
      into a misleading `$0.00`.

  Pure reads. Nothing here gates on `Arbiter.Accounts.enabled?/0` — the page
  is readable with the flag off; only its actions are gated.
  """

  require Ash.Query

  alias Arbiter.Accounts
  alias Arbiter.Accounts.{Concurrency, ProviderCredential, WorkspaceProviderAccount}
  alias Arbiter.Agents.{AuthHold, Claude, Codex, CredentialWatchdog, Gemini}
  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage
  alias Arbiter.Usage.Event

  @usage_window_days 30

  # Providers whose usage has no price (see `Arbiter.Quota`'s
  # `@ledger_providers`: Antigravity has no ledger key it can be priced by).
  @unpriced_providers [:antigravity]

  # Gemini CLI and Antigravity share the one Gemini adapter — the key both
  # `CredentialWatchdog` and `AuthHold` hold their state under.
  @adapters %{claude: Claude, codex: Codex, gemini_cli: Gemini, antigravity: Gemini}

  @type health_state :: :ok | :no_credential | :expired | :auth_hold

  @type row :: %{
          account: Arbiter.Accounts.ProviderAccount.t(),
          workspaces: [map()],
          credentials: [map()],
          live_count: non_neg_integer(),
          max_concurrent: non_neg_integer() | nil,
          quotas: [map()],
          health: map(),
          usage: map()
        }

  @doc "The usage/cost window, in days."
  @spec usage_window_days() :: pos_integer()
  def usage_window_days, do: @usage_window_days

  @doc """
  Every non-merged account, ordered as `Arbiter.Accounts.list_accounts/1`.

  `:auth_hold` / `:watchdog` name the `AuthHold` / `CredentialWatchdog`
  servers to read (default: the application singletons).
  """
  @spec list(keyword()) :: [row()]
  def list(opts \\ []) do
    accounts = Accounts.list_accounts()
    ids = Enum.map(accounts, & &1.id)

    links = links_by_account(ids)
    credentials = credentials_by_account(ids)
    quotas = quotas_by_account(ids)
    since = DateTime.add(DateTime.utc_now(), -@usage_window_days * 86_400, :second)
    health = provider_health(accounts, opts)

    Enum.map(accounts, fn account ->
      account_credentials = Map.get(credentials, account.id, [])

      %{
        account: account,
        workspaces: Map.get(links, account.id, []),
        credentials: account_credentials,
        live_count: Concurrency.live_count(account),
        max_concurrent: account.max_concurrent,
        quotas:
          quotas
          |> Map.get(account.id, [])
          |> Enum.map(&Map.put(&1, :gate_policy, Quota.gate_policy(account.id, nil))),
        health: health(account, account_credentials, Map.fetch!(health, account.provider)),
        usage: usage(account, since)
      }
    end)
  end

  @doc "The `Arbiter.Agents` adapter whose credential state covers `provider`."
  @spec adapter(atom()) :: module() | nil
  def adapter(provider), do: Map.get(@adapters, provider)

  @doc "Workspaces an account can be attached to, as `{name, id}` select options."
  @spec workspace_options() :: [{String.t(), String.t()}]
  def workspace_options do
    Workspace
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!()
    |> Enum.map(&{&1.name, &1.id})
  end

  # ---- per-account pieces ---------------------------------------------------

  defp links_by_account([]), do: %{}

  defp links_by_account(ids) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(provider_account_id in ^ids)
    |> Ash.Query.load(:workspace)
    |> Ash.read!()
    |> Enum.map(fn link ->
      %{
        id: link.id,
        account_id: link.provider_account_id,
        workspace_id: link.workspace_id,
        workspace_name: link.workspace && link.workspace.name,
        provider: link.provider,
        share: link.share
      }
    end)
    |> Enum.sort_by(& &1.workspace_name)
    |> Enum.group_by(& &1.account_id)
  end

  defp credentials_by_account([]), do: %{}

  defp credentials_by_account(ids) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id in ^ids and active == true)
    |> Ash.Query.select([:id, :provider_account_id, :kind, :env_var, :fingerprint, :created_at])
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.read!()
    |> Enum.map(fn credential ->
      %{
        id: credential.id,
        account_id: credential.provider_account_id,
        kind: credential.kind,
        env_var: credential.env_var,
        fingerprint: String.slice(credential.fingerprint, 0, 12),
        created_at: credential.created_at
      }
    end)
    |> Enum.group_by(& &1.account_id)
  end

  defp quotas_by_account([]), do: %{}

  defp quotas_by_account(ids),
    do: ids |> Quota.list_latest() |> Enum.group_by(& &1.provider_account_id)

  # AuthHold and the watchdog key their state by adapter, so read each once.
  defp provider_health(accounts, opts) do
    hold_server = Keyword.get(opts, :auth_hold, AuthHold)
    watchdog = Keyword.get(opts, :watchdog, CredentialWatchdog)

    accounts
    |> Enum.map(& &1.provider)
    |> Enum.uniq()
    |> Map.new(fn provider ->
      case adapter(provider) do
        nil ->
          {provider, %{auth_hold: nil, expired?: false}}

        adapter ->
          {provider,
           %{
             auth_hold: AuthHold.held(adapter, hold_server),
             expired?: CredentialWatchdog.expired?(adapter, watchdog)
           }}
      end
    end)
  end

  defp health(account, credentials, %{auth_hold: hold, expired?: expired?}) do
    state =
      cond do
        hold != nil -> :auth_hold
        expired? -> :expired
        credentials == [] -> :no_credential
        true -> :ok
      end

    {last_probe_at, last_probe_source} = last_probe(account.id)

    %{
      state: state,
      auth_hold: hold,
      expired?: expired?,
      last_probe_at: last_probe_at,
      last_probe_source: last_probe_source
    }
  end

  defp last_probe(account_id) do
    Event
    |> Ash.Query.filter(provider_account_id == ^account_id and source in [:probe, :preflight])
    |> Ash.Query.select([:occurred_at, :source])
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [event] -> {event.occurred_at, event.source}
      [] -> {nil, nil}
    end
  end

  defp usage(account, since) do
    rollup =
      case Usage.summarize(by: :provider_account, since: since, provider_account_id: account.id) do
        {:ok, rows} -> rows
        _ -> []
      end

    rows = Enum.reduce(rollup, 0, &(&1.rows + &2))
    tokens = Enum.reduce(rollup, 0, &(&1.tokens_in + &1.tokens_out + &2))
    cost = Enum.reduce(rollup, 0.0, &((&1.total_cost_usd || 0.0) + &2))

    # No rows at all is a definite $0 — unless the provider cannot be priced,
    # in which case it is n/a whether or not anything ran.
    priced? =
      account.provider not in @unpriced_providers and
        (rollup == [] or Enum.any?(rollup, & &1.cost_known))

    %{rows: rows, tokens: tokens, cost_usd: if(priced?, do: cost), priced?: priced?}
  end
end
