defmodule ArbiterWeb.CoreComponents.Navigation do
  @moduledoc """
  Navigation primitives from the operator-console design handoff: SidebarNav,
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
  migrates call sites. `segmented_control/1` has no such collision and
  resolves normally as `<.segmented_control>`; so does `sidebar_nav/1`.
  """
  use Phoenix.Component

  alias ArbiterWeb.Nav

  import ArbiterWeb.CoreComponents.Core, only: [icon: 1, button: 1]

  # A count riding a nav entry (the open-epic count on "Epics", bd-2wmxt5).
  # Zero and nil both render nothing: a badge only exists to say "there is
  # something here", so an empty one is noise.
  attr :count, :integer, default: nil

  defp nav_badge(assigns) do
    ~H"""
    <span
      :if={nav_badge?(@count)}
      data-role="nav-badge"
      class="ml-1.5 inline-block min-w-[16px] px-1 rounded-[var(--radius-pill)] bg-[var(--surface-raised)] text-[9.5px] leading-[15px] text-center font-[family-name:var(--font-mono)] text-[var(--text-secondary)] align-middle"
    >
      {@count}
    </span>
    """
  end

  defp nav_badge?(count), do: is_integer(count) and count > 0

  @doc """
  The persistent left icon rail (bd-2pezqm): a `var(--nav-rail-width)` icon
  column that widens to `var(--nav-rail-width-expanded)` and grows labels
  when `expanded` is set.

  It renders the shared nav model — pass `ArbiterWeb.Nav.groups/1` straight
  in — and resolves its single active item with `ArbiterWeb.Nav.active_href/2`,
  which is longest-match-wins, so `/workers/history/abc123` lights up
  `Run history` and leaves `Workers` alone (a plain prefix match would light
  up both).

  Three visual states, one markup tree:

  * **collapsed** (`expanded={false}`) — icons only. Each item carries
    `aria-label` and `title` equal to its label, so the label stays reachable
    by screen reader and by hover when no text is drawn; group boundaries are
    hairline separators instead of headers.
  * **expanded** (`expanded={true}`) — labels beside the icons and uppercase
    mono group headers. The leading ungrouped group (`label: nil`) gets no
    header.
  * **floated on hover** — the same expanded markup, driven by whoever renders
    the rail. This component only takes `expanded`; the hover float and the
    page-inset contract belong to the layout (bd-d63b1c / bd-2qqqbp).

  The pin button emits the `"toggle-nav-pin"` event and reports its state
  through `aria-pressed`. Handling that event is the caller's job — this
  component is stateless.

  Sizing comes from the two custom properties only, never from pixel
  literals, so the rail and the page inset can never disagree.

  ## Examples

      <.sidebar_nav groups={ArbiterWeb.Nav.groups(@open_epic_count)} current_path={@current_path}>
        <:footer><.theme_toggle /></:footer>
      </.sidebar_nav>
  """
  attr :groups, :list,
    required: true,
    doc:
      "`ArbiterWeb.Nav.group/0` list — `%{label: string | nil, items: [%{label, href, icon, badge}]}`; a nil label marks the leading ungrouped group"

  attr :current_path, :string,
    default: nil,
    doc: "request path, resolved to one active item by `ArbiterWeb.Nav.active_href/2`"

  attr :expanded, :boolean,
    default: false,
    doc: "labels and group headers instead of bare icons; also drives the pin's `aria-pressed`"

  attr :id, :string, default: "sidebar-nav"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :footer, doc: "pinned to the bottom of the rail, below the last group"

  def sidebar_nav(assigns) do
    assigns =
      assign(assigns, :active_href, Nav.active_href(assigns.groups, assigns.current_path))

    ~H"""
    <nav
      id={@id}
      aria-label="Primary"
      class={[
        "flex flex-col h-full font-[family-name:var(--font-sans)]",
        "bg-[var(--surface-chrome)] border-r border-solid border-[var(--border-default)]",
        @expanded && "w-[var(--nav-rail-width-expanded)]",
        !@expanded && "w-[var(--nav-rail-width)]",
        @class
      ]}
      {@rest}
    >
      <div class={[
        "flex flex-none items-center h-[var(--nav-height)] px-2",
        @expanded && "justify-end",
        !@expanded && "justify-center"
      ]}>
        <button
          type="button"
          phx-click="toggle-nav-pin"
          aria-pressed={to_string(@expanded)}
          aria-label="Pin navigation"
          title="Pin navigation"
          class="flex cursor-pointer items-center justify-center size-7 rounded-[var(--radius-field)] border-0 bg-transparent text-[var(--text-label)] transition-colors duration-150 hover:bg-[var(--arb-raised-hover)] hover:text-[var(--text-title)]"
        >
          <.icon
            name={if(@expanded, do: "hero-chevron-double-left", else: "hero-chevron-double-right")}
            size={14}
          />
        </button>
      </div>

      <div class="flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto overflow-x-hidden pb-2 [scrollbar-width:thin]">
        <div :for={{group, index} <- Enum.with_index(@groups)} class="flex flex-col">
          <div
            :if={!@expanded && index > 0}
            role="separator"
            data-role="nav-group-separator"
            class="mx-3 my-1.5 h-0 border-t border-solid border-[var(--border-default)]"
          >
          </div>
          <div
            :if={@expanded && group.label}
            data-role="nav-group-header"
            class="px-3 pt-3 pb-1 text-[9.5px] uppercase tracking-[0.08em] leading-none text-[var(--text-label)] font-[family-name:var(--font-mono)]"
          >
            {group.label}
          </div>

          <.link
            :for={item <- group.items}
            navigate={item.href}
            aria-current={item.href == @active_href && "page"}
            aria-label={!@expanded && item.label}
            title={!@expanded && item.label}
            class={[
              "relative mx-2 flex items-center rounded-[var(--radius-field)] text-xs transition-colors duration-150",
              @expanded && "gap-2.5 px-2.5 py-[6px]",
              !@expanded && "justify-center py-[7px]",
              item.href == @active_href &&
                "bg-[var(--surface-card)] font-medium text-[var(--text-title)]",
              item.href != @active_href &&
                "font-normal text-[var(--text-secondary)] hover:bg-[var(--arb-raised-hover)] hover:text-[var(--text-title)]"
            ]}
          >
            <.icon :if={item[:icon]} name={item[:icon]} size={16} class="flex-none" />
            <span :if={@expanded} class="min-w-0 truncate">{item.label}</span>
            <.nav_badge :if={@expanded} count={item[:badge]} />
            <span
              :if={!@expanded && nav_badge?(item[:badge])}
              class="absolute top-0.5 right-1 leading-none"
            >
              <.nav_badge count={item[:badge]} />
            </span>
          </.link>
        </div>
      </div>

      <div
        :if={@footer != []}
        class={[
          "flex flex-none items-center border-t border-solid border-[var(--border-default)] p-2",
          @expanded && "justify-start gap-2",
          !@expanded && "justify-center"
        ]}
      >
        {render_slot(@footer)}
      </div>
    </nav>
    """
  end

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

      <.segmented_control options={["7d", "30d", "all"]} value="7d" event="range-change" />
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
