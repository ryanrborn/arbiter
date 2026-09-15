defmodule ArbiterWeb.Loopback do
  @moduledoc """
  Is this peer on the box? The one predicate behind the dashboard's auth model.

  Arbiter binds directly to `127.0.0.1:4848` with no reverse proxy in front,
  so `conn.remote_ip` / `peer_data.address` is always the real peer and
  `X-Forwarded-For` is never to be trusted. Loopback covers the three shapes a
  same-box peer actually arrives as:

    * IPv4 `127.0.0.0/8`
    * IPv6 `::1`
    * IPv4-mapped IPv6 `::ffff:127.x.x.x`, which is what a dual-stack listener
      reports for an IPv4 client

  Extracted from `ArbiterWeb.Plugs.ApiAuth` when the session socket
  (bd-3ymdvi, RFC §10.4 "loopback only") needed the same rule: a WebSocket
  upgrade has a `peer_data`, not a `Plug.Conn`, and two copies of an
  address-range check is exactly the sort of duplication that drifts.
  """

  import Bitwise

  @typedoc "An `:inet` address tuple, as `Plug.Conn` and `Phoenix.Socket` report it."
  @type address :: :inet.ip_address()

  @doc "Whether `address` is a loopback address."
  @spec loopback?(address() | term()) :: boolean()
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?({0, 0, 0, 0, 0, 0xFFFF, hi, _lo}), do: hi >>> 8 == 127
  def loopback?(_), do: false
end
