defmodule ArbiterWeb.CoreComponents.Navigation do
  @moduledoc """
  Navigation primitives from the operator-console design handoff: TopNav,
  FilterTabs, SegmentedControl, Pager, SeeAllLink, BackLink.

  Colors and spacing are drawn from the `--arb-*`/semantic design tokens in
  `assets/css/app.css` via Tailwind arbitrary values (`bg-[var(--...)]`)
  rather than daisyUI's theme slots, matching the handoff's reference
  implementation token-for-token.

  `filter_tabs/1`, `pager/1`, `see_all_link/1`, and `back_link/1` share their
  names with existing `ArbiterWeb.ListComponents` functions that have a
  different attr contract, so `html_helpers/0` imports those four with
  `except:` — call them fully qualified (e.g.
  `ArbiterWeb.CoreComponents.Navigation.pager/1`) until a follow-up ticket
  migrates call sites. `top_nav/1` and `segmented_control/1` have no such
  collision and resolve normally as `<.top_nav>` / `<.segmented_control>`.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  import ArbiterWeb.CoreComponents.Brandmark, only: [brandmark: 1]
  import ArbiterWeb.CoreComponents.Core, only: [icon: 1, button: 1]

  @doc """
  The product's chrome: a fixed 46px bar with the brandmark, the primary
  nav, and a right-hand slot for the quota widget / live badge.

  Active state is a raised pill, not an underline, decided by prefix-matching
  `current_path` against each item's `href` — `"/"` only matches exactly, so
  the dashboard entry doesn't claim every page; every other entry also
  matches its own sub-paths (`/tasks/42` lights up `/tasks`). The nav itself
  never wraps to a second line; it scrolls horizontally under width pressure
  instead. Below the `lg` breakpoint the nav collapses into a hamburger menu.

  ## Examples

      <.top_nav items={[%{label: "Dashboard", href: "/"}, %{label: "Issues", href: "/tasks"}]} current_path={@current_path}>
        <:right><.quota_bar window="5h" pct={68} /><.live_badge live /></:right>
      </.top_nav>
  """
  attr :items, :list, required: true, doc: "list of %{label: string, href: string}"

  attr :current_path, :string,
    default: nil,
    doc: "request path, for prefix-matching the active item"

  attr :id, :string,
    default: "top-nav",
    doc:
      "base id — the mobile menu's id is derived as \"\#{id}-mobile-menu\"; override when rendering more than one top_nav on a page"

  attr :class, :any, default: nil
  attr :rest, :global

  slot :right, doc: "right-hand slot — normally a quota widget plus a live badge"

  def top_nav(assigns) do
    ~H"""
    <header
      id={@id}
      class={[
        "flex items-center gap-[18px] h-[var(--nav-height)] px-4",
        "bg-[var(--surface-chrome)] border-b border-solid border-[var(--border-default)]",
        @class
      ]}
      {@rest}
    >
      <.link navigate="/" class="flex-none" aria-label="Arbiter">
        <.brandmark form="wordmark" size={120} tone="accent" />
      </.link>

      <nav class="flex max-lg:hidden gap-0.5 min-w-0 overflow-x-auto overflow-y-hidden [scrollbar-width:none]">
        <.link
          :for={item <- @items}
          navigate={item.href}
          aria-current={nav_active?(@current_path, item.href) && "page"}
          class={[
            "px-[10px] py-[5px] rounded-[var(--radius-field)] whitespace-nowrap font-[family-name:var(--font-sans)] text-xs",
            nav_active?(@current_path, item.href) &&
              "bg-[var(--surface-card)] font-medium text-[var(--text-title)]",
            !nav_active?(@current_path, item.href) && "font-normal text-[var(--text-secondary)]"
          ]}
        >
          {item.label}
        </.link>
      </nav>

      <details class="dropdown lg:hidden" id={"#{@id}-mobile-menu"} phx-hook="DetailsPreserve">
        <summary class="list-none cursor-pointer flex items-center justify-center" aria-label="Menu">
          <.icon name="hero-bars-3" size={20} />
        </summary>
        <ul class="menu dropdown-content z-50 mt-2 w-56 rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)] p-2">
          <li :for={item <- @items}>
            <.link
              navigate={item.href}
              phx-click={JS.remove_attribute("open", to: "##{@id}-mobile-menu")}
              aria-current={nav_active?(@current_path, item.href) && "page"}
              class={[
                "font-[family-name:var(--font-sans)] text-xs",
                nav_active?(@current_path, item.href) && "font-medium text-[var(--text-title)]",
                !nav_active?(@current_path, item.href) && "font-normal text-[var(--text-secondary)]"
              ]}
            >
              {item.label}
            </.link>
          </li>
        </ul>
      </details>

      <span class="ml-auto flex flex-none items-center gap-4">{render_slot(@right)}</span>
    </header>
    """
  end

  # Ports the pre-existing `nav_class/2` prefix-matching logic verbatim: "/"
  # only matches exactly so the dashboard entry doesn't claim every page;
  # every other entry also matches its own sub-paths.
  defp nav_active?(current, "/"), do: current == "/"
  defp nav_active?(nil, _target), do: false

  defp nav_active?(current, target),
    do: current == target or String.starts_with?(current, target <> "/")

  @doc """
  The status filter on an index page. Counts live inside the tab; a tab only
  takes a state color when its count is nonzero and it wants attention.

  Pass `event` for socket-local state, or `tab_path` when the screen drives
  the active tab through the URL (the usual case for index screens — see
  `ArbiterWeb.ListComponents.filter_tabs/1` for the pattern this mirrors):
  with `tab_path` set, tabs render as `<.link patch={...}>` instead of
  `<button phx-click>`, so the active filter survives in the URL and the
  page stays shareable / back-button safe.

  ## Examples

      <.filter_tabs
        tabs={[%{label: "All", value: "all", count: 84}, %{label: "Open", value: "open", count: 12}]}
        active="all" event="filter-select"
      />

      <.filter_tabs
        tabs={[%{label: "All", value: "all"}, %{label: "Open", value: "open"}]}
        active={@filter} tab_path={&"/tasks?filter=\#{&1}"}
      />
  """
  attr :tabs, :list, required: true, doc: "list of strings or %{label, value, count, tone}"
  attr :active, :string, default: nil
  attr :event, :string, default: nil, doc: ~s(phx-click event name, pushed with phx-value-tab)

  attr :tab_path, :any,
    default: nil,
    doc:
      "1-arity function mapping a tab value to a patch path — renders <.link patch={...}> instead of <button phx-click>"

  attr :class, :any, default: nil
  attr :rest, :global

  def filter_tabs(assigns) do
    ~H"""
    <div
      class={[
        "inline-flex w-full min-w-0 overflow-x-auto overflow-y-hidden rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)]",
        @class
      ]}
      {@rest}
    >
      <.link
        :for={{tab, index} <- Enum.with_index(@tabs)}
        :if={@tab_path}
        patch={@tab_path.(filter_tab_value(tab))}
        aria-current={filter_tab_active?(tab, @active) && "page"}
        class={filter_tab_class(tab, index, @active)}
      >
        {filter_tab_label(tab)}{filter_tab_count(tab)}
      </.link>
      <button
        :for={{tab, index} <- Enum.with_index(@tabs)}
        :if={!@tab_path}
        type="button"
        phx-click={@event}
        phx-value-tab={filter_tab_value(tab)}
        aria-pressed={to_string(filter_tab_active?(tab, @active))}
        class={filter_tab_class(tab, index, @active)}
      >
        {filter_tab_label(tab)}{filter_tab_count(tab)}
      </button>
    </div>
    """
  end

  defp filter_tab_class(tab, index, active) do
    [
      "cursor-pointer border-0 px-3 py-[5px] font-[family-name:var(--font-mono)] text-[11.5px] font-medium",
      index > 0 && "border-l border-solid border-[var(--border-strong)]",
      filter_tab_active?(tab, active) && "bg-[var(--arb-done-wash)] text-[var(--text-title)]",
      !filter_tab_active?(tab, active) && filter_tab_tone(tab) == "attention" &&
        "bg-transparent text-[var(--arb-attention)]",
      !filter_tab_active?(tab, active) && filter_tab_tone(tab) != "attention" &&
        "bg-transparent text-[var(--text-secondary)]"
    ]
  end

  defp filter_tab_label(tab) when is_binary(tab), do: tab
  defp filter_tab_label(%{label: label}), do: label

  defp filter_tab_value(tab) when is_binary(tab), do: tab
  defp filter_tab_value(%{value: value}), do: value
  defp filter_tab_value(%{label: label}), do: label

  defp filter_tab_count(tab) when is_binary(tab), do: nil
  defp filter_tab_count(%{count: count}) when is_integer(count), do: " #{count}"
  defp filter_tab_count(_tab), do: nil

  defp filter_tab_tone(tab) when is_binary(tab), do: "default"
  defp filter_tab_tone(%{tone: tone}), do: tone
  defp filter_tab_tone(_tab), do: "default"

  defp filter_tab_active?(tab, active), do: filter_tab_value(tab) == active

  @doc """
  A two-or-three-way scope switch in a toolbar — narrower than `filter_tabs/1`
  and carries no counts.

  ## Examples

      <.segmented_control options={["mine", "all"]} value="mine" event="scope-change" />
  """
  attr :options, :list, required: true, doc: "list of short scope words, e.g. [\"mine\", \"all\"]"
  attr :value, :string, default: nil
  attr :event, :string, default: nil, doc: ~s(phx-click event name, pushed with phx-value-option)
  attr :class, :any, default: nil
  attr :rest, :global

  def segmented_control(assigns) do
    ~H"""
    <div
      class={[
        "inline-flex overflow-hidden rounded-[var(--radius-field)] border border-solid border-[var(--arb-line)]",
        @class
      ]}
      {@rest}
    >
      <button
        :for={{option, index} <- Enum.with_index(@options)}
        type="button"
        phx-click={@event}
        phx-value-option={option}
        aria-pressed={to_string(option == @value)}
        class={[
          "cursor-pointer border-0 px-[10px] py-[5px] font-[family-name:var(--font-mono)] text-[11px] font-medium",
          index > 0 && "border-l border-solid border-[var(--arb-line)]",
          option == @value && "bg-[var(--arb-raised-hover)] text-[var(--text-title)]",
          option != @value && "bg-transparent text-[var(--text-secondary)]"
        ]}
      >
        {option}
      </button>
    </div>
    """
  end

  @doc """
  Index-page paging: a total on the left, Prev / page-of / Next on the
  right. The total is always shown, even on a single page; the Prev/Next
  group hides itself when there's only one page.

  Pass `event` for socket-local state, or `page_path` when the screen drives
  the current page through the URL (the usual case for index screens — see
  `ArbiterWeb.ListComponents.pager/1` for the pattern this mirrors): with
  `page_path` set, Prev/Next render as `<.link patch={...}>` instead of
  `<.button phx-click>`, so the page survives in the URL and stays
  shareable / back-button safe.

  ## Examples

      <.pager page={2} total_pages={7} total_count={84} event="page-select" />

      <.pager page={@page} total_pages={@total_pages} total_count={@total} page_path={&"/tasks?page=\#{&1}"} />
  """
  attr :page, :integer, default: 1
  attr :total_pages, :integer, default: 1
  attr :total_count, :integer, default: 0
  attr :event, :string, default: nil, doc: ~s(phx-click event name, pushed with phx-value-page)

  attr :page_path, :any,
    default: nil,
    doc:
      "1-arity function mapping a page number to a patch path — renders <.link patch={...}> instead of <.button phx-click>"

  attr :class, :any, default: nil
  attr :rest, :global

  def pager(assigns) do
    ~H"""
    <div class={["flex items-center justify-between gap-4", @class]} {@rest}>
      <span class="font-[family-name:var(--font-mono)] text-[11px] tabular-nums text-[var(--text-label)]">
        {@total_count} total
      </span>
      <span :if={@total_pages > 1} class="flex items-center gap-1.5">
        <.link :if={@page_path && @page > 1} patch={@page_path.(@page - 1)} class={pager_link_class()}>
          Prev
        </.link>
        <.button
          :if={!(@page_path && @page > 1)}
          type="button"
          size="sm"
          disabled={@page <= 1}
          phx-click={@event}
          phx-value-page={@page - 1}
        >
          Prev
        </.button>
        <span class="px-1 font-[family-name:var(--font-mono)] text-[11.5px] tabular-nums text-[var(--text-secondary)]">
          {@page} / {@total_pages}
        </span>
        <.link
          :if={@page_path && @page < @total_pages}
          patch={@page_path.(@page + 1)}
          class={pager_link_class()}
        >
          Next
        </.link>
        <.button
          :if={!(@page_path && @page < @total_pages)}
          type="button"
          size="sm"
          disabled={@page >= @total_pages}
          phx-click={@event}
          phx-value-page={@page + 1}
        >
          Next
        </.button>
      </span>
    </div>
    """
  end

  # Matches Core.button's variant="secondary" size="sm" appearance for the
  # enabled Prev/Next link — an <a> can't carry a meaningful `disabled`
  # state, so the boundary case still falls through to a real disabled
  # <.button> above.
  defp pager_link_class do
    [
      "inline-flex items-center gap-[7px] rounded-[var(--radius-field)] border border-solid font-medium",
      "cursor-pointer h-[var(--control-sm)] px-[10px] text-[11.5px]",
      "bg-[var(--surface-card)] border-[var(--border-strong)] text-[var(--arb-text-body)] hover:bg-[var(--arb-raised-hover)]"
    ]
  end

  @doc """
  Points a dashboard section at its full index. Every dashboard section that
  shows a current-only slice has one.

  ## Examples

      <.see_all_link href="/workers" />
      <.see_all_link href="/workers/history" label="History" />
  """
  attr :href, :string, required: true
  attr :label, :string, default: "See all"
  attr :class, :any, default: nil
  attr :rest, :global

  def see_all_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "inline-flex flex-none items-center gap-1 font-[family-name:var(--font-mono)] text-[11.5px] text-[var(--text-link)]",
        @class
      ]}
      {@rest}
    >
      {@label}<.icon name="hero-arrow-right-micro" size={11} />
    </.link>
    """
  end

  @doc """
  The footer link on every index and detail page. Grey, not cyan — it is a
  way out, not a reference.

  ## Examples

      <.back_link />
      <.back_link href="/issues" label="Back to issues" />
  """
  attr :href, :string, default: "/"
  attr :label, :string, default: "Back to board"
  attr :class, :any, default: nil
  attr :rest, :global

  def back_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "inline-flex w-fit items-center gap-1.5 font-[family-name:var(--font-sans)] text-xs text-[var(--text-secondary)]",
        @class
      ]}
      {@rest}
    >
      <.icon name="hero-arrow-left" size={13} />{@label}
    </.link>
    """
  end
end
