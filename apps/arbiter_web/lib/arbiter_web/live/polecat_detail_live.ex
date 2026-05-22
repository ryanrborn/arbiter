defmodule ArbiterWeb.PolecatDetailLive do
  @moduledoc """
  Per-polecat detail view at `/polecats/:bead_id`. The richest single
  view of a polecat: snapshot, captured Claude stdout (terminal-style
  with auto-scroll), the paired workflow Machine's step progress, the
  bead's workspace context, and a Stop action.

  Subscribes to:
    * `"polecats"`         — lifecycle events (started / stopped).
    * `"polecat:<bead-id>"` — per-line stdout events.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Polecat
  alias Arbiter.Vernacular
  alias Arbiter.Workflows.MachineState
  require Ash.Query
  require Logger

  @polecats_topic "polecats"

  @impl true
  def mount(%{"bead_id" => bead_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @polecats_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, output_topic(bead_id))
    end

    {:ok,
     socket
     |> assign(:bead_id, bead_id)
     |> assign(:live, connected?(socket))
     |> assign(:flash_message, nil)
     |> assign(:worker_label, Vernacular.label(:worker))
     |> assign(:issue_label, Vernacular.label(:issue))
     |> assign(:rig_label, Vernacular.label(:rig))
     |> assign(:workspace_label, Vernacular.label(:workspace))
     |> refresh_all()}
  end

  @impl true
  def handle_info({:polecat_lifecycle, _event, _snap}, socket) do
    {:noreply, refresh_all(socket)}
  end

  def handle_info({:polecat_output, _bead_id, _line}, socket) do
    {:noreply, refresh_all(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("stop", _params, socket) do
    case Polecat.stop(socket.assigns.bead_id, :normal) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Stopped #{Vernacular.label(:worker)} for #{Vernacular.label(:issue)} #{socket.assigns.bead_id}."
         )
         |> push_navigate(to: ~p"/")}

      {:error, :not_found} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "#{String.capitalize(Vernacular.label(:worker))} not registered (already gone?)."
         )}
    end
  end

  # ---- data ----

  defp refresh_all(socket) do
    socket
    |> refresh_snapshot()
    |> refresh_bead()
    |> refresh_workspace()
    |> refresh_machine_state()
  end

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

  defp refresh_bead(socket) do
    case Ash.get(Issue, socket.assigns.bead_id) do
      {:ok, bead} -> assign(socket, :bead, bead)
      _ -> assign(socket, :bead, nil)
    end
  end

  defp refresh_workspace(%{assigns: %{bead: %Issue{workspace_id: ws_id}}} = socket)
       when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> assign(socket, :workspace, ws)
      _ -> assign(socket, :workspace, nil)
    end
  end

  defp refresh_workspace(socket), do: assign(socket, :workspace, nil)

  defp refresh_machine_state(socket) do
    ms =
      try do
        MachineState
        |> Ash.Query.filter(bead_id == ^socket.assigns.bead_id)
        |> Ash.Query.sort(updated_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!()
        |> List.first()
      rescue
        _ -> nil
      end

    workflow_steps = workflow_steps_for(ms)

    socket
    |> assign(:machine_state, ms)
    |> assign(:workflow_steps, workflow_steps)
  end

  defp workflow_steps_for(nil), do: []

  defp workflow_steps_for(%MachineState{workflow_module: name}) when is_binary(name) do
    try do
      mod = Module.safe_concat([name])

      if function_exported?(mod, :steps, 0) do
        Enum.map(mod.steps(), &Atom.to_string/1)
      else
        []
      end
    rescue
      _ -> []
    end
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
    <Layouts.app flash={@flash} current_path={@current_path}>
    <div class="p-6 max-w-7xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">
          {String.capitalize(@worker_label)} <code>{@bead_id}</code>
        </h1>
        <span class={[
          "badge badge-sm",
          if(@live, do: "badge-success", else: "badge-warning")
        ]}>
          <%= if @live do %>
            ● live
          <% else %>
            ⚠ stale (refresh)
          <% end %>
        </span>
      </div>

      <%= if @snapshot do %>
        <section class="card bg-base-200 p-4 mb-4">
          <div class="flex justify-between items-start">
            <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
              <dt class="font-semibold">Status:</dt>
              <dd>
                <span class={["badge", status_class(@snapshot.status)]}>
                  {@snapshot.status}
                </span>
              </dd>
              <dt class="font-semibold">Current step:</dt>
              <dd>{@snapshot.current_step}</dd>
              <dt class="font-semibold">{String.capitalize(@rig_label)}:</dt>
              <dd>{@snapshot.rig}</dd>
              <dt class="font-semibold">{String.capitalize(@workspace_label)}:</dt>
              <dd>
                <%= if @workspace do %>
                  {@workspace.name}
                  <span class="text-base-content/60">
                    (<code>{@workspace.prefix}</code>)
                  </span>
                <% else %>
                  <span class="text-base-content/60">(none)</span>
                <% end %>
              </dd>
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

            <div class="flex flex-col gap-2">
              <.link navigate={~p"/beads/#{@bead_id}"} class="btn btn-sm btn-ghost">
                ↗ {String.capitalize(@issue_label)} detail
              </.link>
              <%= if @snapshot.status in [:idle, :running, :awaiting] do %>
                <button
                  phx-click="stop"
                  data-confirm={"Stop #{@worker_label} for #{@bead_id}? Any active Claude subprocess will be terminated."}
                  class="btn btn-sm btn-error"
                >
                  Stop {@worker_label}
                </button>
              <% end %>
            </div>
          </div>
        </section>

        <%= if @machine_state do %>
          <section class="card bg-base-200 p-4 mb-4">
            <h2 class="text-lg font-semibold mb-2">
              Workflow:
              <code class="text-sm">{short_module(@machine_state.workflow_module)}</code>
            </h2>
            <div class="flex flex-wrap gap-1">
              <%= for step <- @workflow_steps do %>
                <span class={["badge", step_class(step, @machine_state)]}>
                  {step}
                </span>
              <% end %>
            </div>
            <p class="text-xs text-base-content/60 mt-2">
              Machine status: <strong>{@machine_state.status}</strong> · current step:
              <code>{@machine_state.current_step}</code>
            </p>
          </section>
        <% end %>

        <section class="card bg-base-200 p-4">
          <h2 class="text-lg font-semibold mb-3">
            Output ({length(output_lines(@snapshot))} lines)
          </h2>
          <%= if output_lines(@snapshot) == [] do %>
            <p class="text-base-content/60 italic">(no output yet)</p>
          <% else %>
            <pre
              id="polecat-output"
              phx-hook="ScrollToBottom"
              phx-update="ignore"
              class="bg-neutral text-neutral-content font-mono p-3 rounded text-xs overflow-x-auto max-h-[28rem] overflow-y-auto"
            >{Enum.join(output_lines(@snapshot), "\n")}</pre>
            <script
              :type={Phoenix.LiveView.ColocatedHook}
              name=".ScrollToBottom"
            >
              export default {
                mounted() { this.el.scrollTop = this.el.scrollHeight; },
                updated() { this.el.scrollTop = this.el.scrollHeight; }
              }
            </script>
          <% end %>
        </section>
      <% else %>
        <p class="text-base-content/60">
          No {@worker_label} registered for {@issue_label} <code>{@bead_id}</code>. It may have
          stopped, or the Phoenix node was restarted since it ran.
        </p>
      <% end %>

      <div class="mt-6">
        <.link navigate={~p"/"} class="link link-hover">← Back to dashboard</.link>
      </div>
    </div>
    </Layouts.app>
    """
  end

  defp output_lines(snap), do: Map.get(snap.meta || %{}, :output_lines, [])

  defp status_class(:running), do: "badge-info"
  defp status_class(:awaiting), do: "badge-warning"
  defp status_class(:completed), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(_), do: ""

  # Color a workflow step based on whether it's done, current, or upcoming.
  defp step_class(step, %MachineState{completed_steps: completed, current_step: current}) do
    cond do
      step in (completed || []) -> "badge-success"
      step == current -> "badge-info"
      true -> "badge-ghost"
    end
  end

  defp step_class(_, _), do: "badge-ghost"

  defp short_module(name) when is_binary(name) do
    case String.split(name, ".") do
      [] -> name
      parts -> Enum.take(parts, -2) |> Enum.join(".")
    end
  end

  defp short_module(_), do: ""
end
