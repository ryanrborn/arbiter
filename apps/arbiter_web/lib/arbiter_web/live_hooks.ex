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

  **Temporary:** These providers are filtered from the quota list pending fixes:
  - Codex: dispatch is broken (bd-1nyedk, bd-dcvo3n, bd-bi5t54). Showing quota
    bars for a broken provider implies it's dispatchable when it isn't. Once
    dispatch is fixed, remove the filter.
  - Gemini CLI: deprecated and has no reconnect path; reports "project id not
    available; reconnect" (bd-5r6cdy).
  - Antigravity: quota is only checkable while app is actively open and recently
    refreshed; token stales ~1h after app closes (bd-5r6cdy).

  Once these are fixed, remove them from @hidden_providers and this comment.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  require Logger

  # Providers hidden from the UI pending fix; see module docstring for context.
  @hidden_providers ["codex", "gemini_cli", "antigravity"]

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
        quotas = Arbiter.Quota.list_latest(ws_id) |> filter_hidden_providers()

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
            # Skip updates for hidden providers to prevent re-introduction via PubSub
            if quota.provider in @hidden_providers do
              {:halt, socket}
            else
              {:halt, assign(socket, :quotas, upsert_quota(socket.assigns.quotas, quota))}
            end

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

  # Filter out providers marked as hidden from the UI.
  defp filter_hidden_providers(quotas) do
    Enum.reject(quotas, &(&1.provider in @hidden_providers))
  end
end
