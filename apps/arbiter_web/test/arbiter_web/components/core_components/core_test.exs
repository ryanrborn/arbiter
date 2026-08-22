defmodule ArbiterWeb.CoreComponents.CoreTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents.Core

  describe "button/1" do
    test "renders default (secondary/md) variant classes" do
      html = render_component(&button/1, %{inner_block: [%{inner_block: fn _, _ -> "Edit" end}]})

      assert html =~ "Edit"
      assert html =~ "var(--surface-card)"
      assert html =~ "var(--control-md)"
    end

    test "renders primary variant with a size and disabled state" do
      assigns = %{variant: "primary", size: "lg", disabled: true}

      html =
        render_component(&button/1, assigns)

      assert html =~ "var(--control-lg)"
      assert html =~ "disabled"
      assert html =~ "cursor-not-allowed"
    end

    test "renders a trailing key hint chip" do
      html = render_component(&button/1, %{key_hint: "C"})

      assert html =~ ~r/>\s*C\s*</
      assert html =~ "var(--radius-chip)"
    end

    test "renders leading icon slot content" do
      assigns = %{}

      html =
        render_component(
          fn assigns ->
            ~H"""
            <.button>
              <:icon><span id="my-icon">icon-here</span></:icon>
              New issue
            </.button>
            """
          end,
          assigns
        )

      assert html =~ "my-icon"
      assert html =~ "New issue"
    end

    test "danger variant uses a wash-and-outline treatment, not a solid fill" do
      html = render_component(&button/1, %{variant: "danger"})

      assert html =~ "var(--arb-fail-wash)"
      assert html =~ "var(--arb-fail-edge)"
    end
  end

  describe "icon/1" do
    test "renders the full hero class as passed, with the 16px outline default size" do
      html = render_component(&icon/1, %{name: "hero-plus"})

      assert html =~ "hero-plus\""
      assert html =~ "width: 16px"
      assert html =~ "height: 16px"
    end

    test "a -solid/-mini/-micro suffix on name wins over the variant attr" do
      html = render_component(&icon/1, %{name: "hero-check-circle-micro", variant: "outline"})

      assert html =~ "hero-check-circle-micro"
      assert html =~ "width: 12px"
    end

    test "explicit size overrides the variant default" do
      html = render_component(&icon/1, %{name: "hero-plus", size: 30})

      assert html =~ "width: 30px"
    end

    test "explicit color sets the mask background-color" do
      html =
        render_component(&icon/1, %{
          name: "hero-check-circle",
          variant: "micro",
          color: "var(--arb-live)"
        })

      assert html =~ "background-color: var(--arb-live)"
    end
  end

  describe "key_hint/1" do
    test "renders its content as a chip" do
      assigns = %{}

      html =
        render_component(
          fn assigns ->
            ~H"""
            <.key_hint>esc</.key_hint>
            """
          end,
          assigns
        )

      assert html =~ ~r/>\s*esc\s*</
      assert html =~ "var(--radius-chip)"
    end
  end

  describe "toggle/1" do
    test "unlabeled toggle renders a bare switch" do
      html = render_component(&toggle/1, %{checked: false})

      assert html =~ "role=\"switch\""
      assert html =~ "aria-checked=\"false\""
      refute html =~ "flex-direction"
    end

    test "checked toggle uses the lime accent" do
      html = render_component(&toggle/1, %{checked: true})

      assert html =~ "aria-checked=\"true\""
      assert html =~ "var(--accent-primary)"
    end

    test "disabled toggle drops phx-click so it cannot fire its event" do
      assigns = %{}

      html =
        render_component(
          fn assigns ->
            ~H"""
            <.toggle checked={false} disabled phx-click="toggle" />
            """
          end,
          assigns
        )

      assert html =~ "aria-disabled=\"true\""
      assert html =~ "disabled"
      refute html =~ "phx-click"
    end

    test "labeled toggle renders a full settings row with its consequence hint" do
      html =
        render_component(&toggle/1, %{
          checked: true,
          label: "Pause on quota exhaustion",
          hint: "stop dispatching at 100% of the 5h window"
        })

      assert html =~ "Pause on quota exhaustion"
      assert html =~ "stop dispatching at 100% of the 5h window"
      assert html =~ "role=\"switch\""
    end
  end

  describe "panel/1" do
    test "renders a title, meta, and actions in the header" do
      assigns = %{}

      html =
        render_component(
          fn assigns ->
            ~H"""
            <.panel title="Active workers" meta="4 running">
              <:actions><a href="/workers">See all</a></:actions>
              rows go here
            </.panel>
            """
          end,
          assigns
        )

      assert html =~ "Active workers"
      assert html =~ "4 running"
      assert html =~ "See all"
      assert html =~ "rows go here"
    end

    test "omits the header entirely when there is no title or actions" do
      assigns = %{}

      html =
        render_component(
          fn assigns ->
            ~H"""
            <.panel>flush content</.panel>
            """
          end,
          assigns
        )

      refute html =~ "<header"
      assert html =~ "flush content"
    end

    test "padded={false} removes body padding, for a flush table or log" do
      assigns = %{}

      padded_html =
        render_component(
          fn assigns ->
            ~H"""
            <.panel>content</.panel>
            """
          end,
          assigns
        )

      flush_html =
        render_component(
          fn assigns ->
            ~H"""
            <.panel padded={false}>content</.panel>
            """
          end,
          assigns
        )

      assert padded_html =~ "var(--space-4)"
      refute flush_html =~ "var(--space-4)"
    end

    test "surface controls the background token" do
      assigns = %{}

      html =
        render_component(
          fn assigns ->
            ~H"""
            <.panel surface="sunken">content</.panel>
            """
          end,
          assigns
        )

      assert html =~ "var(--arb-canvas-sunken)"
    end
  end

  test "primitives compose: a panel of buttons, an icon, and toggles renders end to end" do
    assigns = %{}

    html =
      render_component(
        fn assigns ->
          ~H"""
          <.panel title="Active workers" meta="4 running">
            <:actions><.button variant="ghost" size="sm">See all</.button></:actions>
            <.button variant="primary" key_hint="C">
              <:icon><.icon name="hero-plus" size={13} /></:icon>
              New issue
            </.button>
            <.button variant="attention">Open review</.button>
            <.button variant="danger" size="sm">Stop</.button>
            <.toggle
              checked
              label="Pause on quota exhaustion"
              hint="stop dispatching at 100% of the 5h window"
            />
            <.toggle checked={false} />
          </.panel>
          """
        end,
        assigns
      )

    assert html =~ "Active workers"
    assert html =~ "See all"
    assert html =~ "New issue"
    assert html =~ "hero-plus"
    assert html =~ "Open review"
    assert html =~ "Stop"
    assert html =~ "Pause on quota exhaustion"
    assert html =~ ~r/>\s*C\s*</
  end
end
