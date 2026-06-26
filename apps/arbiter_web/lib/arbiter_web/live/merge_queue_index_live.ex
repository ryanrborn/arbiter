defmodule ArbiterWeb.MergeQueueIndexLive do
  @moduledoc """
  Index of every merge-queue entry at `/merge_queue` — the "See all" target for
  the dashboard's merge-queue section.

  An entry is a worker parked at `:awaiting_review`: an open MR integrating
  via `Arbiter.Mergers` (Direct/GitLab/GitHub), with the Watchdog's last poll
  result. Sourced live from `Worker.list_children/0`, paged in memory,
  ordered longest-waiting first. Each entry links to the worker detail page
  — the worker IS the merge-queue entry, so its detail page is the entry's
  detail page. Re-renders on `:worker_lifecycle` events and a 1s tick.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Workflows.MergeQueueSupervisor
  alias ArbiterWeb.Paging

  @workers_topic "workers"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
      :timer.send_interval(1000, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:live, connected?(socket))
     |> assign(:now, DateTime.utc_now())
     |> assign(:merge_queue_label, "merge queue")
     |> assign(:pr_label, "pull request")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page, Paging.parse_page(params))
     |> refresh()}
  end

  @impl true
  def handle_info({:worker_lifecycle, _event, _snap}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    workspaces_by_id = index_workspaces()

    entries =
      list_children()
      |> Enum.filter(&(&1.status == :awaiting_review))
      |> Enum.map(fn p ->
        meta = p.meta || %{}

        %{
          task_id: p.task_id,
          workspace_name: workspace_name(workspaces_by_id, p.workspace_id),
          merger_type: merger_type(workspaces_by_id, p.workspace_id),
          mr_ref: p.mr_ref,
          merger_url: p.merger_url,
          merger_status: Map.get(meta, :last_merger_status),
          last_checked_at: Map.get(meta, :last_checked_at),
          since: p.step_started_at || p.started_at
        }
      end)
      |> Enum.sort_by(& &1.since, {:asc, DateTime})

    result = Paging.paginate_list(entries, socket.assigns.page)

    socket
    |> assign(:entries, result.entries)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
    |> assign(:crucible, crucible_entries(workspaces_by_id))
  end

  # The live, serialized, base-aware queue (#354, Phase 3): each running
  # workspace MergeQueue's items, in merge-admission order. Distinct from the
  # worker-based `entries` above (which list awaiting-review workers) — this is
  # the Refinery's own view of the queue it is integrating one PR at a time.
  # Best-effort: a failure to reach the queues yields an empty section.
  defp crucible_entries(workspaces_by_id) do
    MergeQueueSupervisor.queue_views()
    |> Enum.flat_map(fn {ws_id, items} ->
      name = workspace_name(workspaces_by_id, ws_id)
      Enum.map(items, &Map.put(&1, :workspace_name, name))
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp list_children do
    Worker.list_children()
  rescue
    _ -> []
  end

  defp index_workspaces do
    Ash.read!(Workspace) |> Map.new(fn ws -> {ws.id, ws} end)
  rescue
    _ -> %{}
  end

  defp workspace_name(_by_id, nil), do: "(none)"

  defp workspace_name(by_id, ws_id) do
    case Map.fetch(by_id, ws_id) do
      {:ok, ws} -> ws.name
      :error -> "(unknown)"
    end
  end

  defp merger_type(_by_id, nil), do: :direct

  defp merger_type(by_id, ws_id) do
    case Map.fetch(by_id, ws_id) do
      {:ok, ws} -> Workspace.merger_strategy(ws)
      :error -> :direct
    end
  rescue
    _ -> :direct
  end

  defp merge_queue_path(page), do: ~p"/merge_queue?#{%{page: page}}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quota={@quota}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <.index_header
            icon="hero-arrow-path-rounded-square"
            title={cap_plural(@merge_queue_label)}
            count={@total_count}
            subtitle={"Every #{@pr_label} integrating now, longest-waiting first."}
          />
          <.live_badge live={@live} />
        </div>

        <section
          :if={@crucible != []}
          id="crucible"
          class="card bg-base-200 border border-base-300 shadow-sm"
        >
          <div class="card-body p-4 gap-3">
            <div class="flex items-center gap-2">
              <.icon name="hero-fire" class="size-4 text-warning" />
              <h2 class="text-sm font-semibold tracking-tight">
                Crucible · serialized merge order
              </h2>
              <span class="badge badge-sm badge-ghost">{length(@crucible)}</span>
            </div>
            <p class="text-xs text-base-content/60 -mt-1">
              Approved {plural(@pr_label)} are kept rebased on the moving base and merged one at a
              time, front of queue first.
            </p>

            <ul id="crucible-list" class="flex flex-col gap-2">
              <li
                :for={c <- @crucible}
                class="rounded-box bg-base-100 border border-base-300 p-2.5 flex items-center justify-between gap-2"
              >
                <div class="flex items-center gap-2 min-w-0">
                  <span
                    class="badge badge-sm badge-neutral font-mono tabular-nums shrink-0"
                    title="Queue position"
                  >
                    {"##{c.position}"}
                  </span>
                  <.link navigate={~p"/workers/#{c.task_id}"} class="min-w-0 group">
                    <code class="text-xs font-semibold group-hover:text-primary transition-colors truncate">
                      {c.task_id}
                    </code>
                  </.link>
                  <a
                    :if={c.mr_ref && c.merger_url}
                    href={c.merger_url}
                    target="_blank"
                    rel="noopener"
                    class="link link-primary text-xs truncate shrink-0"
                  >
                    {c.mr_ref}
                  </a>
                  <code :if={c.mr_ref && !c.merger_url} class="text-xs text-base-content/60 truncate">
                    {c.mr_ref}
                  </code>
                </div>
                <div class="flex items-center gap-1.5 shrink-0">
                  <span class="text-xs text-base-content/50 truncate hidden sm:inline">
                    {c.workspace_name}
                  </span>
                  <span class={["badge badge-sm", crucible_status_class(c.status)]}>
                    {crucible_status_label(c.status)}
                  </span>
                </div>
              </li>
            </ul>
          </div>
        </section>

        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <.empty_state :if={@entries == []} id="merge_queue-empty" icon="hero-inbox">
              No {plural(@pr_label)} integrating right now.
            </.empty_state>

            <ul :if={@entries != []} id="merge_queue" class="flex flex-col gap-3">
              <li
                :for={m <- @entries}
                class="rounded-box bg-base-100 border border-base-300 p-3 transition-colors duration-150 hover:border-primary/50"
              >
                <div class="flex items-center justify-between gap-2">
                  <.link
                    navigate={~p"/workers/#{m.task_id}"}
                    class="flex items-center gap-2 min-w-0 group"
                  >
                    <span class="relative flex h-2.5 w-2.5 shrink-0">
                      <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-warning opacity-75">
                      </span>
                      <span class="relative inline-flex h-2.5 w-2.5 rounded-full bg-warning"></span>
                    </span>
                    <code class="text-xs font-semibold group-hover:text-primary transition-colors truncate">
                      {m.task_id}
                    </code>
                  </.link>
                  <div class="flex items-center gap-1.5 shrink-0">
                    <span class="badge badge-sm badge-ghost font-mono">
                      {merger_type_label(m.merger_type)}
                    </span>
                    <span class={["badge badge-sm", merge_status_class(m.merger_status)]}>
                      {merge_status_label(m.merger_status)}
                    </span>
                  </div>
                </div>

                <div class="flex items-center justify-between gap-2 mt-1.5 text-xs text-base-content/60">
                  <span class="truncate">{m.workspace_name}</span>
                  <span class="font-mono tabular-nums shrink-0" title="Time in queue">
                    {humanize_seconds(runtime_seconds(m.since, @now))} in queue
                  </span>
                </div>

                <div :if={m.mr_ref} class="flex items-center gap-1 mt-1.5 text-xs min-w-0">
                  <.icon name="hero-arrow-top-right-on-square" class="size-3 text-primary shrink-0" />
                  <a
                    :if={m.merger_url}
                    href={m.merger_url}
                    target="_blank"
                    rel="noopener"
                    class="link link-primary truncate"
                  >
                    {m.mr_ref}
                  </a>
                  <code :if={!m.merger_url} class="truncate text-base-content/70">{m.mr_ref}</code>
                </div>
              </li>
            </ul>

            <.pager
              page={@page}
              total_pages={@total_pages}
              total_count={@total_count}
              page_path={&merge_queue_path/1}
            />
          </div>
        </section>

        <.back_link />
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = now),
    do: DateTime.diff(now, started_at, :second)

  defp runtime_seconds(_, _), do: 0

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp merger_type_label(:direct), do: "Direct"
  defp merger_type_label(:gitlab), do: "GitLab"
  defp merger_type_label(:github), do: "GitHub"
  defp merger_type_label(other), do: other |> to_string() |> String.capitalize()

  defp merge_status_label(nil), do: "Awaiting first poll"

  defp merge_status_label(status) when is_map(status) do
    case Watchdog.effective_block_reason(status) do
      nil ->
        case Watchdog.classify(status) do
          :merged -> "Merged"
          :approved -> "Approved"
          :closed -> "Closed / rejected"
          :pending -> "In review"
        end

      reason ->
        block_reason_label(reason)
    end
  end

  defp merge_status_class(nil), do: "badge-ghost"

  defp merge_status_class(status) when is_map(status) do
    case Watchdog.effective_block_reason(status) do
      nil ->
        case Watchdog.classify(status) do
          :merged -> "badge-success"
          :approved -> "badge-success"
          :closed -> "badge-error"
          :pending -> "badge-info"
        end

      _reason ->
        "badge-error"
    end
  end

  # Crucible item status (#354, Phase 3) — the Refinery's own view of where each
  # queued PR is in the serialized, base-aware merge pipeline.
  defp crucible_status_label(:opening), do: "Opening"
  defp crucible_status_label(:awaiting_approval), do: "In review"
  defp crucible_status_label(:ci_running), do: "CI running"
  defp crucible_status_label(:updating_base), do: "Rebasing onto base"
  defp crucible_status_label(:ready_to_merge), do: "Queued to merge"
  defp crucible_status_label(:merging), do: "Merging"
  defp crucible_status_label(:conflict_resolving), do: "Resolving conflict"
  defp crucible_status_label(:changes_requested), do: "Revising"
  defp crucible_status_label(:failed), do: "Failed"
  defp crucible_status_label(other), do: other |> to_string() |> String.capitalize()

  defp crucible_status_class(:ready_to_merge), do: "badge-success"
  defp crucible_status_class(:merging), do: "badge-success"
  defp crucible_status_class(:updating_base), do: "badge-info"
  defp crucible_status_class(:ci_running), do: "badge-info"
  defp crucible_status_class(:conflict_resolving), do: "badge-warning"
  defp crucible_status_class(:changes_requested), do: "badge-warning"
  defp crucible_status_class(:failed), do: "badge-error"
  defp crucible_status_class(_), do: "badge-ghost"

  # A blocked merge surfaces the *why* (#354, Phase 1) so an unmergeable PR is
  # never indistinguishable from one merely "in review".
  defp block_reason_label(:conflict), do: "Blocked · conflict"
  defp block_reason_label(:behind_base), do: "Blocked · behind base"
  defp block_reason_label(:ci_failed), do: "Blocked · CI failed"
  defp block_reason_label(:needs_approval), do: "Blocked · needs approval"

  defp block_reason_label(:needs_nonauthor_approval),
    do: "Parked · awaiting human reviewer"

  defp block_reason_label(:draft), do: "Blocked · draft"
  defp block_reason_label(:blocked_other), do: "Blocked"
  defp block_reason_label(other), do: "Blocked · #{other}"
end
