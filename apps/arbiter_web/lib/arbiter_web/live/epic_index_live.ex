defmodule ArbiterWeb.EpicIndexLive do
  @moduledoc """
  The `/epics` list — §2 of the bd-2s901b design, built by bd-2wmxt5.

  Epics no longer appear on the board (bd-2s901b §4 removed them from the one
  column they still leaked into), so this page is where they live. Each row is
  one epic with its child-progress rollup: `closed/total`, a stacked bar broken
  into the five board buckets, the `auto_close` marker, age, and whatever stuck
  signals its children raise.

  ## The attention state: `needs_you`

  bd-58z2tu: every open epic with a dependency chain has *some* blocked
  child, so flagging on that alone made the attention state permanently on
  — no signal. `Arbiter.Tasks.EpicRollup` now derives a single `needs_you`
  boolean instead: true only when at least one child is parked in
  `awaiting_verification`, a child's own live worker needs the operator
  (shared with the board's `needs_you?`), or a child is blocked only by
  something that itself needs the operator (parked, awaiting verification,
  or unrefined). That drives the row's attention style, its reason chips,
  and the default sort. `blocked_children` and `idle_with_ready_work` stay
  on the row as neutral informational chips — the machine may still be on
  either of those — rather than triggering the attention style.

  ## Filtering and sorting

  Workspace and open/closed/all are pushed into the `Ash.Query`;
  has-blocked-children is applied to the rollups afterwards, since "blocked" is
  a property of an epic's *children's* edges and has no column to filter on.
  All three combine freely. Every bit of that state — plus the sort —
  round-trips through the URL via `push_patch`, so a filtered view is
  shareable, same as `ArbiterWeb.TaskIndexLive`.

  The default sort is stuck-first, then most recent child activity, then
  oldest-first: the epics that need attention, then the ones actually moving.
  The dropdown also offers age, % complete, and title.

  ## Live updates

  Subscribes to the existing `"tasks"` topic (§6). Any issue lifecycle event
  re-reads the page — a *child's* transition is what moves its epic's row, and
  the child broadcasts on the same topic as everything else, so no epic-specific
  topic is needed.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage

  require Ash.Query

  @tasks_topic "tasks"

  @status_tabs [
    %{label: "Open", value: "open"},
    %{label: "Closed", value: "closed"},
    %{label: "All", value: "all"}
  ]

  @sorts ~w(stuck age percent title)a
  @sort_labels %{
    stuck: "Stuck first",
    age: "Age (oldest first)",
    percent: "% complete",
    title: "Title"
  }

  # The five buckets, in board order — one source for the breakdown line, the
  # stacked bar, and their colors.
  @buckets [
    {:backlog, "backlog", "var(--text-label)"},
    {:ready, "ready", "var(--accent-primary)"},
    {:running, "running", "var(--arb-live)"},
    {:waiting, "waiting", "var(--arb-attention)"},
    {:closed, "closed", "var(--arb-ok)"}
  ]

  @default_filters %{status: :open, workspace: nil, blocked: false, sort: :stuck}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)

    {:ok,
     socket
     |> assign(:status_tabs, @status_tabs)
     |> assign(:sort_options, Enum.map(@sorts, &{@sort_labels[&1], Atom.to_string(&1)}))
     |> assign(:buckets, @buckets)
     |> assign(:workspaces, load_workspaces())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:f, parse_filters(params))
     |> refresh()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    # The status tabs live outside the form, so carry the current one across
    # rather than letting an unrelated change reset it.
    params = Map.put(params, "status", Atom.to_string(socket.assigns.f.status))
    {:noreply, push_patch(socket, to: epic_path(parse_filters(params)))}
  end

  # Any issue transition can move a row: a child's status changes its epic's
  # breakdown and stuck chips, and an epic's own close moves it between tabs.
  @impl true
  def handle_info({:task_lifecycle, _event, _issue}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---- data ----

  defp refresh(socket) do
    f = socket.assigns.f
    epic = :epic

    epics =
      Issue
      |> Ash.Query.filter(issue_type == ^epic)
      |> filter_by_status(f.status)
      |> filter_by_workspace(f.workspace)
      |> Ash.read!()

    rollups = Tasks.epic_rollups(epics)
    workspaces = Map.new(socket.assigns.workspaces, &{&1.id, &1})
    sample = Arbiter.Usage.Estimate.sample()

    rows =
      epics
      |> Enum.map(fn e ->
        %{
          epic: e,
          rollup: Map.fetch!(rollups, e.id),
          cost_rollup: Usage.epic_cost_rollup(e, sample: sample),
          workspace_name: workspace_name(workspaces, e.workspace_id)
        }
      end)
      |> filter_by_blocked(f.blocked)
      |> sort_rows(f.sort)

    socket
    |> assign(:rows, rows)
    |> assign(:total_count, length(rows))
  end

  defp load_workspaces, do: Workspace |> Ash.read!() |> Enum.sort_by(& &1.name)

  defp workspace_name(workspaces, id) do
    case Map.get(workspaces, id) do
      %{name: name} -> name
      _ -> id
    end
  end

  defp filter_by_status(query, :all), do: query

  defp filter_by_status(query, :closed) do
    closed = :closed
    Ash.Query.filter(query, status == ^closed)
  end

  defp filter_by_status(query, :open) do
    closed = :closed
    Ash.Query.filter(query, status != ^closed)
  end

  defp filter_by_workspace(query, nil), do: query
  defp filter_by_workspace(query, id), do: Ash.Query.filter(query, workspace_id == ^id)

  defp filter_by_blocked(rows, false), do: rows
  defp filter_by_blocked(rows, true), do: Enum.filter(rows, &(&1.rollup.blocked_children > 0))

  # ---- sorting ----

  # Erlang term order does the work, so every key component is an integer or an
  # atom that compares the right way against one: `:infinity` sorts after any
  # integer, which is exactly where an epic with no child activity belongs.
  defp sort_rows(rows, :stuck) do
    Enum.sort_by(rows, &{stuck_rank(&1), activity_key(&1), age_key(&1)})
  end

  defp sort_rows(rows, :age), do: Enum.sort_by(rows, &age_key/1)

  defp sort_rows(rows, :percent),
    do: Enum.sort_by(rows, &{-&1.rollup.percent_complete, title_key(&1)})

  defp sort_rows(rows, :title), do: Enum.sort_by(rows, &title_key/1)

  defp stuck_rank(%{rollup: %{needs_you: true}}), do: 0
  defp stuck_rank(_row), do: 1

  defp activity_key(%{rollup: %{last_child_activity_at: %DateTime{} = at}}),
    do: -DateTime.to_unix(at, :microsecond)

  defp activity_key(_row), do: :infinity

  defp age_key(%{epic: %{created_at: %DateTime{} = at}}), do: DateTime.to_unix(at, :microsecond)
  defp age_key(_row), do: :infinity

  defp title_key(%{epic: %{title: title}}) when is_binary(title), do: String.downcase(title)
  defp title_key(_row), do: ""

  # ---- URL <-> filter-state ----

  defp parse_filters(params) do
    %{
      status: parse_status(params),
      workspace: parse_present_string(params, "workspace"),
      blocked: parse_blocked(params),
      sort: parse_sort(params)
    }
  end

  defp parse_status(%{"status" => s}) when s in ~w(open closed all),
    do: String.to_existing_atom(s)

  defp parse_status(_), do: @default_filters.status

  defp parse_present_string(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp parse_blocked(params), do: Map.get(params, "blocked") in ["1", "true", "on"]

  defp parse_sort(%{"sort" => s}) when s in ~w(stuck age percent title),
    do: String.to_existing_atom(s)

  defp parse_sort(_), do: @default_filters.sort

  defp epic_path(f) do
    %{}
    |> put_param(:status, f.status, @default_filters.status)
    |> put_param(:workspace, f.workspace, @default_filters.workspace)
    |> put_param(:blocked, (f.blocked && "1") || nil, nil)
    |> put_param(:sort, f.sort, @default_filters.sort)
    |> then(&~p"/epics?#{&1}")
  end

  defp put_param(params, _key, default, default), do: params
  defp put_param(params, key, value, _default), do: Map.put(params, key, value)

  defp active_filter_summary(f, workspaces) do
    [
      f.status != @default_filters.status && "status: #{f.status}",
      f.workspace &&
        "workspace: #{workspace_name(Map.new(workspaces, &{&1.id, &1}), f.workspace)}",
      f.blocked && "has blocked children",
      f.sort != @default_filters.sort && "sort: #{@sort_labels[f.sort]}"
    ]
    |> Enum.filter(&is_binary/1)
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :active_filters, active_filter_summary(assigns.f, assigns.workspaces))

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
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <%!-- `flex-wrap`: the shared header is a single non-wrapping row, and at
             ~400px its actions are pushed past the viewport edge (measured by
             `ArbiterWeb.EpicPageBrowserTest`). Wrapping is applied here rather
             than in the component so the other index pages keep the layout
             their own screenshots were taken against. --%>
        <ArbiterWeb.CoreComponents.Domain.index_header
          class="flex-wrap"
          icon="hero-rectangle-stack"
          title="Epics"
          count={@total_count}
          subtitle="Parent issues and how their children are moving. Epics are deliberately absent from the board — this is where they live."
        >
          <:actions>
            <ArbiterWeb.CoreComponents.Feedback.live_badge live={@live} />
            <ArbiterWeb.CoreComponents.Core.button
              type="button"
              variant="primary"
              size="sm"
              phx-click={JS.navigate(~p"/tasks/new")}
            >
              <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-plus" size={13} /></:icon>
              New epic
            </ArbiterWeb.CoreComponents.Core.button>
          </:actions>
        </ArbiterWeb.CoreComponents.Domain.index_header>

        <ArbiterWeb.CoreComponents.Navigation.filter_tabs
          tabs={@status_tabs}
          active={Atom.to_string(@f.status)}
          tab_path={fn value -> epic_path(%{@f | status: String.to_existing_atom(value)}) end}
        />

        <form
          id="epics-filter-form"
          phx-change="filter"
          class="flex flex-wrap items-center gap-2.5 p-3 rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--arb-canvas-sunken)]"
        >
          <ArbiterWeb.CoreComponents.Forms.select
            name="workspace"
            id="epics-filter-workspace"
            size="sm"
            prompt="Any workspace"
            value={@f.workspace || ""}
            options={Enum.map(@workspaces, &{&1.name, &1.id})}
          />

          <ArbiterWeb.CoreComponents.Forms.checkbox
            name="blocked"
            id="epics-filter-blocked"
            label="Has blocked children"
            checked={@f.blocked}
            value="1"
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="sort"
            id="epics-filter-sort"
            size="sm"
            value={Atom.to_string(@f.sort)}
            options={@sort_options}
            class="sm:ml-auto"
          />

          <.link
            :if={@active_filters != []}
            id="epics-clear-filters"
            patch={~p"/epics"}
            class="text-[11.5px] text-[var(--text-link)] hover:underline whitespace-nowrap"
          >
            Clear filters
          </.link>
        </form>

        <div :if={@active_filters != []} id="epics-active-filters" class="flex flex-wrap gap-1.5">
          <span
            :for={label <- @active_filters}
            class="badge badge-ghost text-[10.5px] font-[family-name:var(--font-mono)]"
          >
            {label}
          </span>
        </div>

        <ArbiterWeb.CoreComponents.Core.panel body_class="flex flex-col gap-4">
          <div :if={@rows == []} id="epics-empty">
            <ArbiterWeb.CoreComponents.Feedback.empty_state icon="hero-rectangle-stack">
              No epics match
              <%= if @active_filters != [] do %>
                the active filters ({Enum.join(@active_filters, ", ")}).
              <% else %>
                this filter.
              <% end %>
            </ArbiterWeb.CoreComponents.Feedback.empty_state>
          </div>

          <ul :if={@rows != []} id="epics" class="flex flex-col gap-1.5">
            <.epic_row :for={row <- @rows} row={row} buckets={@buckets} />
          </ul>
        </ArbiterWeb.CoreComponents.Core.panel>

        <ArbiterWeb.CoreComponents.Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true
  attr :buckets, :list, required: true

  # Two columns above `sm` — identity on the left, progress on the right — and
  # a single stacked column below it, so the row still reads at ~400px.
  defp epic_row(assigns) do
    ~H"""
    <li id={"epic-#{@row.epic.id}"} class={row_class(@row)}>
      <div class="min-w-0 flex-1 flex flex-col gap-1">
        <div class="flex flex-wrap items-center gap-2">
          <ArbiterWeb.CoreComponents.Core.icon
            :if={@row.rollup.needs_you}
            name="hero-exclamation-triangle-micro"
            color="var(--arb-attention)"
          />
          <.link navigate={~p"/tasks/#{@row.epic.id}"} class="min-w-0 flex items-center gap-2 group">
            <span class="font-[family-name:var(--font-mono)] text-[10.5px] text-[var(--text-secondary)] shrink-0 group-hover:text-[var(--text-link)] transition-colors">
              {@row.epic.id}
            </span>
            <span
              class="truncate text-[12.5px] font-medium text-[var(--text-title)] group-hover:text-[var(--text-link)] transition-colors"
              title={@row.epic.title}
            >
              {@row.epic.title}
            </span>
          </.link>
          <span id={"epic-#{@row.epic.id}-status"}>
            <.status_chip status={@row.epic.status} class="text-[10px]" />
          </span>
        </div>

        <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-[10.5px] text-[var(--text-secondary)] font-[family-name:var(--font-mono)]">
          <span id={"epic-#{@row.epic.id}-workspace"}>{@row.workspace_name}</span>
          <span aria-hidden="true">·</span>
          <span id={"epic-#{@row.epic.id}-age"} title={@row.epic.created_at}>
            {relative_age(@row.epic.created_at)}
          </span>
          <span
            :if={@row.epic.auto_close}
            id={"epic-#{@row.epic.id}-auto-close"}
            class="inline-flex items-center gap-1 badge badge-ghost text-[9.5px]"
            title="auto-closes when all children close"
          >
            <ArbiterWeb.CoreComponents.Core.icon name="hero-lock-closed-micro" size={11} /> auto
          </span>
        </div>

        <%!-- bd-18vl9q, design bd-9jj5lf §4: the compact cost rollup — worker
             spend only (excludes coordinator-session overhead). --%>
        <div
          :if={@row.cost_rollup}
          id={"epic-#{@row.epic.id}-cost-rollup"}
          class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]"
          title="Worker spend only — excludes coordinator session overhead"
        >
          {cost_rollup_label(@row.cost_rollup)}
        </div>

        <div
          :if={@row.rollup.needs_you}
          class="flex flex-wrap items-center gap-1.5"
          data-role="needs-you-chips"
        >
          <span
            :for={{reason, index} <- Enum.with_index(@row.rollup.needs_you_reasons)}
            id={"epic-#{@row.epic.id}-needs-you-#{index}"}
            class="badge text-[9.5px] font-[family-name:var(--font-mono)] bg-[var(--arb-attention-wash)] border-[color:var(--arb-attention-edge)] text-[var(--arb-attention-ink)]"
          >
            {reason}
          </span>
        </div>

        <div
          :if={@row.rollup.blocked_children > 0 or @row.rollup.idle_with_ready_work}
          class="flex flex-wrap items-center gap-1.5"
          data-role="info-chips"
        >
          <span
            :if={@row.rollup.blocked_children > 0}
            id={"epic-#{@row.epic.id}-chip-blocked"}
            class="badge badge-ghost text-[9.5px] font-[family-name:var(--font-mono)]"
          >
            {@row.rollup.blocked_children} blocked
          </span>
          <span
            :if={@row.rollup.idle_with_ready_work}
            id={"epic-#{@row.epic.id}-chip-idle"}
            class="badge badge-ghost text-[9.5px] font-[family-name:var(--font-mono)]"
          >
            queued
          </span>
        </div>
      </div>

      <div class="flex-none w-full sm:w-[300px] flex flex-col gap-1">
        <div class="flex items-baseline justify-between gap-2">
          <span
            id={"epic-#{@row.epic.id}-progress"}
            class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]"
          >
            {@row.rollup.closed}/{@row.rollup.total} closed
          </span>
          <span class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
            {@row.rollup.percent_complete}%
          </span>
        </div>

        <div
          class="flex h-[6px] w-full overflow-hidden rounded-[var(--radius-pill)] bg-[var(--surface-raised)]"
          role="img"
          aria-label={"#{@row.rollup.closed} of #{@row.rollup.total} children closed"}
        >
          <span
            :for={{key, label, color} <- @buckets}
            :if={Map.fetch!(@row.rollup.counts, key) > 0}
            class="h-full transition-[width] duration-[var(--dur-hover)]"
            style={"width: #{segment_pct(@row.rollup, key)}%; background: #{color};"}
            title={"#{label}: #{Map.fetch!(@row.rollup.counts, key)}"}
          >
          </span>
        </div>

        <div
          id={"epic-#{@row.epic.id}-breakdown"}
          class="flex flex-wrap gap-x-2 text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
        >
          <span :for={{key, label, color} <- @buckets} class="inline-flex items-center gap-1">
            <span class="inline-block size-[6px] rounded-full" style={"background: #{color};"} />
            {label} {Map.fetch!(@row.rollup.counts, key)}
          </span>
        </div>
      </div>
    </li>
    """
  end

  # ---- view helpers ----

  defp row_class(row) do
    [
      "flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-4 px-3 py-2.5",
      "rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)]",
      "hover:bg-[var(--arb-raised-hover)] transition-colors duration-[var(--dur-hover)]",
      if(row.rollup.needs_you,
        do: [
          "bg-[var(--arb-attention-wash)]",
          "border-l-[length:var(--border-accent-width)] border-l-[color:var(--arb-attention)]"
        ],
        else: "bg-[var(--surface-card)]"
      ),
      row.epic.status == :closed && "opacity-[0.62]"
    ]
  end

  defp segment_pct(%{total: 0}, _key), do: 0

  defp segment_pct(rollup, key),
    do: Float.round(Map.fetch!(rollup.counts, key) * 100 / rollup.total, 2)

  # Relative age, coarsest unit that still says something: `41m ago`, `2d ago`.
  defp relative_age(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      seconds < 60 -> "#{max(seconds, 0)}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp relative_age(_), do: "—"

  # bd-18vl9q: "$X spent · ~$Y-Z to go" (design bd-9jj5lf §4). Upcoming
  # (unpromoted Backlog) spend is deliberately not in the headline range —
  # only committed, dispatchable work shapes the "to go" number.
  defp cost_rollup_label(%{spent: spent, to_go_low: lo, to_go_high: hi}) do
    "#{money(spent)} spent · ~#{money(lo)}–#{money(hi)} to go"
  end

  defp money(n), do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)
end
