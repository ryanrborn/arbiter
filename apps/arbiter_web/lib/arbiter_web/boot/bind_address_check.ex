defmodule ArbiterWeb.Boot.BindAddressCheck do
  @moduledoc """
  Boot-time check: is the HTTP listener bound off-loopback?

  The dashboard's auth model is "a loopback peer is trusted; there is no
  login" (`ArbiterWeb.Loopback`). Binding anywhere else — `ARB_BIND_ADDRESS`
  set to something other than loopback — hands every unauthenticated
  LiveView page to anyone who can reach the port. The worker-session
  terminal is the exception: it stays loopback-gated regardless of the bind
  address, so off-loopback peers get no terminal. That's sometimes an
  intentional choice (a VPN-reachable install), so this only warns; it
  never blocks boot.
  """

  require Logger

  alias ArbiterWeb.Loopback

  @doc "Log a WARNING if `ip` is not a loopback address. No-op otherwise."
  @spec warn_if_off_loopback(Loopback.address()) :: :ok
  def warn_if_off_loopback(ip) do
    unless Loopback.loopback?(ip) do
      Logger.warning(
        "WARNING: Arbiter is bound to #{format(ip)}, not loopback. " <>
          "The dashboard has no login — every unauthenticated LiveView page " <>
          "is reachable by anyone who can reach this address. The " <>
          "worker-session terminal is the exception: it stays loopback-only, " <>
          "so off-loopback peers get no terminal. This is controlled by " <>
          "ARB_BIND_ADDRESS. If this isn't intentional, unset it (or set it to " <>
          "127.0.0.1) and use SSH port-forwarding for remote access instead " <>
          "(`ssh -L 4848:127.0.0.1:4848 <host>`)."
      )
    end

    :ok
  end

  defp format(ip), do: ip |> :inet.ntoa() |> to_string()
end
