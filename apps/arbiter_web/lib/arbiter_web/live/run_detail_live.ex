defmodule ArbiterWeb.RunDetailLive do
  @moduledoc """
  Detail view for a persisted `Arbiter.Polecats.Run` at
  `/polecats/history/:id` — the post-mortem of a polecat after its GenServer
  is gone. Renders the same output-lines pane as the live polecat detail
  view, but sourced from the persisted Run row rather than a live snapshot.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Beads.Workspace
  alias Arbiter.Polecat
  alias Arbiter.Polecats.Run
  alias Arbiter.Vernacular

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      socket
      |> assign(:run_id, id)
      |> assign(:worker_label, Vernacular.label(:worker))
      |> assign(:issue_label, Vernacular.label(:issue))
      |> assign(:rig_label, Vernacular.label(:rig))
      |> assign(:workspace_label, Vernacular.label(:workspace))
      |> load_run(id)

    {:ok, socket}
  end

  defp load_run(socket, id) do
    case Ash.get(Run, id) do
      {:ok, run} ->
        socket
        |> assign(:run, run)
        |> assign(:workspace, lookup_workspace(run.workspace_id))
        |> assign(:live_polecat?, !is_nil(Polecat.whereis(run.bead_id)))

      _ ->
        socket
        |> assign(:run, nil)
        |> assign(:workspace, nil)
        |> assign(:live_polecat?, false)
    end
  end

  defp lookup_workspace(nil), do: nil

  defp lookup_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="p-6 max-w-7xl mx-auto">
        <%= if @run do %>
          <div class="flex items-center justify-between mb-6">
            <h1 class="text-2xl font-bold">
              {String.capitalize(@worker_label)} run
              <code class="text-base">{@run.bead_id}</code>
            </h1>
            <span class={["badge", run_status_class(@run.status)]}>
              {@run.status}
            </span>
          </div>

          <section class="card bg-base-200 p-4 mb-4">
            <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
              <dt class="font-semibold">{String.capitalize(@issue_label)}:</dt>
              <dd>
                <.link navigate={~p"/beads/#{@run.bead_id}"} class="link link-hover">
                  <code class="text-xs">{@run.bead_id}</code>
                </.link>
                <%= if @run.bead_title do %>
                  <span class="text-base-content/70">— {@run.bead_title}</span>
                <% end %>
              </dd>
              <dt class="font-semibold">{String.capitalize(@rig_label)}:</dt>
              <dd>{@run.rig}</dd>
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
              <dd>{format_dt(@run.started_at)}</dd>
              <%= if @run.completed_at do %>
                <dt class="font-semibold">Completed:</dt>
                <dd>{format_dt(@run.completed_at)}</dd>
                <dt class="font-semibold">Duration:</dt>
                <dd>{humanize_duration(@run.started_at, @run.completed_at)}</dd>
              <% end %>
              <%= if not is_nil(@run.exit_code) do %>
                <dt class="font-semibold">Exit code:</dt>
                <dd>{@run.exit_code}</dd>
              <% end %>
              <%= if @run.failure_reason do %>
                <dt class="font-semibold">Failure:</dt>
                <dd class="text-error">{@run.failure_reason}</dd>
              <% end %>
            </dl>

            <%= if @live_polecat? do %>
              <p class="mt-3 text-sm">
                <.link navigate={~p"/polecats/#{@run.bead_id}"} class="link link-primary">
                  ↗ Live {@worker_label} for this {@issue_label} is still active
                </.link>
              </p>
            <% end %>
          </section>

          <section class="card bg-base-200 p-4">
            <h2 class="text-lg font-semibold mb-3">
              Output ({length(@run.output_lines || [])} lines)
            </h2>
            <%= if (@run.output_lines || []) == [] do %>
              <p class="text-base-content/60 italic">(no captured output)</p>
            <% else %>
              <pre
                id="run-output"
                class="bg-neutral text-neutral-content font-mono p-3 rounded text-xs overflow-x-auto max-h-[28rem] overflow-y-auto"
              >{Enum.join(@run.output_lines, "\n")}</pre>
            <% end %>
          </section>
        <% else %>
          <p class="text-base-content/60">
            No run found for id <code>{@run_id}</code>.
          </p>
        <% end %>

        <div class="mt-6">
          <.link navigate={~p"/"} class="link link-hover">← Back to dashboard</.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp run_status_class(:completed), do: "badge-success"
  defp run_status_class(:failed), do: "badge-error"
  defp run_status_class(:running), do: "badge-info"
  defp run_status_class(_), do: "badge-ghost"

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_dt(_), do: ""

  defp humanize_duration(%DateTime{} = started_at, %DateTime{} = ended_at) do
    started_at |> DateTime.diff(ended_at, :second) |> abs() |> humanize_seconds()
  end

  defp humanize_duration(_, _), do: "—"

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
end
