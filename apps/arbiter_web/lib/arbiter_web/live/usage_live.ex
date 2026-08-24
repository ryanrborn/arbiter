defmodule ArbiterWeb.UsageLive do
  @moduledoc """
  LiveView at `/usage` — the operator-console redesign's spend dashboard
  (design handoff README §9).

  Renders the token-cost ledger rolled up three ways (by task, by model, by
  repo) plus the rework signal: tasks that needed more than one `:work`
  session, and what those extra sessions cost. Also surfaces the primary
  provider's 5h/7d rate-limit windows, sourced the same way `Layouts.app`'s
  nav quota bars are.

  Refresh-on-load only, same as the page it replaces (`live/usage_live.ex`
  v1) — no PubSub subscription since spend events aren't broadcast yet.

  Calls every redesigned component fully-qualified
  (`ArbiterWeb.CoreComponents.{Core,Domain,Feedback,Navigation}`) rather than
  through the bare `<.name>` tag: `ArbiterWeb.html_helpers/0` still imports
  the pre-redesign `ArbiterWeb.CoreComponents`/`ArbiterWeb.ListComponents`
  versions of `icon/1`, `button/1`, `index_header/1`, `live_badge/1`,
  `empty_state/1`, `filter_tabs/1`, `pager/1`, `see_all_link/1`, and
  `back_link/1` unqualified, so a bare call would silently render the old
  component instead.
  """

  use ArbiterWeb, :live_view
  import ArbiterWeb.QuotaHelpers

  alias Arbiter.Agents.ModelDisplay
  alias Arbiter.Tasks.Issue
  alias Arbiter.Usage
  alias Arbiter.Usage.Event
  alias ArbiterWeb.CoreComponents.{Data, Domain, Feedback, Navigation}
  require Ash.Query

  @ranges ~w(7d 30d all)
  @tabs ~w(by_task by_model by_repo)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:range, "30d")
     |> assign(:tab, "by_task")
     |> load_data()}
  end

  @impl true
  def handle_event("range", %{"option" => range}, socket) do
    range = if range in @ranges, do: range, else: "30d"
    {:noreply, socket |> assign(:range, range) |> load_data()}
  end

  def handle_event("tab", %{"tab" => tab}, socket) do
    tab = if tab in @tabs, do: tab, else: "by_task"
    {:noreply, assign(socket, :tab, tab)}
  end

  # ---- data ----

  defp load_data(socket) do
    since = since_for_range(socket.assigns.range)

    task_rollup = summarize!(by: :task, since: since)
    model_rollup = summarize!(by: :model, since: since)
    repo_rollup = summarize!(by: :repo, since: since)
    work_sessions = load_work_sessions(since)
    titles = load_titles(task_rollup)

    grand_cost = sum_cost(task_rollup)
    grand_tokens = sum_tokens(task_rollup)
    total_sessions = sum_rows(task_rollup)
    base_ids = base_ids(task_rollup)

    rework_buckets = rework_buckets(base_ids, work_sessions)
    rework_task_count = rework_buckets.two + rework_buckets.three_plus
    rework_extra_cost = rework_extra_cost(base_ids, work_sessions)

    socket
    |> assign(:grand_cost, grand_cost)
    |> assign(:grand_tokens, grand_tokens)
    |> assign(:total_sessions, total_sessions)
    |> assign(:total_tasks, length(base_ids))
    |> assign(:rework_task_count, rework_task_count)
    |> assign(:rework_extra_cost, rework_extra_cost)
    |> assign(:rework_buckets, rework_buckets)
    |> assign(:by_task_rows, build_by_task_rows(task_rollup, work_sessions, titles))
    |> assign(
      :model_bars,
      bar_rows(model_rollup, grand_cost, &model_hue/2, &ModelDisplay.short/1)
    )
    |> assign(:repo_bars, bar_rows(repo_rollup, grand_cost, &repo_hue/2, &to_string/1))
    |> assign_overage()
  end

  # Overage-spend indicator (bd-7cd38f): when the Claude quota snapshot shows
  # the default workspace is dispatching past the plan cap (`:continue`
  # mode), surface the windowed overage spend in the Rate limits panel.
  # Sourced from the same windowed `Usage.summarize/1` sum the gate uses for
  # the alert threshold.
  defp assign_overage(socket) do
    quota = Enum.find(socket.assigns[:quotas] || [], &(&1.provider == "claude"))
    ws_id = socket.assigns[:_quota_workspace_id]

    {spend, in_overage?} =
      case {quota, ws_id} do
        {%{overage_status: "in_overage"} = q, ws} when is_binary(ws) ->
          {Arbiter.Quota.Overage.windowed_spend(%{id: ws}, q), true}

        _ ->
          {0.0, false}
      end

    socket
    |> assign(:overage_spend, spend)
    |> assign(:in_overage, in_overage?)
  end

  defp summarize!(opts) do
    case Usage.summarize(opts) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp since_for_range("7d"), do: DateTime.add(DateTime.utc_now(), -7, :day)
  defp since_for_range("30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
  defp since_for_range(_), do: nil

  # Tasks with more than one `:work` row are re-dispatchs — the rework story.
  # Queried directly (not via `Usage.summarize/1`, which lumps every step
  # together per task) so the session count is `:work` sessions specifically.
  defp load_work_sessions(since) do
    base_query = Ash.Query.filter(Event, step == :work)

    query =
      case since do
        nil -> base_query
        dt -> Ash.Query.filter(base_query, occurred_at >= ^dt)
      end

    query
    |> Ash.read!()
    |> Enum.group_by(&base_task_id/1)
    |> Map.new(fn {task_id, events} ->
      sorted = Enum.sort_by(events, & &1.occurred_at, DateTime)
      total = Enum.reduce(sorted, 0.0, fn ev, acc -> acc + (ev.cost_usd || 0.0) end)
      first_cost = hd(sorted).cost_usd || 0.0

      {task_id, %{sessions: length(sorted), extra_cost: total - first_cost}}
    end)
  rescue
    _ -> %{}
  end

  defp base_task_id(%{task_id: task_id}), do: base_task_id(task_id)

  defp base_task_id(task_id) when is_binary(task_id),
    do: task_id |> String.split("#", parts: 2) |> hd()

  defp base_task_id(task_id), do: to_string(task_id)

  defp load_titles(task_rollup) do
    base_ids = task_rollup |> Enum.map(&base_task_id(&1.group)) |> Enum.uniq()

    case base_ids do
      [] ->
        %{}

      ids ->
        Issue
        |> Ash.Query.filter(id in ^ids)
        |> Ash.read!()
        |> Map.new(&{&1.id, &1.title})
    end
  rescue
    _ -> %{}
  end

  # Reviewer/implementer sessions write suffixed task ids (`bd-x#review`,
  # `bd-x#review#impl1`), so `task_rollup` (grouped on the raw task_id) has
  # one row per synthetic id for what is really a single task. Collapse to
  # unique base ids before counting tasks or summing rework — otherwise one
  # real task is counted once per synthetic row.
  defp base_ids(task_rollup), do: task_rollup |> Enum.map(&base_task_id(&1.group)) |> Enum.uniq()

  defp build_by_task_rows(task_rollup, work_sessions, titles) do
    task_rollup
    |> Enum.group_by(&base_task_id(&1.group))
    |> Enum.map(fn {base_id, rows} ->
      ws = Map.get(work_sessions, base_id, %{sessions: 0, extra_cost: 0.0})

      %{
        task_id: base_id,
        title: Map.get(titles, base_id, "—"),
        sessions: ws.sessions,
        extra_cost: ws.extra_cost,
        tokens:
          Enum.reduce(rows, 0, fn r, acc -> acc + (r.tokens_in || 0) + (r.tokens_out || 0) end),
        cost_usd: Enum.reduce(rows, 0.0, fn r, acc -> acc + (r.total_cost_usd || 0.0) end)
      }
    end)
    |> Enum.sort_by(&(-&1.cost_usd))
    |> Enum.take(20)
  end

  defp rework_buckets(base_ids, work_sessions) do
    counts =
      base_ids
      |> Enum.map(fn base_id ->
        Map.get(work_sessions, base_id, %{sessions: 1}).sessions
      end)
      |> Enum.frequencies_by(fn
        n when n <= 1 -> :one
        2 -> :two
        _ -> :three_plus
      end)

    %{
      one: Map.get(counts, :one, 0),
      two: Map.get(counts, :two, 0),
      three_plus: Map.get(counts, :three_plus, 0)
    }
  end

  defp rework_extra_cost(base_ids, work_sessions) do
    base_ids
    |> Enum.reduce(0.0, fn base_id, acc ->
      acc + Map.get(work_sessions, base_id, %{extra_cost: 0.0}).extra_cost
    end)
  end

  defp bar_rows(rollup, total_cost, hue_fn, label_fn) do
    rollup
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      pct = if total_cost > 0, do: round(row.total_cost_usd / total_cost * 100), else: 0
      label = label_fn.(to_string(row.group))

      %{
        label: label,
        value: format_usd(row.total_cost_usd),
        pct: pct,
        hue: hue_fn.(label, index)
      }
    end)
  end

  defp model_hue("Sonnet", _index), do: "var(--arb-live)"
  defp model_hue("Opus", _index), do: "var(--arb-proposal)"
  defp model_hue("Haiku", _index), do: "var(--arb-info)"
  defp model_hue(_model, _index), do: "var(--arb-done)"

  defp repo_hue(_repo, 0), do: "var(--arb-live)"
  defp repo_hue(_repo, 1), do: "var(--arb-info)"
  defp repo_hue(_repo, _index), do: "var(--arb-done)"

  defp sum_cost(rollup),
    do: Enum.reduce(rollup, 0.0, fn r, acc -> acc + (r.total_cost_usd || 0.0) end)

  defp sum_tokens(rollup),
    do: Enum.reduce(rollup, 0, fn r, acc -> acc + (r.tokens_in || 0) + (r.tokens_out || 0) end)

  defp sum_rows(rollup), do: Enum.reduce(rollup, 0, fn r, acc -> acc + (r.rows || 0) end)

  defp format_usd(nil), do: "—"

  defp format_usd(amount) when is_float(amount) or is_integer(amount) do
    f = amount * 1.0

    cond do
      f == 0.0 -> "$0.00"
      f < 0.01 -> "$#{:erlang.float_to_binary(f, decimals: 6)}"
      f < 1.0 -> "$#{:erlang.float_to_binary(f, decimals: 4)}"
      true -> "$#{:erlang.float_to_binary(f, decimals: 2)}"
    end
  end

  defp format_tokens(nil), do: "—"
  defp format_tokens(n) when n in [0, 0.0], do: "0"

  defp format_tokens(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 2)}M"
  end

  defp format_tokens(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}k"
  end

  defp format_tokens(n) when is_integer(n), do: Integer.to_string(n)

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto flex flex-col gap-4">
        <Domain.index_header
          icon="hero-clock"
          title="Usage"
          subtitle={"Actual spend over the #{since_label(@range)} from the usage ledger. Rework is the number to watch — extra sessions on one task."}
        >
          <:actions>
            <div class="flex items-center gap-3">
              <.segmented_control options={~w(7d 30d all)} value={@range} event="range" />
              <Feedback.live_badge id="usage-live" />
            </div>
          </:actions>
        </Domain.index_header>

        <div class="grid grid-cols-4 gap-3">
          <Domain.stat_card
            label="Total spend"
            value={format_usd(@grand_cost)}
            tone="live"
            note={since_label(@range)}
          />
          <Domain.stat_card label="Total tokens" value={format_tokens(@grand_tokens)} />
          <Domain.stat_card
            label="Sessions"
            value={@total_sessions}
            note={"#{@total_tasks} tasks"}
          />
          <Domain.stat_card
            label="Rework tasks"
            value={@rework_task_count}
            tone="attention"
            note="2+ sessions"
          />
        </div>

        <div class="grid grid-cols-[minmax(0,1fr)_320px] gap-4 items-start">
          <.panel title="Spend" meta={tab_meta(@tab)}>
            <Navigation.filter_tabs
              tabs={[
                %{label: "By task", value: "by_task"},
                %{label: "By model", value: "by_model"},
                %{label: "By repo", value: "by_repo"}
              ]}
              active={@tab}
              event="tab"
              class="mb-3"
            />

            <Data.data_table
              :if={@tab == "by_task" && @by_task_rows != []}
              id="usage-by-task"
              rows={@by_task_rows}
            >
              <:col :let={row} label="task" width="84px">{row.task_id}</:col>
              <:col :let={row} label="title" mono={false}>{row.title}</:col>
              <:col :let={row} label="sessions" width="70px" align="right">
                <span
                  class={row.sessions > 1 && "text-[var(--arb-attention)]"}
                  title="Number of :work sessions for this task"
                >
                  {row.sessions}
                </span>
              </:col>
              <:col :let={row} label="rework" width="64px" align="right">
                <span
                  class={
                    if row.extra_cost > 0,
                      do: "text-[var(--arb-attention)]",
                      else: "text-[var(--text-label)]"
                  }
                  title="Extra sessions cost (sessions beyond the first)"
                >
                  {if row.extra_cost > 0, do: format_usd(row.extra_cost), else: "—"}
                </span>
              </:col>
              <:col :let={row} label="tokens" width="64px" align="right">
                {format_tokens(row.tokens)}
              </:col>
              <:col :let={row} label="spend" width="60px" align="right">
                {format_usd(row.cost_usd)}
              </:col>
            </Data.data_table>
            <Feedback.empty_state :if={@tab == "by_task" && @by_task_rows == []} icon={nil}>
              No usage events yet.
            </Feedback.empty_state>

            <div :if={@tab == "by_model"} class="flex flex-col gap-[10px]">
              <.usage_bar
                :for={bar <- @model_bars}
                label={bar.label}
                value={bar.value}
                pct={bar.pct}
                hue={bar.hue}
              />
              <Feedback.empty_state :if={@model_bars == []} icon={nil}>
                No usage events yet.
              </Feedback.empty_state>
            </div>

            <div :if={@tab == "by_repo"} class="flex flex-col gap-[10px]">
              <.usage_bar
                :for={bar <- @repo_bars}
                label={bar.label}
                value={bar.value}
                pct={bar.pct}
                hue={bar.hue}
              />
              <Feedback.empty_state :if={@repo_bars == []} icon={nil}>
                No usage events yet.
              </Feedback.empty_state>
            </div>
          </.panel>

          <div class="flex flex-col gap-4">
            <.panel title="Rate limits" meta="live">
              <div class="flex flex-col gap-3">
                <div :for={quota <- @quotas} class="flex flex-col gap-[3px]">
                  <span class="text-[9.5px] uppercase tracking-[0.08em] leading-none text-[var(--text-label)] font-[family-name:var(--font-mono)]">
                    {quota_provider_label(quota.provider)}
                  </span>
                  <div class="flex flex-col gap-[6px]">
                    <Feedback.quota_bar
                      provider={quota.provider}
                      show_label={false}
                      window="5h"
                      utilization={quota.utilization_5h}
                      reset_at={quota.reset_5h_at}
                      overage_status={quota.overage_status}
                      representative_claim={quota.representative_claim}
                      width={170}
                    />
                    <Feedback.quota_bar
                      provider={quota.provider}
                      show_label={false}
                      window="7d"
                      utilization={quota.utilization_7d}
                      reset_at={quota.reset_7d_at}
                      overage_status={quota.overage_status}
                      representative_claim={quota.representative_claim}
                      width={170}
                    />
                  </div>
                </div>
                <p class="m-0 text-[11.5px] leading-[1.55] text-[var(--text-secondary)]">
                  The hairline is elapsed time. Bar past the line means you are burning faster than the window.
                </p>
                <p
                  :if={@in_overage}
                  id="overage-indicator"
                  class="m-0 text-[11.5px] leading-[1.55] text-[var(--arb-fail)]"
                >
                  Paid overage active — approximately
                  <span class="font-[family-name:var(--font-mono)] font-semibold">
                    {format_usd(@overage_spend)}
                  </span>
                  spent this 5h window past the plan cap.
                </p>
              </div>
            </.panel>

            <.panel title="Rework" meta={"#{@rework_task_count} tasks"}>
              <div class="flex flex-col gap-[10px]">
                <.usage_bar
                  label="1 session"
                  value={"#{@rework_buckets.one} tasks"}
                  pct={bucket_pct(@rework_buckets.one, @total_tasks)}
                  hue="var(--arb-done)"
                />
                <.usage_bar
                  label="2 sessions"
                  value={"#{@rework_buckets.two} tasks"}
                  pct={bucket_pct(@rework_buckets.two, @total_tasks)}
                  hue="var(--arb-attention)"
                />
                <.usage_bar
                  label="3+"
                  value={"#{@rework_buckets.three_plus} tasks"}
                  pct={bucket_pct(@rework_buckets.three_plus, @total_tasks)}
                  hue="var(--arb-fail)"
                />
                <p class="m-0 text-[11.5px] leading-[1.55] text-[var(--text-secondary)]">
                  Extra sessions cost {format_usd(@rework_extra_cost)} over the {since_label(@range)} — the loop pass reads this to propose routing changes.
                </p>
              </div>
            </.panel>
          </div>
        </div>

        <Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :pct, :integer, required: true
  attr :hue, :string, required: true

  defp usage_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-[10px]">
      <span
        class="w-[74px] shrink-0 truncate text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]"
        title={@label}
      >
        {@label}
      </span>
      <span class="relative flex-1 h-[8px] rounded-[var(--radius-pill)] bg-[var(--arb-done-wash)] overflow-hidden">
        <span
          class="absolute inset-y-0 left-0 rounded-[var(--radius-pill)]"
          style={"width: #{@pct}%; background-color: #{@hue};"}
        />
      </span>
      <span class="w-[56px] shrink-0 text-right text-[11px] tabular-nums font-[family-name:var(--font-mono)] text-[var(--text-body)]">
        {@value}
      </span>
    </div>
    """
  end

  defp since_label("7d"), do: "last 7 days"
  defp since_label("30d"), do: "last 30 days"
  defp since_label(_), do: "all time"

  defp tab_meta("by_task"), do: "by task"
  defp tab_meta("by_model"), do: "by model"
  defp tab_meta("by_repo"), do: "by repo"

  defp bucket_pct(_count, 0), do: 0
  defp bucket_pct(count, total), do: round(count / total * 100)
end
