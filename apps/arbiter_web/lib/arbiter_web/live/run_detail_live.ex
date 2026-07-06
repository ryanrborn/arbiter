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
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <%= if @run do %>
          <%!-- ── Header ─────────────────────────────────────────────── --%>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div class="min-w-0">
              <div class="flex items-center gap-2 text-xs text-base-content/50">
                <.link navigate={~p"/"} class="link link-hover">Dashboard</.link>
                <.icon name="hero-chevron-right" class="size-3" />
                <span>{String.capitalize(@worker_label)} run history</span>
              </div>
              <h1 class="text-2xl font-bold tracking-tight flex items-center gap-2 mt-0.5">
                {String.capitalize(@worker_label)} run
                <code class="text-base font-mono text-base-content/80">{@run.task_id}</code>
              </h1>
            </div>

            <div class="flex items-center gap-2">
              <span
                class="badge badge-ghost gap-1.5"
                title="This is a persisted post-mortem, not a live view"
              >
                <.icon name="hero-archive-box" class="size-4" /> Historical
              </span>
              <span class={["badge gap-1", run_status_class(@run.status)]}>
                {@run.status}
              </span>
            </div>
          </div>

          <%!-- ── Post-mortem banner ─────────────────────────────────── --%>
          <div class="rounded-box bg-base-300/40 border border-base-300 px-4 py-2.5 flex items-center gap-2 text-sm text-base-content/70">
            <.icon name="hero-clock" class="size-4 shrink-0" />
            <span>
              Post-mortem of a completed run, reconstructed from the persisted record. This page does not update live.
            </span>
          </div>

          <%!-- ── Status / duration / timestamps stat row ────────────── --%>
          <div class="stats stats-vertical sm:stats-horizontal w-full shadow bg-base-200 border border-base-300">
            <div class="stat">
              <div class="stat-figure">
                <.icon name="hero-flag" class="size-7 text-base-content/50" />
              </div>
              <div class="stat-title">Final status</div>
              <div class="stat-value text-2xl">
                <span class={["badge badge-lg", run_status_class(@run.status)]}>{@run.status}</span>
              </div>
              <div class="stat-desc">
                <%= if not is_nil(@run.exit_code) do %>
                  exit code {@run.exit_code}
                <% else %>
                  no exit code recorded
                <% end %>
              </div>
            </div>

            <div class="stat">
              <div class="stat-figure">
                <.icon name="hero-clock" class="size-7 text-base-content/50" />
              </div>
              <div class="stat-title">Duration</div>
              <div class="stat-value text-2xl font-mono tabular-nums">
                {humanize_duration(@run.started_at, @run.completed_at)}
              </div>
              <div class="stat-desc">wall-clock runtime</div>
            </div>

            <div class="stat">
              <div class="stat-figure">
                <.icon name="hero-calendar" class="size-7 text-base-content/50" />
              </div>
              <div class="stat-title">Started</div>
              <div class="stat-value text-base font-mono tabular-nums">
                {format_dt(@run.started_at)}
              </div>
              <div class="stat-desc">
                <%= if @run.completed_at do %>
                  ended {format_dt(@run.completed_at)}
                <% else %>
                  not yet completed
                <% end %>
              </div>
            </div>
          </div>

          <%!-- ── Run detail ─────────────────────────────────────────── --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-2 text-sm">
                <dt class="font-medium text-base-content/60">{String.capitalize(@issue_label)}:</dt>
                <dd>
                  <.link navigate={~p"/tasks/#{@run.task_id}"} class="link link-hover">
                    <code class="font-mono text-xs">{@run.task_id}</code>
                  </.link>
                  <span :if={@run.task_title} class="text-base-content/70">— {@run.task_title}</span>
                </dd>
                <dt class="font-medium text-base-content/60">{String.capitalize(@repo_label)}:</dt>
                <dd><code class="font-mono text-xs">{@run.repo}</code></dd>
                <dt class="font-medium text-base-content/60">Type:</dt>
                <dd><span class="badge badge-sm badge-ghost">{@run.worker_type}</span></dd>
                <%= if @run.model do %>
                  <dt class="font-medium text-base-content/60">Model:</dt>
                  <dd><code class="font-mono text-xs">{@run.model}</code></dd>
                <% end %>
                <dt class="font-medium text-base-content/60">
                  {String.capitalize(@workspace_label)}:
                </dt>
                <dd>
                  <%= if @workspace do %>
                    {@workspace.name}
                    <span class="text-base-content/50">
                      (<code class="font-mono text-xs">{@workspace.prefix}</code>)
                    </span>
                  <% else %>
                    <span class="text-base-content/50">(none)</span>
                  <% end %>
                </dd>
                <%= if @run.failure_reason do %>
                  <dt class="font-medium text-base-content/60">Failure:</dt>
                  <dd class="text-error font-mono text-xs">{@run.failure_reason}</dd>
                <% end %>
              </dl>

              <div :if={@live_worker?} class="rounded-box bg-info/10 border border-info/30 p-3">
                <.link
                  navigate={~p"/workers/#{@run.task_id}"}
                  class="link link-primary text-sm flex items-center gap-1.5 w-fit"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                  Live {@worker_label} for this {@issue_label} is still active
                </.link>
              </div>
            </div>
          </section>

          <%!-- ── Captured output terminal (static) ──────────────────── --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm overflow-hidden">
            <div class="card-body p-0 gap-0">
              <div class="flex items-center justify-between gap-2 px-4 py-2.5 border-b border-base-300">
                <h2 class="text-sm font-medium flex items-center gap-2">
                  <.icon name="hero-command-line" class="size-4 text-base-content/70" />
                  Captured output
                  <span class="badge badge-ghost badge-sm font-mono tabular-nums">
                    {length(@run.output_lines || [])} lines
                  </span>
                </h2>
                <span class="badge badge-ghost badge-sm gap-1">
                  <.icon name="hero-archive-box" class="size-3" /> archived
                </span>
              </div>

              <%= if (@run.output_lines || []) == [] do %>
                <div class="bg-neutral text-neutral-content/50 font-mono text-xs p-6 text-center italic">
                  (no captured output)
                </div>
              <% else %>
                <div
                  id="run-output"
                  class="bg-neutral text-neutral-content font-mono text-xs overflow-x-auto max-h-[28rem] overflow-y-auto"
                >
                  <div
                    :for={{line, idx} <- Enum.with_index(@run.output_lines, 1)}
                    class="flex hover:bg-neutral-content/5 transition-colors"
                  >
                    <span class="select-none shrink-0 w-12 text-right pr-3 py-0.5 text-neutral-content/30 tabular-nums border-r border-neutral-content/10">
                      {idx}
                    </span>
                    <code class="flex-1 whitespace-pre-wrap break-all px-3 py-0.5">{line}</code>
                  </div>
                </div>
              <% end %>
            </div>
          </section>
        <% else %>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-8 items-center text-center gap-2">
              <.icon name="hero-archive-box-x-mark" class="size-10 text-base-content/30" />
              <p class="text-sm text-base-content/70">
                No run found for id <code class="font-mono">{@run_id}</code>.
              </p>
            </div>
          </section>
        <% end %>

        <div>
          <.link navigate={~p"/"} class="link link-hover text-sm flex items-center gap-1 w-fit">
            <.icon name="hero-arrow-left" class="size-4" /> Back to dashboard
          </.link>
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
