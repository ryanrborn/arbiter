defmodule ArbiterWeb.AuditLogLive do
  @moduledoc """
  LiveView at `/audit` — a filtered/paged table of task state transitions
  sourced from `AshPaperTrail` versions on `Arbiter.Tasks.Issue`.

  ## Columns

  time / actor / subject / action / detail — `detail` renders a status
  transition **verbatim**, e.g. `open → in_progress`, never humanized. Any
  other changed fields are shown as `key=value`, also verbatim — see
  `ArbiterWeb.CoreComponents.Data.status_chip/1`'s doc for the same rule
  applied elsewhere in this component library.

  ## Actor

  `Issue` has no `belongs_to_actor` (see `Arbiter.PaperTrail`'s moduledoc) —
  the only actor signal on an Issue version is the optional `change_origin`
  argument threaded through the `:update` action (`create`/`close`/`reopen`
  never set it), landing in `version_action_inputs["change_origin"]` via
  `store_action_inputs?(true)`. A version with no `change_origin` is shown
  as `"system"`.

  The **Human / Machine** tabs approximate a real actor-kind distinction
  from that one string: `"worker:<task_id>"`, `"loop:..."`, `"coordinator"`,
  and unattributed (`"system"`) writes are machine actors (every one of
  those is itself an AI agent session); `"cli"`, `"dashboard"`, or any other
  bare label is treated as human. This is a heuristic, not a first-class
  actor model — the moduledoc this replaces already punted actor filtering
  to "Phase 5" for the same reason (no actor resource to belong to).

  ## Query syntax

  The mono search box accepts space-separated `key:value` clauses —
  `subject:`, `actor:`, `action:` — ANDed together; a bare word without a
  `key:` prefix matches subject, actor, or action (substring, case
  insensitive).

  Reads are bounded to the 500 most recent versions (same cap the prior
  implementation used); tabs/query filter and pagination happen in memory
  over that window, matching `ArbiterWeb.WorkerIndexLive`'s in-memory
  paging pattern for other bounded, non-tabular-query data.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Issue.Version
  alias ArbiterWeb.CoreComponents.{Core, Data, Feedback, Forms, Navigation}
  alias ArbiterWeb.Paging
  require Ash.Query

  @tabs [
    %{label: "All", value: "all"},
    %{label: "Human", value: "human"},
    %{label: "Machine", value: "machine"}
  ]

  @actor_hues ~w(--arb-live --arb-info --arb-proposal --arb-attention --arb-fail)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:tabs, @tabs)
     |> assign(:tab, "all")
     |> assign(:query, "")
     |> assign(:page, 1)
     |> load_events()}
  end

  @impl true
  def handle_event("filter-tab", %{"tab" => tab}, socket) do
    {:noreply, socket |> assign(:tab, tab) |> assign(:page, 1) |> load_events()}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:query, q) |> assign(:page, 1) |> load_events()}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(:page, Paging.parse_page(%{"page" => page})) |> load_events()}
  end

  # ---- data ----

  defp load_events(socket) do
    rows =
      read_events()
      |> filter_by_tab(socket.assigns.tab)
      |> filter_by_query(socket.assigns.query)

    page = Paging.paginate_list(rows, socket.assigns.page)

    socket
    |> assign(:events, page.entries)
    |> assign(:page_info, page)
  end

  defp read_events do
    Version
    |> Ash.Query.new()
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.Query.limit(500)
    |> Ash.read!()
    |> Enum.sort_by(& &1.version_inserted_at, {:asc, DateTime})
    |> annotate_transitions()
    |> Enum.reverse()
  end

  # Walk chronologically so a status change can show what it changed *from*,
  # not just what it changed to — `changes` (AshPaperTrail's changes_only
  # mode) only ever carries the new value.
  defp annotate_transitions(versions) do
    {rows, _last_status_by_subject} =
      Enum.map_reduce(versions, %{}, fn v, last_status ->
        subject = v.version_source_id
        changes = v.changes || %{}
        new_status = Map.get(changes, "status")

        transition = new_status && {Map.get(last_status, subject), new_status}

        last_status =
          if new_status, do: Map.put(last_status, subject, new_status), else: last_status

        row = %{
          id: v.id,
          at: v.version_inserted_at,
          actor: actor_of(v),
          subject: subject,
          action: v.version_action_name,
          transition: transition,
          changes: Map.delete(changes, "status")
        }

        {row, last_status}
      end)

    rows
  end

  defp actor_of(%{version_action_inputs: %{"change_origin" => origin}})
       when is_binary(origin) and origin != "",
       do: origin

  defp actor_of(_version), do: "system"

  defp actor_kind("system"), do: "machine"

  defp actor_kind(actor) do
    cond do
      String.starts_with?(actor, "worker:") -> "machine"
      String.starts_with?(actor, "loop:") -> "machine"
      actor == "coordinator" -> "machine"
      true -> "human"
    end
  end

  defp actor_hue(actor) do
    Enum.at(@actor_hues, :erlang.phash2(actor, length(@actor_hues)))
  end

  defp filter_by_tab(rows, "all"), do: rows
  defp filter_by_tab(rows, tab), do: Enum.filter(rows, &(actor_kind(&1.actor) == tab))

  defp filter_by_query(rows, query) when query in [nil, ""], do: rows

  defp filter_by_query(rows, query) do
    clauses = query |> String.split() |> Enum.map(&parse_clause/1)
    Enum.filter(rows, fn row -> Enum.all?(clauses, &matches_clause?(row, &1)) end)
  end

  defp parse_clause("subject:" <> v), do: {:subject, v}
  defp parse_clause("actor:" <> v), do: {:actor, v}
  defp parse_clause("action:" <> v), do: {:action, v}
  defp parse_clause(v), do: {:any, v}

  defp matches_clause?(row, {:subject, v}), do: contains?(row.subject, v)
  defp matches_clause?(row, {:actor, v}), do: contains?(row.actor, v)
  defp matches_clause?(row, {:action, v}), do: contains?(to_string(row.action), v)

  defp matches_clause?(row, {:any, v}) do
    contains?(row.subject, v) or contains?(row.actor, v) or contains?(to_string(row.action), v)
  end

  defp contains?(str, sub), do: String.contains?(String.downcase(str), String.downcase(sub))

  defp detail_text(%{transition: {old, new}}) when not is_nil(new) do
    if old, do: "#{old} → #{new}", else: new
  end

  defp detail_text(%{changes: changes}) do
    Enum.map_join(changes, ", ", fn {k, v} -> "#{k}=#{verbatim(v)}" end)
  end

  defp verbatim(v) when is_binary(v), do: v
  defp verbatim(v), do: inspect(v)

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6" id="audit-log">
        <div>
          <h1 class="text-2xl font-bold tracking-tight flex items-center gap-2">
            <Core.icon name="hero-clock" class="size-6 text-base-content/70" /> Audit log
          </h1>
          <p class="text-sm text-base-content/60 mt-1">
            {@page_info.total_count} matching events (of the 500 most recent), sourced from
            <code class="text-xs">ash_paper_trail</code>
            versions on <code class="text-xs">Arbiter.Tasks.Issue</code>.
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <Navigation.filter_tabs tabs={@tabs} active={@tab} event="filter-tab" />
          <form phx-change="search" class="flex-1 min-w-[240px]">
            <Forms.input
              type="text"
              name="q"
              id="audit-query"
              value={@query}
              placeholder="subject:bd-3o8mq1"
              mono
            />
          </form>
        </div>

        <Feedback.empty_state :if={@events == []} icon="hero-inbox" detail="No matching audit events.">
          Nothing here
        </Feedback.empty_state>

        <Data.data_table :if={@events != []} id="audit-table" rows={@events}>
          <:col :let={row} label="Time">
            <span class="text-xs text-base-content/60 font-mono tabular-nums whitespace-nowrap">
              {Calendar.strftime(row.at, "%Y-%m-%d %H:%M:%S")}
            </span>
          </:col>
          <:col :let={row} label="Actor">
            <span class="font-mono text-xs" style={"color: var(#{actor_hue(row.actor)});"}>
              {row.actor}
            </span>
          </:col>
          <:col :let={row} label="Subject">
            <code class="text-xs">{row.subject}</code>
          </:col>
          <:col :let={row} label="Action">
            <span class="font-mono text-xs">{row.action}</span>
          </:col>
          <:col :let={row} label="Detail">
            <span class="font-mono text-xs break-words">{detail_text(row)}</span>
          </:col>
        </Data.data_table>

        <Navigation.pager
          :if={@page_info.total_pages > 1}
          page={@page_info.page}
          total_pages={@page_info.total_pages}
          total_count={@page_info.total_count}
          event="page"
        />
      </div>
    </Layouts.app>
    """
  end
end
