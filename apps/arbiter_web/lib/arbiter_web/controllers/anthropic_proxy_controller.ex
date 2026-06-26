defmodule ArbiterWeb.AnthropicProxyController do
  @moduledoc """
  Transparent local proxy in front of `api.anthropic.com` (bd-5boun6).

  Workers are spawned with `ANTHROPIC_BASE_URL` pointed at
  `/proxy/anthropic/<workspace_id>`, so every Claude CLI request flows through
  here. We forward verbatim (method, path, query, headers, body) to Anthropic
  over HTTPS, stream the response back — including `text/event-stream` SSE,
  chunk-by-chunk so the CLI sees streamed output — and on the way through we
  snapshot the `anthropic-ratelimit-unified-*` quota headers into
  `Arbiter.Quota` for the originating workspace.

  ## Workspace attribution

  The Claude CLI can't be made to send a custom workspace header, so the
  workspace id rides as the first path segment of the base URL. The CLI joins
  it with the API path (`/proxy/anthropic/<ws>/v1/messages`); we pop the
  leading UUID segment, attribute captured headers to it, and forward the
  remainder (`/v1/messages`) upstream. A request with no leading UUID (a
  workspace-agnostic probe) is attributed to the installation default.

  ## Health check

  The CLI first probes `HEAD /` against the base URL. `Plug.Head` rewrites that
  to a bodyless `GET`; we answer any request whose upstream path is empty with
  a bare `200` without touching Anthropic.
  """

  use ArbiterWeb, :controller

  require Logger

  @default_upstream "https://api.anthropic.com"
  @finch ArbiterWeb.Finch

  # Standard UUID (the workspace id ride-along segment). Anthropic API paths
  # start with `v1`, never a UUID, so this disambiguates cleanly.
  @uuid_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  # Hop-by-hop request/response headers that must not be forwarded verbatim.
  @hop_by_hop ~w(
    connection keep-alive proxy-authenticate proxy-authorization te trailer
    transfer-encoding upgrade host content-length
  )

  # Response headers we strip before handing the response back to the CLI
  # (cookies and Cloudflare noise the CLI has no use for).
  @strip_response ~w(set-cookie content-length transfer-encoding connection keep-alive)

  @doc """
  Entry point for `ANY /proxy/anthropic/*path`. Splits off the optional
  workspace segment, short-circuits the health check, otherwise forwards.
  """
  def forward(conn, %{"path" => segments}) do
    {workspace_id, upstream_segments} = split_workspace(segments)

    case upstream_segments do
      [] -> send_resp(conn, 200, "")
      _ -> proxy(conn, workspace_id, upstream_segments)
    end
  end

  # The catch-all matches `/proxy/anthropic` with no trailing path too.
  def forward(conn, _params), do: send_resp(conn, 200, "")

  defp split_workspace([first | rest]) do
    if Regex.match?(@uuid_re, first), do: {first, rest}, else: {nil, [first | rest]}
  end

  defp split_workspace([]), do: {nil, []}

  defp proxy(conn, workspace_id, upstream_segments) do
    {:ok, body, conn} = read_full_body(conn)
    url = build_url(upstream_segments, conn.query_string)
    method = conn.method
    headers = forward_request_headers(conn)

    request = Finch.build(method, url, headers, body)
    stream_upstream(conn, request, workspace_id, 3)
  end

  # Stream the upstream response back, retrying transient transport errors that
  # arrive BEFORE any bytes reach the client (connect/reset blips to
  # api.anthropic.com). Once streaming has started we can only unwind. (bd-5boun6)
  defp stream_upstream(conn, request, workspace_id, attempts_left) do
    acc = %{conn: conn, workspace_id: workspace_id, status: 200, started?: false}
    t0 = System.monotonic_time(:millisecond)

    case Finch.stream(request, @finch, acc, &handle_stream/2, receive_timeout: receive_timeout()) do
      {:ok, %{conn: conn, started?: true}} ->
        conn

      {:ok, %{conn: conn, status: status, started?: false}} ->
        send_resp(conn, status, "")

      {:error, reason, %{conn: conn, started?: false}} when attempts_left > 1 ->
        elapsed = System.monotonic_time(:millisecond) - t0

        Logger.warning(
          "anthropic proxy upstream error (retrying, #{attempts_left - 1} left, " <>
            "elapsed_ms=#{elapsed}, started?=false): #{inspect(reason)}"
        )

        stream_upstream(conn, request, workspace_id, attempts_left - 1)

      {:error, reason, %{conn: conn, started?: started?}} ->
        elapsed = System.monotonic_time(:millisecond) - t0

        Logger.warning(
          "anthropic proxy upstream error (elapsed_ms=#{elapsed}, started?=#{started?}): #{inspect(reason)}"
        )

        if started?, do: conn, else: bad_gateway(conn)
    end
  end

  defp receive_timeout do
    :arbiter_web
    |> Application.get_env(:anthropic_proxy, [])
    |> Keyword.get(:receive_timeout, 120_000)
  end

  # ---- Finch streaming callbacks ----------------------------------------

  defp handle_stream({:status, status}, acc), do: %{acc | status: status}

  defp handle_stream({:headers, headers}, acc) do
    capture_quota(acc.workspace_id, headers)

    conn =
      acc.conn
      |> put_response_headers(headers)
      |> send_chunked(acc.status)

    %{acc | conn: conn, started?: true}
  end

  defp handle_stream({:data, data}, acc) do
    case chunk(acc.conn, data) do
      {:ok, conn} -> %{acc | conn: conn}
      # Client hung up mid-stream; keep the acc so the loop unwinds cleanly.
      {:error, _} -> acc
    end
  end

  # ---- header / body plumbing -------------------------------------------

  # Read the entire request body (Anthropic message payloads are small enough
  # to buffer; the streaming concern is the *response*, not the request).
  defp read_full_body(conn, acc \\ "") do
    case read_body(conn, length: 1_000_000) do
      {:ok, body, conn} -> {:ok, acc <> body, conn}
      {:more, partial, conn} -> read_full_body(conn, acc <> partial)
      {:error, _} -> {:ok, acc, conn}
    end
  end

  defp build_url(segments, query) do
    path = Enum.map_join(segments, "/", &URI.encode/1)
    base = upstream_base() <> "/" <> path

    case query do
      "" -> base
      q -> base <> "?" <> q
    end
  end

  # Forward all request headers except hop-by-hop ones. `host` is dropped so
  # Finch sets it to api.anthropic.com; `authorization` / `anthropic-*` /
  # `x-api-key` pass through untouched so OAuth and API-key auth both work.
  defp forward_request_headers(conn) do
    # Force identity encoding upstream (bd-5boun6 fix): the proxy streams the
    # body through verbatim, so a gzipped response truncated by a mid-stream
    # upstream blip reaches the CLI as a corrupt gzip stream (ZlibError) that
    # kills the session. Requesting identity keeps responses uncompressed, so a
    # truncation is at worst incomplete-but-valid bytes. Captured rate-limit
    # headers are unaffected.
    forwarded =
      Enum.reject(conn.req_headers, fn {name, _} ->
        n = String.downcase(name)
        n in @hop_by_hop or n == "accept-encoding"
      end)

    [{"accept-encoding", "identity"} | forwarded]
  end

  # Mirror upstream response headers back to the CLI, minus the ones that don't
  # survive re-chunking (content-length / transfer-encoding) plus cookies and
  # Cloudflare noise. Content-type (e.g. text/event-stream) is preserved.
  defp put_response_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      lname = String.downcase(name)

      if lname in @strip_response or String.starts_with?(lname, "cf-") do
        acc
      else
        put_resp_header(acc, lname, value)
      end
    end)
  end

  # ---- quota capture -----------------------------------------------------

  # Overridable in test to point at a stub upstream instead of api.anthropic.com.
  defp upstream_base do
    Application.get_env(:arbiter_web, :anthropic_upstream, @default_upstream)
    |> String.trim_trailing("/")
  end

  defp capture_quota(workspace_id, headers) do
    Arbiter.Quota.capture(workspace_id, headers)
  rescue
    e ->
      Logger.warning("anthropic proxy quota capture failed: #{inspect(e)}")
      :error
  end

  # ---- fallbacks ---------------------------------------------------------

  # Only reached before any bytes are streamed (the error arrived on connect),
  # so the conn is always unsent here.
  defp bad_gateway(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      502,
      Jason.encode!(%{error: %{type: "proxy_error", message: "upstream unreachable"}})
    )
  end
end
