defmodule Arbiter.Http.Client do
  @moduledoc """
  The shared HTTP mechanics behind every tracker and merger adapter.

  Seven provider modules (GitHub/GitLab mergers; GitHub/GitLab/Jira/Linear/
  Shortcut trackers) each used to hand-roll the same four things: Req option
  construction, `Req.Test` stub injection, 200..299-vs-error classification,
  and — for the two forge trackers — a pagination loop. This module owns all
  of it once; a provider now supplies only what is genuinely provider-specific
  (base URL, auth headers, and an `Arbiter.Http.Error` spec) and calls the
  functions here.

  ## Configuration

    * `:base_url` — prefixed to the `path` given to `request/4`.
    * `:headers` — request headers, already resolved from the provider config.
    * `:errors` — an `Arbiter.Http.Error` spec.
    * `:stub` — `{app_env_key, stub_name}`, or `nil`. When the `:arbiter`
      application env key is true, `plug: {Req.Test, stub_name}` is injected.
    * `:gate` — optional `(( -> result) -> result)`. GitHub passes
      `Arbiter.Github.Limiter.gate/2` here so every attempt is metered.
    * `:retry` — optional map enabling a bounded retry loop, see below.
    * `:receive_timeout` — defaults to 15s, as every provider used.

  ## Retry

  `:retry` is `%{max:, retry?:, delay:, sleep:, on_retry:}`:

    * `retry?` — `(resp -> boolean)`, consulted only on `{:ok, resp}`.
      Transport errors are never retried.
    * `delay` — `(resp, attempt -> ms)`.
    * `sleep` — `(ms -> any)`, so tests can make backoff free.
    * `on_retry` — optional `(resp, attempt -> any)` side-effect hook (logging).

  The gate is applied *per attempt*, inside the loop, so a retried request is
  counted — and can be shed — as the several real requests it is (bd-8y1i58).

  ## Errors without a request

  `handle_json/2`, `expect_ok/2`, `http_error/4` and `transport_error/2` accept
  either a client or a bare `Arbiter.Http.Error` spec, so a provider can
  classify a response without rebuilding its request config.
  """

  alias Arbiter.Http.Error

  @enforce_keys [:base_url, :headers, :errors]
  defstruct [
    :base_url,
    :headers,
    :errors,
    :stub,
    :gate,
    :retry,
    receive_timeout: 15_000
  ]

  @type t :: %__MODULE__{}
  @type result :: {:ok, Req.Response.t()} | {:error, Exception.t() | term()}

  @doc "Builds a client from the keyword options documented above."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  The full `Req.request/1` option list for a call, without performing it.

  Caller `req_opts` override the defaults; stub injection is applied last so a
  stubbed test run always reaches the stub plug.
  """
  @spec build_opts(t(), atom(), String.t(), keyword()) :: keyword()
  def build_opts(%__MODULE__{} = client, method, path, req_opts) do
    [
      method: method,
      url: client.base_url <> path,
      headers: client.headers,
      receive_timeout: client.receive_timeout,
      retry: false
    ]
    |> Keyword.merge(req_opts)
    |> Keyword.merge(stub_opts(client))
  end

  @doc """
  Performs a request, returning Req's own `{:ok, resp} | {:error, exception}`.

  Callers keep pattern-matching on `%Req.Response{}` exactly as before; pass
  the result to `handle_json/2` or `expect_ok/2` to turn it into a provider
  result.
  """
  @spec request(t(), atom(), String.t(), keyword()) :: result()
  def request(%__MODULE__{} = client, method, path, req_opts \\ []) do
    perform(client, build_opts(client, method, path, req_opts), 0)
  end

  @doc """
  Performs a request from a pre-built option list (see `build_opts/4`).

  For the rare call that has to bypass the client's standard headers — GitHub's
  raw-diff fetch negotiates a different `Accept` — while still going through
  the same gate and retry loop.
  """
  @spec request_opts(t(), keyword()) :: result()
  def request_opts(%__MODULE__{} = client, full_opts), do: perform(client, full_opts, 0)

  @doc "`{:ok, body}` on 2xx, otherwise a provider error."
  @spec handle_json(t() | Error.t(), result()) :: {:ok, term()} | {:error, struct()}
  def handle_json(_ctx, {:ok, %Req.Response{status: status, body: body}})
      when status in 200..299,
      do: {:ok, body}

  def handle_json(ctx, {:ok, %Req.Response{status: status, body: body} = resp}),
    do: {:error, http_error(ctx, status, body, resp)}

  def handle_json(ctx, {:error, exception}), do: {:error, transport_error(ctx, exception)}

  @doc "`:ok` on 2xx, otherwise a provider error — for callers that ignore the body."
  @spec expect_ok(t() | Error.t(), result()) :: :ok | {:error, struct()}
  def expect_ok(_ctx, {:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok

  def expect_ok(ctx, {:ok, %Req.Response{status: status, body: body} = resp}),
    do: {:error, http_error(ctx, status, body, resp)}

  def expect_ok(ctx, {:error, exception}), do: {:error, transport_error(ctx, exception)}

  @doc """
  Follows a paginated list endpoint, concatenating every page.

  Options:

    * `:max_pages` (required) — hard cap so a runaway response can't hammer
      the API.
    * `:next_page` (required) — `(resp_headers, path, req_opts -> {path, req_opts} | nil)`.
      GitHub reads the RFC 5988 `Link` header; GitLab reads `x-next-page`.
    * `:transform_page` — optional `(page -> page)` applied to each page's list
      before accumulating (GitHub uses it to drop PRs from the issues feed).

  A non-list body counts as an empty page. The first non-2xx response or
  transport failure aborts with a provider error.
  """
  @spec paginate(t(), String.t(), keyword(), keyword()) :: {:ok, list()} | {:error, struct()}
  def paginate(%__MODULE__{} = client, path, req_opts, opts) do
    max_pages = Keyword.fetch!(opts, :max_pages)
    next_page = Keyword.fetch!(opts, :next_page)
    transform = Keyword.get(opts, :transform_page, & &1)

    do_paginate(client, path, req_opts, [], max_pages, next_page, transform)
  end

  @doc "Builds a provider error struct for a non-2xx response."
  @spec http_error(t() | Error.t(), integer(), term(), Req.Response.t() | nil) :: struct()
  def http_error(ctx, status, body, resp \\ nil),
    do: Error.build(errors(ctx), status, body, resp)

  @doc "Builds a `:network` provider error for a transport-level failure."
  @spec transport_error(t() | Error.t(), term()) :: struct()
  def transport_error(ctx, exception), do: Error.transport(errors(ctx), exception)

  # ---- Internals ----------------------------------------------------------

  defp errors(%__MODULE__{errors: %Error{} = spec}), do: spec
  defp errors(%Error{} = spec), do: spec

  defp do_paginate(_client, _path, _req_opts, acc, 0, _next_page, _transform),
    do: {:ok, acc |> Enum.reverse() |> List.flatten()}

  defp do_paginate(client, path, req_opts, acc, pages_left, next_page, transform) do
    case request(client, :get, path, req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        page = transform.(if is_list(body), do: body, else: [])

        case next_page.(headers, path, req_opts) do
          nil ->
            {:ok, [page | acc] |> Enum.reverse() |> List.flatten()}

          {next_path, next_req_opts} ->
            do_paginate(
              client,
              next_path,
              next_req_opts,
              [page | acc],
              pages_left - 1,
              next_page,
              transform
            )
        end

      {:ok, %Req.Response{status: status, body: body} = resp} ->
        {:error, http_error(client, status, body, resp)}

      {:error, exception} ->
        {:error, transport_error(client, exception)}
    end
  end

  defp perform(%__MODULE__{retry: nil} = client, full_opts, _attempt),
    do: gated(client, full_opts)

  defp perform(%__MODULE__{retry: retry} = client, full_opts, attempt) do
    case gated(client, full_opts) do
      {:ok, %Req.Response{} = resp} = result ->
        if attempt < retry.max and retry.retry?.(resp) do
          if on_retry = Map.get(retry, :on_retry), do: on_retry.(resp, attempt)
          retry.sleep.(retry.delay.(resp, attempt))
          perform(client, full_opts, attempt + 1)
        else
          result
        end

      other ->
        other
    end
  end

  defp gated(%__MODULE__{gate: nil}, full_opts), do: Req.request(full_opts)

  defp gated(%__MODULE__{gate: gate}, full_opts) when is_function(gate, 1),
    do: gate.(fn -> Req.request(full_opts) end)

  defp stub_opts(%__MODULE__{stub: nil}), do: []

  defp stub_opts(%__MODULE__{stub: {env_key, stub_name}}) do
    if Application.get_env(:arbiter, env_key, false) do
      [plug: {Req.Test, stub_name}]
    else
      []
    end
  end
end
