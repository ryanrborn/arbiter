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
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  require Logger

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
    case Arbiter.Quota.default_workspace_id() do
      {:ok, ws_id} ->
        quota = Arbiter.Quota.latest(ws_id)

        socket =
          socket
          |> assign(:quota, quota)
          |> assign(:_quota_workspace_id, ws_id)
          |> maybe_subscribe_quota(ws_id)

        {:cont, socket}

      _ ->
        {:cont, assign(socket, :quota, nil)}
    end
  end

  defp maybe_subscribe_quota(socket, workspace_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, "quota:#{workspace_id}")
      attach_hook(socket, :quota_updates, :handle_info, fn msg, socket ->
        case msg do
          {:quota_updated, ^workspace_id, quota} ->
            {:halt, assign(socket, :quota, quota)}

          _ ->
            {:cont, socket}
        end
      end)
    else
      socket
    end
  end
end
