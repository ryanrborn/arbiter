defmodule ArbiterWeb.LiveHooks do
  @moduledoc """
  Shared `on_mount` callbacks attached via `live_session` in the router.

  ## `:current_path`

  Stores the request path of the current LiveView on the socket as
  `:current_path`, kept in sync across `live_navigate`/`live_patch` via a
  `handle_params` hook. The `Layouts.app` nav reads it to highlight the
  active link.

  ## `:quota`

  Loads the latest Anthropic quota snapshot for the default workspace and
  assigns it as `:quota` on the socket. Returns `nil` when no snapshot has
  been captured yet.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  def on_mount(:current_path, _params, _session, socket) do
    socket =
      socket
      |> assign(:current_path, nil)
      |> attach_hook(:gt_current_path, :handle_params, fn _params, uri, socket ->
        {:cont, assign(socket, :current_path, URI.parse(uri).path)}
      end)

    {:cont, socket}
  end

  def on_mount(:quota, _params, _session, socket) do
    quota =
      case Arbiter.Quota.default_workspace_id() do
        {:ok, ws_id} -> Arbiter.Quota.latest(ws_id)
        _ -> nil
      end

    {:cont, assign(socket, :quota, quota)}
  end
end
