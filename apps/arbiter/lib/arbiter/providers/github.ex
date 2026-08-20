defmodule Arbiter.Providers.Github do
  @moduledoc """
  Shared low-level GitHub REST mechanics behind `Arbiter.Mergers.Github` and
  `Arbiter.Trackers.GitHub` (bd-1c3y0b).

  Both adapters hit the same API with the same auth scheme, gate every call
  through the same account-wide budget (`Arbiter.GitHub.Limiter`, bd-3p5vqc),
  and classify the same status codes into their own (near-identical) `Error`
  struct. This module owns that shared plumbing on top of
  `Arbiter.Http.Client` (bd-1r2kkg); each adapter supplies only its own
  `Error` module, endpoint paths, and payload shapes.

  ## What stays per-adapter

  Each adapter still defines its own `Error` struct (the two `kind` enums
  differ slightly — mergers alone can see `:conflict` / `:not_mergeable` from
  the merge endpoints) and its own thin `client/1`, `request/4`,
  `handle_json/1`, `expect_ok/1`, `http_error/3`, `transport_error/1`
  wrappers that close over that module, so call sites read exactly as they
  did before this split.
  """

  alias Arbiter.GitHub.Limiter
  alias Arbiter.Http.Client
  alias Arbiter.Http.Error, as: ErrorSpec
  alias Arbiter.Http.RateLimit

  require Logger

  @max_secondary_retries 2
  @base_backoff_ms 250
  @max_backoff_ms 5_000

  @doc "The auth headers every GitHub REST/GraphQL call carries."
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "arbiter"}
    ]
  end

  @doc """
  Builds the `Arbiter.Http.Error` spec for `error_module`, using GitHub's
  shared status-code classification and message extraction.
  """
  @spec error_spec(module()) :: ErrorSpec.t()
  def error_spec(error_module) do
    ErrorSpec.new(
      module: error_module,
      classify_kind: &classify_kind/2,
      error_message: &error_message/2,
      retry_after_ms: &RateLimit.retry_after_ms/2
    )
  end

  @doc """
  Builds the `Arbiter.Http.Client` an adapter uses for every call: GitHub auth
  headers, `error_module`'s error spec, `Req.Test` stub wiring, and gating
  through the shared account-wide `Arbiter.GitHub.Limiter`.

  `opts`:

    * `:stub_name` (required) — the `Req.Test` stub identity for this
      adapter, injected when `:arbiter, :github_http_stub` is true.
    * `:retry` — `nil` (default) for no retry, or `:secondary_rate_limit` to
      attach the backoff-and-retry policy for GitHub's secondary/abuse rate
      limit (bd-8y1i58). Only the merger currently opts in — its write-heavy
      PR operations are worth the extra round trips; tracker calls are not.
  """
  @spec client(map(), module(), keyword()) :: Client.t()
  def client(cfg, error_module, opts) do
    Client.new(
      base_url: cfg.base_url,
      headers: headers(cfg.token),
      errors: error_spec(error_module),
      stub: {:github_http_stub, Keyword.fetch!(opts, :stub_name)},
      gate: fn fun -> Limiter.gate(cfg.token, fun) end,
      retry: retry_opts(Keyword.get(opts, :retry))
    )
  end

  @doc """
  `Arbiter.Http.Client.paginate/4`'s `:next_page` for GitHub: walks the RFC
  5988 `Link` header's `rel="next"` entry.

  GitHub's `Link` header names an absolute next URL, so the next page moves
  to a new path with fresh params rather than reusing the current ones.
  """
  @spec next_page(map() | list(), String.t(), keyword()) :: {String.t(), keyword()} | nil
  def next_page(headers, _path, _req_opts) do
    case next_page_url(headers) do
      nil -> nil
      {next_path, next_params} -> {next_path, [params: next_params]}
    end
  end

  # ---- Internals: retry -----------------------------------------------------

  defp retry_opts(nil), do: nil

  defp retry_opts(:secondary_rate_limit) do
    %{
      max: @max_secondary_retries,
      retry?: fn %Req.Response{status: status} = resp ->
        status in [403, 429] and secondary_rate_limited?(resp)
      end,
      delay: &retry_delay_ms/2,
      sleep: &sleep/1,
      on_retry: fn _resp, attempt ->
        Logger.info(
          "GitHub: secondary rate limit hit (attempt #{attempt + 1}); backing off before retry"
        )
      end
    }
  end

  # GitHub's secondary/abuse limit is a 403 whose body names it explicitly, or
  # (per GitHub's docs) may carry a `Retry-After` header — unlike a primary
  # quota 403, which never does. Either signal is enough to treat it as
  # transient rather than a hard auth/permissions failure.
  defp secondary_rate_limited?(%Req.Response{} = resp) do
    RateLimit.retry_after_seconds(resp) != nil or secondary_limit_message?(resp.body)
  end

  defp secondary_limit_message?(%{"message" => msg}) when is_binary(msg) do
    msg = String.downcase(msg)
    String.contains?(msg, "secondary rate limit") or String.contains?(msg, "abuse detection")
  end

  defp secondary_limit_message?(_), do: false

  # Honor GitHub's own Retry-After when it sends one (capped), else back off
  # exponentially.
  defp retry_delay_ms(resp, attempt) do
    case RateLimit.retry_after_seconds(resp) do
      nil -> backoff_ms(attempt)
      seconds -> min(seconds * 1_000, @max_backoff_ms)
    end
  end

  # Exponential backoff with jitter, capped — used when GitHub gives no
  # Retry-After header to honor directly.
  defp backoff_ms(attempt) do
    base = @base_backoff_ms * Integer.pow(2, attempt)
    jitter = :rand.uniform(div(base, 2) + 1)
    min(base + jitter, @max_backoff_ms)
  end

  # Overridable in tests (`Application.put_env(:arbiter, :github_retry_sleep_fun, fun)`)
  # so retry backoff never actually blocks the test suite.
  defp sleep(ms) do
    case Application.get_env(:arbiter, :github_retry_sleep_fun) do
      fun when is_function(fun, 1) -> fun.(ms)
      _ -> Process.sleep(ms)
    end
  end

  # ---- Internals: pagination -------------------------------------------------

  defp next_page_url(headers) do
    headers
    |> link_header_value()
    |> parse_next_link()
  end

  defp link_header_value(headers) when is_map(headers) do
    case Map.get(headers, "link") || Map.get(headers, "Link") do
      [v | _] when is_binary(v) -> v
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp link_header_value(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {"link", v} -> v
      {"Link", v} -> v
      _ -> nil
    end)
  end

  defp link_header_value(_), do: nil

  defp parse_next_link(nil), do: nil

  defp parse_next_link(value) when is_binary(value) do
    case Regex.run(~r/<([^>]+)>\s*;\s*rel="next"/, value) do
      [_, url] -> split_url(url)
      _ -> nil
    end
  end

  defp split_url(url) do
    uri = URI.parse(url)

    params =
      case uri.query do
        nil -> []
        q -> URI.decode_query(q) |> Enum.to_list()
      end

    {uri.path || "/", params}
  end

  # ---- Internals: error classification ---------------------------------------

  # A 429 is always a rate limit. A 403 is a rate limit only when the body
  # says so — otherwise it's an ordinary scope/permission `:forbidden`. 405
  # and 409 only ever come from the merge endpoints, but classifying them
  # here (rather than per-adapter) costs nothing and keeps this the single
  # copy of GitHub's status-code mapping.
  defp classify_kind(429, _body), do: :rate_limited

  defp classify_kind(403, body),
    do: if(rate_limited_body?(body), do: :rate_limited, else: :forbidden)

  defp classify_kind(status, _body), do: kind_for_status(status)

  defp rate_limited_body?(%{"message" => msg}) when is_binary(msg) do
    msg = String.downcase(msg)
    String.contains?(msg, "rate limit") or String.contains?(msg, "abuse detection")
  end

  defp rate_limited_body?(_), do: false

  defp kind_for_status(400), do: :validation_failed
  defp kind_for_status(401), do: :unauthenticated
  defp kind_for_status(403), do: :forbidden
  defp kind_for_status(404), do: :not_found
  defp kind_for_status(405), do: :not_mergeable
  defp kind_for_status(409), do: :conflict
  defp kind_for_status(422), do: :validation_failed
  defp kind_for_status(status) when status >= 500 and status < 600, do: :server_error
  defp kind_for_status(_), do: :http

  defp error_message(%{"message" => msg}, _status) when is_binary(msg), do: msg
  defp error_message(_, status), do: "HTTP #{status}"
end
