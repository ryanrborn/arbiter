defmodule ArbiterCli.Client do
  @moduledoc """
  Thin Req wrapper for talking to the arbiter_web REST API. Surfaces clean
  `{:ok, body}` / `{:error, %Error{}}` tuples so command modules don't deal
  with raw HTTP plumbing.

  Configuration:

    * `ARB_HOST` env var overrides the base URL (default `http://127.0.0.1:4848`)
    * `ARB_TOKEN` env var sets a Bearer token for authentication. Required for
      remote access (ARB_HOST pointing to a different server). Not needed for
      local loopback access — unless `ARB_SESSION_ID` is set, see below.
    * `ARB_SESSION_ID` — set by every Arbiter session's `launch.sh`
      (`Arbiter.Sessions.Provisioning`), absent everywhere else (the
      operator's own shell, a Claude Code session opened against a plain
      `arb init` checkout). When set, this client is running **inside** an
      Arbiter session, and never makes an unauthenticated call even over
      loopback (bd-5b5hq7) — the session's own MCP token, read from a
      mode-`0600` file at `$ARB_SESSION_ROOT/mcp_token`
      (`Arbiter.Sessions.Layout.mcp_token_path/1`), is used instead. That
      token is deliberately weaker than a bare loopback call would get for
      free: `can_dispatch: false` by default, possibly workspace-bound, and
      revoked the moment the session ends. An explicit `ARB_TOKEN` still
      takes priority, matching the non-session behavior. If neither is
      available, the request is refused with a clear error rather than
      falling back to an unauthenticated call.

  Tests can override the Req adapter via `:req_options` in the process dict:

      Process.put(:bd2_req_options, plug: {Req.Test, MyStub})
  """

  defmodule Error do
    @moduledoc """
    Normalised error returned by every Client function on failure.

    Kinds:
      * `:connection_refused` — Phoenix isn't running
      * `:timeout`
      * `:transport` — other transport-layer error (DNS, etc.)
      * `:http` — server returned a 4xx/5xx; `status` + `body` populated
      * `:decode` — server returned non-JSON
    """
    defstruct [:kind, :status, :body, :message, :hint]

    # `:no_session_token` — inside an Arbiter session (`ARB_SESSION_ID` set)
    # with no usable token: no `ARB_TOKEN` override and no readable
    # `$ARB_SESSION_ROOT/mcp_token` file. The request is refused before it is
    # ever sent (bd-5b5hq7) rather than going out unauthenticated.

    @type t :: %__MODULE__{
            kind: atom(),
            status: nil | integer(),
            body: any(),
            message: String.t(),
            hint: nil | String.t()
          }
  end

  @default_base "http://127.0.0.1:4848"

  @spec base_url() :: String.t()
  def base_url do
    System.get_env("ARB_HOST", @default_base)
  end

  @doc """
  The bearer token this client would send, or `nil` for none — outside a
  session, an unset `ARB_TOKEN` legitimately means "send unauthenticated"
  (loopback). Prefer `resolve_token/0` for making a request: it distinguishes
  that from the in-session case where no token is a hard error.
  """
  @spec token() :: String.t() | nil
  def token do
    System.get_env("ARB_TOKEN")
  end

  @spec get(String.t(), keyword()) :: {:ok, any()} | {:error, Error.t()}
  def get(path, params \\ []), do: request(:get, path, params: params)

  @spec post(String.t(), map()) :: {:ok, any()} | {:error, Error.t()}
  def post(path, body), do: request(:post, path, json: body)

  @spec patch(String.t(), map()) :: {:ok, any()} | {:error, Error.t()}
  def patch(path, body), do: request(:patch, path, json: body)

  @spec delete(String.t(), keyword()) :: {:ok, any()} | {:error, Error.t()}
  def delete(path, params \\ []), do: request(:delete, path, params: params)

  defp request(method, path, opts) do
    with {:ok, token} <- resolve_token() do
      do_request(method, path, token, opts)
    end
  end

  # Outside a session: `ARB_TOKEN` or nothing (unauthenticated — the loopback
  # default). Inside a session (`ARB_SESSION_ID` set): `ARB_TOKEN` still wins
  # if the operator set one, otherwise the session's own token file — and if
  # neither exists, refuse rather than ever send the request unauthenticated
  # (bd-5b5hq7). A session's `arb` is on PATH with `ARB_TOKEN` unset by
  # default; without this, `arb mcp token mint --tier coordinator` run from
  # inside a session would ride the same unauthenticated-loopback path the
  # operator's own shell relies on and mint a token more powerful than the
  # session's own.
  defp resolve_token do
    case System.get_env("ARB_SESSION_ID") do
      session_id when is_binary(session_id) and session_id != "" ->
        case token() do
          t when is_binary(t) and t != "" -> {:ok, t}
          _ -> session_token()
        end

      _ ->
        {:ok, token()}
    end
  end

  defp session_token do
    with :error <- session_token_file(), :error <- session_mcp_json_token() do
      {:error,
       %Error{
         kind: :no_session_token,
         message: "no MCP token available for this session",
         hint:
           "ARB_SESSION_ID is set but no session token file was found — this session has " <>
             "no usable Arbiter credential, so the request was refused rather than sent " <>
             "unauthenticated. Set ARB_TOKEN explicitly to override."
       }}
    end
  end

  defp session_token_file do
    root = System.get_env("ARB_SESSION_ROOT")
    path = root && root != "" && Path.join(root, "mcp_token")

    with path when is_binary(path) <- path,
         {:ok, contents} <- File.read(path) do
      {:ok, String.trim(contents)}
    else
      _ -> :error
    end
  end

  # Fallback for sessions provisioned before `$ARB_SESSION_ROOT/mcp_token` was
  # written (bd-5b5hq7 round 2): every session still gets a `.mcp.json` under
  # its workspace with the same scope token in a bearer header
  # (`Arbiter.MCP.AgentConfig.Claude`, `Arbiter.Sessions.Layout.mcp_config_path/1`),
  # so read that instead of refusing outright. Without this, every `arb`
  # invocation in an already-running session breaks the moment the
  # coordinator restarts onto this deploy.
  #
  # Resolved against `$ARB_SESSION_ROOT`, never the cwd: reading a cwd-local
  # `.mcp.json` would let a session that `cd`s into an `arb init` checkout
  # (which writes an unrestricted, unrevocable coordinator token) silently
  # authenticate as that foreign token instead of its own.
  defp session_mcp_json_token do
    root = System.get_env("ARB_SESSION_ROOT")

    with root when is_binary(root) and root != "" <- root,
         :error <- read_mcp_json_token(Path.join([root, "workspace", ".mcp.json"])) do
      read_mcp_json_token(Path.join(root, ".mcp.json"))
    else
      {:ok, token} -> {:ok, token}
      _ -> :error
    end
  end

  defp read_mcp_json_token(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"mcpServers" => servers}} when is_map(servers) <- Jason.decode(contents),
         {:ok, server} <- arbiter_mcp_server(servers),
         %{"headers" => %{"Authorization" => "Bearer " <> token}} <- server,
         true <- token != "" do
      {:ok, token}
    else
      _ -> :error
    end
  end

  # Selects the Arbiter entry by name (never "whichever key the map
  # enumerates first") so a `.mcp.json` with other MCP servers configured
  # can't leak a third-party server's bearer credential to the Arbiter host.
  defp arbiter_mcp_server(servers) do
    name = System.get_env("ARB_MCP_SERVER_NAME") || "arbiter"

    case Map.fetch(servers, name) do
      {:ok, server} ->
        {:ok, server}

      :error ->
        servers
        |> Map.values()
        |> Enum.find(fn
          %{"url" => url} when is_binary(url) -> String.starts_with?(url, base_url())
          _ -> false
        end)
        |> case do
          nil -> :error
          server -> {:ok, server}
        end
    end
  end

  defp do_request(method, path, token, opts) do
    url = base_url() <> path

    headers = auth_headers(token)

    req_opts =
      [
        method: method,
        url: url,
        receive_timeout: 10_000,
        connect_options: [timeout: 5_000],
        retry: false,
        headers: headers
      ] ++ opts ++ test_opts()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, resp.body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, %{reason: :econnrefused}} ->
        {:error,
         %Error{
           kind: :connection_refused,
           message: "could not connect to #{base_url()}",
           hint:
             "Phoenix app isn't running. Start it with `mix phx.server` from the umbrella root."
         }}

      {:error, %{reason: :timeout}} ->
        {:error, %Error{kind: :timeout, message: "request to #{url} timed out"}}

      {:error, %{reason: :nxdomain}} ->
        {:error,
         %Error{
           kind: :transport,
           message: "could not resolve host for #{url}",
           hint: "Check that ARB_HOST is set correctly."
         }}

      {:error, %{__exception__: true} = e} ->
        {:error, %Error{kind: :transport, message: Exception.message(e)}}

      {:error, other} ->
        {:error, %Error{kind: :transport, message: inspect(other)}}
    end
  end

  defp auth_headers(nil), do: []
  defp auth_headers(token), do: [{"authorization", "Bearer #{token}"}]

  defp http_error(401, %{"error" => %{"message" => msg} = err}) do
    %Error{
      kind: :http,
      status: 401,
      body: err,
      message: msg,
      hint:
        "set ARB_TOKEN — remote arb requires a token (mint one with `arb mcp token mint --tier coordinator`)"
    }
  end

  defp http_error(401, body) do
    %Error{
      kind: :http,
      status: 401,
      body: body,
      message: "HTTP 401 (Unauthorized)",
      hint:
        "set ARB_TOKEN — remote arb requires a token (mint one with `arb mcp token mint --tier coordinator`)"
    }
  end

  defp http_error(status, %{"error" => %{"message" => msg} = err}) do
    %Error{
      kind: :http,
      status: status,
      body: err,
      message: msg
    }
  end

  defp http_error(status, body) do
    %Error{
      kind: :http,
      status: status,
      body: body,
      message: "HTTP #{status}"
    }
  end

  # Test hook: a test can stuff Req options (e.g. `plug: {Req.Test, MyStub}`)
  # into the process dict to redirect requests to a stub.
  defp test_opts do
    Process.get(:bd2_req_options, [])
  end
end
