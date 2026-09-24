defmodule ArbiterWeb.CoreComponents.NavigationTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents.Navigation

  # Pulls the full `<a>...</a>` / `<button>...</button>` element whose text
  # content contains `text`, so tests can assert on one item's classes/attrs
  # without pulling in an HTML parser dependency the app doesn't otherwise use.
  defp element_containing(html, text) do
    ~r/<(a|button)\b[^>]*>[^<]*#{Regex.escape(text)}[^<]*<\/\1>/s
    |> Regex.run(html)
    |> List.first()
  end

  describe "sidebar_nav/1" do
    @rail_groups [
      %{
        label: nil,
        items: [%{label: "Board", href: "/", icon: "hero-view-columns", badge: nil}]
      },
      %{
        label: "Fleet",
        items: [
          %{label: "Workers", href: "/workers", icon: "hero-cpu-chip", badge: nil},
          %{label: "Run history", href: "/workers/history", icon: "hero-clock", badge: nil}
        ]
      }
    ]

    # Rail items wrap an icon <span> and an optional badge <span>, so the
    # text-only `element_containing/2` above cannot reach them. Hrefs are
    # unique within the rail, so the opening tag is the reliable anchor.
    defp rail_item_tag(html, href) do
      ~r/<a\b[^>]*href="#{Regex.escape(href)}"[^>]*>/
      |> Regex.run(html)
      |> List.first()
    end

    defp render_rail(overrides) do
      render_component(&sidebar_nav/1, Map.merge(%{groups: @rail_groups}, Map.new(overrides)))
    end

    test "renders every label and href from a two-group fixture" do
      html = render_rail(expanded: true, current_path: "/")

      for label <- ["Board", "Workers", "Run history"], do: assert(html =~ label)
      assert html =~ ~s(href="/workers")
      assert html =~ ~s(href="/workers/history")
    end

    test "the rail is a nav labelled Primary and honours the id attr" do
      html = render_rail(id: "rail-two")

      assert html =~ ~s(aria-label="Primary")
      assert html =~ ~s(id="rail-two")
    end

    test "the active item is the longest match and its siblings are not active" do
      html = render_rail(current_path: "/workers/history/abc123")

      assert rail_item_tag(html, "/workers/history") =~ "bg-[var(--surface-card)]"
      assert rail_item_tag(html, "/workers/history") =~ "font-medium"
      assert rail_item_tag(html, "/workers/history") =~ "text-[var(--text-title)]"
      assert rail_item_tag(html, "/workers/history") =~ ~s(aria-current="page")

      refute rail_item_tag(html, "/workers") =~ "bg-[var(--surface-card)]"
      refute rail_item_tag(html, "/workers") =~ "aria-current"
      assert rail_item_tag(html, "/workers") =~ "font-normal"
      assert rail_item_tag(html, "/workers") =~ "text-[var(--text-secondary)]"
    end

    test "a nil current_path leaves every item inactive" do
      html = render_rail(current_path: nil)

      refute html =~ "bg-[var(--surface-card)]"
      refute html =~ "aria-current"
    end

    test "the badge renders at a positive count in both states" do
      groups = [%{label: "Work", items: [badge_item(7)]}]

      for expanded <- [false, true] do
        html = render_component(&sidebar_nav/1, %{groups: groups, expanded: expanded})

        assert html =~ ~s(data-role="nav-badge")
        assert html =~ "7"
      end
    end

    test "the badge is absent at 0 and at nil in both states" do
      for count <- [0, nil], expanded <- [false, true] do
        groups = [%{label: "Work", items: [badge_item(count)]}]
        html = render_component(&sidebar_nav/1, %{groups: groups, expanded: expanded})

        refute html =~ ~s(data-role="nav-badge")
      end
    end

    test "collapsed renders aria-label and title for every item" do
      html = render_rail(expanded: false)

      for label <- ["Board", "Workers", "Run history"] do
        assert html =~ ~s(aria-label="#{label}")
        assert html =~ ~s(title="#{label}")
      end
    end

    test "collapsed sizes itself from --nav-rail-width and draws group boundaries as separators" do
      html = render_rail(expanded: false)

      assert html =~ "w-[var(--nav-rail-width)]"
      refute html =~ "w-[var(--nav-rail-width-expanded)]"
      assert html =~ ~s(data-role="nav-group-separator")
      assert html =~ "border-[var(--border-default)]"
    end

    test "group headers render only when expanded" do
      collapsed = render_rail(expanded: false)
      expanded = render_rail(expanded: true)

      refute collapsed =~ "Fleet"
      refute collapsed =~ ~s(data-role="nav-group-header")

      assert expanded =~ ~s(data-role="nav-group-header")
      assert expanded =~ "Fleet"
      assert expanded =~ "text-[9.5px] uppercase tracking-[0.08em]"
      assert expanded =~ "font-[family-name:var(--font-mono)]"
    end

    test "expanded sizes itself from --nav-rail-width-expanded and renders no header for the ungrouped leading group" do
      html = render_rail(expanded: true)

      assert html =~ "w-[var(--nav-rail-width-expanded)]"
      # one header for "Fleet", none for the nil-labelled leading group
      assert length(Regex.scan(~r/data-role="nav-group-header"/, html)) == 1
    end

    test "the pin button reports aria-pressed and pushes the documented event" do
      collapsed = render_rail(expanded: false)
      expanded = render_rail(expanded: true)

      assert collapsed =~ ~s(aria-pressed="false")
      assert expanded =~ ~s(aria-pressed="true")
      assert collapsed =~ ~s(aria-label="Pin navigation")
      assert collapsed =~ ~s(type="button")
      assert collapsed =~ ~s(phx-click="toggle-nav-pin")
    end

    test "renders the footer slot" do
      assigns = %{groups: @rail_groups}

      html =
        render_component(
          fn assigns ->
            ~H"""
            <.sidebar_nav groups={@groups}>
              <:footer><span id="rail-footer">theme</span></:footer>
            </.sidebar_nav>
            """
          end,
          assigns
        )

      assert html =~ "rail-footer"
    end

    defp badge_item(count) do
      %{label: "Epics", href: "/epics", icon: "hero-rectangle-stack", badge: count}
    end
  end

  describe "filter_tabs/1" do
    test "renders string tabs and highlights the active one" do
      html = render_component(&filter_tabs/1, %{tabs: ["all", "open"], active: "open"})

      assert element_containing(html, "open") =~ "var(--arb-done-wash)"
    end

    test "renders map tabs with a live count" do
      tabs = [%{label: "All", value: "all", count: 84}]
      html = render_component(&filter_tabs/1, %{tabs: tabs, active: "all"})

      assert html =~ "All"
      assert html =~ "84"
    end

    test "an attention-tone tab is only tinted while inactive" do
      tabs = [%{label: "Review", value: "review", count: 3, tone: "attention"}]

      inactive = render_component(&filter_tabs/1, %{tabs: tabs, active: "all"})
      assert inactive =~ "var(--arb-attention)"

      active = render_component(&filter_tabs/1, %{tabs: tabs, active: "review"})
      refute active =~ "var(--arb-attention)"
    end

    test "dispatches the configured event with the tab value on click" do
      tabs = [%{label: "Open", value: "open", count: 1}]

      html =
        render_component(&filter_tabs/1, %{tabs: tabs, active: "open", event: "filter-select"})

      assert html =~ ~s(phx-click="filter-select")
      assert html =~ ~s(phx-value-tab="open")
    end

    test "renders <.link patch> to tab_path instead of a phx-click button when tab_path is set" do
      tabs = [%{label: "Open", value: "open", count: 1}]

      html =
        render_component(&filter_tabs/1, %{
          tabs: tabs,
          active: "open",
          tab_path: fn value -> "/tasks?filter=#{value}" end
        })

      assert html =~ ~s(href="/tasks?filter=open")
      assert html =~ ~s(data-phx-link="patch")
      refute html =~ "phx-click"
    end

    test "exposes pressed state via aria-pressed on both active and inactive tabs" do
      tabs = [%{label: "All", value: "all", count: 1}, %{label: "Open", value: "open", count: 1}]
      html = render_component(&filter_tabs/1, %{tabs: tabs, active: "all"})

      assert element_containing(html, "All") =~ ~s(aria-pressed="true")
      assert element_containing(html, "Open") =~ ~s(aria-pressed="false")
    end

    test "renders with overflow-x-auto to allow horizontal scrolling on narrow viewports" do
      tabs = [
        %{label: "Live", value: "live"},
        %{label: "Proposed", value: "proposed"},
        %{label: "Hypothesis", value: "hypothesis"},
        %{label: "Applied", value: "applied"},
        %{label: "Rejected", value: "rejected"},
        %{label: "Superseded", value: "superseded"}
      ]

      html = render_component(&filter_tabs/1, %{tabs: tabs, active: "live", event: "filter"})

      assert html =~ "overflow-x-auto"
    end
  end

  describe "segmented_control/1" do
    test "renders each option and highlights the current value" do
      html = render_component(&segmented_control/1, %{options: ["mine", "all"], value: "mine"})

      assert element_containing(html, "mine") =~ "var(--arb-raised-hover)"
      refute element_containing(html, "all") =~ "var(--arb-raised-hover)"
    end

    test "exposes pressed state via aria-pressed on both active and inactive options" do
      html = render_component(&segmented_control/1, %{options: ["mine", "all"], value: "mine"})

      assert element_containing(html, "mine") =~ ~s(aria-pressed="true")
      assert element_containing(html, "all") =~ ~s(aria-pressed="false")
    end

    test "dispatches the configured event with the option on click" do
      html =
        render_component(&segmented_control/1, %{
          options: ["mine", "all"],
          value: "mine",
          event: "scope-change"
        })

      assert html =~ ~s(phx-click="scope-change")
      assert html =~ ~s(phx-value-option="mine")
      assert html =~ ~s(phx-value-option="all")
    end
  end

  describe "pager/1" do
    test "always shows the total count" do
      html = render_component(&pager/1, %{page: 1, total_pages: 1, total_count: 7})

      assert html =~ "7 total"
    end

    test "hides the prev/next controls on a single page" do
      html = render_component(&pager/1, %{page: 1, total_pages: 1, total_count: 7})

      refute html =~ "Prev"
      refute html =~ "Next"
    end

    test "shows prev/next and disables prev on the first page" do
      html = render_component(&pager/1, %{page: 1, total_pages: 7, total_count: 84})

      assert html =~ "1 / 7"
      assert element_containing(html, "Prev") =~ "disabled"
    end

    test "disables next on the last page" do
      html = render_component(&pager/1, %{page: 7, total_pages: 7, total_count: 84})

      assert element_containing(html, "Next") =~ "disabled"
    end

    test "dispatches the configured event with the target page" do
      html =
        render_component(&pager/1, %{
          page: 3,
          total_pages: 7,
          total_count: 84,
          event: "page-select"
        })

      assert html =~ ~s(phx-click="page-select")
      assert html =~ ~s(phx-value-page="2")
      assert html =~ ~s(phx-value-page="4")
    end

    test "Prev/Next buttons are type=\"button\" so they can't submit an enclosing form" do
      html =
        render_component(&pager/1, %{
          page: 3,
          total_pages: 7,
          total_count: 84,
          event: "page-select"
        })

      assert element_containing(html, "Prev") =~ ~s(type="button")
      assert element_containing(html, "Next") =~ ~s(type="button")
    end

    test "renders <.link patch> to page_path instead of a phx-click button when page_path is set" do
      html =
        render_component(&pager/1, %{
          page: 3,
          total_pages: 7,
          total_count: 84,
          page_path: fn page -> "/tasks?page=#{page}" end
        })

      assert element_containing(html, "Prev") =~ ~s(href="/tasks?page=2")
      assert element_containing(html, "Next") =~ ~s(href="/tasks?page=4")
      refute html =~ "phx-click"
    end

    test "page_path still falls back to a disabled button at the boundaries" do
      html =
        render_component(&pager/1, %{
          page: 1,
          total_pages: 7,
          total_count: 84,
          page_path: fn page -> "/tasks?page=#{page}" end
        })

      assert element_containing(html, "Prev") =~ "disabled"
      refute element_containing(html, "Prev") =~ "href"
    end
  end

  describe "see_all_link/1" do
    test "defaults to label \"See all\"" do
      html = render_component(&see_all_link/1, %{href: "/workers"})

      assert html =~ ~s(href="/workers")
      assert html =~ "See all"
      assert html =~ "hero-arrow-right"
    end

    test "accepts a custom href and label" do
      html = render_component(&see_all_link/1, %{href: "/workers/history", label: "History"})

      assert html =~ ~s(href="/workers/history")
      assert html =~ "History"
    end
  end

  describe "back_link/1" do
    test "defaults to href \"/\" and label \"Back to board\"" do
      html = render_component(&back_link/1, %{})

      assert html =~ ~s(href="/")
      assert html =~ "Back to board"
      assert html =~ "hero-arrow-left"
    end

    test "accepts a custom href and label" do
      html = render_component(&back_link/1, %{href: "/issues", label: "Back to issues"})

      assert html =~ ~s(href="/issues")
      assert html =~ "Back to issues"
    end
  end
end
