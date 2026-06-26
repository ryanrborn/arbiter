defmodule ArbiterWeb.ListComponents do
  @moduledoc """
  Shared building blocks for the uniform list / index / detail pattern.

  Every entity type (issues, workers, the merge queue, …)
  presents the same shape:

    * the **dashboard** shows only the *current* slice of a section, each with
      a `<.see_all_link>` to …
    * an **index** page that lists *everything* with `<.filter_tabs>` and a
      `<.pager>`, every row linking to …
    * a **detail** page.

  These components keep that surface consistent so a new entity type only has
  to supply its rows — not re-implement headers, filters, paging, or the
  live/stale indicator.
  """
  use Phoenix.Component

  import ArbiterWeb.CoreComponents, only: [icon: 1]

  @doc """
  A "See all →" link for a dashboard section header. Points at the entity's
  index page.
  """
  attr :navigate, :string, required: true, doc: "the index route to navigate to"
  attr :label, :string, default: "See all"
  attr :class, :any, default: nil

  def see_all_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "link link-hover text-sm text-primary flex items-center gap-1 shrink-0",
        @class
      ]}
    >
      {@label} <.icon name="hero-arrow-right" class="size-3" />
    </.link>
    """
  end

  @doc """
  Index-page header: an icon, a title, a live total count and an optional
  subtitle. Mirrors the dashboard's section-header styling so the two read as
  one family.
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, default: nil
  attr :subtitle, :string, default: nil
  slot :actions

  def index_header(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4">
      <div class="min-w-0">
        <h1 class="text-2xl font-bold tracking-tight flex items-center gap-2">
          <.icon name={@icon} class="size-6 text-base-content/70" />
          {@title}
          <span :if={@count != nil} class="text-base-content/40 font-normal">({@count})</span>
        </h1>
        <p :if={@subtitle} class="text-sm text-base-content/60 mt-1">{@subtitle}</p>
      </div>
      <div class="shrink-0">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  The live / stale connection indicator, shared by every live page so the
  "is this updating in real time?" affordance looks identical everywhere.
  """
  attr :live, :boolean, required: true

  def live_badge(assigns) do
    ~H"""
    <span
      id="live-indicator"
      class={[
        "badge badge-sm gap-1.5 transition-colors duration-200 shrink-0",
        if(@live, do: "badge-success", else: "badge-warning")
      ]}
      title={
        if @live,
          do: "WebSocket connected — updates arrive in real time",
          else: "Static render — refresh the page to reconnect"
      }
    >
      <%= if @live do %>
        <span class="relative flex h-2 w-2">
          <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-success-content opacity-75">
          </span>
          <span class="relative inline-flex h-2 w-2 rounded-full bg-success-content"></span>
        </span>
        live
      <% else %>
        <.icon name="hero-exclamation-triangle" class="size-3" /> stale (refresh)
      <% end %>
    </span>
    """
  end

  @doc """
  Filter tabs for an index page. `tabs` is a list of `{label, value}` pairs;
  `tab_path` is a 1-arity function mapping a value to a route (so the active
  filter survives in the URL and the page stays shareable / back-button safe).
  """
  attr :tabs, :list, required: true, doc: "list of {label, value} tuples"
  attr :active, :any, required: true, doc: "the currently selected value"
  attr :tab_path, :any, required: true, doc: "fn value -> route string"

  def filter_tabs(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <div role="tablist" class="tabs tabs-box w-fit" id="filter-tabs">
        <.link
          :for={{label, value} <- @tabs}
          patch={@tab_path.(value)}
          role="tab"
          class={["tab", @active == value && "tab-active"]}
        >
          {label}
        </.link>
      </div>
    </div>
    """
  end

  @doc """
  Pager for an index page. Renders Prev / page-of / Next, where the prev/next
  links are built by the `page_path` function so the current filter is
  preserved. Hidden entirely when there's a single page.
  """
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :total_count, :integer, required: true
  attr :page_path, :any, required: true, doc: "fn page -> route string"

  def pager(assigns) do
    ~H"""
    <div :if={@total_count > 0} id="pager" class="flex items-center justify-between gap-4 pt-2">
      <span class="text-xs text-base-content/50 tabular-nums">
        {@total_count} total
      </span>
      <div :if={@total_pages > 1} class="join">
        <.pager_link
          patch={@page > 1 && @page_path.(@page - 1)}
          disabled={@page <= 1}
          label="Prev"
        />
        <span class="join-item btn btn-sm btn-ghost pointer-events-none tabular-nums">
          {@page} / {@total_pages}
        </span>
        <.pager_link
          patch={@page < @total_pages && @page_path.(@page + 1)}
          disabled={@page >= @total_pages}
          label="Next"
        />
      </div>
    </div>
    """
  end

  attr :patch, :any, required: true
  attr :disabled, :boolean, required: true
  attr :label, :string, required: true

  defp pager_link(%{disabled: true} = assigns) do
    ~H"""
    <span class="join-item btn btn-sm btn-disabled">{@label}</span>
    """
  end

  defp pager_link(assigns) do
    ~H"""
    <.link patch={@patch} class="join-item btn btn-sm">{@label}</.link>
    """
  end

  @doc """
  Empty-state panel for a list/section with no entries. `id` lets tests assert
  on the empty state deterministically.
  """
  attr :id, :string, default: nil
  attr :icon, :string, default: "hero-inbox"
  slot :inner_block, required: true

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
    >
      <.icon name={@icon} class="size-8 mx-auto text-base-content/30" />
      <p class="mt-2 text-sm text-base-content/60">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  @doc """
  A "back to dashboard" footer link, shared across detail pages.
  """
  attr :navigate, :string, default: "/"
  attr :label, :string, default: "Back to dashboard"

  def back_link(assigns) do
    ~H"""
    <div>
      <.link navigate={@navigate} class="link link-hover text-sm flex items-center gap-1 w-fit">
        <.icon name="hero-arrow-left" class="size-4" /> {@label}
      </.link>
    </div>
    """
  end
end
