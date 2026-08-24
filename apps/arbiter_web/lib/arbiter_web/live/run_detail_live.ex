defmodule ArbiterWeb.RunDetailLive do
  @moduledoc """
  Detail view for a persisted `Arbiter.Workers.Run` at
  `/workers/history/:id` — the post-mortem of a worker after its GenServer
  is gone. Renders the same output-lines pane as the live worker detail
  view, but sourced from the persisted Run row rather than a live snapshot.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Workers.Run
  alias ArbiterWeb.CoreComponents.Domain

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      socket
      |> assign(:run_id, id)
      |> assign(:worker_label, "worker")
      |> assign(:issue_label, "issue")
      |> assign(:repo_label, "repo")
      |> assign(:workspace_label, "workspace")
      |> load_run(id)

    {:ok, socket}
  end

  defp load_run(socket, id) do
    case Ash.get(Run, id) do
      {:ok, run} ->
        socket
        |> assign(:run, run)
        |> assign(:workspace, lookup_workspace(run.workspace_id))
        |> assign(:live_worker?, !is_nil(Worker.whereis(run.task_id)))

      _ ->
        socket
        |> assign(:run, nil)
        |> assign(:workspace, nil)
        |> assign(:live_worker?, false)
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
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas} live={@live}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <%= if @run do %>
          <%!-- ── Header ─────────────────────────────────────────────── --%>
          <div class="flex flex-col gap-6">
            <div class="flex flex-wrap items-center justify-between gap-4">
              <div class="min-w-0">
                <div class="flex items-center gap-2 text-[10.5px] text-[var(--text-label)]">
                  <.link
                    navigate={~p"/"}
                    class="text-[var(--text-link)] hover:text-[var(--text-title)] transition-colors"
                  >
                    Dashboard
                  </.link>
                  <ArbiterWeb.CoreComponents.Core.icon name="hero-chevron-right" size={12} />
                  <span>{cap_plural(@worker_label)} history</span>
                </div>
                <h1 class="text-[24px] font-semibold leading-[1.2] tracking-[var(--tracking-section)] text-[var(--text-title)] flex items-center gap-2 mt-1.5">
                  {cap_plural(@worker_label)} run
                  <code class="font-[family-name:var(--font-mono)] text-[16px] font-normal text-[var(--text-secondary)]">
                    {@run.task_id}
                  </code>
                </h1>
              </div>

              <div class="flex items-center gap-2 flex-none">
                <span
                  class="text-[10.5px] px-1.5 py-px rounded-[var(--radius-field)] bg-[var(--arb-panel)] text-[var(--text-secondary)] font-medium"
                  title="This is a persisted post-mortem, not a live view"
                >
                  <ArbiterWeb.CoreComponents.Core.icon
                    name="hero-archive-box"
                    size={12}
                    class="inline mr-1"
                  /> Historical
                </span>
                <span class={[
                  "text-[10.5px] px-1.5 py-px rounded-[var(--radius-field)] font-medium",
                  run_status_badge_class(@run.status)
                ]}>
                  {format_status(@run.status)}
                </span>
              </div>
            </div>

            <%!-- ── Run metadata ────────────────────────────────────── --%>
            <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-4">
              <div class="flex flex-col gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--arb-panel-alt)]">
                <span class="text-[10.5px] text-[var(--text-label)] font-medium font-[family-name:var(--font-mono)]">
                  DURATION
                </span>
                <span class="text-[14px] font-semibold text-[var(--text-title)] font-[family-name:var(--font-mono)]">
                  {humanize_duration(@run.started_at, @run.completed_at)}
                </span>
                <span class="text-[10px] text-[var(--text-secondary)]">wall-clock runtime</span>
              </div>

              <div class="flex flex-col gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--arb-panel-alt)]">
                <span class="text-[10.5px] text-[var(--text-label)] font-medium font-[family-name:var(--font-mono)]">
                  STARTED
                </span>
                <span class="text-[12px] font-medium text-[var(--text-title)] font-[family-name:var(--font-mono)]">
                  {format_dt(@run.started_at)}
                </span>
                <span class="text-[10px] text-[var(--text-secondary)]">
                  <%= if @run.completed_at do %>
                    ended {format_dt(@run.completed_at)}
                  <% else %>
                    not yet completed
                  <% end %>
                </span>
              </div>

              <div class="flex flex-col gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--arb-panel-alt)]">
                <span class="text-[10.5px] text-[var(--text-label)] font-medium font-[family-name:var(--font-mono)]">
                  TYPE
                </span>
                <span class="text-[12px] font-medium text-[var(--text-title)] font-[family-name:var(--font-mono)] truncate">
                  {@run.worker_type}
                </span>
                <span class="text-[10px] text-[var(--text-secondary)]">
                  <%= if @run.model do %>
                    {@run.model}
                  <% else %>
                    no model recorded
                  <% end %>
                </span>
              </div>
            </div>

            <%!-- ── Live worker link ────────────────────────────────── --%>
            <div
              :if={@live_worker?}
              class="rounded-[var(--radius-field)] bg-[color-mix(in_oklch,var(--arb-live)_10%,transparent)] border border-[color-mix(in_oklch,var(--arb-live)_30%,transparent)] p-3"
            >
              <.link
                navigate={~p"/workers/#{@run.task_id}"}
                class="text-[12px] font-medium text-[var(--arb-live)] hover:text-[var(--text-title)] transition-colors flex items-center gap-1.5 w-fit"
              >
                <ArbiterWeb.CoreComponents.Core.icon name="hero-arrow-top-right-on-square" size={12} />
                Live {@worker_label} for this {@issue_label} is still active
              </.link>
            </div>
          </div>

          <%!-- ── Captured output log stream ──────────────────────────── --%>
          <Domain.log_stream
            id="run-transcript"
            live={false}
            lines={build_log_lines(@run.output_lines || [])}
            max_height="28rem"
          />
        <% else %>
          <ArbiterWeb.CoreComponents.Core.panel>
            <div class="flex flex-col items-center justify-center gap-3 py-12">
              <ArbiterWeb.CoreComponents.Core.icon
                name="hero-archive-box-x-mark"
                size={32}
                color="var(--text-label)"
              />
              <p class="text-[12px] text-[var(--text-secondary)]">
                No run found for id <code class="font-mono">{@run_id}</code>.
              </p>
            </div>
          </ArbiterWeb.CoreComponents.Core.panel>
        <% end %>

        <div>
          <.link
            navigate={~p"/"}
            class="text-[12px] font-medium text-[var(--text-link)] hover:text-[var(--text-title)] transition-colors flex items-center gap-1.5 w-fit"
          >
            <ArbiterWeb.CoreComponents.Core.icon name="hero-arrow-left" size={14} /> Back to dashboard
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp run_status_badge_class(:completed),
    do: "bg-[color-mix(in_oklch,var(--arb-done)_20%,transparent)] text-[var(--arb-done)]"

  defp run_status_badge_class(:failed),
    do: "bg-[color-mix(in_oklch,var(--arb-fail)_20%,transparent)] text-[var(--arb-fail-text)]"

  defp run_status_badge_class(:running),
    do: "bg-[color-mix(in_oklch,var(--arb-live)_20%,transparent)] text-[var(--arb-live)]"

  defp run_status_badge_class(_), do: "bg-[var(--arb-panel)] text-[var(--text-secondary)]"

  defp format_status(:completed), do: "Completed"
  defp format_status(:failed), do: "Failed"
  defp format_status(:running), do: "Running"
  defp format_status(status), do: String.capitalize(to_string(status))

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_dt(_), do: ""

  defp humanize_duration(%DateTime{} = started_at, %DateTime{} = ended_at) do
    started_at |> DateTime.diff(ended_at, :second) |> abs() |> humanize_seconds()
  end

  defp humanize_duration(_, _), do: "—"

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp build_log_lines(output_lines) do
    output_lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, idx} ->
      %{
        time: format_line_time(idx),
        role: "output",
        text: line
      }
    end)
  end

  defp format_line_time(idx) do
    idx
    |> Integer.to_string()
    |> String.pad_leading(5, "0")
  end
end
