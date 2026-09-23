defmodule Arbiter.Quota do
  @moduledoc """
  Ash domain + public API for per-**account** Anthropic quota state
  (bd-5boun6; re-keyed off the workspace by P5, bd-3yokey).

  `get/2` / `serialize/2` read quota snapshots for the MCP `quota_get` tool,
  the `GET /api/quota` endpoint, and `arb quota`.

  ## Quota source: polling + archived header capture

  The primary source is `capture_oauth_usage/2`, which consumes Anthropic's
  polled `/api/oauth/usage` endpoint snapshot, driven by `Arbiter.Quota.CloudProbe`.
  This allows the dispatch gate to work on a fleet that is quota-held or idle,
  with current data. Per-model weekly breakdowns and account overage spend are
  available only through this endpoint.

  `capture/3` is now dormant / archival-only (bd-7cvh8z): it consumed
  `anthropic-ratelimit-unified-*` response headers from worker traffic, but
  the Anthropic proxy that was the sole caller was deleted once endpoint polling
  became the unified architecture across all providers. The function remains
  for compatibility with any offline migration workflows, but produces no
  in-production quota updates.

  Each write stamps `capture_source` (`"headers"` / `"oauth_poll"`, see
  `header_source/0` and `oauth_poll_source/0`) so a row says which one
  produced it — `arb quota` prints it, and
  `Arbiter.Quota.Gate.staleness_threshold_seconds/1` keys the staleness margin
  off it, because the polled source has a far tighter request budget than
  header capture ever did.

  ## Keyed by the provider account (P5, `docs/provider-account-design.md` §6)

  Every provider's rate limit is enforced per *account*, so the read API here
  takes a `provider_account_id`, not a workspace: `latest/2`,
  `latest_for_provider/2`, `serialize/3`, `list_latest/1`,
  `provider_spend/1` and `capture_oauth_usage/2` all key on the account.

  A caller holding only a workspace resolves it first —
  `account_id/2` (a pure read, `nil` when the workspace has no account) or
  `ensure_account_id/2` (write paths, which provision rather than drop the
  reading). Workspace-flavoured *writes* — `capture/3`,
  `capture_oauth_usage_for_group/2` — keep their workspace argument and do
  that hop themselves, so a spawn's call site is unchanged.
  """

  use Ash.Domain

  alias Arbiter.Accounts.Credentials
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.CloudCode
  alias Arbiter.Tasks.Workspace
  require Ash.Query

  resources do
    resource Arbiter.Quota.AnthropicQuota
    resource Arbiter.Quota.CodexQuota
    resource Arbiter.Quota.GoogleQuota
  end

  @default_provider "claude"

  @typedoc """
  A `%{workspace_id => workspace_spend/1}` memo, built by `spend_cache/1` and
  threaded through `account_fields/3` so one request's worth of quota views
  scans the usage ledger once per workspace rather than once per
  workspace-and-provider.
  """
  @type spend_cache :: %{optional(String.t()) => %{optional(String.t()) => float()}}

  # `capture_source` provenance markers (bd-b0zody). Both sources write the
  # same primary columns during the overlap window, so the row records which
  # one last wrote it — `arb quota` prints it, and `Arbiter.Quota.Gate` picks
  # its staleness threshold off it.
  @header_source "headers"
  @oauth_poll_source "oauth_poll"

  @doc "The `capture_source` value `capture/3` (header capture) stamps."
  @spec header_source() :: String.t()
  def header_source, do: @header_source

  @doc "The `capture_source` value the `/api/oauth/usage` poll stamps."
  @spec oauth_poll_source() :: String.t()
  def oauth_poll_source, do: @oauth_poll_source

  # Cost pricing (bd-ajh7bd). Rather than invent a second price table, we reuse
  # the real per-session `cost_usd` already recorded in the `Arbiter.Usage`
  # ledger (which prices Claude off the CLI's own figure and Gemini via
  # `Arbiter.Agents.Gemini.Pricing`) and roll a trailing window of actual spend
  # up per provider, so `arb quota` / the `/usage` page can show dollars spent
  # alongside utilization %.
  #
  # The ledger keys spend by an inferred provider ("claude" / "gemini" /
  # "openai"), which doesn't 1:1 match the quota provider codes — this maps each
  # quota code to the ledger key(s) that roll up under it. Antigravity has no
  # distinct ledger key (it shares Gemini/Claude/GPT models with other surfaces,
  # so its spend can't be cleanly attributed) → no cost figure.
  @ledger_providers %{
    "claude" => ["claude"],
    "codex" => ["openai"],
    "gemini_cli" => ["gemini"],
    "antigravity" => []
  }

  # Trailing window over which per-provider spend is summed for the cost figure.
  @cost_window_days 30

  # ---- dispatch gate (bd-7cd38f) -----------------------------------------

  @doc """
  Resolve the `Arbiter.Quota.Gate` implementation for a workspace.

  Precedence:

    1. The `:arbiter, :quota` `:gate` app-env override — a hard module override
       used as the kill switch and the test-injection seam. Set it to
       `Arbiter.Quota.Gate.Continue` (or a stub) to bypass throttling entirely.
    2. Otherwise the workspace's resolved `on_exhaustion` mode
       (`Workspace.quota_on_exhaustion/1`, which itself layers per-workspace over
       global over the hardcoded `:throttle`): `:continue` → `Gate.Continue`,
       else `Gate.Throttle`.
  """
  @spec gate_for_workspace(Workspace.t() | nil) :: module()
  def gate_for_workspace(workspace) do
    case Application.get_env(:arbiter, :quota, [])[:gate] do
      mod when is_atom(mod) and not is_nil(mod) ->
        mod

      _ ->
        case Workspace.quota_on_exhaustion(workspace) do
          :continue -> Arbiter.Quota.Gate.Continue
          _ -> Arbiter.Quota.Gate.Throttle
        end
    end
  end

  @doc """
  Whether the workspace's resolved quota gate is `:continue` mode — the
  `dispatch/2` seam will let work through past the cap (paid overage) rather
  than holding it.

  Shared by `Arbiter.Board.Snapshot.quota_hold/1` (bd-5j6nmn) so the board and
  Autopilot's one-per-tick promotion gate defer to the same
  seam-resolved mode — including the `:arbiter, :quota, :gate` test/kill-switch
  override — instead of each independently re-deriving `on_exhaustion`.
  """
  @spec continue_mode?(Workspace.t() | nil) :: boolean()
  def continue_mode?(workspace) do
    gate_for_workspace(workspace) == Arbiter.Quota.Gate.Continue
  end

  # Quota-provider code for each dispatchable agent type / provider alias. The
  # gate resolves the provider a dispatch will actually run on and reads that
  # provider's snapshot table through `latest_for_provider/2` (bd-2mpo3f).
  #
  # `"gemini"` (the agent-type alias, as opposed to the concrete `"gemini_cli"`
  # / `"antigravity"` codes) is deliberately absent here — it is resolved
  # dynamically in `provider_code/1` via `Arbiter.Agents.Gemini.resolve_executable/0`
  # (bd-7qj58o) rather than pinned to a static code, so the gate always reads
  # the quota table matching the CLI that will actually run.
  @provider_codes %{
    "claude" => "claude",
    "anthropic" => "claude",
    "codex" => "codex",
    "openai" => "codex",
    "gemini_cli" => "gemini_cli",
    "antigravity" => "antigravity"
  }

  @doc """
  The latest persisted quota snapshot for `provider_account_id` on
  `provider`, read from that provider's own table (bd-2mpo3f):

    * `:claude` → `AnthropicQuota` (OAuth polling + header capture from responses)
    * `:codex` → `CodexQuota` (`Arbiter.Quota.CloudProbe` / `Quota.Codex.fetch/2`)
    * `:gemini` / `:antigravity` → `GoogleQuota` (`Arbiter.Quota.CloudCode`)

  Accepts the agent-type atom (`:claude` / `:codex` / `:gemini`) or the quota
  provider code string. Returns `nil` for an unknown provider or when nothing
  has been captured yet — the gate's fail-open input.
  """
  @spec latest_for_provider(String.t() | nil, atom() | String.t()) :: struct() | nil
  def latest_for_provider(account_id, provider) when is_binary(account_id) do
    case provider_code(provider) do
      "claude" -> latest(account_id, "claude")
      "codex" -> Arbiter.Quota.Codex.latest(account_id, "codex")
      code when code in ["gemini_cli", "antigravity"] -> CloudCode.latest(account_id, code)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def latest_for_provider(_account_id, _provider), do: nil

  @doc """
  `latest_for_provider/2` for a caller that holds a workspace rather than an
  account — the shape the dispatch gate, the board and `Dispatch` still speak
  (their own re-key is P7/P8). `nil` when the workspace has no account for
  that provider, which is the gate's existing fail-open input.
  """
  @spec latest_for_workspace(String.t() | nil, atom() | String.t()) :: struct() | nil
  def latest_for_workspace(workspace_id, provider) do
    case account_id(workspace_id, provider) do
      nil -> nil
      id -> latest_for_provider(id, provider)
    end
  end

  @doc """
  The provider account `workspace_id` is metered under for `provider`, or
  `nil`. A pure read — see `Arbiter.Accounts.Resolver`.
  """
  @spec account_id(String.t() | nil, atom() | String.t() | nil) :: String.t() | nil
  def account_id(workspace_id, provider),
    do: Resolver.account_id(workspace_id, provider_code(provider) || provider)

  @doc """
  `account_id/2`, provisioning an account when the install has none — the
  form every quota *write* uses, because a reading has nowhere to go without
  one.
  """
  @spec ensure_account_id(String.t() | nil, atom() | String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_account_id(workspace_id, provider),
    do: Resolver.ensure_account_id(workspace_id, provider_code(provider) || provider)

  @doc "Every provider account this workspace is linked to, `%{provider => account_id}`."
  @spec account_ids(String.t() | nil) :: %{optional(String.t()) => String.t()}
  def account_ids(workspace_id), do: Resolver.account_ids(workspace_id)

  @doc """
  Canonical quota provider code for an agent type / provider alias, or `nil`
  when the provider has no tracked quota. `:gemini` and `:antigravity` both
  resolve into the Google Cloud Code table under distinct codes.

  `"gemini"` is resolved dynamically (bd-7qj58o): it reuses
  `Arbiter.Agents.Gemini.resolve_executable/0` — the same PATH probe the
  adapter itself uses to pick a CLI to spawn — to return `"antigravity"` when
  `agy` is what will actually run, or `"gemini_cli"` when the upstream CLI (or
  neither, matching the adapter's historical dispatch-fails default) would.
  A caller that already names the concrete code (`"gemini_cli"` /
  `"antigravity"`) gets it back verbatim — only the ambiguous agent-type alias
  is resolved live.
  """
  @spec provider_code(atom() | String.t() | nil) :: String.t() | nil
  def provider_code(provider) when is_atom(provider) and not is_nil(provider),
    do: provider_code(Atom.to_string(provider))

  def provider_code("gemini"), do: gemini_provider_code()
  def provider_code(provider) when is_binary(provider), do: Map.get(@provider_codes, provider)
  def provider_code(_), do: nil

  defp gemini_provider_code do
    case Arbiter.Agents.Gemini.resolve_executable() do
      {:ok, {:agy, _path}} -> "antigravity"
      _ -> "gemini_cli"
    end
  end

  @doc """
  Best-effort resolution of the quota provider a workspace's dispatches run
  on absent a per-dispatch override — the workspace's default agent provider
  (`Arbiter.Agents.for_workspace/1`), as an atom.

  Used by the board's dispatch gate (`Arbiter.Board.Snapshot.quota_hold/1`,
  bd-5j6nmn) and the `dispatch/2` seam, so both read the same provider's
  snapshot for a given workspace. Any load failure or unresolvable id falls back to `:claude`
  (the historical default).
  """
  @spec default_provider(Workspace.t() | String.t() | nil) :: atom()
  def default_provider(%Workspace{} = workspace) do
    String.to_existing_atom(Arbiter.Agents.for_workspace(workspace).provider())
  rescue
    _ -> :claude
  end

  def default_provider(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> default_provider(ws)
      _ -> :claude
    end
  rescue
    _ -> :claude
  catch
    :exit, _ -> :claude
  end

  def default_provider(_), do: :claude

  # ---- capture -----------------------------------------------------------

  @doc """
  Upsert a quota snapshot for `workspace_id` from a list of HTTP response
  `headers` (`[{name, value}]`, as Finch/Plug deliver them).

  Returns `{:ok, quota}` when the headers carried any
  `anthropic-ratelimit-unified-*` value, `:noop` when they didn't (so health
  checks and non-Anthropic responses are silently skipped), and
  `{:error, reason}` if the upsert fails.

  A `nil` / blank `workspace_id` is resolved to the installation default
  workspace so a workspace-agnostic credential probe still records state, and
  from there to the provider account that workspace meters under (P5) — the
  row itself is keyed by the account.
  """
  @spec capture(String.t() | nil, [{String.t(), String.t()}], keyword()) ::
          {:ok, AnthropicQuota.t()} | :noop | {:error, term()}
  def capture(workspace_id, headers, opts \\ []) when is_list(headers) do
    case parse_unified_headers(headers) do
      attrs when map_size(attrs) == 0 ->
        :noop

      attrs ->
        provider = Keyword.get(opts, :provider, @default_provider)

        with {:ok, ws_id} <- resolve_workspace_id(workspace_id),
             {:ok, account_id} <- ensure_account_id(ws_id, provider) do
          full =
            attrs
            |> Map.put(:provider_account_id, account_id)
            |> Map.put(:provider, provider)
            |> Map.put(:capture_source, @header_source)
            |> Map.put_new(:captured_at, DateTime.utc_now() |> DateTime.truncate(:second))

          require Logger

          Logger.debug(
            "Quota.capture: account=#{account_id}, provider=#{provider}, status_5h=#{Map.get(attrs, :status_5h)}, utilization_5h=#{Map.get(attrs, :utilization_5h)}, captured_at=#{Map.get(full, :captured_at)}"
          )

          result =
            AnthropicQuota
            |> Ash.Changeset.for_create(:upsert, full)
            |> Ash.create()

          with {:ok, quota} <- result do
            broadcast_quota_update(account_id, quota)
          end

          result
        end
    end
  end

  # Broadcast a quota update, carrying the uniform view map (not the raw
  # resource struct) so every provider's live update lands on the LiveView in
  # the same shape `list_latest/1` returns.
  #
  # The topic is still per workspace — that is what the dashboard subscribes
  # to, and a workspace is what a page is looking at — so one account-keyed
  # write fans out to every workspace metered under that account (P5).
  defp broadcast_quota_update(account_id, %AnthropicQuota{} = quota) do
    Arbiter.Quota.Broadcast.quota_updated(account_id, view(quota))
  end

  @doc """
  Latest quota snapshot for `provider_account_id` + `provider`, or `nil` if
  none has been captured yet.
  """
  @spec latest(String.t() | nil, String.t()) :: AnthropicQuota.t() | nil
  def latest(account_id, provider \\ @default_provider)

  def latest(account_id, provider) when is_binary(account_id) do
    AnthropicQuota
    |> Ash.Query.filter(provider_account_id == ^account_id and provider == ^provider)
    |> Ash.read_one()
    |> case do
      {:ok, %AnthropicQuota{} = q} -> q
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # A caller whose workspace has no account for this provider yet (§6's
  # backfill has not reached it) reads as "nothing captured", which is the
  # same fail-open input a missing row already produced.
  def latest(_account_id, _provider), do: nil

  @doc """
  Serialize the latest snapshot for `provider_account_id` into the public map
  shape (string-friendly, ISO-8601 timestamps), or `nil` when none exists.

  `:workspace_id` names the workspace whose gate config annotates the
  `gating_*` fields. Thresholds are still workspace-scoped until P7, so a
  caller that came in through `arb quota --workspace X` passes X here and
  gets the same answer it did before the re-key; with none given the
  account's alphabetically-first workspace stands in.

  `:spend_cache` optionally supplies a `spend_cache/1` memo so a caller that
  also lists the other providers pays for the ledger scan once — see
  `account_fields/3`.
  """
  @spec serialize(String.t() | nil, String.t(), keyword()) :: map() | nil
  def serialize(account_id, provider \\ @default_provider, opts \\ []) do
    case latest(account_id, provider) do
      nil ->
        nil

      %AnthropicQuota{} = q ->
        q
        |> serialize_quota()
        |> Map.merge(gating_fields(q, Resolver.get(account_id), gate_workspace(account_id, opts)))
        |> Map.merge(account_fields(account_id, provider, Keyword.get(opts, :spend_cache, %{})))
    end
  end

  defp gate_workspace(account_id, opts) do
    case Keyword.get(opts, :workspace_id) do
      ws_id when is_binary(ws_id) -> safe_workspace(ws_id)
      _ -> account_id |> Resolver.workspaces() |> List.first()
    end
  end

  # Which window (if any) is currently gating dispatch for this workspace, as
  # `arb quota` / the `quota_get` MCP tool render it (bd-1tuxv8). Before this,
  # both surfaces showed the 5h and 7d numbers side by side with no indication
  # that only the 5h one was ever consulted — the coordinator read the 7d row as
  # the thing holding Autopilot back when the gate never looked at it.
  defp gating_fields(%AnthropicQuota{} = q, account, workspace) do
    if Arbiter.Quota.continue_mode?(workspace) do
      # `:continue` workspaces dispatch past the cap by design, so no window
      # gates them — mirroring `Board.Snapshot.quota_hold/1`'s short-circuit.
      %{gating_window: nil, gating_reason: nil}
    else
      # P7 (§4.2): thresholds resolve `min(account, workspace)`, so the
      # rendered reason has to be computed against the same pair the gate
      # itself uses — otherwise `arb quota` reports headroom that dispatch
      # has already closed.
      policy = {account, workspace}

      case Arbiter.Quota.Gate.gating_window(q, policy) do
        nil ->
          %{gating_window: nil, gating_reason: nil}

        %{window: w} ->
          %{gating_window: w, gating_reason: Arbiter.Quota.Gate.hold_phrase(q, policy)}
      end
    end
  end

  defp safe_workspace(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ---- account identity + per-workspace breakdown (P5, §6) ---------------

  @doc """
  The account header §6's `arb quota` prints, plus the per-workspace spend
  breakdown underneath it: `%{account: …, workspaces: […]}`.

  `workspaces` carries each workspace metered under the account with its own
  30-day spend for `provider`, so the CLI can render
  `default $A · emricare $B · vstim $C` under the account total. Empty when
  the account has no workspaces linked to it yet.

  `cache` is an optional `spend_cache/1` memo. Each `workspace_spend/1` term
  is a full 30-day ledger scan for that workspace and is *provider
  independent*, so a caller that asks for several providers' fields (every
  page mount goes through `list_latest/2`, which asks for four) must pass one
  cache rather than rescan the ledger once per provider per workspace.
  """
  @spec account_fields(String.t() | nil, String.t(), spend_cache()) :: map()
  def account_fields(account_id, provider \\ @default_provider, cache \\ %{}) do
    %{
      account: account_view(Resolver.get(account_id)),
      workspaces:
        Enum.map(Resolver.workspaces(account_id), fn ws ->
          %{id: ws.id, name: ws.name, cost_usd: cost_for(provider, cached_spend(ws.id, cache))}
        end)
    }
  end

  defp cached_spend(workspace_id, cache),
    do: Map.get_lazy(cache, workspace_id, fn -> workspace_spend(workspace_id) end)

  defp account_view(%ProviderAccount{} = account) do
    %{
      id: account.id,
      slug: account.slug,
      provider: Atom.to_string(account.provider),
      label: account.label,
      plan: account.plan
    }
  end

  defp account_view(_), do: nil

  # ---- uniform multi-provider view (bd-ajh7bd) ---------------------------

  @doc """
  The canonical empty quota "view" — the uniform two-window shape the topbar and
  `/usage` page render, one entry per tracked provider. Each provider's `view/1`
  merges its real figures onto this so the UI can read a single set of keys
  (`utilization_5h`, `reset_5h_at`, `overage_status`, …) across Claude, Codex,
  Gemini CLI, and Antigravity — whose native shapes differ (5h/7d vs
  session/weekly vs per-model). `primary_label` / `secondary_label` name the two
  bars per provider (Claude: "5h"/"7d"; Codex: "session"/"weekly"; Google:
  "used"/none).
  """
  @spec blank_view(String.t()) :: map()
  def blank_view(provider) when is_binary(provider) do
    %{
      # Deprecated (P5): kept for one release as the alias for "the workspace
      # this view was looked up through". The account is the real key.
      workspace_id: nil,
      provider_account_id: nil,
      account: nil,
      workspaces: [],
      provider: provider,
      utilization_5h: nil,
      reset_5h_at: nil,
      status_5h: nil,
      utilization_7d: nil,
      reset_7d_at: nil,
      status_7d: nil,
      overage_status: nil,
      representative_claim: nil,
      captured_at: nil,
      per_model_utilization: %{},
      extra_usage: %{},
      oauth_utilization_5h: nil,
      oauth_utilization_7d: nil,
      oauth_captured_at: nil,
      capture_source: nil,
      primary_label: "5h",
      secondary_label: "7d",
      plan: nil,
      message: nil,
      models: [],
      cost_usd: nil
    }
  end

  @doc "Map a loaded `AnthropicQuota` row to the uniform quota view shape."
  @spec view(AnthropicQuota.t()) :: map()
  def view(%AnthropicQuota{} = q) do
    blank_view(q.provider)
    |> Map.merge(%{
      provider_account_id: q.provider_account_id,
      utilization_5h: q.utilization_5h,
      reset_5h_at: q.reset_5h_at,
      status_5h: q.status_5h,
      utilization_7d: q.utilization_7d,
      reset_7d_at: q.reset_7d_at,
      status_7d: q.status_7d,
      overage_status: q.overage_status,
      representative_claim: q.representative_claim,
      captured_at: q.captured_at,
      per_model_utilization: q.per_model_utilization || %{},
      extra_usage: q.extra_usage || %{},
      oauth_utilization_5h: q.oauth_utilization_5h,
      oauth_utilization_7d: q.oauth_utilization_7d,
      oauth_captured_at: q.oauth_captured_at,
      capture_source: q.capture_source
    })
  end

  @doc """
  The human-readable `codex_message` the `arb quota` / `quota_get` surface pairs
  with a `nil` Codex snapshot. `nil` when a snapshot *is* present (bd-ajh7bd).

  In the pure-DB-read world a missing Codex row means the periodic probe hasn't
  stored one yet — almost always because the `codex` CLI isn't authenticated on
  this host (the probe no-ops without creds).
  """
  @spec codex_absence_message(map() | nil) :: String.t() | nil
  def codex_absence_message(nil),
    do: "Codex quota not captured yet — authenticate the codex CLI on this host."

  def codex_absence_message(_present), do: nil

  @doc "Serialize a loaded `AnthropicQuota` row into the public map shape."
  @spec serialize_quota(AnthropicQuota.t()) :: map()
  def serialize_quota(%AnthropicQuota{} = q) do
    %{
      provider: q.provider,
      provider_account_id: q.provider_account_id,
      utilization_5h: q.utilization_5h,
      reset_5h_at: iso(q.reset_5h_at),
      status_5h: q.status_5h,
      utilization_7d: q.utilization_7d,
      reset_7d_at: iso(q.reset_7d_at),
      status_7d: q.status_7d,
      representative_claim: q.representative_claim,
      overage_status: q.overage_status,
      captured_at: iso(q.captured_at),
      stale: Arbiter.Quota.Gate.stale?(q),
      # bd-4fbpto: `stale` alone can't distinguish "nothing has succeeded in a
      # while" from "the poll is fine, it just hasn't landed a usable 5h figure
      # this cycle" — both look identical (STALE, old `captured_at`) without
      # this. `arb quota` uses it to say which one it is.
      oauth_poll_fresh: Arbiter.Quota.Gate.oauth_poll_fresh?(q),
      # bd-1pmf9h: `stale` alone reads identically whether the poll is merely
      # quiet or the fleet is flatly unauthenticated — a dead token still
      # serves a stale-but-present snapshot for hours. Surfaces
      # `CredentialWatchdog`'s own expiry state (set by `CloudProbe`'s
      # consecutive-401 tracking or the periodic CLI probe) directly here.
      credentials_expired: Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Claude),
      per_model_utilization: q.per_model_utilization || %{},
      extra_usage: q.extra_usage || %{},
      oauth_utilization_5h: q.oauth_utilization_5h,
      oauth_utilization_7d: q.oauth_utilization_7d,
      oauth_captured_at: iso(q.oauth_captured_at),
      capture_source: q.capture_source
    }
  end

  # ---- Google Cloud Code Assist quota (bd-57ukgb) ------------------------

  @doc """
  On-demand Gemini CLI + Antigravity quota snapshots via the Cloud Code Assist
  API (`Arbiter.Quota.CloudCode`).

  Returns `%{gemini: snapshot | nil, antigravity: snapshot | nil}`. Unlike the
  Anthropic snapshot — persisted from OAuth polling + response header capture —
  these fetch live from Google, so both providers are queried concurrently and
  each is bounded by a timeout; a hung or crashed fetch degrades to `nil`.

  Gated by the `:arbiter, :cloud_code_quota` `:enabled` flag (default on; the
  test env turns it off so `GET /api/quota` stays a pure DB read there). Pass
  `enabled: true` in `opts` to force the live path in a test that stubs HTTP.

  Options are forwarded to `CloudCode.gemini/1` and `CloudCode.antigravity/1`
  (`:creds_path`, `:project_id`, `:plug`, `:receive_timeout`).
  """
  @spec google_snapshots(keyword()) :: %{gemini: map() | nil, antigravity: map() | nil}
  def google_snapshots(opts \\ []) do
    if google_enabled?(opts) do
      fetch_opts = Keyword.delete(opts, :enabled)

      gemini = Task.async(fn -> CloudCode.gemini(fetch_opts) end)
      antigravity = Task.async(fn -> CloudCode.antigravity(fetch_opts) end)

      %{
        gemini: await_snapshot(gemini),
        antigravity: await_snapshot(antigravity)
      }
    else
      %{gemini: nil, antigravity: nil}
    end
  end

  defp google_enabled?(opts) do
    case Keyword.fetch(opts, :enabled) do
      {:ok, val} -> val == true
      :error -> Application.get_env(:arbiter, :cloud_code_quota, [])[:enabled] != false
    end
  end

  # CloudCode fetchers never raise, but bound the wall time anyway so a stalled
  # Google endpoint can't hang the quota surface. A timeout / crash → nil.
  defp await_snapshot(task) do
    case Task.yield(task, 20_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> nil
    end
  end

  @doc """
  On-demand fetch of Anthropic's `/api/oauth/usage` endpoint (bd-8tpha6) —
  per-model weekly utilization + `extra_usage` overage, layered onto the
  account's `AnthropicQuota` snapshot alongside (never instead of) the
  header-capture aggregate figures. Takes a `provider_account_id` since P5
  (§6) — `/api/oauth/usage` is an account endpoint and always was.

  Best-effort by design: a 429 cooldown (`Arbiter.Quota.OAuthUsage`), missing
  credentials, or any transport error is returned as `{:error, reason}` here
  but never raises — callers that just want "whatever we have" should use
  `refresh_and_serialize/2` instead, which swallows this outright.

  Since P6 (§9), an explicit `:token` in `opts` (tests, or an already-resolved
  credential) is always honored as-is. Otherwise this resolves *this
  account's own* `cli_credentials_file` credential
  (`Arbiter.Accounts.Credentials.account_oauth_usage_token/1`) to authenticate
  the request, and tags the fetch with `:provider_account_id` so
  `Arbiter.Quota.OAuthUsage`'s 429 cooldown is keyed on the account, not
  whichever credential happened to authenticate it — two credentials on one
  account (e.g. mid-rotation) share the one cooldown window the account's
  rate limit actually enforces. An account with no credential row yet (a
  pre-migration install) falls back to `OAuthUsage.fetch/1`'s own default
  (the operator's `.credentials.json` on disk).
  """
  @spec capture_oauth_usage(String.t() | nil, keyword()) ::
          {:ok, AnthropicQuota.t()} | {:error, term()}
  def capture_oauth_usage(account_id, opts \\ []) do
    case capture_oauth_usage_tagged(account_id, opts) do
      {:error, {_stage, reason}} -> {:error, reason}
      other -> other
    end
  end

  # Same fetch-then-write as `capture_oauth_usage/2`, but keeps the failure
  # tagged with which stage produced it (`:fetch` vs `:write`) instead of
  # collapsing both to a bare `{:error, reason}`. `write_once_per_account/4`
  # needs that distinction: a per-account *fetch* failure (a 401, a transport
  # error, an unresolvable account) must count toward `CloudProbe`'s
  # consecutive-failure/401 streaks even when other accounts in the same
  # cycle succeed, while a *write* failure (fetch succeeded, only the DB
  # write failed) must not be conflated with it. See the HIGH finding on
  # bd-3j92yv: before this, both stages surfaced as the same bare error and
  # `CloudProbe.note_oauth_result/3` reset the streak on any cycle where at
  # least one account succeeded, silently killing 401/failure detection for
  # any multi-account install.
  defp capture_oauth_usage_tagged(account_id, opts) do
    provider = Keyword.get(opts, :provider, @default_provider)

    case fetch_account_id(account_id) do
      {:error, reason} ->
        {:error, {:fetch, reason}}

      {:ok, id} ->
        case Arbiter.Quota.OAuthUsage.fetch(account_oauth_fetch_opts(id, opts)) do
          {:error, reason} -> {:error, {:fetch, reason}}
          {:ok, usage} -> tag_write_error(record_oauth_usage(id, provider, usage))
        end
    end
  end

  defp tag_write_error({:error, reason}), do: {:error, {:write, reason}}
  defp tag_write_error(ok), do: ok

  # Resolves the token to authenticate `/api/oauth/usage` with (see the
  # moduledoc on `capture_oauth_usage/2`). An explicit `:token` already in
  # `opts` — the pre-P6 shape every existing test and on-demand caller uses —
  # is never overridden, and in that case the cooldown stays keyed on the
  # token exactly as before P6, so a caller that already knows exactly which
  # credential it wants keeps full control of both the fetch and the
  # cooldown it shares with other calls using that same explicit token.
  defp account_oauth_fetch_opts(account_id, opts) do
    if Keyword.has_key?(opts, :token) do
      opts
    else
      case Credentials.account_oauth_usage_token(account_id) do
        # Only tag the fetch with `:provider_account_id` — and so only key
        # its 429 cooldown on the account — when a per-account credential
        # was actually resolved. When it wasn't (`:none`: pre-migration or
        # partially-migrated install), `OAuthUsage.fetch/1` falls back to
        # the operator's on-disk `.credentials.json`, the same real token
        # every credential-less account shares; tagging the account here
        # regardless (as before) gave every such account its own cooldown
        # key for that one shared token, so a 429 on one no longer
        # suppressed the others — exactly the multiplication this option
        # exists to eliminate. Leaving `opts` untouched here keeps the
        # pre-P6 token-keyed cooldown for that shared-fallback case.
        {:ok, token} ->
          opts
          |> Keyword.put(:provider_account_id, account_id)
          |> Keyword.put(:token, token)

        :none ->
          opts
      end
    end
  end

  # A write has to name a real account row: the quota tables carry no FK (the
  # column is plain text on SQLite), so a caller that still passes a
  # workspace id here would otherwise create a row keyed by something that is
  # not an account and never be read back. Fail loudly instead.
  defp fetch_account_id(account_id) when is_binary(account_id) and account_id != "" do
    case Resolver.get(account_id) do
      %ProviderAccount{id: id} -> {:ok, id}
      _ -> {:error, {:no_provider_account, account_id}}
    end
  end

  defp fetch_account_id(other), do: {:error, {:no_provider_account, other}}

  @doc """
  `capture_oauth_usage/2`, but for a *group of workspaces* (bd-5xuneh).
  `/api/oauth/usage` is account-wide and rate-limited per account, not per
  workspace, so fetching it once per workspace burns the shared rate-limit
  budget for an identical number.

  bd-5xuneh originally grouped workspaces by
  `Arbiter.Agents.Claude.ConfigDir.oauth_token/1` and passed the resolved
  token through `opts`, on the theory that a workspace's own `worker_env`
  token could authenticate this call. bd-4fbpto found that backwards — that
  token is scope/rate-limited for this endpoint and passing it here is why
  every poll silently failed once the header-capture fallback was removed
  (see the status codes and body shapes recorded in PR #1607).

  Each workspace id is resolved to the account it meters under (§6), and this
  fetches **once per distinct account**, not once for the whole group — P5
  made the *write* per-account; P6 (§9) is what makes the *fetch* genuinely
  per-account too, via `capture_oauth_usage/2`, so N accounts sharing this
  cycle's workspace list get N independent fetches, each authenticated with
  that account's own credential (or the install-wide default, when the
  account has none — see `capture_oauth_usage/2`). Three workspaces on one
  account still produce exactly one fetch and one write, exactly as before.

  Returns `{:ok, results}` with one entry per input workspace, in the same
  order, so a caller can tell which workspace's account failed — workspaces
  sharing an account share that account's result. Each failure is tagged
  with the stage it came from, `{:error, {:fetch, reason}}` (the account's
  own `/api/oauth/usage` fetch failed — a 401, a transport error, an
  unresolvable workspace/account) or `{:error, {:write, reason}}` (the fetch
  succeeded, only the DB write failed), so a caller like `CloudProbe` can
  tell "this account's credential/upstream is broken" apart from "the fetch
  was fine, persistence hiccuped" instead of conflating the two (bd-3j92yv).
  When every workspace in the group resolves to the *same* failure
  (typically: one account, or every account failing identically), the
  failure is surfaced as a bare, still-tagged `{:error, {stage, reason}}`
  instead of the `{:ok, results}` wrapper, matching this function's pre-P6
  contract shape (minus the tag) for the single-account case every existing
  caller relies on.
  """
  @spec capture_oauth_usage_for_group([String.t()], keyword()) ::
          {:ok, [{:ok, AnthropicQuota.t()} | {:error, {:fetch | :write, term()}}]}
          | {:error, {:fetch | :write, term()}}
  def capture_oauth_usage_for_group(workspace_ids, opts \\ []) when is_list(workspace_ids) do
    provider = Keyword.get(opts, :provider, @default_provider)

    {results, _seen} =
      Enum.map_reduce(workspace_ids, %{}, fn workspace_id, seen ->
        write_once_per_account(workspace_id, provider, opts, seen)
      end)

    collapse_uniform_failure(results)
  end

  # One fetch + write per distinct account per cycle. `seen` memoizes the
  # result so the second and third workspace on an account neither re-fetch
  # nor re-write, and report the same outcome as the first.
  defp write_once_per_account(workspace_id, provider, opts, seen) do
    with {:ok, ws_id} <- resolve_workspace_id(workspace_id),
         {:ok, account_id} <- ensure_account_id(ws_id, provider) do
      case Map.fetch(seen, account_id) do
        {:ok, result} ->
          {result, seen}

        :error ->
          result = capture_oauth_usage_tagged(account_id, Keyword.put(opts, :provider, provider))
          {result, Map.put(seen, account_id, result)}
      end
    else
      {:error, reason} -> {{:error, {:fetch, reason}}, seen}
    end
  end

  # Pre-P6 callers (and every existing test) expect a single fetch shared by
  # the whole group to fail as a bare `{:error, reason}`, not
  # `{:ok, [{:error, reason}, ...]}` — this keeps that contract for the
  # common case (one account, or every account failing the same way) while
  # still exposing real per-account divergence (some accounts ok, some not)
  # through the per-workspace `results` list.
  defp collapse_uniform_failure(results) do
    results
    |> Enum.map(fn
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end)
    |> Enum.uniq()
    |> case do
      [{:error, reason}] -> {:error, reason}
      _ -> {:ok, results}
    end
  end

  # Persist one parsed `/api/oauth/usage` snapshot (bd-b0zody).
  #
  # The poll is the *primary* quota source: when the body carried an aggregate
  # 5h figure we write the primary columns (`utilization_5h` / `status_5h` /
  # `reset_5h_at` / the 7d trio / `representative_claim` / `overage_status`)
  # plus a fresh `captured_at`, so `Arbiter.Quota.Gate` gates off the poll
  # rather than depending on worker traffic alone.
  #
  # Two guards keep a thin or broken body from erasing a good row:
  #
  #   * no aggregate 5h figure → fall back to the narrow secondary-only write,
  #     which touches neither the primary columns nor `captured_at`;
  #   * any individual `nil` field is dropped from the attrs, so the upsert
  #     never nils out a column another source had filled in (`AshSqlite`
  #     narrows `upsert_fields` to the attributes actually on the changeset).
  #
  # A fetch that failed outright (429 / cooldown / transport) never reaches
  # here at all, so the previous row survives untouched.
  defp record_oauth_usage(account_id, provider, usage) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    secondary = %{
      provider_account_id: account_id,
      provider: provider,
      per_model_utilization: usage.per_model_utilization,
      extra_usage: usage.extra_usage,
      oauth_utilization_5h: usage.utilization_5h,
      oauth_utilization_7d: usage.utilization_7d,
      oauth_captured_at: now
    }

    {action, attrs} =
      if is_number(usage.utilization_5h) do
        primary =
          %{
            utilization_5h: usage.utilization_5h,
            status_5h: usage.status_5h,
            reset_5h_at: usage.reset_5h_at,
            utilization_7d: usage.utilization_7d,
            status_7d: usage.status_7d,
            reset_7d_at: usage.reset_7d_at,
            representative_claim: usage.representative_claim,
            overage_status: usage.overage_status
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
          |> Map.merge(%{captured_at: now, capture_source: @oauth_poll_source})

        {:record_oauth_snapshot, Map.merge(secondary, primary)}
      else
        {:record_oauth_usage, secondary}
      end

    result =
      AnthropicQuota
      |> Ash.Changeset.for_create(action, attrs)
      |> Ash.create()

    with {:ok, quota} <- result do
      broadcast_quota_update(account_id, quota)
    end

    result
  end

  @doc """
  `serialize/2`, but first attempts a `capture_oauth_usage/2` refresh and
  silently ignores any failure (missing creds, 429 cooldown, network error) —
  the header-capture aggregate figures already in the snapshot are returned
  either way. This is what `arb quota` / the `quota_get` MCP tool call.
  """
  @spec refresh_and_serialize(String.t() | nil, String.t(), keyword()) :: map() | nil
  def refresh_and_serialize(account_id, provider \\ @default_provider, opts \\ []) do
    _ = safe_capture_oauth_usage(account_id, provider: provider)
    serialize(account_id, provider, opts)
  end

  defp safe_capture_oauth_usage(account_id, opts) do
    capture_oauth_usage(account_id, opts)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  @doc """
  Every tracked provider's latest quota snapshot for the given provider
  account(s), as the uniform view map (`view/1` / `Codex.view/1` / `CloudCode.view/1`) — one entry
  per distinct `provider`, `"claude"` sorted first (so the single-provider case
  renders exactly as before), the rest alphabetically.

  Merges three sources (bd-ajh7bd): the generic `AnthropicQuota` table (Claude +
  any legacy header-capture provider), the dedicated `CodexQuota` table, and the
  dedicated `GoogleQuota` table (Gemini CLI / Antigravity). When the same
  provider appears in both a dedicated table and the generic one, the dedicated
  row wins. This is the single read path the topbar, `/usage` LiveView, and the
  REST `quotas` list all sit on — no live provider fetch at request time.

  Each view also carries `cost_usd` — the provider's actual spend over the last
  #{@cost_window_days} days from the `Arbiter.Usage` ledger (`nil` when none) —
  so the dashboard can show dollars alongside utilization.

  `:spend_cache` reuses a caller's `spend_cache/1` memo (e.g. `GET /api/quota`,
  which also serializes Claude on its own); with none given this builds one
  for the pass, so the ledger is scanned once per workspace no matter how many
  providers come back.
  """
  @spec list_latest(String.t() | [String.t()] | map(), keyword()) :: [map()]
  def list_latest(accounts, opts \\ []) do
    account_ids = normalize_account_ids(accounts)

    if account_ids == [] do
      []
    else
      dedicated = codex_views(account_ids) ++ google_views(account_ids)
      dedicated_providers = MapSet.new(dedicated, & &1.provider)

      generic =
        AnthropicQuota
        |> Ash.Query.filter(provider_account_id in ^account_ids)
        |> Ash.read!()
        |> Enum.map(&view/1)
        |> Enum.reject(&MapSet.member?(dedicated_providers, &1.provider))

      case generic ++ dedicated do
        # No captured quota anywhere on these accounts — nothing to decorate,
        # so don't pay for the ledger scans a cache would run up front.
        [] ->
          []

        views ->
          cache = Keyword.get_lazy(opts, :spend_cache, fn -> spend_cache(account_ids) end)

          views
          |> Enum.map(&decorate_view(&1, cache))
          |> Enum.sort_by(&{&1.provider != @default_provider, &1.provider})
      end
    end
  rescue
    _ -> []
  end

  @doc """
  `list_latest/2` for a caller that holds a workspace: resolves every
  provider account the workspace is linked to, then reads by account. The
  shape the dashboard and `GET /api/quota` still speak.
  """
  @spec list_latest_for_workspace(String.t() | nil, keyword()) :: [map()]
  def list_latest_for_workspace(workspace_id, opts \\ []) do
    workspace_id
    |> account_ids()
    |> list_latest(opts)
    |> Enum.map(&Map.put(&1, :workspace_id, workspace_id))
  end

  defp normalize_account_ids(accounts) when is_map(accounts) and not is_struct(accounts),
    do: accounts |> Map.values() |> normalize_account_ids()

  defp normalize_account_ids(accounts) when is_list(accounts),
    do: accounts |> Enum.filter(&is_binary/1) |> Enum.uniq()

  defp normalize_account_ids(account_id) when is_binary(account_id), do: [account_id]
  defp normalize_account_ids(_), do: []

  # Each view carries its *own* account's spend and workspace breakdown — two
  # accounts in one list are two separate budgets and must not be summed.
  #
  # The headline `cost_usd` is the sum of the breakdown rather than a second
  # pass over the ledger, so `arb quota`'s account total always equals the
  # per-workspace line printed under it, and one view costs one ledger read
  # per workspace instead of two.
  defp decorate_view(view, cache) do
    fields = account_fields(view.provider_account_id, view.provider, cache)

    view
    |> Map.merge(fields)
    |> Map.put(:cost_usd, total_cost(fields.workspaces))
  end

  # `nil` (not `0.0`) when no workspace on the account has attributable spend,
  # matching `cost_for/2` — the UI shows "—" rather than a misleading "$0.00".
  defp total_cost(workspaces) do
    workspaces
    |> Enum.map(& &1.cost_usd)
    |> Enum.filter(&is_number/1)
    |> case do
      [] -> nil
      costs -> costs |> Enum.sum() |> Float.round(6)
    end
  end

  @doc """
  Per-provider actual spend for the **account** over the last
  #{@cost_window_days} days, as a `%{ledger_provider => total_cost_usd}` map
  drawn from the `Arbiter.Usage` ledger. Keyed by the *ledger* provider
  ("claude" / "gemini" / "openai"); `cost_for/2` maps quota codes onto it.
  Returns `%{}` on any error so cost is a best-effort add-on, never a failure.

  "How much of this plan did I spend?" is an account question (§8), read
  straight off `usage_events.provider_account_id` (P9) rather than summed
  through the workspace link — `workspace_spend/1` sums *only* rows that
  carry a `workspace_id`, so a probe/pre-flight row (`workspace_id: nil`, but
  always a `provider_account_id` — §8's seam with bd-adyhvn) would silently
  drop out of the total, reintroducing the exact under-reporting bias
  bd-adyhvn measured. `workspace_spend/1` is still the per-workspace term
  §6's breakdown line prints, since that one *is* workspace-scoped by
  definition.
  """
  @spec provider_spend(String.t() | nil) :: %{optional(String.t()) => float()}
  def provider_spend(nil), do: %{}

  def provider_spend(account_id) when is_binary(account_id) do
    since = DateTime.utc_now() |> DateTime.add(-@cost_window_days * 86_400, :second)

    case Arbiter.Usage.summarize(by: :provider, since: since, provider_account_id: account_id) do
      {:ok, rows} -> Map.new(rows, &{&1.group, &1.total_cost_usd})
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  def provider_spend(_), do: %{}

  @doc """
  Build the `t:spend_cache/0` memo for `accounts`: one `workspace_spend/1`
  scan per distinct workspace metered under them.

  `workspace_spend/1` reads every `usage_events` row in the window (blob
  column included) and aggregates in Elixir, and its result is the same for
  every provider, so the number of scans a request pays for must be the
  number of *workspaces* it touches — not that times the number of providers
  it renders. `list_latest/2` builds one of these per pass; a caller that
  makes several calls for one request (`GET /api/quota`) builds it once and
  passes it to each.
  """
  @spec spend_cache(String.t() | [String.t()] | map()) :: spend_cache()
  def spend_cache(accounts) do
    accounts
    |> normalize_account_ids()
    |> Enum.flat_map(&Resolver.workspace_ids/1)
    |> Enum.uniq()
    |> Map.new(&{&1, workspace_spend(&1)})
  end

  @doc """
  One workspace's own per-provider spend over the last #{@cost_window_days}
  days — the breakdown term under §6's account total.
  """
  @spec workspace_spend(String.t() | nil) :: %{optional(String.t()) => float()}
  def workspace_spend(workspace_id) when is_binary(workspace_id) do
    since = DateTime.utc_now() |> DateTime.add(-@cost_window_days * 86_400, :second)

    case Arbiter.Usage.summarize(by: :provider, since: since, workspace_id: workspace_id) do
      {:ok, rows} -> Map.new(rows, &{&1.group, &1.total_cost_usd})
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  def workspace_spend(_), do: %{}

  # Roll the ledger spend for a quota provider code up from its mapped ledger
  # key(s). `nil` (not `0.0`) when the provider has no spend / no clean mapping,
  # so the UI shows "—" rather than a misleading "$0.00".
  defp cost_for(provider, spend) do
    keys = Map.get(@ledger_providers, provider, [])

    case Enum.reduce(keys, {0.0, false}, fn key, {sum, any?} ->
           case Map.get(spend, key) do
             c when is_number(c) -> {sum + c, true}
             _ -> {sum, any?}
           end
         end) do
      {_sum, false} -> nil
      {sum, true} -> Float.round(sum, 6)
    end
  end

  defp codex_views(account_ids) do
    for account_id <- account_ids,
        row = Arbiter.Quota.Codex.latest(account_id),
        not is_nil(row) do
      Arbiter.Quota.Codex.view(row)
    end
  rescue
    _ -> []
  end

  defp google_views(account_ids) do
    for account_id <- account_ids,
        provider <- ["gemini_cli", "antigravity"],
        row = CloudCode.latest(account_id, provider),
        not is_nil(row) do
      CloudCode.view(row)
    end
  rescue
    _ -> []
  end

  @doc "`list_latest/2`, serialized into the public map shape (ISO timestamps)."
  @spec list_serialized(String.t() | [String.t()] | map(), keyword()) :: [map()]
  def list_serialized(accounts, opts \\ []) do
    accounts
    |> list_latest(opts)
    |> Enum.map(&serialize_view/1)
  end

  @doc "`list_latest_for_workspace/2`, serialized into the public map shape."
  @spec list_serialized_for_workspace(String.t() | nil, keyword()) :: [map()]
  def list_serialized_for_workspace(workspace_id, opts \\ []) do
    workspace_id
    |> list_latest_for_workspace(opts)
    |> Enum.map(&serialize_view/1)
  end

  @doc """
  Serialize a uniform view map (from `list_latest/1`) into the public,
  string-friendly shape — ISO-8601 timestamps, JSON-safe values.
  """
  @spec serialize_view(map()) :: map()
  def serialize_view(%{} = view) do
    view
    |> Map.take([
      :provider,
      :provider_account_id,
      :account,
      :workspaces,
      :workspace_id,
      :status_5h,
      :status_7d,
      :overage_status,
      :representative_claim,
      :per_model_utilization,
      :extra_usage,
      :oauth_utilization_5h,
      :oauth_utilization_7d,
      :capture_source,
      :utilization_5h,
      :utilization_7d,
      :primary_label,
      :secondary_label,
      :plan,
      :message,
      :models,
      :cost_usd
    ])
    |> Map.merge(%{
      reset_5h_at: iso(view[:reset_5h_at]),
      reset_7d_at: iso(view[:reset_7d_at]),
      captured_at: iso(view[:captured_at]),
      oauth_captured_at: iso(view[:oauth_captured_at])
    })
  end

  @doc """
  The installation default workspace id: the lone workspace when there is
  exactly one, else the one named "default". `{:error, reason}` when ambiguous
  or empty.
  """
  @spec default_workspace_id() :: {:ok, String.t()} | {:error, term()}
  def default_workspace_id do
    case Ash.read!(Workspace) do
      [%Workspace{id: id}] -> {:ok, id}
      [] -> {:error, :no_workspaces}
      many -> default_named(many)
    end
  rescue
    _ -> {:error, :no_workspaces}
  end

  defp default_named(workspaces) do
    case Enum.find(workspaces, &(&1.name == "default")) do
      %Workspace{id: id} -> {:ok, id}
      nil -> {:error, :ambiguous_workspace}
    end
  end

  @doc """
  The `on_exhaustion` mode (`:throttle` / `:continue`) for the installation
  default workspace (bd-l4epbc) — used by the quota-bar UI to word the
  pace-warning label ("stalls in Nm" vs "starts billing overage in Nm")
  without threading the workspace record through every LiveView. Falls back
  to `Workspace.quota_on_exhaustion(nil)` (global default) when the default
  workspace can't be resolved.
  """
  @spec default_workspace_on_exhaustion() :: :throttle | :continue
  def default_workspace_on_exhaustion do
    with {:ok, ws_id} <- default_workspace_id(),
         {:ok, workspace} <- Ash.get(Workspace, ws_id) do
      Workspace.quota_on_exhaustion(workspace)
    else
      _ -> Workspace.quota_on_exhaustion(nil)
    end
  end

  # ---- internals ---------------------------------------------------------

  defp resolve_workspace_id(ws_id) when is_binary(ws_id) and ws_id != "", do: {:ok, ws_id}
  defp resolve_workspace_id(_), do: default_workspace_id()

  # Pull the `anthropic-ratelimit-unified-*` family out of a response header
  # list into AnthropicQuota attrs. Unknown / absent headers are simply left
  # out, so the returned map is empty when nothing relevant was present.
  @doc false
  @spec parse_unified_headers([{String.t(), String.t()}]) :: map()
  def parse_unified_headers(headers) do
    index =
      for {name, value} <- headers,
          into: %{},
          do: {String.downcase(to_string(name)), to_string(value)}

    %{}
    |> put_float(:utilization_5h, index, "anthropic-ratelimit-unified-5h-utilization")
    |> put_reset(:reset_5h_at, index, "anthropic-ratelimit-unified-5h-reset")
    |> put_string(:status_5h, index, "anthropic-ratelimit-unified-5h-status")
    |> put_float(:utilization_7d, index, "anthropic-ratelimit-unified-7d-utilization")
    |> put_reset(:reset_7d_at, index, "anthropic-ratelimit-unified-7d-reset")
    |> put_string(:status_7d, index, "anthropic-ratelimit-unified-7d-status")
    |> put_string(
      :representative_claim,
      index,
      "anthropic-ratelimit-unified-representative-claim"
    )
    |> put_string(:overage_status, index, "anthropic-ratelimit-unified-overage-status")
  end

  defp put_float(acc, key, index, header) do
    case Map.get(index, header) do
      nil ->
        acc

      raw ->
        case Float.parse(raw) do
          {f, _} -> Map.put(acc, key, f)
          :error -> acc
        end
    end
  end

  defp put_string(acc, key, index, header) do
    case Map.get(index, header) do
      nil -> acc
      "" -> acc
      raw -> Map.put(acc, key, raw)
    end
  end

  # The reset headers are unix epoch seconds.
  defp put_reset(acc, key, index, header) do
    with raw when is_binary(raw) <- Map.get(index, header),
         {secs, _} <- Integer.parse(raw),
         {:ok, dt} <- DateTime.from_unix(secs) do
      Map.put(acc, key, DateTime.truncate(dt, :second))
    else
      _ -> acc
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
