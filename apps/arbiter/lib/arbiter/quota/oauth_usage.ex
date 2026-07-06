defmodule Arbiter.Quota.OAuthUsage do
  @moduledoc """
  On-demand fetch of Anthropic's undocumented `/api/oauth/usage` endpoint
  (bd-8tpha6, part of bd-5qe3qs).

  This is a **secondary, additive** quota source alongside the zero-cost
  header-capture mechanism in `Arbiter.Quota` (`anthropic-ratelimit-unified-*`
  response headers, updated on every real proxied request). The headers are
  aggregate-only (one 5h + one 7d figure); this endpoint is the only way to
  get a **per-model** weekly breakdown (`seven_day_sonnet`, `seven_day_opus`,
  ...) and the account's `extra_usage` overage spend.

  ## Auth

  Uses the operator's own Claude Code consumer OAuth token —
  `claudeAiOauth.accessToken` in `~/.claude/.credentials.json` (or
  `$CLAUDE_CONFIG_DIR/.credentials.json`), the same file
  `Arbiter.Agents.Claude.ConfigDir` seeds worker spawns from. This is a
  read-only fetch: we only ever open + read the file, never write to or
  watch it, so a concurrent token refresh by the CLI is never at risk.

  ## Rate limiting

  This specific endpoint 429s far more readily than normal `/v1/messages`
  traffic. On a 429 we start a 180s cooldown for that token (mirroring
  9router's `open-sse/services/usage/claude.js`) — `fetch/1` skips the call
  and returns `{:error, :cooling_down}` until it lapses, so a hot polling
  loop can never hammer this endpoint into a harder ban. The header-capture
  aggregate figures are entirely unaffected by this cooldown.

  ## Cadence

  Callers are expected to invoke `fetch/1` **on demand** (e.g. when
  `arb quota` / the `quota_get` MCP tool is invoked) rather than on a
  periodic timer — see `Arbiter.Quota.RefreshProbe`'s moduledoc for why that
  timer intentionally does not call this endpoint.
  """

  require Logger

  alias Arbiter.Agents.Claude.ConfigDir

  @default_base_url "https://api.anthropic.com"
  @stub_name __MODULE__.HTTP
  @anthropic_version "2023-06-01"
  @anthropic_beta "oauth-2025-04-20"
  @cooldown_ms 180_000

  @type usage :: %{
          utilization_5h: float() | nil,
          utilization_7d: float() | nil,
          per_model_utilization: %{String.t() => float()},
          extra_usage: map()
        }

  @doc """
  Fetch the current oauth/usage snapshot.

  Options:

    * `:token` — access token to use instead of reading `.credentials.json`.
    * `:source_dir` — directory to read `.credentials.json` from, instead of
      `Arbiter.Agents.Claude.ConfigDir.source_dir/0`.
    * `:base_url` — override the Anthropic base URL (tests).
    * `:plug` — a `Req` plug to inject (tests); otherwise the
      `:arbiter, :oauth_usage_http_stub` app-env flag routes through
      `Req.Test` the same way `Arbiter.GitHub` does.

  Returns `{:error, :cooling_down}` without making a request when this
  token 429'd within the last 180s. Never raises.
  """
  @spec fetch(keyword()) :: {:ok, usage()} | {:error, term()}
  def fetch(opts \\ []) do
    with {:ok, token} <- fetch_token(opts) do
      key = cooldown_key(token)

      if cooling_down?(key) do
        {:error, :cooling_down}
      else
        request(token, key, opts)
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # ---- token resolution ---------------------------------------------------

  defp fetch_token(opts) do
    case Keyword.get(opts, :token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        read_token_from_credentials(opts)
    end
  end

  defp read_token_from_credentials(opts) do
    dir = Keyword.get(opts, :source_dir) || ConfigDir.source_dir()

    with dir when is_binary(dir) <- dir,
         path <- Path.join(dir, ".credentials.json"),
         {:ok, content} <- File.read(path),
         {:ok, json} <- Jason.decode(content),
         %{"accessToken" => token} when is_binary(token) and token != "" <-
           Map.get(json, "claudeAiOauth") do
      {:ok, token}
    else
      _ -> {:error, :no_credentials}
    end
  end

  # ---- HTTP ----------------------------------------------------------------

  defp request(token, cooldown_key, opts) do
    base = Keyword.get(opts, :base_url, @default_base_url)

    full_opts =
      [
        method: :get,
        url: base <> "/api/oauth/usage",
        headers: [
          {"authorization", "Bearer " <> token},
          {"anthropic-beta", @anthropic_beta},
          {"anthropic-version", @anthropic_version}
        ],
        receive_timeout: 10_000,
        retry: false
      ]
      |> Keyword.merge(stub_opts(opts))

    case Req.request(full_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_usage(body)}

      {:ok, %Req.Response{status: 429}} ->
        set_cooldown(cooldown_key)
        {:error, :rate_limited}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp stub_opts(opts) do
    cond do
      Keyword.has_key?(opts, :plug) ->
        [plug: Keyword.fetch!(opts, :plug)]

      Application.get_env(:arbiter, :oauth_usage_http_stub, false) ->
        [plug: {Req.Test, @stub_name}]

      true ->
        []
    end
  end

  # ---- parsing ---------------------------------------------------------

  # Anthropic's `utilization` fields here are 0-100 percentages (9router
  # derives `remaining = 100 - utilization`), unlike the
  # `anthropic-ratelimit-unified-*` headers this app already parses as 0-1
  # fractions (see `Arbiter.Quota.parse_unified_headers/1`). Normalize to the
  # same 0-1 fraction scale so both sources render identically downstream.
  defp parse_usage(body) when is_map(body) do
    %{
      utilization_5h: utilization(Map.get(body, "five_hour")),
      utilization_7d: utilization(Map.get(body, "seven_day")),
      per_model_utilization: per_model_utilization(body),
      extra_usage: normalize_extra_usage(Map.get(body, "extra_usage"))
    }
  end

  defp parse_usage(_),
    do: %{
      utilization_5h: nil,
      utilization_7d: nil,
      per_model_utilization: %{},
      extra_usage: %{}
    }

  defp utilization(%{"utilization" => u}) when is_number(u), do: u / 100.0
  defp utilization(_), do: nil

  defp per_model_utilization(body) do
    for {key, %{"utilization" => u}} <- body,
        is_binary(key),
        key != "seven_day",
        String.starts_with?(key, "seven_day_"),
        is_number(u),
        into: %{} do
      {String.replace_prefix(key, "seven_day_", ""), u / 100.0}
    end
  end

  defp normalize_extra_usage(nil), do: %{}
  defp normalize_extra_usage(n) when is_number(n), do: %{"amount_usd" => n / 1.0}
  defp normalize_extra_usage(%{} = m), do: m
  defp normalize_extra_usage(_), do: %{}

  # ---- 429 cooldown --------------------------------------------------------

  defp cooldown_key(token), do: {:arbiter_oauth_usage_cooldown, :erlang.phash2(token)}

  defp cooling_down?(key) do
    case :persistent_term.get(key, nil) do
      nil -> false
      until -> System.monotonic_time(:millisecond) < until
    end
  end

  defp set_cooldown(key) do
    :persistent_term.put(key, System.monotonic_time(:millisecond) + @cooldown_ms)
  end

  @doc false
  @spec reset_cooldown!(String.t()) :: :ok
  def reset_cooldown!(token) do
    _ = :persistent_term.erase(cooldown_key(token))
    :ok
  end
end
