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
  alias Arbiter.Tasks.Workspace
  require Ash.Query

  resources do
    resource Arbiter.Quota.AnthropicQuota
    resource Arbiter.Quota.CodexQuota
  end

  @default_provider "claude"
  @default_base_url "http://127.0.0.1:4848/proxy/anthropic"

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

  # Broadcast quota update to all subscribers for the workspace
  defp broadcast_quota_update(workspace_id, quota) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      "quota:#{workspace_id}",
      {:quota_updated, workspace_id, quota}
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
  Every tracked provider's latest quota snapshot for `workspace_id` — one row
  per distinct `provider` that has ever been captured, `"claude"` sorted
  first (so the single-provider case renders exactly as before), the rest
  alphabetically.
  """
  @spec list_latest(String.t()) :: [AnthropicQuota.t()]
  def list_latest(workspace_id) when is_binary(workspace_id) do
    AnthropicQuota
    |> Ash.Query.filter(workspace_id == ^workspace_id)
    |> Ash.read!()
    |> Enum.sort_by(&{&1.provider != @default_provider, &1.provider})
  rescue
    _ -> []
  end

  @doc "`list_latest/1`, serialized into the public map shape."
  @spec list_serialized(String.t()) :: [map()]
  def list_serialized(workspace_id) do
    workspace_id
    |> list_latest()
    |> Enum.map(&serialize_quota/1)
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
