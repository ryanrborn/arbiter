defmodule ArbiterWeb.CoreComponents.NavigationImportTest do
  @moduledoc """
  Guards the `html_helpers/0` wiring, not the components themselves.

  `ArbiterWeb.ListComponents` already exports `filter_tabs/1`, `pager/1`,
  `see_all_link/1`, and `back_link/1` with a different attr contract, so
  importing `ArbiterWeb.CoreComponents.Navigation` wholesale would make those
  calls ambiguous (or silently wrong) app-wide. The import excludes them.
  This test pins both halves of that contract, plus that `top_nav/1` and
  `segmented_control/1` — which have no collision — resolve unqualified.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  defmodule Template do
    use ArbiterWeb, :html

    # Unqualified: these must resolve to CoreComponents.Navigation.
    def navigation(assigns) do
      ~H"""
      <.top_nav items={[%{label: "Dashboard", href: "/"}]} current_path="/" />
      <.segmented_control options={["mine", "all"]} value="mine" event="scope-change" />
      """
    end

    # Unqualified `filter_tabs`/`pager`/`see_all_link`/`back_link` must still
    # be the old ListComponents ones — they render daisyUI classes.
    def legacy(assigns) do
      ~H"""
      <.filter_tabs tabs={[{"All", "all"}]} active="all" tab_path={&"/tasks?filter=#{&1}"} />
      <.pager page={1} total_pages={2} total_count={2} page_path={&"/tasks?page=#{&1}"} />
      <.see_all_link navigate="/workers" />
      <.back_link navigate="/" />
      """
    end

    # The handoff versions are reachable fully-qualified.
    def handoff(assigns) do
      ~H"""
      <ArbiterWeb.CoreComponents.Navigation.filter_tabs
        tabs={[%{label: "All", value: "all", count: 84}]}
        active="all"
        event="filter-select"
      />
      <ArbiterWeb.CoreComponents.Navigation.pager
        page={1}
        total_pages={2}
        total_count={2}
        event="page-select"
      />
      <ArbiterWeb.CoreComponents.Navigation.see_all_link href="/workers" />
      <ArbiterWeb.CoreComponents.Navigation.back_link href="/" />
      """
    end
  end

  test "top_nav and segmented_control are importable unqualified from html_helpers/0" do
    html = render_component(&Template.navigation/1, %{})

    assert html =~ ~s(id="top-nav")
    assert html =~ "scope-change"
  end

  test "unqualified filter_tabs/pager/see_all_link/back_link still resolve to legacy ListComponents" do
    html = render_component(&Template.legacy/1, %{})

    assert html =~ "tabs tabs-box"
    assert html =~ "join"
    assert html =~ "link link-hover"
    refute html =~ "font-[family-name:var(--font-mono)]"
  end

  test "the handoff navigation primitives are reachable fully-qualified" do
    html = render_component(&Template.handoff/1, %{})

    assert html =~ "font-[family-name:var(--font-mono)]"
    refute html =~ "tabs tabs-box"
  end
end
