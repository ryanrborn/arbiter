defmodule ArbiterWeb.LiveHooks do
  @moduledoc """
  Shared `on_mount` callbacks attached via `live_session` in the router.

  ## `:current_path`

  Stores the request path of the current LiveView on the socket as
  `:current_path`, kept in sync across `live_navigate`/`live_patch` via a
  `handle_params` hook. The `Layouts.app` nav reads it to highlight the
  active link.

  ## `:quota`

  Loads the latest quota snapshot for every tracked provider on the default
  workspace and assigns the list as `:quotas` on the socket (`[]` when
  nothing has been captured yet).
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
        quotas = Arbiter.Quota.list_latest(ws_id)

        socket =
          socket
          |> assign(:quotas, quotas)
          |> assign(:_quota_workspace_id, ws_id)
          |> maybe_subscribe_quota(ws_id)

        {:cont, socket}

      _ ->
        {:cont, assign(socket, :quotas, [])}
    end
  end

  defp maybe_subscribe_quota(socket, workspace_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, "quota:#{workspace_id}")

      attach_hook(socket, :quota_updates, :handle_info, fn msg, socket ->
        case msg do
          {:quota_updated, ^workspace_id, quota} ->
            {:halt, assign(socket, :quotas, upsert_quota(socket.assigns.quotas, quota))}

          _ ->
            {:cont, socket}
        end
      end)
    else
      socket
    end
  end

  # Replace the list entry matching `quota.provider`, or append it when this
  # is the first snapshot seen for that provider.
  defp upsert_quota(quotas, quota) do
    if Enum.any?(quotas, &(&1.provider == quota.provider)) do
      Enum.map(quotas, fn
        %{provider: provider} = existing when provider == quota.provider ->
          preserve_cost(existing, quota)

        existing ->
          existing
      end)
    else
      quotas ++ [quota]
    end
  end

  # Live broadcast views don't carry `cost_usd` (it's a read-path add-on from the
  # usage ledger, not part of the per-provider fetch), so a naive replace would
  # blank the figure on every tick. Keep the last known cost when the incoming
  # update omits it (bd-ajh7bd).
  defp preserve_cost(existing, %{cost_usd: nil} = incoming),
    do: %{incoming | cost_usd: Map.get(existing, :cost_usd)}

  defp preserve_cost(_existing, incoming), do: incoming
end
