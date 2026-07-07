defmodule Arbiter.Quota do
  @moduledoc """
  Ash domain + public API for per-workspace Anthropic quota state (bd-5boun6).

  The local HTTP proxy in `arbiter_web` forwards Claude CLI traffic to
  `api.anthropic.com` and feeds the `anthropic-ratelimit-unified-*` response
  headers through `capture/3`, which upserts an `AnthropicQuota` snapshot for
  the originating workspace. `get/2` / `serialize/2` read the latest snapshot
  back for the MCP `quota_get` tool, the `GET /api/quota` endpoint, and
  `arb quota`.

  ## Proxy wiring

  This module also owns the `ANTHROPIC_BASE_URL` the Claude adapter exports at
  spawn time so every worker request is intercepted. The base URL embeds the
  workspace id as the first path segment (`/proxy/anthropic/<workspace_id>`)
  so the proxy can attribute captured headers without a custom request header
  the CLI would never send.
  """

  use Ash.Domain

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
  @default_base_url "http://127.0.0.1:4848/proxy/anthropic"

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

  # ---- proxy config ------------------------------------------------------

  @doc """
  Whether worker spawns should route Anthropic traffic through the local
  proxy. Defaults to `true`; the test env disables it so adapter/dispatch
  specs that assert the raw spawn env stay deterministic.
  """
  @spec proxy_enabled?() :: boolean()
  def proxy_enabled?, do: Keyword.get(proxy_config(), :enabled, true) == true

  @doc "The proxy base URL (no workspace segment)."
  @spec proxy_base_url() :: String.t()
  def proxy_base_url do
    proxy_config()
    |> Keyword.get(:base_url, @default_base_url)
    |> String.trim_trailing("/")
  end

  @doc """
  The `ANTHROPIC_BASE_URL` a worker for `workspace_id` should export. The
  workspace id rides as the first path segment so the proxy can attribute the
  captured quota headers. A `nil` workspace (workspace-agnostic probe) yields
  the bare base URL.
  """
  @spec worker_base_url(String.t() | nil) :: String.t()
  def worker_base_url(workspace_id) when is_binary(workspace_id) and workspace_id != "",
    do: proxy_base_url() <> "/" <> workspace_id

  def worker_base_url(_), do: proxy_base_url()

  defp proxy_config, do: Application.get_env(:arbiter, :anthropic_proxy, [])

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

  # ---- capture -----------------------------------------------------------

  @doc """
  Upsert a quota snapshot for `workspace_id` from a list of HTTP response
  `headers` (`[{name, value}]`, as Finch/Plug deliver them).

  Returns `{:ok, quota}` when the headers carried any
  `anthropic-ratelimit-unified-*` value, `:noop` when they didn't (so health
  checks and non-Anthropic responses are silently skipped), and
  `{:error, reason}` if the upsert fails.

  A `nil` / blank `workspace_id` is resolved to the installation default
  workspace so a workspace-agnostic credential probe still records state.
  """
  @spec capture(String.t() | nil, [{String.t(), String.t()}], keyword()) ::
          {:ok, AnthropicQuota.t()} | :noop | {:error, term()}
  def capture(workspace_id, headers, opts \\ []) when is_list(headers) do
    case parse_unified_headers(headers) do
      attrs when map_size(attrs) == 0 ->
        :noop

      attrs ->
        with {:ok, ws_id} <- resolve_workspace_id(workspace_id) do
          provider = Keyword.get(opts, :provider, @default_provider)

          full =
            attrs
            |> Map.put(:workspace_id, ws_id)
            |> Map.put(:provider, provider)
            |> Map.put_new(:captured_at, DateTime.utc_now() |> DateTime.truncate(:second))

          result =
            AnthropicQuota
            |> Ash.Changeset.for_create(:upsert, full)
            |> Ash.create()

          with {:ok, quota} <- result do
            broadcast_quota_update(ws_id, quota)
          end

          result
        end
    end
  end

  # Broadcast a quota update to all subscribers for the workspace, carrying the
  # uniform view map (not the raw resource struct) so every provider's live
  # update lands on the LiveView in the same shape `list_latest/1` returns.
  defp broadcast_quota_update(workspace_id, %AnthropicQuota{} = quota) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      "quota:#{workspace_id}",
      {:quota_updated, workspace_id, view(quota)}
    )
  rescue
    e ->
      require Logger
      Logger.debug("quota pubsub broadcast failed: #{inspect(e)}")
      :error
  end

  @doc """
  Latest quota snapshot for `workspace_id` + `provider`, or `nil` if none has
  been captured yet.
  """
  @spec latest(String.t(), String.t()) :: AnthropicQuota.t() | nil
  def latest(workspace_id, provider \\ @default_provider) when is_binary(workspace_id) do
    AnthropicQuota
    |> Ash.Query.filter(workspace_id == ^workspace_id and provider == ^provider)
    |> Ash.read_one()
    |> case do
      {:ok, %AnthropicQuota{} = q} -> q
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Serialize the latest snapshot for `workspace_id` into the public map shape
  (string-friendly, ISO-8601 timestamps), or `nil` when none exists.
  """
  @spec serialize(String.t(), String.t()) :: map() | nil
  def serialize(workspace_id, provider \\ @default_provider) do
    case latest(workspace_id, provider) do
      nil -> nil
      %AnthropicQuota{} = q -> serialize_quota(q)
    end
  end

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
      workspace_id: nil,
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
      workspace_id: q.workspace_id,
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
      oauth_captured_at: q.oauth_captured_at
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
      utilization_5h: q.utilization_5h,
      reset_5h_at: iso(q.reset_5h_at),
      status_5h: q.status_5h,
      utilization_7d: q.utilization_7d,
      reset_7d_at: iso(q.reset_7d_at),
      status_7d: q.status_7d,
      representative_claim: q.representative_claim,
      overage_status: q.overage_status,
      captured_at: iso(q.captured_at),
      per_model_utilization: q.per_model_utilization || %{},
      extra_usage: q.extra_usage || %{},
      oauth_utilization_5h: q.oauth_utilization_5h,
      oauth_utilization_7d: q.oauth_utilization_7d,
      oauth_captured_at: iso(q.oauth_captured_at)
    }
  end

  # ---- Google Cloud Code Assist quota (bd-57ukgb) ------------------------

  @doc """
  On-demand Gemini CLI + Antigravity quota snapshots via the Cloud Code Assist
  API (`Arbiter.Quota.CloudCode`).

  Returns `%{gemini: snapshot | nil, antigravity: snapshot | nil}`. Unlike the
  Anthropic snapshot — a passive DB read of proxy-captured headers — these fetch
  live from Google, so both providers are queried concurrently and each is
  bounded by a timeout; a hung or crashed fetch degrades to `nil`.

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
  workspace's `AnthropicQuota` snapshot alongside (never instead of) the
  header-capture aggregate figures.

  Best-effort by design: a 429 cooldown (`Arbiter.Quota.OAuthUsage`), missing
  credentials, or any transport error is returned as `{:error, reason}` here
  but never raises — callers that just want "whatever we have" should use
  `refresh_and_serialize/2` instead, which swallows this outright.
  """
  @spec capture_oauth_usage(String.t() | nil, keyword()) ::
          {:ok, AnthropicQuota.t()} | {:error, term()}
  def capture_oauth_usage(workspace_id, opts \\ []) do
    provider = Keyword.get(opts, :provider, @default_provider)

    with {:ok, ws_id} <- resolve_workspace_id(workspace_id),
         {:ok, usage} <- Arbiter.Quota.OAuthUsage.fetch(opts) do
      attrs = %{
        workspace_id: ws_id,
        provider: provider,
        per_model_utilization: usage.per_model_utilization,
        extra_usage: usage.extra_usage,
        oauth_utilization_5h: usage.utilization_5h,
        oauth_utilization_7d: usage.utilization_7d,
        oauth_captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      result =
        AnthropicQuota
        |> Ash.Changeset.for_create(:record_oauth_usage, attrs)
        |> Ash.create()

      with {:ok, quota} <- result do
        broadcast_quota_update(ws_id, quota)
      end

      result
    end
  end

  @doc """
  `serialize/2`, but first attempts a `capture_oauth_usage/2` refresh and
  silently ignores any failure (missing creds, 429 cooldown, network error) —
  the header-capture aggregate figures already in the snapshot are returned
  either way. This is what `arb quota` / the `quota_get` MCP tool call.
  """
  @spec refresh_and_serialize(String.t() | nil, String.t()) :: map() | nil
  def refresh_and_serialize(workspace_id, provider \\ @default_provider) do
    _ = safe_capture_oauth_usage(workspace_id, provider: provider)
    serialize(workspace_id, provider)
  end

  defp safe_capture_oauth_usage(workspace_id, opts) do
    capture_oauth_usage(workspace_id, opts)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  @doc """
  Every tracked provider's latest quota snapshot for `workspace_id`, as the
  uniform view map (`view/1` / `Codex.view/1` / `CloudCode.view/1`) — one entry
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
  """
  @spec list_latest(String.t()) :: [map()]
  def list_latest(workspace_id) when is_binary(workspace_id) do
    dedicated = codex_views(workspace_id) ++ google_views(workspace_id)
    dedicated_providers = MapSet.new(dedicated, & &1.provider)

    generic =
      AnthropicQuota
      |> Ash.Query.filter(workspace_id == ^workspace_id)
      |> Ash.read!()
      |> Enum.map(&view/1)
      |> Enum.reject(&MapSet.member?(dedicated_providers, &1.provider))

    spend = provider_spend(workspace_id)

    (generic ++ dedicated)
    |> Enum.map(&%{&1 | cost_usd: cost_for(&1.provider, spend)})
    |> Enum.sort_by(&{&1.provider != @default_provider, &1.provider})
  rescue
    _ -> []
  end

  @doc """
  Per-provider actual spend for `workspace_id` over the last
  #{@cost_window_days} days, as a `%{ledger_provider => total_cost_usd}` map
  drawn from the `Arbiter.Usage` ledger. Keyed by the *ledger* provider
  ("claude" / "gemini" / "openai"); `cost_for/2` maps quota codes onto it.
  Returns `%{}` on any error so cost is a best-effort add-on, never a failure.
  """
  @spec provider_spend(String.t()) :: %{optional(String.t()) => float()}
  def provider_spend(workspace_id) do
    since = DateTime.utc_now() |> DateTime.add(-@cost_window_days * 86_400, :second)

    case Arbiter.Usage.summarize(by: :provider, since: since, workspace_id: workspace_id) do
      {:ok, rows} -> Map.new(rows, &{&1.group, &1.total_cost_usd})
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

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

  defp codex_views(workspace_id) do
    case Arbiter.Quota.Codex.latest(workspace_id) do
      nil -> []
      row -> [Arbiter.Quota.Codex.view(row)]
    end
  rescue
    _ -> []
  end

  defp google_views(workspace_id) do
    for provider <- ["gemini_cli", "antigravity"],
        row = CloudCode.latest(workspace_id, provider),
        not is_nil(row) do
      CloudCode.view(row)
    end
  rescue
    _ -> []
  end

  @doc "`list_latest/1`, serialized into the public map shape (ISO timestamps)."
  @spec list_serialized(String.t()) :: [map()]
  def list_serialized(workspace_id) do
    workspace_id
    |> list_latest()
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
      :status_5h,
      :status_7d,
      :overage_status,
      :representative_claim,
      :per_model_utilization,
      :extra_usage,
      :oauth_utilization_5h,
      :oauth_utilization_7d,
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
