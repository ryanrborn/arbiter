defmodule GtElixirWeb.PolecatDetailLive do
  @moduledoc """
  Per-polecat detail view at `/polecats/:bead_id` — shows the full
  snapshot plus the captured output stream (the recent stdout lines
  the polecat collected from its Claude subprocess).

  Subscribes to two PubSub topics so the page updates live:

    * `"polecats"`        — lifecycle events (started / stopped).
    * `"polecat:<bead-id>"` — per-line output events broadcast by the
                              polecat as Claude prints to stdout.
  """

  use GtElixirWeb, :live_view

  alias GtElixir.Polecat
  require Logger

  @polecats_topic "polecats"

  @impl true
  def mount(%{"bead_id" => bead_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GtElixir.PubSub, @polecats_topic)
      Phoenix.PubSub.subscribe(GtElixir.PubSub, output_topic(bead_id))
    end

    {:ok,
     socket
     |> assign(:bead_id, bead_id)
     |> assign(:live, connected?(socket))
     |> refresh_snapshot()}
  end

  @impl true
  def handle_info({:polecat_lifecycle, _event, _snap}, socket) do
    {:noreply, refresh_snapshot(socket)}
  end

  def handle_info({:polecat_output, _bead_id, _line}, socket) do
    # The output line is already in the polecat's meta after this fires;
    # re-read the snapshot to pick up the appended line.
    {:noreply, refresh_snapshot(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ---- data ----

  defp refresh_snapshot(socket) do
    snap =
      case Polecat.whereis(socket.assigns.bead_id) do
        nil ->
          nil

        pid ->
          case safe_state(pid) do
            %{} = s -> Map.put(s, :pid, pid)
            _ -> nil
          end
      end

    assign(socket, :snapshot, snap)
  end

  defp safe_state(pid) do
    Polecat.state(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp output_topic(bead_id), do: "polecat:" <> bead_id

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-7xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">
          Polecat <code>{@bead_id}</code>
        </h1>
        <span
          class={[
            "badge badge-sm",
            if(@live, do: "badge-success", else: "badge-warning")
          ]}
        >
          <%= if @live do %>
            ● live
          <% else %>
            ⚠ stale (refresh)
          <% end %>
        </span>
      </div>

      <%= if @snapshot do %>
        <section class="card bg-base-200 p-4 mb-4">
          <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
            <dt class="font-semibold">Status:</dt>
            <dd>
              <span class={["badge", status_class(@snapshot.status)]}>
                {@snapshot.status}
              </span>
            </dd>
            <dt class="font-semibold">Current step:</dt>
            <dd>{@snapshot.current_step}</dd>
            <dt class="font-semibold">Rig:</dt>
            <dd>{@snapshot.rig}</dd>
            <dt class="font-semibold">Started:</dt>
            <dd>{@snapshot.started_at}</dd>
            <%= if exit_status = Map.get(@snapshot.meta || %{}, :exit_status) do %>
              <dt class="font-semibold">Exit status:</dt>
              <dd>{exit_status}</dd>
            <% end %>
            <%= if result = Map.get(@snapshot.meta || %{}, :result) do %>
              <dt class="font-semibold">Result:</dt>
              <dd>{inspect(result)}</dd>
            <% end %>
            <%= if reason = Map.get(@snapshot.meta || %{}, :failure_reason) do %>
              <dt class="font-semibold">Failure:</dt>
              <dd class="text-error">{inspect(reason)}</dd>
            <% end %>
          </dl>
        </section>

        <section class="card bg-base-200 p-4">
          <h2 class="text-lg font-semibold mb-3">
            Output ({length(output_lines(@snapshot))} lines)
          </h2>
          <%= if output_lines(@snapshot) == [] do %>
            <p class="text-base-content/60 italic">(no output yet)</p>
          <% else %>
            <pre
              id="polecat-output"
              class="bg-base-300 p-3 rounded text-xs overflow-x-auto max-h-96"
            ><%= for line <- output_lines(@snapshot) do %><%= line %>
<% end %></pre>
          <% end %>
        </section>
      <% else %>
        <p class="text-base-content/60">
          No polecat registered for bead <code>{@bead_id}</code>. It may have
          stopped, or the Phoenix node was restarted since it ran.
        </p>
      <% end %>

      <div class="mt-6">
        <.link navigate={~p"/"} class="link link-hover">← Back to dashboard</.link>
      </div>
    </div>
    """
  end

  defp output_lines(snap), do: Map.get(snap.meta || %{}, :output_lines, [])

  defp status_class(:running), do: "badge-info"
  defp status_class(:awaiting), do: "badge-warning"
  defp status_class(:completed), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(_), do: ""
end
