defmodule ArbiterWeb.LayoutsTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest

  alias ArbiterWeb.Layouts

  defp render_app(assigns_overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          flash: %{},
          current_path: "/",
          quotas: [],
          quota_on_exhaustion: :ask,
          open_epic_count: 0
        },
        assigns_overrides
      )

    render_component(
      fn assigns ->
        ~H"""
        <Layouts.app
          flash={@flash}
          current_path={@current_path}
          quotas={@quotas}
          quota_on_exhaustion={@quota_on_exhaustion}
          open_epic_count={@open_epic_count}
        >
          content
        </Layouts.app>
        """
      end,
      assigns
    )
  end

  describe "app/1 — nav" do
    test "the rail renders the 13 nav entries in order, with their hrefs and group headers" do
      rail = render_app() |> LazyHTML.from_fragment() |> LazyHTML.query("#nav-rail")

      entries =
        rail
        |> LazyHTML.query("a[href]")
        |> Enum.map(fn a ->
          {a |> LazyHTML.text() |> String.trim(), a |> LazyHTML.attribute("href") |> hd()}
        end)

      assert entries == [
               {"Board", "/"},
               {"Issues", "/tasks"},
               {"Epics", "/epics"},
               {"Merge queues", "/merge_queue"},
               {"Workers", "/workers"},
               {"Run history", "/workers/history"},
               {"Sessions", "/sessions"},
               {"Usage", "/usage"},
               {"Reviews", "/reviews"},
               {"Audit", "/audit"},
               {"Workspaces", "/workspaces"},
               {"Skills", "/skills"},
               {"Loop", "/loop"}
             ]

      headers =
        rail
        |> LazyHTML.query(~s([data-role="nav-group-header"]))
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert headers == ["Work", "Fleet", "Analysis", "Config"]
    end

    test "the top_nav bar is gone" do
      html = render_app()

      refute html =~ ~s(id="top-nav")
      refute html =~ "top-nav-mobile-menu"
    end

    test "the Epics entry links to /epics and sits directly after Issues" do
      html = render_app()

      assert html =~ ~s(href="/epics")

      {issues, _} = :binary.match(html, "Issues")
      {epics, _} = :binary.match(html, "Epics")
      {workers, _} = :binary.match(html, "Workers")

      assert issues < epics and epics < workers
    end

    test "the Epics entry carries a badge with the open-epic count" do
      html = render_app(%{open_epic_count: 7})

      # Whitespace-tolerant: the formatter decides whether the count sits on
      # its own line inside the span, and that is not what this test is about.
      assert html =~ ~r/data-role="nav-badge"[^>]*>\s*7\s*</
    end

    test "a zero open-epic count renders no badge" do
      html = render_app(%{open_epic_count: 0})

      refute html =~ ~s(data-role="nav-badge")
    end

    test "About is no longer part of the nav" do
      html = render_app()

      refute html =~ ~s(href="/about")
    end

    test "renders the fixed 46px chrome bar" do
      html = render_app()

      assert html =~ "var(--nav-height)"
    end

    test "renders the accent wordmark brandmark, not the retired <img> logo" do
      html = render_app()

      assert html =~ "arbiter"
      refute html =~ "<img"
    end
  end

  describe "app/1 — status bar" do
    defp status_bar(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.query("#app-status-bar")

    defp classes(node), do: node |> LazyHTML.attribute("class") |> hd() |> String.split()

    test "is a nav-height chrome bar with a bottom border" do
      bar = status_bar(render_app())

      assert Enum.count(bar) == 1
      assert "h-[var(--nav-height)]" in classes(bar)
      assert "bg-[var(--surface-chrome)]" in classes(bar)
      assert "border-b" in classes(bar)
    end

    test "carries the wordmark and the whole right cluster, but no nav links" do
      quota = Arbiter.Quota.blank_view("anthropic")
      bar = status_bar(render_app(%{quotas: [quota, Arbiter.Quota.blank_view("codex")]}))

      assert bar |> LazyHTML.query("svg, [aria-label]") |> Enum.count() > 0
      assert bar |> LazyHTML.text() =~ "arbiter"
      assert bar |> LazyHTML.query("#appshell-live") |> Enum.count() == 1
      assert bar |> LazyHTML.query("#coordinator-inbox-trigger") |> Enum.count() == 1
      assert bar |> LazyHTML.query("[data-phx-theme]") |> Enum.count() == 3
      # One 5h + 7d pair per provider.
      assert bar |> LazyHTML.text() |> String.split("5h") |> length() == 3
      assert bar |> LazyHTML.text() |> String.split("7d") |> length() == 3

      assert bar |> LazyHTML.query("nav, a[href]") |> Enum.to_list() == []
    end

    test "holds the below-lg hamburger that opens the rail as an overlay" do
      html = render_app()
      toggle = html |> status_bar() |> LazyHTML.query("#nav-rail-toggle")

      assert Enum.count(toggle) == 1
      assert "lg:hidden" in classes(toggle)
      assert toggle |> LazyHTML.attribute("aria-controls") == ["nav-rail"]

      backdrop = html |> LazyHTML.from_fragment() |> LazyHTML.query("#nav-rail-backdrop")
      assert Enum.count(backdrop) == 1
      assert "fixed" in classes(backdrop)
      assert backdrop |> LazyHTML.attribute("phx-click") |> hd() =~ "nav-rail:close"
    end
  end

  describe "app/1 — rail geometry" do
    defp rail(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.query("#nav-rail")

    test "is a fixed column between the status bar and the dock strip" do
      rail = rail(render_app())
      class = rail |> LazyHTML.attribute("class") |> hd() |> String.split()

      assert "fixed" in class
      assert "left-0" in class
      assert "top-[var(--nav-height)]" in class
      assert "bottom-[var(--session-dock-strip-height)]" in class
      assert rail |> LazyHTML.attribute("phx-hook") == ["NavRail"]
      assert rail |> LazyHTML.query("#sidebar-nav") |> Enum.count() == 1
    end

    test "sits below the dock's expanded window and the coordinator drawer" do
      html = render_app()
      [z] = Regex.run(~r/\bz-(\d+)\b/, rail(html) |> LazyHTML.attribute("class") |> hd(), capture: :all_but_first)

      # The dock root is `z-30`; the drawer's backdrop is `z-40`, the drawer `z-50`.
      assert String.to_integer(z) < 30
      assert html =~ ~r/id="coordinator-drawer-backdrop"[^>]*z-40/s
      assert html =~ ~r/id="coordinator-drawer"[^>]*z-50/s
    end

    test "the hover-expanded layer is fixed and out of <main>'s flow" do
      doc = render_app() |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("main #nav-rail") |> Enum.to_list() == []
      assert doc |> LazyHTML.query("main #sidebar-nav") |> Enum.to_list() == []
      assert doc |> LazyHTML.query("main") |> LazyHTML.text() =~ "content"
    end
  end

  describe "app.css — rail inset contract" do
    @css Path.expand("../../../assets/css/app.css", __DIR__)

    # Comments stripped, so a rule's selector is only its selector.
    defp css, do: @css |> File.read!() |> String.replace(~r{/\*.*?\*/}s, "")

    # Every rule in the stylesheet that assigns `--nav-rail-page-inset`.
    defp inset_rules do
      ~r/([^{}]+)\{[^{}]*--nav-rail-page-inset:\s*([^;]+);/
      |> Regex.scan(css(), capture: :all_but_first)
      |> Enum.map(fn [selector, value] -> {String.trim(selector), String.trim(value)} end)
    end

    test "pinned insets the page by the expanded width, unpinned by the collapsed width" do
      rules = inset_rules()

      assert {~S|html[data-nav-rail="pinned"]:has(#nav-rail)|, "var(--nav-rail-width-expanded)"} in rules
      assert {"html:has(#nav-rail)", "var(--nav-rail-width)"} in rules
    end

    test "the inset only exists at lg and up; below it the page keeps its full width" do
      [lg_block] =
        Regex.run(~r/@media \(min-width: 64rem\) \{\s*html:has\(#nav-rail\).*?\n\}/s, css())

      assert lg_block =~ "html:has(#nav-rail)"
      assert lg_block =~ ~S|html[data-nav-rail="pinned"]:has(#nav-rail)|
      assert css() =~ "--nav-rail-page-inset: 0px"
    end

    test "hovering never changes the inset — the float is width-only on the fixed rail" do
      for {selector, _value} <- inset_rules() do
        refute selector =~ ":hover"
        refute selector =~ ":focus-within"
      end

      assert css() =~ ~r/\.nav-rail:hover[^{]*\{[^}]*width: var\(--nav-rail-width-expanded\)/s
    end
  end

  describe "app/1 — quota + live badge" do
    test "renders a 5h and 7d quota bar per tracked provider" do
      quota =
        Arbiter.Quota.blank_view("anthropic")
        |> Map.put(:utilization_5h, 0.42)
        |> Map.put(:utilization_7d, 0.1)

      html = render_app(%{quotas: [quota]})

      assert html =~ "5h"
      assert html =~ "7d"
      assert html =~ "42%"
    end

    test "renders the live badge" do
      html = render_app()

      assert html =~ "live-badge" or html =~ ~s(id="appshell-live")
    end

    test "passes the raw provider key through so claude keeps its pace-aware hairline and label" do
      reset_at = DateTime.add(DateTime.utc_now(), 200 * 60, :second)

      quota =
        Arbiter.Quota.blank_view("claude")
        |> Map.put(:utilization_5h, 0.85)
        |> Map.put(:reset_5h_at, reset_at)

      expected_elapsed_pct = ArbiterWeb.QuotaHelpers.quota_elapsed_pct_5h("claude", reset_at)

      expected_pace_label =
        ArbiterWeb.QuotaHelpers.quota_pace_label_5h("claude", 0.85, reset_at, nil, :throttle)

      # Sanity-check the fixture actually exercises the amber/red pace path
      # (and not the "claude" label ever leaking `quota_provider_label/1`'s
      # already-mapped display string back into the logic functions).
      assert expected_elapsed_pct
      assert expected_pace_label =~ "stalls in"

      html = render_app(%{quotas: [quota], quota_on_exhaustion: :throttle})

      assert html =~ "left: #{expected_elapsed_pct}%;"
      assert html =~ expected_pace_label
      assert html =~ "Claude"
    end
  end

  describe "app/1 — theme toggle" do
    test "keeps the phx:set-theme dispatch for all three options" do
      html = render_app()

      assert html =~ ~s(data-phx-theme="system")
      assert html =~ ~s(data-phx-theme="light")
      assert html =~ ~s(data-phx-theme="dark")
      assert html =~ "phx:set-theme"
    end

    test "is restyled onto design tokens, not the old daisyUI classes" do
      html = render_app()

      assert html =~ "var(--surface-card)"
      refute html =~ "bg-base-300"
      refute html =~ "border-base-300"
    end
  end

  describe "app/1 — page inset" do
    # bd-2qqqbp: the page-inset contract is two-sided. `<main>` gives up room on
    # the right for a side-panel session window and on the left for the nav
    # rail, and each side is its own variable so the page only pays for an edge
    # something is actually occupying.
    test "main is inset from both edges, not just the dock's" do
      html = render_app()

      assert html =~ "pl-[var(--nav-rail-page-inset)]"
      assert html =~ "pr-[var(--session-dock-page-inset)]"
    end
  end

  describe "app/1 — flash" do
    test "renders flash via the toast group, not the old flash_group" do
      html = render_app(%{flash: %{"info" => "Saved"}})

      assert html =~ "Saved"
      assert html =~ "toast-group"
    end
  end
end
