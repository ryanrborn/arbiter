defmodule ArbiterWeb.MCP.Session do
  @moduledoc """
  Session bookkeeping for the `Arbiter.MCP` Streamable HTTP transport.

  A session ties a client's open `GET /mcp` SSE stream (the server → client
  channel) to an opaque id that POST requests thread back via the
  `Mcp-Session-Id` header. The id is minted on the `initialize` POST response and
  re-presented on the GET stream and on subsequent POSTs, so the server can route
  a server-initiated message to the right open stream.

  Routing is backed by a `Registry` (`ArbiterWeb.MCP.SessionRegistry`, started in
  `ArbiterWeb.Application`) keyed by session id. The SSE handler claims the id
  for its own process with `claim/1` and drops it with `unregister/1` when the
  stream ends; `notify/2` looks the id up and sends the message to that process,
  which frames it as an SSE event on the live stream. When no stream is open for
  an id, `notify/2` returns `{:error, :no_session}`.

  A session id is the client's, not ours: it presents the same id on every POST
  and on every reconnect of the GET stream. So a reconnect that lands while the
  previous stream is still registered **takes the id over** (`claim/1` asks the
  incumbent to close and waits for it to let go) instead of quietly routing
  under some other id the client will never ask about.
  """

  @registry ArbiterWeb.MCP.SessionRegistry

  # How long a reconnecting stream waits for the incumbent holder of its session
  # id to let go, and how often it re-checks. There is no "released" signal to
  # subscribe to: the displaced stream may unregister itself (its process lives
  # on to serve the next request on a keep-alive connection) or simply die, and
  # `Registry` clears the entry either way — so poll the entry.
  @takeover_timeout_ms 1_000
  @takeover_poll_ms 10

  @doc "The `Registry` name backing session → stream routing."
  @spec registry() :: module()
  def registry, do: @registry

  @doc "Mint a fresh opaque session id."
  @spec new_id() :: String.t()
  def new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @doc """
  Register the calling process as the owner of `session_id`'s SSE stream.

  Returns `:ok`, or `{:error, :already_registered}` if a stream is already open
  for that id (a duplicate GET for the same session). Prefer `claim/1`, which
  resolves that collision instead of reporting it.
  """
  @spec register(String.t()) :: :ok | {:error, :already_registered}
  def register(session_id) when is_binary(session_id) do
    case Registry.register(@registry, session_id, nil) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_registered}
    end
  end

  @doc """
  Claim `session_id` for the calling process, displacing the stream that holds
  it now, if any.

  A client reconnecting its GET stream re-presents the session id it already
  POSTs with, and the incumbent registration is usually a stream the server has
  not finished reaping. Minting a different id instead would route every
  server-initiated message to that dead stream while the client waits on the id
  it knows, so the incumbent is asked to close (`:mcp_sse_close`, which ends
  `ArbiterWeb.MCP.Plug`'s stream loop and unregisters it) and the id is re-claimed
  once released.

  Returns `{:error, :session_in_use}` if the incumbent is still holding the id
  after `timeout_ms` — the caller should refuse the connection rather than serve
  an unroutable stream.
  """
  @spec claim(String.t(), pos_integer()) :: :ok | {:error, :session_in_use}
  def claim(session_id, timeout_ms \\ @takeover_timeout_ms) when is_binary(session_id) do
    claim_until(session_id, System.monotonic_time(:millisecond) + timeout_ms)
  end

  @doc """
  Release the calling process's claim on `session_id`.

  Always called when a stream ends: a Bandit connection process outlives the
  request it served, so without this the entry would linger and `notify/2` would
  hand later messages to a process that is no longer streaming.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(session_id) when is_binary(session_id) do
    Registry.unregister(@registry, session_id)
  end

  @doc """
  Route a server-initiated `message` to `session_id`'s open SSE stream.

  Sends `{:mcp_sse, message}` to the registered stream process, which frames it
  as an SSE `data:` event. Returns `{:error, :no_session}` when no stream is open
  for the id.
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

  # ---- session takeover ----------------------------------------------------

  defp claim_until(session_id, deadline) do
    case Registry.register(@registry, session_id, nil) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, pid}} when pid == self() -> :ok
      {:error, {:already_registered, pid}} -> displace(session_id, pid, deadline)
    end
  end

  defp displace(session_id, pid, deadline) do
    send(pid, :mcp_sse_close)

    if await_release(session_id, pid, deadline) do
      claim_until(session_id, deadline)
    else
      {:error, :session_in_use}
    end
  end

  defp await_release(session_id, pid, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      not owner?(session_id, pid) -> true
      remaining <= 0 -> false
      true -> wait_and_recheck(session_id, pid, deadline, remaining)
    end
  end

  defp wait_and_recheck(session_id, pid, deadline, remaining) do
    Process.sleep(min(remaining, @takeover_poll_ms))
    await_release(session_id, pid, deadline)
  end

  defp owner?(session_id, pid) do
    match?([{^pid, _}], Registry.lookup(@registry, session_id))
  end
end
