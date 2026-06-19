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

  alias Arbiter.Beads.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
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
          bead_id: p.bead_id,
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
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <.index_header
            icon="hero-arrow-path-rounded-square"
            title={cap_plural(@merge_queue_label)}
            count={@total_count}
            subtitle={"Every #{@pr_label} integrating now, longest-waiting first."}
          />
          <.live_badge live={@live} />
        </div>

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
                    navigate={~p"/workers/#{m.bead_id}"}
                    class="flex items-center gap-2 min-w-0 group"
                  >
                    <span class="relative flex h-2.5 w-2.5 shrink-0">
                      <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-warning opacity-75">
                      </span>
                      <span class="relative inline-flex h-2.5 w-2.5 rounded-full bg-warning"></span>
                    </span>
                    <code class="text-xs font-semibold group-hover:text-primary transition-colors truncate">
                      {m.bead_id}
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
    case Watchdog.classify(status) do
      :merged -> "Merged"
      :approved -> "Approved"
      :closed -> "Closed / rejected"
      :pending -> "In review"
    end
  end

  defp merge_status_class(nil), do: "badge-ghost"

  defp merge_status_class(status) when is_map(status) do
    case Watchdog.classify(status) do
      :merged -> "badge-success"
      :approved -> "badge-success"
      :closed -> "badge-error"
      :pending -> "badge-info"
    end
  end
end
