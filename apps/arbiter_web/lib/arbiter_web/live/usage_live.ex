defmodule ArbiterWeb.UsageLive do
  @moduledoc """
  LiveView at `/usage` — spend dashboard over the token-cost ledger.

  Renders per-day, per-provider, per-model, and per-step rollups sourced from
  `Arbiter.Usage.summarize/1`. Also surfaces the top beads by cost and the
  rework signal (beads with more than one `:work` row — re-slings).

  Refresh-on-load only for v1; PubSub live updates are a Phase 5 add-on once
  spend events are broadcast.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Usage
  alias Arbiter.Usage.Event
  require Ash.Query

  @by_options ~w(day provider model step)a
  @since_options [
    {"7 days", 7},
    {"30 days", 30},
    {"90 days", 90},
    {"All time", nil}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:by, :day)
     |> assign(:since_days, 30)
     |> assign(:by_options, @by_options)
     |> assign(:since_options, @since_options)
     |> load_data()}
  end

  @impl true
  def handle_event("set_by", %{"by" => by_str}, socket) do
    by =
      case by_str do
        v when v in ~w(day provider model step) -> String.to_existing_atom(v)
        _ -> :day
      end

    {:noreply, socket |> assign(:by, by) |> load_data()}
  end

  def handle_event("set_since", %{"since_days" => days_str}, socket) do
    since_days =
      case Integer.parse(days_str) do
        {n, ""} when n > 0 -> n
        _ -> nil
      end

    {:noreply, socket |> assign(:since_days, since_days) |> load_data()}
  end

  # ---- data ----

  defp load_data(socket) do
    by = socket.assigns.by
    since_days = socket.assigns.since_days
    since = since_dt(since_days)

    main_rollup =
      case Usage.summarize(by: by, since: since) do
        {:ok, rows} -> rows
        _ -> []
      end

    top_beads =
      case Usage.summarize(by: :bead, since: since, limit: 20) do
        {:ok, rows} -> rows
        _ -> []
      end

    rework_beads = load_rework_beads(since)

    socket
    |> assign(:main_rollup, main_rollup)
    |> assign(:top_beads, top_beads)
    |> assign(:rework_beads, rework_beads)
    |> assign(:grand_cost, sum_cost(main_rollup))
    |> assign(:grand_tokens, sum_tokens(main_rollup))
  end

  defp since_dt(nil), do: nil

  defp since_dt(days) when is_integer(days) and days > 0 do
    DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)
  end

  # Beads with more than one :work row — re-slings, which is the rework story
  # #77 was built to expose. Queries :work events directly rather than going
  # through summarize/1 because summarize groups all steps together per bead.
  defp load_rework_beads(since) do
    base_query = Ash.Query.filter(Event, step == :work)

    query =
      case since do
        nil -> base_query
        dt -> Ash.Query.filter(base_query, occurred_at >= ^dt)
      end

    query
    |> Ash.read!()
    |> Enum.group_by(fn ev ->
      ev.bead_id |> String.split("#", parts: 2) |> hd()
    end)
    |> Enum.filter(fn {_bead_id, events} -> length(events) > 1 end)
    |> Enum.map(fn {bead_id, events} ->
      %{
        bead_id: bead_id,
        work_sessions: length(events),
        total_cost_usd: Enum.reduce(events, 0.0, fn ev, acc -> acc + (ev.cost_usd || 0.0) end)
      }
    end)
    |> Enum.sort_by(fn r -> -(r.total_cost_usd || 0.0) end)
  rescue
    _ -> []
  end

  defp sum_cost(rollup) do
    Enum.reduce(rollup, 0.0, fn r, acc -> acc + (r.total_cost_usd || 0.0) end)
  end

  defp sum_tokens(rollup) do
    Enum.reduce(rollup, 0, fn r, acc -> acc + (r.tokens_in || 0) + (r.tokens_out || 0) end)
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="p-6 max-w-7xl mx-auto space-y-6">
        <%!-- ── Header ───────────────────────────────────────────────── --%>
        <div>
          <h1 class="text-2xl font-bold tracking-tight flex items-center gap-2">
            <.icon name="hero-banknotes" class="size-6 text-base-content/70" /> Usage &amp; Spend
          </h1>
          <p class="text-sm text-base-content/60 mt-1">
            Token cost ledger — per-session spend rolled up from <code class="text-xs">Arbiter.Usage.Event</code>.
            Multiple rows per bead expose rework spend (re-slings).
          </p>
        </div>

        <%!-- ── Controls ─────────────────────────────────────────────── --%>
        <div class="flex flex-wrap items-center gap-3">
          <%!-- Since filter --%>
          <div class="flex items-center gap-2">
            <span class="text-sm text-base-content/60 font-medium">Since:</span>
            <div class="join">
              <button
                :for={{label, days} <- @since_options}
                phx-click="set_since"
                phx-value-since_days={days || ""}
                class={[
                  "join-item btn btn-sm",
                  if(@since_days == days, do: "btn-primary", else: "btn-ghost border border-base-300")
                ]}
              >
                {label}
              </button>
            </div>
          </div>

          <div class="flex-1"></div>

          <%!-- Grouping toggle --%>
          <div class="flex items-center gap-2">
            <span class="text-sm text-base-content/60 font-medium">Group by:</span>
            <div class="join">
              <button
                :for={opt <- @by_options}
                phx-click="set_by"
                phx-value-by={opt}
                class={[
                  "join-item btn btn-sm",
                  if(@by == opt, do: "btn-secondary", else: "btn-ghost border border-base-300")
                ]}
              >
                {opt}
              </button>
            </div>
          </div>
        </div>

        <%!-- ── Summary stats ──────────────────────────────────────────── --%>
        <div class="stats stats-vertical lg:stats-horizontal w-full shadow bg-base-200 border border-base-300">
          <div class="stat">
            <div class="stat-figure text-primary">
              <.icon name="hero-currency-dollar" class="size-7" />
            </div>
            <div class="stat-title">Total spend</div>
            <div class="stat-value text-primary">{format_usd(@grand_cost)}</div>
            <div class="stat-desc">{since_label(@since_days)}</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-base-content/70">
              <.icon name="hero-cpu-chip" class="size-7" />
            </div>
            <div class="stat-title">Total tokens</div>
            <div class="stat-value">{format_tokens(@grand_tokens)}</div>
            <div class="stat-desc">input + output</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-base-content/70">
              <.icon name="hero-table-cells" class="size-7" />
            </div>
            <div class="stat-title">Sessions</div>
            <div class="stat-value">{sum_rows(@main_rollup)}</div>
            <div class="stat-desc">usage events</div>
          </div>

          <div class="stat">
            <div class={[
              "stat-figure",
              if(@rework_beads == [], do: "text-base-content/40", else: "text-warning")
            ]}>
              <.icon name="hero-arrow-path" class="size-7" />
            </div>
            <div class="stat-title">Rework beads</div>
            <div class={[
              "stat-value",
              if(@rework_beads == [], do: "text-base-content/40", else: "text-warning")
            ]}>
              {length(@rework_beads)}
            </div>
            <div class="stat-desc">
              {if @rework_beads == [], do: "none re-slung", else: "re-slung ≥ twice"}
            </div>
          </div>
        </div>

        <%!-- ── Main rollup table ────────────────────────────────────── --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <h2 class="text-lg font-semibold flex items-center gap-2">
              <.icon name="hero-chart-bar" class="size-5 text-base-content/70" />
              Spend by {to_string(@by)}
              <span class="badge badge-ghost badge-sm font-normal">{length(@main_rollup)} rows</span>
            </h2>

            <div
              :if={@main_rollup == []}
              class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-8 text-center"
            >
              <.icon name="hero-inbox" class="size-8 mx-auto text-base-content/30" />
              <p class="mt-2 text-sm text-base-content/60">
                No usage events recorded yet {since_label_lower(@since_days)}.
              </p>
            </div>

            <div :if={@main_rollup != []} class="overflow-x-auto">
              <table class="table table-sm" id="main-rollup">
                <thead>
                  <tr class="text-base-content/60">
                    <th class="capitalize">{to_string(@by)}</th>
                    <th class="text-right">Cost (USD)</th>
                    <th class="text-right">Tokens in</th>
                    <th class="text-right">Tokens out</th>
                    <th class="text-right">Sessions</th>
                    <th class="text-right">Duration</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={row <- @main_rollup}
                    class="hover:bg-base-300/40 transition-colors"
                  >
                    <td class="font-mono text-xs max-w-xs truncate" title={to_string(row.group)}>
                      {to_string(row.group)}
                    </td>
                    <td class="text-right font-mono tabular-nums text-xs">
                      {format_usd(row.total_cost_usd)}
                    </td>
                    <td class="text-right font-mono tabular-nums text-xs">
                      {format_tokens(row.tokens_in)}
                    </td>
                    <td class="text-right font-mono tabular-nums text-xs">
                      {format_tokens(row.tokens_out)}
                    </td>
                    <td class="text-right text-xs">{row.rows}</td>
                    <td class="text-right font-mono tabular-nums text-xs">
                      {format_duration(row.duration_ms)}
                    </td>
                  </tr>
                </tbody>
                <tfoot>
                  <tr class="font-semibold text-base-content/70 border-t border-base-300">
                    <td>Total</td>
                    <td class="text-right font-mono tabular-nums text-xs text-primary">
                      {format_usd(@grand_cost)}
                    </td>
                    <td class="text-right font-mono tabular-nums text-xs">
                      {format_tokens(
                        Enum.reduce(@main_rollup, 0, fn r, acc -> acc + (r.tokens_in || 0) end)
                      )}
                    </td>
                    <td class="text-right font-mono tabular-nums text-xs">
                      {format_tokens(
                        Enum.reduce(@main_rollup, 0, fn r, acc -> acc + (r.tokens_out || 0) end)
                      )}
                    </td>
                    <td class="text-right text-xs">{sum_rows(@main_rollup)}</td>
                    <td class="text-right font-mono tabular-nums text-xs">
                      {format_duration(
                        Enum.reduce(@main_rollup, 0, fn r, acc -> acc + (r.duration_ms || 0) end)
                      )}
                    </td>
                  </tr>
                </tfoot>
              </table>
            </div>
          </div>
        </section>

        <%!-- ── Top beads by cost + Rework ────────────────────────────── --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Top beads by cost --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-trophy" class="size-5 text-base-content/70" /> Top beads by cost
                <span class="badge badge-ghost badge-sm font-normal">
                  top {length(@top_beads)}
                </span>
              </h2>

              <div
                :if={@top_beads == []}
                class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
              >
                <p class="text-sm text-base-content/60">
                  No usage events {since_label_lower(@since_days)}.
                </p>
              </div>

              <ul :if={@top_beads != []} class="flex flex-col gap-1.5">
                <li
                  :for={{row, rank} <- Enum.with_index(@top_beads, 1)}
                  class="rounded-box bg-base-100 border border-base-300 px-3 py-2 transition-colors duration-150 hover:border-primary/40"
                >
                  <div class="flex items-center gap-2">
                    <span class="text-xs text-base-content/40 tabular-nums w-5 shrink-0 text-right">
                      {rank}.
                    </span>
                    <.link
                      navigate={~p"/beads/#{row.group}"}
                      class="flex-1 min-w-0 group"
                    >
                      <code class="text-xs text-base-content/70 group-hover:text-primary transition-colors truncate block">
                        {row.group}
                      </code>
                    </.link>
                    <span class="badge badge-ghost badge-sm font-mono text-xs shrink-0">
                      {row.rows} sessions
                    </span>
                    <span class="font-mono tabular-nums text-xs text-primary shrink-0 font-semibold">
                      {format_usd(row.total_cost_usd)}
                    </span>
                  </div>
                </li>
              </ul>
            </div>
          </section>

          <%!-- Rework signal --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon
                  name="hero-arrow-path"
                  class={[
                    "size-5",
                    if(@rework_beads == [], do: "text-base-content/40", else: "text-warning")
                  ]}
                /> Rework signal
                <span class="text-sm font-normal text-base-content/50">
                  — re-slung beads
                </span>
                <span class={[
                  "badge badge-sm font-normal",
                  if(@rework_beads == [], do: "badge-ghost", else: "badge-warning")
                ]}>
                  {length(@rework_beads)}
                </span>
              </h2>

              <div
                :if={@rework_beads == []}
                class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
              >
                <.icon name="hero-check-circle" class="size-8 mx-auto text-success/50" />
                <p class="mt-2 text-sm text-base-content/60">
                  No re-slung beads {since_label_lower(@since_days)}.
                </p>
                <p class="text-xs text-base-content/40 mt-1">
                  Beads with more than one <code>:work</code> session appear here —
                  each additional session is spend on rework.
                </p>
              </div>

              <ul :if={@rework_beads != []} class="flex flex-col gap-1.5">
                <li
                  :for={r <- @rework_beads}
                  class="rounded-box bg-base-100 border border-warning/30 border-l-4 px-3 py-2 transition-colors duration-150 hover:border-warning/60"
                >
                  <div class="flex items-center gap-2">
                    <.link
                      navigate={~p"/beads/#{r.bead_id}"}
                      class="flex-1 min-w-0 group"
                    >
                      <code class="text-xs text-base-content/70 group-hover:text-warning transition-colors truncate block">
                        {r.bead_id}
                      </code>
                    </.link>
                    <span
                      class="badge badge-warning badge-sm gap-1 shrink-0"
                      title="Number of :work sessions for this bead"
                    >
                      <.icon name="hero-arrow-path" class="size-3" />
                      {r.work_sessions}× work
                    </span>
                    <span class="font-mono tabular-nums text-xs text-warning shrink-0 font-semibold">
                      {format_usd(r.total_cost_usd)}
                    </span>
                  </div>
                </li>
              </ul>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  defp since_label(nil), do: "all time"
  defp since_label(7), do: "last 7 days"
  defp since_label(30), do: "last 30 days"
  defp since_label(90), do: "last 90 days"
  defp since_label(n), do: "last #{n} days"

  defp since_label_lower(nil), do: "across all time"
  defp since_label_lower(days), do: "in the #{since_label(days)}"

  defp sum_rows(rollup) do
    Enum.reduce(rollup, 0, fn r, acc -> acc + (r.rows || 0) end)
  end

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
  defp format_tokens(0), do: "0"

  defp format_tokens(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_duration(nil), do: "—"
  defp format_duration(0), do: "0s"

  defp format_duration(ms) when is_integer(ms) do
    s = div(ms, 1000)

    cond do
      s < 60 -> "#{s}s"
      s < 3600 -> "#{div(s, 60)}m #{rem(s, 60)}s"
      true -> "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
    end
  end
end
