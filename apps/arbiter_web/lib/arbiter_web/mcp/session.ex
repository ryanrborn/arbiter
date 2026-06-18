defmodule ArbiterWeb.MCP.Session do
  @moduledoc """
  Session bookkeeping for the `Arbiter.MCP` Streamable HTTP transport.

  A session ties a client's open `GET /mcp` SSE stream (the server → client
  channel) to an opaque id that POST requests thread back via the
  `Mcp-Session-Id` header. The id is minted on the `initialize` POST response and
  re-presented on the GET stream and on subsequent POSTs, so the server can route
  a server-initiated message to the right open stream.

  Routing is backed by a `Registry` (`ArbiterWeb.MCP.SessionRegistry`, started in
  `ArbiterWeb.Application`) keyed by session id. The SSE handler registers the
  stream's owning process under its id; `notify/2` looks the id up and sends the
  message to that process, which frames it as an SSE event on the live stream.
  When no stream is open for an id, `notify/2` returns `{:error, :no_session}`
  and the caller falls back to a plain JSON POST response.
  """

  @registry ArbiterWeb.MCP.SessionRegistry

  @doc "The `Registry` name backing session → stream routing."
  @spec registry() :: module()
  def registry, do: @registry

  @doc "Mint a fresh opaque session id."
  @spec new_id() :: String.t()
  def new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @doc """
  Register the calling process as the owner of `session_id`'s SSE stream.

  Returns `:ok`, or `{:error, :already_registered}` if a stream is already open
  for that id (a duplicate GET for the same session).
  """
  @spec register(String.t()) :: :ok | {:error, :already_registered}
  def register(session_id) when is_binary(session_id) do
    case Registry.register(@registry, session_id, nil) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_registered}
    end
  end

  @doc """
  Route a server-initiated `message` to `session_id`'s open SSE stream.

  Sends `{:mcp_sse, message}` to the registered stream process, which frames it
  as an SSE `data:` event. Returns `{:error, :no_session}` when no stream is open
  for the id — the caller should fall back to a plain JSON response.
  """
  @spec notify(String.t(), term()) :: :ok | {:error, :no_session}
  def notify(session_id, message) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] ->
        send(pid, {:mcp_sse, message})
        :ok

      [] ->
        {:error, :no_session}
    end
  end
end
