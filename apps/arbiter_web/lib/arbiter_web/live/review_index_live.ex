defmodule ArbiterWeb.ReviewIndexLive do
  @moduledoc """
  LiveView at `/reviews` — the external-review audit ledger (bd-4jllkg,
  bd-amtjxk). Read-only visibility for `worker_review(pr:)` /
  `arb review --pr` runs, which are not task-linked and previously had no
  UI beyond the transient `/events?subscribe=external_review` stream.

  List + inline row expansion, same shape as `AuditLogLive`/`UsageLive`:
  filters and page round-trip through the URL (`?workspace_id=&status=&page=`),
  `ArbiterWeb.Paging` backs pagination.

  Live updates: subscribes to the global `Arbiter.Events` PubSub topic (which
  receives a copy of every workspace-scoped broadcast, `Events.broadcast/3`)
  and, on an `external_review` event, re-fetches the single record by id and
  replaces it in the currently-loaded page in place — no polling, no full
  reload. See `Arbiter.Reviews.ExternalReview`'s `broadcast_review_event/3`
  for the (deliberately partial) event payload shape.

  Expanding a row also loads that review's durable corpus (bd-7efini): the
  composed prompt it was given, the tool calls its reviewer made and what they
  returned, and the transcript itself — the same class of data a regular
  worker run's `worker_log` exposes. Loaded lazily on expand (one row at a
  time, dropped on collapse) rather than per row on render, since each read
  hits disk. See `Arbiter.Reviews.Transcript`.

  Greenlight-from-UI is out of scope for v1 per the design doc — this is a
  read-only view.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Events
  alias Arbiter.Reviews.Record
  alias Arbiter.Reviews.Transcript
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.CoreComponents.{Core, Data, Feedback, Forms, Navigation}
  alias ArbiterWeb.Paging
  require Ash.Query

  @statuses Record.statuses()
  @status_strings Enum.map(@statuses, &Atom.to_string/1)
  @status_options Enum.map(@statuses, &{Atom.to_string(&1), Atom.to_string(&1)})

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arbiter.PubSub, Events.pubsub_topic(nil))

    workspaces =
      Workspace
      |> Ash.Query.sort(name: :asc)
      |> Ash.read!()

    {:ok,
     socket
     |> assign(:workspaces, workspaces)
     |> assign(:workspace_names, Map.new(workspaces, &{&1.id, &1.name}))
     |> assign(:status_options, @status_options)
     |> assign(:expanded, nil)
     |> assign(:transcript, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = present(params["workspace_id"])
    status = if params["status"] in @status_strings, do: params["status"]
    page = Paging.parse_page(params)

    {:noreply,
     socket
     |> assign(:workspace_id, workspace_id)
     |> assign(:status, status)
     |> assign(:page, page)
     |> load_records()}
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(v), do: v

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     push_patch(socket,
       to: reviews_path(present(params["workspace_id"]), present(params["status"]), 1)
     )}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         reviews_path(
           socket.assigns.workspace_id,
           socket.assigns.status,
           Paging.parse_page(%{"page" => page})
         )
     )}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    expanded = if socket.assigns.expanded == id, do: nil, else: id

    {:noreply,
     socket
     |> assign(:expanded, expanded)
     |> assign(:transcript, expanded && load_transcript(expanded))}
  end

  @impl true
  def handle_info({:event, %{topic: "external_review", review_record_id: id}}, socket)
      when is_binary(id) do
    {:noreply, patch_record(socket, id)}
  end

  def handle_info({:event, _payload}, socket), do: {:noreply, socket}

  # Catch-all: `LiveHooks.on_mount(:coordinator_inbox)` subscribes every view
  # in this live_session to the per-workspace coordinator-mailbox topic and
  # `:cont`s messages like `{:new_message, _}` on to us, regardless of
  # whether this view cares about them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reviews_path(workspace_id, status, page),
    do: ~p"/reviews?#{[workspace_id: workspace_id, status: status, page: page]}"

  # ---- data ----

  defp load_records(socket) do
    query =
      Record
      |> filter_workspace(socket.assigns.workspace_id)
      |> filter_status(socket.assigns.status)
      |> Ash.Query.sort(started_at: :desc)

    page = Paging.paginate(query, socket.assigns.page)

    socket
    |> assign(:records, page.entries)
    |> assign(:page_info, page)
  end

  # Cap on rendered transcript events: an agentic review over a large PR runs
  # to thousands of JSONL lines, and the whole point of the durable file is
  # that the UI never has to be the complete record. The tail is what an
  # operator reads first (verdict, last tool calls); the full corpus stays on
  # disk and is reachable via `external_review_transcript` / the REST endpoint.
  @event_limit 300

  # Read one review's corpus off disk. Never raises: a review that predates
  # capture, or whose file was reaped, renders as "no transcript captured"
  # rather than taking the page down.
  defp load_transcript(record_id) do
    summary = Transcript.summary(record_id)
    all_events = Transcript.events(record_id)
    shown = Enum.take(all_events, -@event_limit)

    %{
      record_id: record_id,
      summary: summary,
      prompt: transcript_prompt(record_id),
      tool_uses: Transcript.tool_uses(record_id),
      events: shown,
      event_count: length(all_events),
      truncated: length(all_events) > length(shown)
    }
  rescue
    _ -> nil
  end

  defp transcript_prompt(record_id) do
    case Transcript.prompt(record_id) do
      {:ok, prompt} -> prompt
      {:error, _} -> nil
    end
  end

  defp filter_workspace(query, nil), do: query
  defp filter_workspace(query, ws), do: Ash.Query.filter(query, workspace_id == ^ws)

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: Ash.Query.filter(query, status == ^status)

  # Replace a single record in the currently-loaded page in place, matching
  # the design doc's re-fetch-by-id approach (the broadcast payload only
  # carries a handful of fields — not enough to render every column). If the
  # record isn't part of the loaded page (e.g. a brand new running review on
  # page 1), a full `load_records/1` re-derives the correct page/total. A
  # record already on the page is patched in place even if its new status no
  # longer matches an active `?status=` filter — the operator is watching
  # this row transition, so leaving it visible is preferable to it vanishing
  # out from under them; it reappears filtered on the next navigation.
  defp patch_record(socket, id) do
    case Ash.get(Record, id) do
      {:ok, record} ->
        if Enum.any?(socket.assigns.records, &(&1.id == id)) do
          records =
            Enum.map(socket.assigns.records, fn r -> if r.id == id, do: record, else: r end)

          assign(socket, :records, records)
        else
          load_records(socket)
        end

      _ ->
        socket
    end
  rescue
    _ -> socket
  end

  # ---- formatting ----

  defp workspace_name(_names, nil), do: "—"
  defp workspace_name(names, id), do: Map.get(names, id, id)

  defp format_started(nil), do: "—"
  defp format_started(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp format_maybe(nil), do: "—"
  defp format_maybe(v), do: to_string(v)

  defp pr_label(%{pr_ref: pr_ref, pr: pr}), do: pr || pr_ref

  defp show_proposed_comments?(%{status: :completed_unposted}), do: true
  defp show_proposed_comments?(%{mode: :report_only, greenlight_status: :pending}), do: true
  defp show_proposed_comments?(_record), do: false

  defp comment_field(comment, key) when is_map(comment),
    do: Map.get(comment, key) || Map.get(comment, to_string(key))

  # ---- transcript formatting ----

  # The transcript assign belongs to whichever row is expanded; guard against
  # rendering a stale one after a live patch swapped the record out.
  defp transcript_for(%{record_id: id} = transcript, id), do: transcript
  defp transcript_for(_transcript, _id), do: nil

  defp event_label(%{kind: :system}), do: "init"
  defp event_label(%{kind: :assistant_text}), do: "assistant"
  defp event_label(%{kind: :tool_use}), do: "tool"
  defp event_label(%{kind: :tool_result}), do: "result"
  defp event_label(%{kind: :result}), do: "final"
  defp event_label(_event), do: "raw"

  defp event_text(%{kind: :system} = e),
    do: Enum.join(Enum.reject([e[:model], e[:session_id]], &is_nil/1), " · ")

  defp event_text(%{kind: :tool_use} = e), do: "#{e.name} #{compact_json(e.input)}"
  defp event_text(%{text: text}) when is_binary(text), do: truncate(text, 2_000)
  defp event_text(_event), do: ""

  defp compact_json(map) when map_size(map) == 0, do: ""

  defp compact_json(map) do
    case Jason.encode(map) do
      {:ok, json} -> truncate(json, 300)
      _ -> inspect(map)
    end
  end

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "…", else: text
  end

  defp truncate(text, _limit), do: text

  # ---- render ----

  # The durable corpus of one review (bd-7efini): what the reviewer was told,
  # which tools it reached for and what came back, and the transcript itself.
  attr :transcript, :map, default: nil

  defp review_transcript(assigns) do
    ~H"""
    <div :if={@transcript} class="flex flex-col gap-3 border-t border-[var(--border-default)] pt-3">
      <div :if={!@transcript.summary.exists && !@transcript.summary.prompt_exists}>
        <p class="text-[11.5px] text-base-content/60">
          No transcript captured for this review — it ran before durable review
          capture existed, or its reviewer produced no output.
        </p>
      </div>

      <details :if={@transcript.prompt} class="text-[11.5px]">
        <summary class="cursor-pointer font-medium text-[var(--text-label)]">
          Prompt ({byte_size(@transcript.prompt)} bytes)
        </summary>
        <pre class="mt-1 max-h-72 overflow-auto whitespace-pre-wrap break-words font-[family-name:var(--font-mono)] text-[11px] leading-relaxed bg-base-200/40 rounded-[var(--radius-field)] p-2">{@transcript.prompt}</pre>
      </details>

      <div :if={@transcript.tool_uses != []} class="flex flex-col gap-1">
        <p class="text-[11.5px] font-medium text-[var(--text-label)]">
          Tools used ({@transcript.summary.tool_use_count})
        </p>
        <div class="flex flex-wrap gap-1">
          <span
            :for={tool <- @transcript.summary.tools_used}
            class="badge badge-ghost text-[10px] font-[family-name:var(--font-mono)]"
          >
            {tool.name} ×{tool.count}
          </span>
        </div>
        <details class="text-[11.5px]">
          <summary class="cursor-pointer text-[var(--text-label)]">Calls and results</summary>
          <div class="mt-1 flex flex-col gap-1 max-h-72 overflow-auto">
            <div
              :for={tool <- @transcript.tool_uses}
              class="border-l-2 border-[var(--border-default)] pl-2"
            >
              <span class="font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                {tool.name}
              </span>
              <span class="font-[family-name:var(--font-mono)] text-[11px] break-all">
                {compact_json(tool.input)}
              </span>
              <p
                :if={tool.result}
                class="mt-0.5 text-base-content/70 whitespace-pre-wrap break-words font-[family-name:var(--font-mono)] text-[11px]"
              >
                {truncate(tool.result, 600)}
              </p>
            </div>
          </div>
        </details>
      </div>

      <details :if={@transcript.summary.exists} class="text-[11.5px]">
        <summary class="cursor-pointer font-medium text-[var(--text-label)]">
          Transcript ({@transcript.summary.line_count} lines{if @transcript.truncated,
            do: ", showing the last #{length(@transcript.events)} events",
            else: ""})
        </summary>
        <div class="mt-1 max-h-96 overflow-auto flex flex-col gap-0.5 bg-base-200/40 rounded-[var(--radius-field)] p-2">
          <div :for={event <- @transcript.events} class="flex gap-2 items-start">
            <span class="shrink-0 w-14 text-[10px] uppercase tracking-wide text-base-content/50 font-[family-name:var(--font-mono)]">
              {event_label(event)}
            </span>
            <span class="whitespace-pre-wrap break-words font-[family-name:var(--font-mono)] text-[11px] leading-relaxed">
              {event_text(event)}
            </span>
          </div>
        </div>
        <p class="mt-1 text-[10px] text-base-content/50 break-all">
          {@transcript.summary.path}
        </p>
      </details>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6" id="reviews">
        <div>
          <h1 class="text-2xl font-bold tracking-tight flex items-center gap-2">
            <Core.icon name="hero-magnifying-glass" size={24} class="text-base-content/70" /> Reviews
          </h1>
          <p class="text-sm text-base-content/60 mt-1">
            External reviews (<code class="text-xs">worker_review(pr:)</code> / <code class="text-xs">arb review --pr</code>), sourced from the
            <code class="text-xs">Arbiter.Reviews.Record</code>
            audit ledger.
          </p>
        </div>

        <form phx-change="filter" class="flex flex-wrap items-center gap-3">
          <Forms.select
            name="workspace_id"
            id="reviews-workspace-filter"
            value={@workspace_id}
            prompt="All workspaces"
            options={Enum.map(@workspaces, &{&1.name, &1.id})}
            size="sm"
          />
          <Forms.select
            name="status"
            id="reviews-status-filter"
            value={@status}
            prompt="All statuses"
            options={@status_options}
            size="sm"
          />
        </form>

        <Feedback.empty_state
          :if={@records == []}
          icon="hero-inbox"
          detail="No external reviews match these filters."
        >
          Nothing here
        </Feedback.empty_state>

        <div :if={@records != []} id="reviews-table" class="w-full overflow-x-auto" role="table">
          <div
            class="grid items-center gap-3 h-[30px] px-[14px] bg-[var(--arb-chrome)]"
            style="grid-template-columns: 150px minmax(120px,1fr) 140px 90px 130px 90px 120px 80px 90px;"
            role="row"
          >
            <span
              :for={label <- ~w(Started PR Workspace Strategy Status Mode Verdict Findings Cost)}
              class="text-[10.5px] uppercase tracking-[0.06em] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              role="columnheader"
            >
              {label}
            </span>
          </div>

          <div :for={record <- @records} class="flex flex-col">
            <div
              class="grid items-center gap-3 min-h-[34px] px-[14px] border-b border-[var(--arb-line-soft)] hover:bg-[var(--arb-raised-hover)] cursor-pointer"
              style="grid-template-columns: 150px minmax(120px,1fr) 140px 90px 130px 90px 120px 80px 90px;"
              role="row"
              id={"review-row-#{record.id}"}
              phx-click="toggle"
              phx-value-id={record.id}
            >
              <span
                role="cell"
                class="text-[11.5px] font-[family-name:var(--font-mono)] tabular-nums text-[var(--text-body)]"
              >
                {format_started(record.started_at)}
              </span>
              <span role="cell" class="text-[11.5px] truncate">
                <a
                  :if={record.link}
                  href={record.link}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="hover:underline"
                  onclick="event.stopPropagation()"
                >
                  {pr_label(record)}
                </a>
                <span :if={!record.link}>{pr_label(record)}</span>
              </span>
              <span role="cell" class="text-[11.5px] truncate">
                {workspace_name(@workspace_names, record.workspace_id)}
              </span>
              <span role="cell" class="badge badge-ghost text-[10.5px]">
                {format_maybe(record.strategy)}
              </span>
              <span role="cell"><Data.status_chip status={record.status} /></span>
              <span role="cell" class="text-[11.5px]">{format_maybe(record.mode)}</span>
              <span role="cell" class="text-[11.5px]">{format_maybe(record.verdict)}</span>
              <span
                role="cell"
                class="text-[11.5px] font-[family-name:var(--font-mono)] tabular-nums"
              >
                {format_maybe(record.finding_count)}
              </span>
              <span
                role="cell"
                class="text-[11.5px] font-[family-name:var(--font-mono)] tabular-nums"
              >
                {Data.format_usd(record.cost_usd)}
              </span>
            </div>

            <div
              :if={@expanded == record.id}
              class="mt-1 mb-2 border border-[var(--border-default)] rounded-[var(--radius-field)] p-3 flex flex-col gap-3"
              id={"review-detail-#{record.id}"}
            >
              <Data.data_list>
                <:item label="Findings summary">{record.findings_summary || "—"}</:item>
                <:item label="Model">{format_maybe(record.model)}</:item>
                <:item label="Tokens in / out">
                  {format_maybe(record.tokens_in)} / {format_maybe(record.tokens_out)}
                </:item>
                <:item label="Dispatched by">{format_maybe(record.dispatched_by)}</:item>
                <:item label="PR">{format_maybe(record.pr)} ({format_maybe(record.pr_ref)})</:item>
              </Data.data_list>

              <div :if={record.engagement_id}>
                <.link
                  navigate={~p"/tasks/#{record.engagement_id}"}
                  class="text-[11.5px] hover:underline text-[var(--text-label)]"
                >
                  linked engagement: {record.engagement_id} →
                </.link>
              </div>

              <div :if={record.status == :failed} class="text-[11.5px]">
                <p class="font-medium text-[var(--arb-fail-text)]">
                  Failed at {format_maybe(record.failure_stage)}
                </p>
                <p class="text-base-content/70">{record.failure_reason || "no reason recorded"}</p>
              </div>

              <.review_transcript transcript={transcript_for(@transcript, record.id)} />

              <div :if={show_proposed_comments?(record)} class="flex flex-col gap-2">
                <p class="text-[11.5px] font-medium text-[var(--text-label)]">
                  Proposed comments ({length(record.proposed_comments)})
                </p>
                <div
                  :for={comment <- record.proposed_comments}
                  class="text-[11.5px] border-l-2 border-[var(--border-default)] pl-2"
                >
                  <span class="font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                    {comment_field(comment, :file)}:{comment_field(comment, :line)}
                  </span>
                  <span class="badge badge-ghost text-[10px] ml-1">
                    {comment_field(comment, :severity)}
                  </span>
                  <p class="mt-0.5">{comment_field(comment, :message)}</p>
                </div>
              </div>
            </div>
          </div>
        </div>

        <Navigation.pager
          :if={@page_info.total_pages > 1}
          page={@page_info.page}
          total_pages={@page_info.total_pages}
          total_count={@page_info.total_count}
          page_path={&reviews_path(@workspace_id, @status, &1)}
        />
      </div>
    </Layouts.app>
    """
  end
end
