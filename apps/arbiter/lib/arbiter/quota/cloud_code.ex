defmodule Arbiter.Quota.CloudCode do
  @moduledoc """
  On-demand quota snapshots for the Google Cloud Code Assist family:
  **Gemini CLI** and **Antigravity** (bd-57ukgb, part of bd-5qe3qs).

  Unlike the Anthropic quota — which the local proxy captures passively from
  response headers (`Arbiter.Quota.AnthropicQuota`) — neither Gemini CLI nor
  Antigravity emits usage on ordinary traffic. We query it directly, modeled on
  9router's `open-sse/services/usage/google.js`, using the same Cloud Code Assist
  endpoints the real `gemini /stats` command hits.

  ## Credentials (read-only)

  The Gemini CLI stores its OAuth token at `~/.gemini/oauth_creds.json`
  (`access_token`).

  Antigravity does **not** share that token — despite both being Google Cloud
  Code Assist clients, they are registered as two separate OAuth clients, each
  with its own independent refresh token (confirmed against 9router's
  `open-sse/providers/shared.js`, which lists distinct `ANTIGRAVITY_OAUTH_CLIENT`
  / `GOOGLE_OAUTH_CLIENT` client ids). Re-authenticating one has no effect on
  the other, and a stale Gemini CLI token does not mean Antigravity is stale
  (bd-5bchzv fixes the bd-4n1r8m spike's wrong assumption that they shared a
  token). Antigravity itself — the IDE app, a VS Code fork — persists its live
  access token in its own `globalStorage` sqlite DB at
  `~/.config/Antigravity/User/globalStorage/state.vscdb`, under the
  `antigravityAuthStatus` key's `apiKey` field, and rewrites that row every time
  the app refreshes its token in the background. We read that DB read-only via
  `Exqlite.Sqlite3`. If it's unavailable (e.g. Antigravity was never installed
  on this host), we fall back to the shared Gemini CLI creds file as a
  last-ditch attempt rather than reporting "not configured" outright. Neither
  path is ever written, and we do **not** refresh either token — the real app
  keeps its own fresh through normal use, so a stale token degrades to a
  `message` rather than triggering an OAuth dance here.

  ## Flow

  1. Read `access_token` from the creds file. Missing/blank → `nil` (no-op).
  2. Resolve the Cloud Code project id. Neither CLI caches it locally, so we
     POST `loadCodeAssist` (which also returns `currentTier.name`, the plan).
     A caller may inject a known id via `opts[:project_id]` to skip this hop.
  3. POST the quota endpoint (`retrieveUserQuota` for Gemini,
     `fetchAvailableModels` for Antigravity) with `{project: id}` and normalize
     each model's `remainingFraction` into a `{used, total: 1000, ...}` shape.

  Both `gemini/1` and `antigravity/1` return either `nil` (not configured) or a
  serialized snapshot map — never raise — so the `arb quota` / `quota_get` /
  `GET /api/quota` surface can render or omit them without special-casing errors.

  ## Persistence (bd-ajh7bd)

  `refresh/3` wraps a live fetch with an upsert into `Arbiter.Quota.GoogleQuota`
  and a `{:quota_updated, ws, view}` PubSub broadcast, so `Arbiter.Quota.CloudProbe`
  can keep the snapshot fresh on a timer and the web dashboard picks it up live —
  exactly like the Anthropic header-capture path. `latest/2` / `serialize_latest/2`
  read the persisted row back so the REST + MCP quota surface never fetches live
  at request time.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Quota.GoogleQuota

  # ---- endpoints (verified against 9router registry/gemini-cli.js + antigravity.js)
  @gemini_quota_url "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
  @gemini_load_url "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
  @antigravity_quota_url "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
  @antigravity_load_url "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"

  @default_creds_path "~/.gemini/oauth_creds.json"
  @default_antigravity_state_path "~/.config/Antigravity/User/globalStorage/state.vscdb"
  @antigravity_auth_status_key "antigravityAuthStatus"

  # Normalized base — the provider only hands us a fraction, not raw units, so
  # we mirror 9router's arbitrary 1000-unit base for used/total. Percentage is
  # carried alongside for callers that prefer a plain 0–100 figure.
  @total 1000

  # loadCodeAssist metadata (9router CLIENT_METADATA): ideType ANTIGRAVITY=9,
  # pluginType GEMINI=2. Platform is a coarse enum; LINUX_AMD64=3 is a safe
  # default for the server host and is not load-bearing for quota reads.
  @client_metadata %{"ideType" => 9, "pluginType" => 2, "platform" => 3}

  # Antigravity exposes dozens of models; 9router filters the quota view down to
  # this allowlist of the ones worth surfacing. We replicate it so the display
  # stays legible rather than dumping every internal variant.
  @antigravity_important_models MapSet.new(~w(
    gemini-3-flash-agent
    gemini-3.5-flash-low
    gemini-3.5-flash-extra-low
    gemini-pro-agent
    gemini-3.1-pro-low
    claude-sonnet-4-6
    claude-opus-4-6-thinking
    gpt-oss-120b-medium
    gemini-3-flash
    gemini-3.1-flash-image
    gemini-3-pro-image
  ))

  @antigravity_user_agent "antigravity/1.104.0"
  @antigravity_client_version "1.107.0"

  @type model_quota :: %{
          model_id: String.t(),
          used: non_neg_integer(),
          total: non_neg_integer(),
          remaining_percentage: float(),
          reset_at: String.t() | nil,
          unlimited: boolean()
        }

  @type snapshot :: %{
          provider: String.t(),
          plan: String.t(),
          models: [model_quota()],
          message: String.t() | nil,
          captured_at: String.t()
        }

  # ---- Gemini CLI --------------------------------------------------------

  @doc """
  Gemini CLI per-model quota snapshot, or `nil` when not configured.

  Options:
    * `:creds_path`   — override the oauth creds file (tests / non-default homes)
    * `:project_id`   — a known Cloud Code project id, skips `loadCodeAssist`
    * `:plug`         — a `Req.Test` plug for stubbing HTTP in tests
    * `:receive_timeout` — per-request timeout (default 8s)
  """
  @spec gemini(keyword()) :: snapshot() | nil
  def gemini(opts \\ []) do
    case load_access_token(opts) do
      {:ok, token} -> fetch_gemini(token, opts)
      :error -> nil
    end
  end

  defp fetch_gemini(token, opts) do
    {project_id, plan} = resolve_gemini_project(token, opts)

    cond do
      is_nil(project_id) ->
        snapshot("gemini-cli", plan, [], project_missing_message("Gemini CLI"))

      true ->
        case post(@gemini_quota_url, bearer_headers(token), %{project: project_id}, opts) do
          {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
            snapshot("gemini-cli", plan, gemini_models(body), nil)

          {:ok, %Req.Response{status: 401}} ->
            snapshot("gemini-cli", plan, [], "Gemini CLI quota auth expired; reconnect the CLI.")

          {:ok, %Req.Response{status: status}} ->
            snapshot("gemini-cli", plan, [], "Gemini CLI quota error (#{status}).")

          {:error, err} ->
            snapshot("gemini-cli", plan, [], "Gemini CLI quota error: #{transport_message(err)}")
        end
    end
  end

  defp resolve_gemini_project(token, opts) do
    case normalize_project_id(opts[:project_id]) do
      pid when is_binary(pid) ->
        {pid, "Free"}

      nil ->
        case post(@gemini_load_url, bearer_headers(token), %{metadata: @client_metadata}, opts) do
          {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
            {normalize_project_id(body["cloudaicompanionProject"]), plan_name(body)}

          _ ->
            {nil, "Free"}
        end
    end
  end

  defp gemini_models(%{"buckets" => buckets}) when is_list(buckets) do
    for bucket <- buckets,
        is_binary(bucket["modelId"]),
        not is_nil(bucket["remainingFraction"]) do
      normalize_model(bucket["modelId"], bucket["remainingFraction"], bucket["resetTime"], nil)
    end
  end

  defp gemini_models(_), do: []

  # ---- Antigravity -------------------------------------------------------

  @doc """
  Antigravity per-model quota snapshot, or `nil` when not configured.

  Reads Antigravity's own live access token from its `globalStorage` sqlite
  state DB (see the moduledoc) — falling back to the Gemini CLI creds file
  only if that DB is unavailable. Options:

    * `:antigravity_state_path` — override the state DB path (tests / non-default homes)
    * `:creds_path`, `:project_id`, `:plug`, `:receive_timeout` — see `gemini/1`
  """
  @spec antigravity(keyword()) :: snapshot() | nil
  def antigravity(opts \\ []) do
    case load_antigravity_token(opts) do
      {:ok, token} -> fetch_antigravity(token, opts)
      :error -> nil
    end
  end

  defp fetch_antigravity(token, opts) do
    {project_id, plan} = resolve_antigravity_project(token, opts)
    body = if project_id, do: %{project: project_id}, else: %{}

    case post(@antigravity_quota_url, antigravity_headers(token), body, opts) do
      {:ok, %Req.Response{status: status, body: resp}} when status in 200..299 ->
        snapshot("antigravity", plan, antigravity_models(resp), nil)

      {:ok, %Req.Response{status: 403}} ->
        snapshot("antigravity", plan, [], "Antigravity quota API access forbidden.")

      {:ok, %Req.Response{status: 401}} ->
        snapshot("antigravity", plan, [], "Antigravity quota auth expired; reconnect.")

      {:ok, %Req.Response{status: status}} ->
        snapshot("antigravity", plan, [], "Antigravity quota error (#{status}).")

      {:error, err} ->
        snapshot("antigravity", plan, [], "Antigravity quota error: #{transport_message(err)}")
    end
  end

  defp resolve_antigravity_project(token, opts) do
    case normalize_project_id(opts[:project_id]) do
      pid when is_binary(pid) ->
        {pid, "Unknown"}

      nil ->
        body = %{metadata: @client_metadata, mode: 1}

        case post(@antigravity_load_url, antigravity_subscription_headers(token), body, opts) do
          {:ok, %Req.Response{status: status, body: resp}} when status in 200..299 ->
            {normalize_project_id(resp["cloudaicompanionProject"]), plan_name(resp, "Unknown")}

          _ ->
            {nil, "Unknown"}
        end
    end
  end

  defp antigravity_models(%{"models" => models}) when is_map(models) do
    for {model_key, info} <- models,
        is_map(info),
        is_map(info["quotaInfo"]),
        info["isInternal"] != true,
        MapSet.member?(@antigravity_important_models, model_key) do
      quota = info["quotaInfo"]

      normalize_model(
        model_key,
        quota["remainingFraction"],
        quota["resetTime"],
        info["displayName"]
      )
    end
  end

  defp antigravity_models(_), do: []

  # ---- persistence (bd-ajh7bd) -------------------------------------------

  # Persisted provider codes (match `ArbiterWeb.QuotaHelpers` labels), keyed by
  # the fetch atom passed to `refresh/3`.
  @provider_codes %{gemini: "gemini_cli", antigravity: "antigravity"}

  @doc """
  Fetch one Google provider's live quota and upsert it into `GoogleQuota`.

  `which` is `:gemini` or `:antigravity`. Returns the serialized snapshot map on
  a successful fetch (persisting a row + broadcasting `{:quota_updated, ws, view}`),
  or `nil` when the provider isn't configured on this host (no creds) — in which
  case **no row is written**, so a transient logout doesn't wipe the last good
  reading. `opts` are forwarded to `gemini/1` / `antigravity/1`.
  """
  @spec refresh(String.t(), :gemini | :antigravity, keyword()) :: snapshot() | nil
  def refresh(workspace_id, which, opts \\ [])
      when is_binary(workspace_id) and which in [:gemini, :antigravity] do
    case fetch_snapshot(which, opts) do
      nil ->
        nil

      snapshot ->
        provider = Map.fetch!(@provider_codes, which)

        case upsert(workspace_id, provider, snapshot) do
          {:ok, row} ->
            broadcast(workspace_id, row)
            snapshot

          {:error, reason} ->
            Logger.debug("Arbiter.Quota.CloudCode: #{provider} upsert failed: #{inspect(reason)}")
            snapshot
        end
    end
  rescue
    e ->
      Logger.debug("Arbiter.Quota.CloudCode.refresh raised: #{Exception.message(e)}")
      nil
  end

  defp fetch_snapshot(:gemini, opts), do: gemini(opts)
  defp fetch_snapshot(:antigravity, opts), do: antigravity(opts)

  defp upsert(workspace_id, provider, snapshot) do
    {used_percent, reset_at} = representative(snapshot)

    attrs = %{
      workspace_id: workspace_id,
      provider: provider,
      plan: snapshot[:plan],
      message: snapshot[:message],
      used_percent: used_percent,
      reset_at: reset_at,
      snapshot: stringify(snapshot),
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    GoogleQuota
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create()
  end

  # The representative bar figure: the worst (most-used) important model, i.e.
  # the smallest `remaining_percentage`. `{used_percent :: float | nil,
  # reset_at :: DateTime | nil}` — nil/nil when the snapshot carries no models.
  defp representative(%{models: [_ | _] = models}) do
    worst = Enum.min_by(models, & &1.remaining_percentage)
    used = Float.round(100.0 - (worst.remaining_percentage || 0.0), 2)
    {clamp(used, 0.0, 100.0), parse_datetime(worst[:reset_at])}
  end

  defp representative(_), do: {nil, nil}

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  # JSON-normalize the snapshot to string keys so the read-back shape is stable
  # regardless of the `:map` data-layer's round-trip.
  defp stringify(term) do
    term |> Jason.encode!() |> Jason.decode!()
  end

  defp broadcast(workspace_id, %GoogleQuota{} = row) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      "quota:#{workspace_id}",
      {:quota_updated, workspace_id, view(row)}
    )
  rescue
    _ -> :error
  end

  @doc "Latest stored Google snapshot row for `workspace_id` + `provider`, or `nil`."
  @spec latest(String.t(), String.t()) :: GoogleQuota.t() | nil
  def latest(workspace_id, provider) when is_binary(workspace_id) and is_binary(provider) do
    GoogleQuota
    |> Ash.Query.filter(workspace_id == ^workspace_id and provider == ^provider)
    |> Ash.read_one()
    |> case do
      {:ok, %GoogleQuota{} = row} -> row
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Serialize the latest stored snapshot for `workspace_id` + `provider`, or `nil`."
  @spec serialize_latest(String.t(), String.t()) :: map() | nil
  def serialize_latest(workspace_id, provider) do
    case latest(workspace_id, provider) do
      nil -> nil
      %GoogleQuota{snapshot: snapshot} -> snapshot
    end
  end

  @doc """
  Map a stored `GoogleQuota` row to the uniform two-window quota view shape the
  topbar / `/usage` page render. Google has no time windows, so the
  representative used-fraction fills the primary ("5h") slot and the secondary
  ("7d") slot is left empty.
  """
  @spec view(GoogleQuota.t()) :: map()
  def view(%GoogleQuota{} = row) do
    Arbiter.Quota.blank_view(row.provider)
    |> Map.merge(%{
      workspace_id: row.workspace_id,
      utilization_5h: fraction(row.used_percent),
      reset_5h_at: row.reset_at,
      captured_at: row.captured_at,
      plan: row.plan,
      message: row.message,
      models: models_from(row.snapshot),
      primary_label: "used",
      secondary_label: nil
    })
  end

  defp fraction(nil), do: nil
  defp fraction(pct) when is_number(pct), do: pct / 100.0

  defp models_from(%{"models" => models}) when is_list(models), do: models
  defp models_from(_), do: []

  # ---- normalization -----------------------------------------------------

  defp normalize_model(model_id, fraction, reset, display_name) do
    frac = to_fraction(fraction)
    remaining = round(@total * frac)
    used = max(0, @total - remaining)

    base = %{
      model_id: model_id,
      used: used,
      total: @total,
      remaining_percentage: frac * 100,
      reset_at: parse_reset(reset),
      unlimited: false
    }

    if is_binary(display_name), do: Map.put(base, :display_name, display_name), else: base
  end

  defp snapshot(provider, plan, models, message) do
    %{
      provider: provider,
      plan: plan,
      models: models,
      message: message,
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp to_fraction(f) when is_number(f), do: f * 1.0

  defp to_fraction(f) when is_binary(f) do
    case Float.parse(f) do
      {v, _} -> v
      :error -> 0.0
    end
  end

  defp to_fraction(_), do: 0.0

  # Provider reset times arrive as unix seconds, unix millis, a numeric string,
  # or an ISO-8601 string. Normalize all to ISO-8601 (mirrors 9router's
  # parseResetTime); anything unparseable degrades to nil.
  defp parse_reset(nil), do: nil

  defp parse_reset(n) when is_integer(n) do
    ms = if n < 1_000_000_000_000, do: n * 1000, else: n

    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp parse_reset(v) when is_binary(v) do
    if Regex.match?(~r/^\d+$/, v) do
      parse_reset(String.to_integer(v))
    else
      case DateTime.from_iso8601(v) do
        {:ok, dt, _offset} -> DateTime.to_iso8601(dt)
        _ -> nil
      end
    end
  end

  defp parse_reset(_), do: nil

  defp plan_name(body, default \\ "Free")
  defp plan_name(%{"currentTier" => %{"name" => name}}, _default) when is_binary(name), do: name
  defp plan_name(_body, default), do: default

  defp normalize_project_id(project) when is_binary(project) do
    case String.trim(project) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_project_id(%{"id" => id}) when is_binary(id), do: normalize_project_id(id)
  defp normalize_project_id(_), do: nil

  defp project_missing_message(label) do
    "#{label} project id not available; reconnect the CLI or configure a Cloud " <>
      "project with Code Assist access before checking quota."
  end

  # ---- credentials (read-only) -------------------------------------------

  defp load_access_token(opts) do
    path =
      opts[:creds_path] ||
        Application.get_env(:arbiter, :gemini_creds_path) ||
        @default_creds_path

    with {:ok, raw} <- File.read(Path.expand(path)),
         {:ok, %{"access_token" => token}} <- Jason.decode(raw),
         true <- is_binary(token) and token != "" do
      {:ok, token}
    else
      _ -> :error
    end
  end

  # Antigravity's own token, read from its globalStorage sqlite state DB (see
  # moduledoc). Falls back to the Gemini CLI creds file as a last resort only
  # if the state DB isn't readable — Antigravity and Gemini CLI are separate
  # OAuth clients, so that fallback is a degraded-but-better-than-nothing path,
  # not the primary source.
  defp load_antigravity_token(opts) do
    case load_antigravity_state_token(opts) do
      {:ok, token} -> {:ok, token}
      :error -> load_access_token(opts)
    end
  end

  defp load_antigravity_state_token(opts) do
    path =
      opts[:antigravity_state_path] ||
        Application.get_env(:arbiter, :antigravity_state_path) ||
        @default_antigravity_state_path

    expanded = Path.expand(path)

    with true <- File.exists?(expanded),
         {:ok, raw} <- read_item_table_value(expanded, @antigravity_auth_status_key),
         {:ok, %{"apiKey" => token}} <- Jason.decode(raw),
         true <- is_binary(token) and token != "" do
      {:ok, token}
    else
      _ -> :error
    end
  end

  # Read a single value out of a VS Code-style `ItemTable (key, value)` sqlite
  # DB, read-only, without pulling in a full Ecto repo for one lookup.
  defp read_item_table_value(db_path, key) do
    with {:ok, db} <- Exqlite.Sqlite3.open(db_path, mode: :readonly) do
      try do
        with {:ok, stmt} <-
               Exqlite.Sqlite3.prepare(db, "SELECT value FROM ItemTable WHERE key = ?"),
             :ok <- Exqlite.Sqlite3.bind(stmt, [key]),
             {:row, [value]} <- Exqlite.Sqlite3.step(db, stmt) do
          {:ok, to_string(value)}
        else
          _ -> :error
        end
      after
        Exqlite.Sqlite3.close(db)
      end
    end
  rescue
    _ -> :error
  end

  # ---- HTTP --------------------------------------------------------------

  defp bearer_headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"content-type", "application/json"}
    ]
  end

  defp antigravity_headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"content-type", "application/json"},
      {"user-agent", @antigravity_user_agent},
      {"x-client-name", "antigravity"},
      {"x-client-version", @antigravity_client_version},
      {"x-request-source", "local"}
    ]
  end

  defp antigravity_subscription_headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"content-type", "application/json"},
      {"user-agent", @antigravity_user_agent},
      {"x-request-source", "local"}
    ]
  end

  defp post(url, headers, body, opts) do
    full =
      [
        method: :post,
        url: url,
        headers: headers,
        json: body,
        receive_timeout: Keyword.get(opts, :receive_timeout, 8_000),
        retry: false
      ]
      |> Keyword.merge(stub_opts(opts))

    Req.request(full)
  end

  defp stub_opts(opts) do
    cond do
      Keyword.has_key?(opts, :plug) ->
        [plug: Keyword.fetch!(opts, :plug)]

      Application.get_env(:arbiter, :cloud_code_http_stub, false) ->
        [plug: {Req.Test, __MODULE__}]

      true ->
        []
    end
  end

  defp transport_message(%{reason: reason}), do: inspect(reason)
  defp transport_message(other), do: inspect(other)
end
