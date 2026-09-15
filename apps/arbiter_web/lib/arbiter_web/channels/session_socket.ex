defmodule ArbiterWeb.SessionSocket do
  @moduledoc """
  The dedicated socket for browser-hosted coordinator sessions
  (bd-3ymdvi, phase 4 of `docs/browser-hosted-coordinator-sessions.md` §5.1).

  A **channel**, not a LiveView hook alone. LiveView's diffing is the wrong
  tool for a 60 fps ANSI byte stream — every frame would become a diff against
  an element the hook is mutating anyway — and a channel gives three things
  that matter here: a raw binary path, its own backpressure, and a topic keyed
  to the *session id* rather than to a LiveView process, so a browser reload
  reattaches to the same session instead of re-mounting terminal state.

  ## Auth (§10.4)

  The same rule the rest of the dashboard uses, via `ArbiterWeb.Loopback`:
  a peer on loopback is trusted (the dashboard has no login, and off-LAN
  access is Remote Control's job — §8), anything else must present a signed
  `Arbiter.MCP.Scope` token as the `token` connect param. No new remote-auth
  scheme is designed here, deliberately.

  That includes phase 3's per-session tokens (§9.3), which carry a `session_id`
  claim and stop verifying once the session ends or the token is revoked — so
  revoking a session's credential closes its terminal socket too, not just its
  `/mcp` access.

  ## `caller_session_id`

  A client may declare which session *it* is running inside. That is the input
  to phase 1's self-kill guard (§10.1): a coordinator session driving its own
  terminal in a browser tab must not be able to `kill` itself out from under
  the call. It is a hint from the client and is only ever used to **refuse**
  an action, never to grant one, so a client lying about it can only reduce
  its own privileges.
  """

  use Phoenix.Socket

  alias Arbiter.MCP.Scope
  alias ArbiterWeb.Loopback

  channel "session:*", ArbiterWeb.SessionChannel

  @impl true
  def connect(params, socket, connect_info) do
    if authorized?(params, connect_info) do
      {:ok, assign(socket, :caller_session_id, caller_session_id(params))}
    else
      :error
    end
  end

  @impl true
  def id(_socket), do: nil

  defp authorized?(params, connect_info) do
    Loopback.loopback?(peer_address(connect_info)) or valid_token?(params)
  end

  defp peer_address(%{peer_data: %{address: address}}), do: address
  defp peer_address(_connect_info), do: nil

  defp valid_token?(%{"token" => token}) when is_binary(token) do
    match?({:ok, _scope}, Scope.from_token(String.trim(token)))
  end

  defp valid_token?(_params), do: false

  defp caller_session_id(%{"caller_session_id" => id}) when is_binary(id) and id != "", do: id
  defp caller_session_id(_params), do: nil
end
