defmodule ArbiterWeb.CoreComponents.NavigationTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents.Navigation

  @items [
    %{label: "Dashboard", href: "/"},
    %{label: "Issues", href: "/tasks"},
    %{label: "Workers", href: "/workers"}
  ]

  # Pulls the full `<a>...</a>` / `<button>...</button>` element whose text
  # content contains `text`, so tests can assert on one item's classes/attrs
  # without pulling in an HTML parser dependency the app doesn't otherwise use.
  defp element_containing(html, text) do
    ~r/<(a|button)\b[^>]*>[^<]*#{Regex.escape(text)}[^<]*<\/\1>/s
    |> Regex.run(html)
    |> List.first()
  end

  describe "top_nav/1" do
    test "renders every item's label and href" do
      html = render_component(&top_nav/1, %{items: @items, current_path: "/"})

      assert html =~ "Dashboard"
      assert html =~ "Issues"
      assert html =~ "Workers"
      assert html =~ ~s(href="/tasks")
      assert html =~ ~s(href="/workers")
    end

    test "the dashboard entry (\"/\") is only active on an exact match" do
      html = render_component(&top_nav/1, %{items: @items, current_path: "/tasks/42"})

      refute element_containing(html, "Dashboard") =~ "var(--surface-card)"
    end

    test "a non-root entry is active on an exact match or a path-prefix match" do
      html = render_component(&top_nav/1, %{items: @items, current_path: "/tasks/42"})

      assert element_containing(html, "Issues") =~ "var(--surface-card)"
    end

    test "a non-root entry does not match a sibling path that merely shares the prefix string" do
      html = render_component(&top_nav/1, %{items: @items, current_path: "/tasksomething"})

      refute element_containing(html, "Issues") =~ "var(--surface-card)"
    end

    test "a nil current_path leaves every item inactive" do
      html = render_component(&top_nav/1, %{items: @items, current_path: nil})

      refute html =~ "var(--surface-card)"
    end

    test "renders the right slot content" do
      assigns = %{items: @items}

      html =
        render_component(
          fn assigns ->
            ~H"""
            <.top_nav items={@items} current_path="/">
              <:right><span id="quota-widget">quota</span></:right>
            </.top_nav>
            """
          end,
          assigns
        )

      assert html =~ "quota-widget"
    end

    test "renders a lg:hidden mobile menu with the same items" do
      html = render_component(&top_nav/1, %{items: @items, current_path: "/"})

      assert html =~ "lg:hidden"
      assert html =~ "hero-bars-3"
    end

    test "derives the mobile menu id from the id attr so two top_navs on one page don't collide" do
      html = render_component(&top_nav/1, %{items: @items, current_path: "/", id: "second-nav"})

      assert html =~ ~s(id="second-nav-mobile-menu")
      assert html =~ "second-nav-mobile-menu&quot;,&quot;attr&quot;:&quot;open&quot;"
      refute html =~ "top-nav-mobile-menu"
    end

    test "renders the id attr on the header itself" do
      html = render_component(&top_nav/1, %{items: @items, current_path: "/", id: "second-nav"})

      assert html =~ ~s(<header id="second-nav")
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
