defmodule ArbiterWeb.WorkerIndexLive do
  @moduledoc """
  Index of every active worker (worker) at `/workers` — the "See all"
  target for the dashboard's active-workers section.

  Workers are live GenServer state, not rows, so the listing comes from
  `Worker.list_children/0` and is paged in memory. A status filter narrows to
  running vs awaiting work. Re-renders live on `:worker_lifecycle` events and
  on a 1s tick (for the elapsed counters). Each row links to the worker
  detail page; completed/failed runs live on the run history index instead.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias ArbiterWeb.Paging
  alias ArbiterWeb.CoreComponents.Domain
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Navigation
  require Ash.Query

  @workers_topic "workers"

  @filters [
    %{label: "All", value: "all"},
    %{label: "Running", value: "running"},
    %{label: "Awaiting", value: "awaiting"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
      :timer.send_interval(1000, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:now, DateTime.utc_now())
     |> assign(:worker_label, "worker")
     |> assign(:issue_label, "issue")
     |> assign(:filters, @filters)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:status, parse_status(params))
     |> assign(:page, Paging.parse_page(params))
     |> refresh()}
  end

  @impl true
  def handle_info({:worker_lifecycle, _event, _snap}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    workspaces_by_id = index_workspaces()

    all =
      list_children()
      |> Enum.map(fn p ->
        Map.put(p, :workspace_name, workspace_name(workspaces_by_id, p.workspace_id))
      end)
      |> Enum.filter(&matches_status?(&1, socket.assigns.status))
      |> Enum.sort_by(& &1.started_at, {:asc, DateTime})

    result = Paging.paginate_list(all, socket.assigns.page)

    socket
    |> assign(:workers, result.entries)
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

  defp matches_status?(_p, :all), do: true
  defp matches_status?(%{status: :running}, :running), do: true

  defp matches_status?(%{status: status}, :awaiting),
    do: status in [:awaiting, :awaiting_review, :awaiting_review_gate]

  defp matches_status?(_p, _), do: false

  defp parse_status(%{"status" => s}) when s in ~w(running awaiting all),
    do: String.to_existing_atom(s)

  defp parse_status(_), do: :all

  defp worker_path(:all, page), do: ~p"/workers?#{%{page: page}}"
  defp worker_path(status, page), do: ~p"/workers?#{%{status: status, page: page}}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas} live={@live}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <Domain.index_header
            icon="hero-cpu-chip"
            title={"Active #{cap_plural(@worker_label)}"}
            count={@total_count}
            subtitle={"Every #{@worker_label} running right now. Finished runs live on the history index."}
          />
          <Feedback.live_badge live={@live} />
        </div>

        <Navigation.filter_tabs
          tabs={@filters}
          active={Atom.to_string(@status)}
          tab_path={fn value -> worker_path(String.to_existing_atom(value), 1) end}
        />

        <ArbiterWeb.CoreComponents.Core.panel body_class="flex flex-col gap-4">
          <div :if={@workers == []} id="workers-empty">
            <Feedback.empty_state icon="hero-moon">
              No active {plural(@worker_label)} match this filter.
            </Feedback.empty_state>
          </div>

          <ul :if={@workers != []} id="workers" class="flex flex-col gap-3">
            <li :for={p <- @workers} class="flex flex-col">
              <.link
                navigate={~p"/workers/#{p.task_id}"}
                class={[
                  "flex items-center justify-between gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-solid",
                  "border-[var(--border-default)] bg-[var(--arb-panel-alt)] hover:bg-[var(--arb-raised-hover)]",
                  "transition-colors duration-[var(--dur-hover)] no-underline"
                ]}
              >
                <div class="flex items-center gap-2 min-w-0 flex-1">
                  <span class="relative flex h-2.5 w-2.5 shrink-0">
                    <span
                      :if={p.status == :running}
                      class="absolute inline-flex h-full w-full animate-ping rounded-full bg-[var(--arb-live)] opacity-75"
                    >
                    </span>
                    <span class={[
                      "relative inline-flex h-2.5 w-2.5 rounded-full",
                      status_dot_class(p.status)
                    ]}>
                    </span>
                  </span>
                  <code class="text-[11px] font-medium font-[family-name:var(--font-mono)] text-[var(--text-secondary)] group-hover:text-[var(--text-link)] transition-colors truncate">
                    {p.task_id}
                  </code>
                </div>
                <div class="flex items-center gap-2 flex-none">
                  <span
                    class="text-[10.5px] text-[var(--text-label)] font-[family-name:var(--font-mono)] whitespace-nowrap"
                    title="Elapsed"
                  >
                    {humanize_seconds(runtime_seconds(p.started_at, @now))}
                  </span>
                  <span class={[
                    "text-[10.5px] px-1.5 py-px rounded-[var(--radius-field)] font-medium",
                    awaiting_review_status_class(p)
                  ]}>
                    {awaiting_review_status_label(p)}
                  </span>
                </div>
              </.link>
              <span class="text-[10.5px] text-[var(--text-label)] px-3 py-1">
                {p.workspace_name}
              </span>
            </li>
          </ul>

          <Navigation.pager
            page={@page}
            total_pages={@total_pages}
            total_count={@total_count}
            page_path={fn page -> worker_path(@status, page) end}
          />
        </ArbiterWeb.CoreComponents.Core.panel>

        <div class="flex items-center gap-4">
          <Navigation.back_link />
          <.link
            navigate={~p"/workers/history"}
            class="text-[12.5px] font-medium text-[var(--text-link)] hover:text-[var(--text-title)] transition-colors flex items-center gap-1.5"
          >
            <ArbiterWeb.CoreComponents.Core.icon name="hero-clock" size={14} />
            History (completed {plural(@worker_label)})
          </.link>
        </div>
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

  defp status_dot_class(:running), do: "bg-[var(--arb-live)]"
  defp status_dot_class(:awaiting), do: "bg-[var(--arb-attention)]"
  defp status_dot_class(:awaiting_review), do: "bg-[var(--arb-attention)]"
  defp status_dot_class(:awaiting_review_gate), do: "bg-[var(--arb-attention)]"
  defp status_dot_class(:completed), do: "bg-[var(--arb-done)]"
  defp status_dot_class(:failed), do: "bg-[var(--arb-fail)]"
  defp status_dot_class(_), do: "bg-[var(--text-label)]"

  defp worker_status_class(:idle), do: "bg-[var(--arb-panel)] text-[var(--text-secondary)]"

  defp worker_status_class(:resuming),
    do: "bg-[color-mix(in_oklch,var(--arb-info)_20%,transparent)] text-[var(--arb-info)]"

  defp worker_status_class(:running),
    do: "bg-[color-mix(in_oklch,var(--arb-live)_20%,transparent)] text-[var(--arb-live)]"

  defp worker_status_class(:awaiting),
    do:
      "bg-[color-mix(in_oklch,var(--arb-attention)_20%,transparent)] text-[var(--arb-attention)]"

  defp worker_status_class(:awaiting_review_gate),
    do:
      "bg-[color-mix(in_oklch,var(--arb-attention)_20%,transparent)] text-[var(--arb-attention)]"

  defp worker_status_class(:awaiting_review),
    do:
      "bg-[color-mix(in_oklch,var(--arb-attention)_20%,transparent)] text-[var(--arb-attention)]"

  defp worker_status_class(:completed),
    do: "bg-[color-mix(in_oklch,var(--arb-done)_20%,transparent)] text-[var(--arb-done)]"

  defp worker_status_class(:failed),
    do: "bg-[color-mix(in_oklch,var(--arb-fail)_20%,transparent)] text-[var(--arb-fail-text)]"

  defp worker_status_class(_), do: "bg-[var(--arb-panel)] text-[var(--text-secondary)]"

  defp worker_status_label(:idle), do: "Idle"
  defp worker_status_label(:resuming), do: "Resuming"
  defp worker_status_label(:running), do: "Running"
  defp worker_status_label(:awaiting), do: "Awaiting"
  defp worker_status_label(:awaiting_review_gate), do: "In review_gate"
  defp worker_status_label(:awaiting_review), do: "Awaiting review"
  defp worker_status_label(:completed), do: "Completed"
  defp worker_status_label(:failed), do: "Failed"

  defp worker_status_label(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  defp worker_status_label(other), do: to_string(other)

  # For awaiting_review workers, delegate to approval_class/approval_label to maintain
  # correct priority order: blocks > approved > ci_pending > default.
  defp awaiting_review_status_label(%{status: :awaiting_review, meta: meta}) when is_map(meta) do
    case Map.get(meta, :last_merger_status) do
      merger_status when is_map(merger_status) ->
        ArbiterWeb.WorkerDetailLive.approval_label(merger_status)

      _ ->
        "Awaiting review"
    end
  end

  defp awaiting_review_status_label(worker), do: worker_status_label(worker.status)

  defp awaiting_review_status_class(%{status: :awaiting_review, meta: meta}) when is_map(meta) do
    case Map.get(meta, :last_merger_status) do
      merger_status when is_map(merger_status) ->
        approval_badge_class(merger_status)

      _ ->
        worker_status_class(:awaiting_review)
    end
  end

  defp awaiting_review_status_class(worker), do: worker_status_class(worker.status)

  defp approval_badge_class(%{status: :merged}),
    do: "bg-[color-mix(in_oklch,var(--arb-done)_20%,transparent)] text-[var(--arb-done)]"

  defp approval_badge_class(%{status: :closed}),
    do: "bg-[color-mix(in_oklch,var(--arb-fail)_20%,transparent)] text-[var(--arb-fail-text)]"

  defp approval_badge_class(status) when is_map(status) do
    case status do
      %{blocks: blocks} when is_list(blocks) and blocks != [] ->
        "bg-[color-mix(in_oklch,var(--arb-fail)_20%,transparent)] text-[var(--arb-fail-text)]"

      %{approved_by: approved} when is_list(approved) and approved != [] ->
        "bg-[color-mix(in_oklch,var(--arb-done)_20%,transparent)] text-[var(--arb-done)]"

      _ ->
        "bg-[color-mix(in_oklch,var(--arb-attention)_20%,transparent)] text-[var(--arb-attention)]"
    end
  end

  defp approval_badge_class(_),
    do:
      "bg-[color-mix(in_oklch,var(--arb-attention)_20%,transparent)] text-[var(--arb-attention)]"
end
