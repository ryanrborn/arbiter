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
  (`access_token`). Antigravity has no dedicated file and shares that token (per
  the bd-4n1r8m spike). We read the file, never write it, and do **not** refresh
  the token — the real CLI keeps it fresh through normal use, so a stale token
  degrades to a `message` rather than triggering an OAuth dance here.

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
  """

  # ---- endpoints (verified against 9router registry/gemini-cli.js + antigravity.js)
  @gemini_quota_url "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
  @gemini_load_url "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
  @antigravity_quota_url "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
  @antigravity_load_url "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"

  @default_creds_path "~/.gemini/oauth_creds.json"

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
  Antigravity per-model quota snapshot, or `nil` when not configured. Shares the
  Gemini CLI credentials. See `gemini/1` for options.
  """
  @spec antigravity(keyword()) :: snapshot() | nil
  def antigravity(opts \\ []) do
    case load_access_token(opts) do
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
