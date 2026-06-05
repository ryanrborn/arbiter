defmodule ArbiterWeb.ConvoyIndexLive do
  @moduledoc """
  Index of every campaign (convoy) at `/convoys` — the "See all" target for
  the dashboard's current-only campaigns section.

  Lists all convoys with a status filter (all / open / closed) and paging,
  each showing its issue-progress aggregate and linking to the convoy detail
  page. A convoy's progress is derived from its member issues, so this view
  refreshes live on `:bead_lifecycle` events.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Beads.Convoy
  alias Arbiter.Vernacular
  alias ArbiterWeb.Paging
  require Ash.Query

  @beads_topic "beads"

  @filters [
    {"All", :all},
    {"Open", :open},
    {"Closed", :closed}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @beads_topic)

    {:ok,
     socket
     |> assign(:live, connected?(socket))
     |> assign(:convoy_label, Vernacular.label(:batch))
     |> assign(:issue_label, Vernacular.label(:issue))
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
  def handle_info({:bead_lifecycle, _event, _issue}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    query =
      Convoy
      |> filter_by_status(socket.assigns.status)
      |> Ash.Query.load([:total_issues, :closed_issues])
      |> Ash.Query.sort(updated_at: :desc)

    result = Paging.paginate(query, socket.assigns.page)

    socket
    |> assign(:convoys, result.entries)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
  end

  defp filter_by_status(query, :all), do: Ash.Query.new(query)
  defp filter_by_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp parse_status(%{"status" => s}) when s in ~w(open closed),
    do: String.to_existing_atom(s)

  defp parse_status(_), do: :all

  defp convoy_path(:all, page), do: ~p"/convoys?#{%{page: page}}"
  defp convoy_path(status, page), do: ~p"/convoys?#{%{status: status, page: page}}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <.index_header
            icon="hero-rectangle-stack"
            title={cap_plural(@convoy_label)}
            count={@total_count}
            subtitle={"Every #{@convoy_label} — batches of related #{plural(@issue_label)} tracked together."}
          />
          <.live_badge live={@live} />
        </div>

        <.filter_tabs
          tabs={@filters}
          active={@status}
          tab_path={fn value -> convoy_path(value, 1) end}
        />

        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <.empty_state :if={@convoys == []} id="convoys-empty" icon="hero-rectangle-stack">
              No {plural(@convoy_label)} match this filter.
            </.empty_state>

            <ul :if={@convoys != []} id="convoys" class="flex flex-col gap-2">
              <li
                :for={c <- @convoys}
                class="rounded-box border border-base-300 bg-base-100 px-3 py-2.5 transition-colors duration-150 hover:bg-base-300/40"
              >
                <div class="flex items-center gap-2">
                  <span class={["badge badge-sm shrink-0", status_badge_class(c.status)]}>
                    {c.status}
                  </span>
                  <.link navigate={~p"/convoys/#{c.id}"} class="min-w-0 flex-1 group">
                    <div class="flex items-center gap-2">
                      <code class="text-xs text-base-content/60 shrink-0 group-hover:text-primary transition-colors">
                        {c.id}
                      </code>
                      <span
                        class="truncate text-sm group-hover:text-primary transition-colors"
                        title={c.title}
                      >
                        {c.title}
                      </span>
                    </div>
                  </.link>
                  <span class="badge badge-ghost badge-sm shrink-0 font-mono" title="lifecycle">
                    {c.lifecycle}
                  </span>
                  <span
                    class="text-xs font-mono tabular-nums text-base-content/60 shrink-0"
                    title={"#{c.closed_issues} of #{c.total_issues} #{plural(@issue_label)} closed"}
                  >
                    {c.closed_issues}/{c.total_issues}
                  </span>
                </div>
                <progress
                  class="progress progress-success w-full mt-2 h-1.5"
                  value={c.closed_issues}
                  max={max(c.total_issues, 1)}
                >
                </progress>
              </li>
            </ul>

            <.pager
              page={@page}
              total_pages={@total_pages}
              total_count={@total_count}
              page_path={fn page -> convoy_path(@status, page) end}
            />
          </div>
        </section>

        <.back_link />
      </div>
    </Layouts.app>
    """
  end

  defp status_badge_class(:open), do: "badge-success"
  defp status_badge_class(:closed), do: "badge-ghost"
  defp status_badge_class(_), do: ""
end
