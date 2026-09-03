defmodule ArbiterWeb.LiveHooks do
  @moduledoc """
  Shared `on_mount` callbacks attached via `live_session` in the router.

  ## `:current_path`

  Stores the request path of the current LiveView on the socket as
  `:current_path`, kept in sync across `live_navigate`/`live_patch` via a
  `handle_params` hook. The `Layouts.app` nav reads it to highlight the
  active link.

  ## `:live`

  Assigns `:live` on the socket as `connected?(socket)` — `false` on the
  initial dead render, `true` once the LiveView process is connected over
  the socket. `Layouts.app`'s navbar badge (and every page-level
  `live_badge`) reads this assign; `live_badge/1`'s `live` attr is
  `required: true` precisely so no call site can fall back to a client-only
  mechanism instead. The DOM-only join-direction mechanism `live_badge/1`
  used to default to (`phx-connected` flipping "stale" to "Live" with no
  server assign) was the root cause of bd-akygjy — see the "Root cause"
  note on `ArbiterWeb.CoreComponents.Feedback.live_badge/1` for what was
  and wasn't established about why. This hook is the single source of
  truth every call site must be fed from.

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

  ## `:coordinator_inbox`

  Lifted off `BoardLive` (bd-3kgb0e) so the coordinator's mailbox — the
  upward channel of `arb inbox` / `arb msg` — surfaces from the AppShell
  drawer on every screen instead of only the board. Subscribes to every
  workspace's message topic and assigns `:coordinator_inbox` (unread) and
  `:coordinator_outstanding_count` (seen but not cleared) same as the old
  `BoardLive.refresh_coordinator_inbox/1`. Also owns the drawer's two
  actions (`coordinator_mark_read`, `coordinator_clear`) via a
  `:handle_event` hook, so no LiveView needs its own clauses for them —
  distinct event names from `WorkerDetailLive`'s own `"mark_read"` (a
  different, per-worker mailbox) avoid a collision.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Arbiter.Messages.Message

  require Logger

  # Providers hidden from the UI pending fix; see module docstring for context.
  @hidden_providers ["codex", "gemini_cli", "antigravity"]

  @coordinator_ref Message.coordinator_ref()

  def on_mount(:current_path, _params, _session, socket) do
    socket =
      socket
      |> assign(:current_path, nil)
      |> attach_hook(:gt_current_path, :handle_params, fn _params, uri, socket ->
        {:cont, assign(socket, :current_path, URI.parse(uri).path)}
      end)

    {:cont, socket}
  end

  def on_mount(:live, _params, _session, socket) do
    {:cont, assign(socket, :live, connected?(socket))}
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

  def on_mount(:coordinator_inbox, _params, _session, socket) do
    socket =
      socket
      |> assign(:coordinator_inbox_now, DateTime.utc_now())
      |> refresh_coordinator_inbox()
      |> maybe_subscribe_coordinator_inbox()
      |> maybe_tick_coordinator_inbox_now()
      |> attach_hook(:coordinator_inbox_events, :handle_event, fn
        "coordinator_mark_read", %{"id" => id}, socket ->
          with {:ok, msg} <- Ash.get(Message, id),
               {:ok, _} <- Message.mark_read(msg) do
            {:halt, refresh_coordinator_inbox(socket)}
          else
            _ -> {:halt, refresh_coordinator_inbox(socket)}
          end

        "coordinator_clear", _params, socket ->
          _ = Message.clear_read(@coordinator_ref)
          {:halt, refresh_coordinator_inbox(socket)}

        _event, _params, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  # Independent of any host LiveView's own :tick — the drawer is global chrome,
  # so its "N ago" timestamps need to advance even on pages with no clock of
  # their own. A per-minute cadence is plenty for coarse relative labels.
  defp maybe_tick_coordinator_inbox_now(socket) do
    if connected?(socket) do
      :timer.send_interval(60_000, self(), :coordinator_inbox_tick)

      attach_hook(socket, :coordinator_inbox_tick, :handle_info, fn
        :coordinator_inbox_tick, socket ->
          {:halt, assign(socket, :coordinator_inbox_now, DateTime.utc_now())}

        _msg, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  defp maybe_subscribe_coordinator_inbox(socket) do
    if connected?(socket) do
      workspaces =
        try do
          Arbiter.Tasks.Workspace |> Ash.read!()
        rescue
          _ -> []
        end

      for ws <- workspaces, do: Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(ws.id))

      attach_hook(socket, :coordinator_inbox_updates, :handle_info, fn
        {:new_message, _message}, socket -> {:cont, refresh_coordinator_inbox(socket)}
        {:message_read, _message}, socket -> {:cont, refresh_coordinator_inbox(socket)}
        {:mailbox_cleared, _workspace_id}, socket -> {:cont, refresh_coordinator_inbox(socket)}
        _msg, socket -> {:cont, socket}
      end)
    else
      socket
    end
  end

  # Two figures, not one: pending (unread — never seen) and outstanding (seen
  # but not cleared — still owes an action). Reading no longer empties the
  # queue, so "still open" needs its own number.
  defp refresh_coordinator_inbox(socket) do
    {inbox, outstanding} =
      try do
        {Message.inbox(@coordinator_ref), Message.outstanding(@coordinator_ref)}
      rescue
        _ -> {[], []}
      end

    socket
    |> assign(:coordinator_inbox, inbox)
    |> assign(:coordinator_outstanding_count, length(outstanding))
  end

  defp maybe_subscribe_quota(socket, workspace_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, "quota:#{workspace_id}")

      attach_hook(socket, :quota_updates, :handle_info, fn msg, socket ->
        case msg do
          {:quota_updated, ^workspace_id, quota} ->
            # Skip updates for hidden providers to prevent re-introduction via PubSub
            # Pre-existing nesting 4 — baselined when bd-4x2yhq first
            # wired Credo up. Thresholds stay at the tool's own default so new
            # code is held to it; see the note in .credo.exs.
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
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
