defmodule ArbiterWeb.MergeQueueIndexLive do
  @moduledoc """
  Index of every merge-queue entry at `/merge_queue` — the "See all" target for
  the dashboard's merge-queue section.

  Three tabs, each its own slice of the merge lifecycle:

    * **Queued** — a worker parked at `:awaiting_review`: an open MR
      integrating via `Arbiter.Mergers` (Direct/GitLab/GitHub), with the
      Watchdog's last poll result. Sourced live from `Worker.list_children/0`,
      paged in memory, ordered longest-waiting first. Each row anatomy is
      queue position / task id / title / PR link / check dots / time in
      queue.
    * **Landed today** — every `Arbiter.Workers.Run` that reached `:completed`
      (its MR merged) since UTC midnight, rendered as a 3-column grid of
      muted `TaskCard`s.
    * **Rejected** — a rejected/closed MR never accumulates a list here: the
      workflow reopens the task it belongs to, so it leaves the merge queue's
      domain entirely. The tab is a single `EmptyState` explaining that.

  Each entry links to the worker detail page — the worker IS the merge-queue
  entry, so its detail page is the entry's detail page. Re-renders on
  `:worker_lifecycle` events and a 1s tick.
  """

  use ArbiterWeb, :live_view

  require Ash.Query

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.MergeQueueSupervisor
  alias ArbiterWeb.CoreComponents.Domain
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Navigation
  alias ArbiterWeb.Paging

  @workers_topic "workers"
  @tabs ~w(queued landed rejected)
  @landed_page_size 24

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
      :timer.send_interval(1000, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:now, DateTime.utc_now())
     |> assign(:merge_queue_label, "merge queue")
     |> assign(:pr_label, "pull request")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:tab, parse_tab(params))
     |> assign(:page, Paging.parse_page(params))
     |> refresh()}
  end

  @impl true
  def handle_info({:worker_lifecycle, _event, _snap}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp parse_tab(%{"tab" => tab}) when tab in @tabs, do: tab
  defp parse_tab(_params), do: "queued"

  defp refresh(socket) do
    children = list_children()

    socket
    |> assign(:queued_count, Enum.count(children, &(&1.status == :awaiting_review)))
    |> refresh_tab(children)
  end

  defp refresh_tab(%{assigns: %{tab: "landed"}} = socket, _children) do
    result = Paging.paginate(landed_today_query(), socket.assigns.page, @landed_page_size)

    socket
    |> assign(:landed, Enum.map(result.entries, &landed_task_card_attrs/1))
    |> assign(:landed_today_count, result.total_count)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
  end

  defp refresh_tab(%{assigns: %{tab: "rejected"}} = socket, _children) do
    socket
    |> assign(:landed_today_count, landed_today_count())
    |> assign(:total_pages, 1)
    |> assign(:total_count, 0)
  end

  defp refresh_tab(socket, children) do
    workspaces_by_id = index_workspaces()
    queue_positions = queue_positions_by_task_id()
    workers = queued_workers(children) |> Enum.sort_by(& &1.since, {:asc, DateTime})

    {_next_rank, wait_ranks} =
      Enum.reduce(workers, {1, %{}}, fn p, {rank, acc} ->
        if Map.has_key?(queue_positions, p.task_id) do
          {rank, acc}
        else
          {rank + 1, Map.put(acc, p.task_id, rank)}
        end
      end)

    entries =
      workers
      |> Enum.map(fn p ->
        position = Map.get(queue_positions, p.task_id) || Map.fetch!(wait_ranks, p.task_id)

        %{
          position: position,
          task_id: p.task_id,
          title: p.title,
          workspace_name: workspace_name(workspaces_by_id, p.workspace_id),
          mr_ref: p.mr_ref,
          merger_url: p.merger_url,
          merger_status: p.merger_status,
          since: p.since
        }
      end)
      |> Enum.sort_by(&{&1.workspace_name, &1.position})

    result = Paging.paginate_list(entries, socket.assigns.page)

    socket
    |> assign(:landed_today_count, landed_today_count())
    |> assign(:entries, result.entries)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
  end

  # ---- Queued ----

  defp queued_workers(children) do
    workers = Enum.filter(children, &(&1.status == :awaiting_review))
    titles_by_id = titles_for(Enum.map(workers, & &1.task_id))

    Enum.map(workers, fn p ->
      meta = p.meta || %{}

      %{
        task_id: p.task_id,
        title: Map.get(titles_by_id, p.task_id, p.task_id),
        workspace_id: p.workspace_id,
        mr_ref: p.mr_ref,
        merger_url: p.merger_url,
        merger_status: Map.get(meta, :last_merger_status),
        since: p.step_started_at || p.started_at
      }
    end)
  end

  # Real merge-admission position and per-item pipeline status from the
  # running MergeQueue, keyed by task_id. Workers whose workspace has no
  # running queue (or the queue call times out) fall back to a wait-time
  # rank in `refresh_tab/2` — best-effort, never blocks the page.
  defp queue_positions_by_task_id do
    MergeQueueSupervisor.queue_views()
    |> Enum.flat_map(fn {_ws_id, items} -> items end)
    |> Map.new(fn item -> {item.task_id, item.position} end)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp titles_for([]), do: %{}

  defp titles_for(task_ids) do
    Issue
    |> Ash.Query.filter(id in ^task_ids)
    |> Ash.Query.select([:id, :title])
    |> Ash.read!()
    |> Map.new(&{&1.id, &1.title})
  rescue
    _ -> %{}
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

  # ---- Landed today ----

  defp today_start_utc do
    DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
  end

  defp landed_today_query do
    today = today_start_utc()

    Run
    |> Ash.Query.filter(
      status == :completed and worker_type == :main and not is_nil(mr_ref) and
        completed_at >= ^today
    )
    |> Ash.Query.sort(completed_at: :desc)
  end

  defp landed_today_count do
    landed_today_query() |> Ash.count!()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp landed_task_card_attrs(%Run{} = run) do
    %{
      id: run.task_id,
      title: run.task_title || run.task_id,
      footer: landed_footer(run)
    }
  end

  defp landed_footer(%Run{completed_at: nil}), do: nil

  defp landed_footer(%Run{completed_at: completed_at}) do
    "merged #{Calendar.strftime(completed_at, "%H:%M")} UTC"
  end

  # ---- view helpers ----

  defp merge_queue_path(tab, page), do: ~p"/merge_queue?#{%{tab: tab, page: page}}"

  defp tabs(queued_count, landed_today_count) do
    [
      %{label: "Queued", value: "queued", count: queued_count},
      %{label: "Landed today", value: "landed", count: landed_today_count},
      %{label: "Rejected", value: "rejected"}
    ]
  end

  defp header_count("landed", _queued_count, landed_today_count), do: landed_today_count
  defp header_count("rejected", _queued_count, _landed_today_count), do: 0
  defp header_count(_tab, queued_count, _landed_today_count), do: queued_count

  defp header_subtitle("landed", pr_label), do: "Every #{pr_label} merged since midnight UTC."

  defp header_subtitle("rejected", pr_label),
    do: "Rejected or closed #{plural(pr_label)} reopen their task instead of collecting here."

  defp header_subtitle(_tab, pr_label),
    do: "Every #{pr_label} integrating now, longest-waiting first."

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:tab_defs, tabs(assigns.queued_count, assigns.landed_today_count))
      |> assign(
        :header_count,
        header_count(assigns.tab, assigns.queued_count, assigns.landed_today_count)
      )
      |> assign(:header_subtitle, header_subtitle(assigns.tab, assigns.pr_label))

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas} live={@live}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <Domain.index_header
            icon="hero-arrow-path-rounded-square"
            title={cap_plural(@merge_queue_label)}
            count={@header_count}
            subtitle={@header_subtitle}
          />
          <Feedback.live_badge live={@live} />
        </div>

        <Navigation.filter_tabs
          tabs={@tab_defs}
          active={@tab}
          tab_path={fn value -> merge_queue_path(value, 1) end}
        />

        <ArbiterWeb.CoreComponents.Core.panel :if={@tab == "queued"} body_class="flex flex-col gap-4">
          <div :if={@entries == []} id="merge_queue-empty">
            <Feedback.empty_state icon="hero-inbox">
              No {plural(@pr_label)} integrating right now.
            </Feedback.empty_state>
          </div>

          <ul :if={@entries != []} id="merge_queue" class="flex flex-col gap-3">
            <li
              :for={m <- @entries}
              class="rounded-[var(--radius-panel)] bg-[var(--surface-card)] border border-[var(--border-default)] p-3 transition-colors duration-[var(--dur-hover)] hover:border-[var(--border-strong)]"
            >
              <div class="flex items-center justify-between gap-2">
                <div class="flex items-center gap-2 min-w-0">
                  <span
                    class="inline-flex items-center rounded-[var(--radius-field)] bg-[var(--arb-panel-alt)] px-1.5 py-0.5 text-[10px] font-[family-name:var(--font-mono)] tabular-nums text-[var(--text-label)] shrink-0"
                    title="Queue position"
                  >
                    {"##{m.position}"}
                  </span>
                  <.link
                    navigate={~p"/workers/#{m.task_id}"}
                    class="flex items-center gap-2 min-w-0 group"
                  >
                    <code class="text-[11px] font-semibold text-[var(--text-title)] group-hover:text-[var(--text-link)] transition-colors truncate font-[family-name:var(--font-mono)]">
                      {m.task_id}
                    </code>
                    <span class="text-[12px] text-[var(--text-secondary)] truncate">{m.title}</span>
                  </.link>
                </div>
                <div class="flex items-center gap-1.5 shrink-0" title="CI / Approval / Mergeable">
                  <span
                    :for={{label, state} <- check_dots(m.merger_status)}
                    class={["h-1.5 w-1.5 rounded-full shrink-0", check_dot_class(state)]}
                    title={label}
                  />
                </div>
              </div>

              <div class="flex items-center justify-between gap-2 mt-1.5 text-[11px] text-[var(--text-label)]">
                <span class="truncate">{m.workspace_name}</span>
                <span
                  class="font-[family-name:var(--font-mono)] tabular-nums shrink-0"
                  title="Time in queue"
                >
                  {humanize_seconds(runtime_seconds(m.since, @now))} in queue
                </span>
              </div>

              <div :if={m.mr_ref} class="flex items-center gap-1 mt-1.5 text-[11px] min-w-0">
                <ArbiterWeb.CoreComponents.Core.icon
                  name="hero-arrow-top-right-on-square"
                  size={12}
                  class="text-[var(--text-link)] shrink-0"
                />
                <a
                  :if={m.merger_url}
                  href={m.merger_url}
                  target="_blank"
                  rel="noopener"
                  class="text-[var(--text-link)] hover:underline truncate"
                >
                  {m.mr_ref}
                </a>
                <code :if={!m.merger_url} class="truncate text-[var(--text-label)]">{m.mr_ref}</code>
              </div>
            </li>
          </ul>

          <Navigation.pager
            page={@page}
            total_pages={@total_pages}
            total_count={@total_count}
            page_path={fn page -> merge_queue_path(@tab, page) end}
          />
        </ArbiterWeb.CoreComponents.Core.panel>

        <ArbiterWeb.CoreComponents.Core.panel :if={@tab == "landed"} body_class="flex flex-col gap-4">
          <div :if={@landed == []} id="merge_queue-landed-empty">
            <Feedback.empty_state icon="hero-check-circle">
              No {plural(@pr_label)} have landed today yet.
            </Feedback.empty_state>
          </div>

          <div
            :if={@landed != []}
            id="merge_queue-landed"
            class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3"
          >
            <Domain.task_card
              :for={t <- @landed}
              id={t.id}
              title={t.title}
              footer={t.footer}
              muted
            />
          </div>

          <Navigation.pager
            page={@page}
            total_pages={@total_pages}
            total_count={@total_count}
            page_path={fn page -> merge_queue_path(@tab, page) end}
          />
        </ArbiterWeb.CoreComponents.Core.panel>

        <ArbiterWeb.CoreComponents.Core.panel
          :if={@tab == "rejected"}
          body_class="flex flex-col gap-4"
        >
          <div id="merge_queue-rejected-empty">
            <Feedback.empty_state
              icon="hero-arrow-uturn-left"
              detail={"A rejected or closed #{@pr_label} reopens its task and sends it back to the board for another pass — nothing stays queued once that happens."}
            >
              Rejected merges don't collect here.
            </Feedback.empty_state>
          </div>
        </ArbiterWeb.CoreComponents.Core.panel>

        <ArbiterWeb.CoreComponents.Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end

  # ---- render helpers ----

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = now),
    do: DateTime.diff(now, started_at, :second)

  defp runtime_seconds(_, _), do: 0

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  # Three checks derived from the Watchdog's last poll result: CI, Approval,
  # Mergeable. `nil` (no poll yet) renders all three unknown.
  defp check_dots(nil), do: [{"CI", :unknown}, {"Approval", :unknown}, {"Mergeable", :unknown}]

  defp check_dots(status) when is_map(status) do
    [
      {"CI", check_ci_state(status)},
      {"Approval", check_approval_state(status)},
      {"Mergeable", check_mergeable_state(status)}
    ]
  end

  defp check_ci_state(status) do
    cond do
      Watchdog.ci_failed?(status) -> :fail
      Watchdog.ci_pending?(status) -> :pending
      Map.get(status, :pipeline) in [nil, :not_started] -> :unknown
      true -> :pass
    end
  end

  defp check_approval_state(status) do
    cond do
      Map.get(status, :approved) == true -> :pass
      Map.get(status, :changes_requested) == true -> :fail
      true -> :pending
    end
  end

  defp check_mergeable_state(status) do
    if Watchdog.block_reason(status) in [
         nil,
         :ci_failed,
         :needs_approval,
         :needs_nonauthor_approval
       ],
       do: :pass,
       else: :fail
  end

  defp check_dot_class(:pass), do: "bg-success"
  defp check_dot_class(:fail), do: "bg-error"
  defp check_dot_class(:pending), do: "bg-warning"
  defp check_dot_class(:unknown), do: "bg-base-300"
end
