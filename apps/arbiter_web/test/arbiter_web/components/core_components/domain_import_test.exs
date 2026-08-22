defmodule ArbiterWeb.CoreComponents.DomainImportTest do
  @moduledoc """
  Guards the `html_helpers/0` wiring, not the components themselves.

  `ArbiterWeb.ListComponents` already exports an `index_header/1` that every
  index page calls unqualified. Importing `ArbiterWeb.CoreComponents.Domain`
  wholesale would make that call ambiguous and fail to compile app-wide, so
  the import excludes it. This test pins both halves of that contract.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  defmodule Template do
    use ArbiterWeb, :html

    # Unqualified: these must resolve to CoreComponents.Domain.
    def domain(assigns) do
      ~H"""
      <.stat_card label="Open issues" value={84} tone="live" />
      <.task_card id="bd-1" title="A card" accent="live" />
      <.run_row role="impl" worker="w-11" status="running" />
      <.log_stream id="log" lines={[%{time: "t", role: "agent", text: "x"}]} />
      """
    end

    # Unqualified `index_header` must still be the old ListComponents one —
    # it takes a required `icon` and renders daisyUI classes.
    def legacy_header(assigns) do
      ~H"""
      <.index_header icon="hero-clipboard-document-list" title="Issues" count={84} />
      """
    end

    # The handoff header is reachable fully-qualified.
    def handoff_header(assigns) do
      ~H"""
      <ArbiterWeb.CoreComponents.Domain.index_header title="Issues" count={84} />
      """
    end
  end

  test "the domain primitives are importable unqualified from html_helpers/0" do
    html = render_component(&Template.domain/1, %{})

    assert html =~ "Open issues"
    assert html =~ "bd-1"
    assert html =~ "w-11"
    assert html =~ "minmax(92px,max-content)"
    assert html =~ ~s(id="log-line-0")
  end

  test "unqualified index_header still resolves to the legacy ListComponents one" do
    html = render_component(&Template.legacy_header/1, %{})

    assert html =~ "text-2xl font-bold"
    refute html =~ "tracking-[var(--tracking-section)]"
  end

  test "the handoff index_header is reachable fully-qualified" do
    html = render_component(&Template.handoff_header/1, %{})

    assert html =~ "tracking-[var(--tracking-section)]"
    refute html =~ "text-2xl font-bold"
  end
end
