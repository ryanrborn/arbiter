defmodule ArbiterWeb.CoreComponents.BrandmarkTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents.Brandmark

  describe "icon form" do
    test "display master (32px+) renders the two-bracket + slash geometry" do
      html = render_component(&brandmark/1, form: "icon", size: 32, tone: "accent")

      assert html =~ ~s(viewBox="0 0 64 64")
      assert html =~ ~s(d="M22 10 H12 V54 H22")
      assert html =~ ~s(d="M42 10 H52 V54 H42")
      assert html =~ ~s(d="M27 46 L37 18")
      assert html =~ ~s(stroke-width="7")
      assert html =~ ~s(stroke-linecap="square")
      assert html =~ ~s(stroke-linecap="butt")
    end

    test "micro master (under 32px) insets the verticals and thickens the stroke" do
      html = render_component(&brandmark/1, form: "icon", size: 24, tone: "accent")

      assert html =~ ~s(d="M23 12 H14 V52 H23")
      assert html =~ ~s(d="M41 12 H50 V52 H41")
      assert html =~ ~s(stroke-width="9")
    end

    test "below 16px falls back to the tile+slash favicon geometry" do
      html = render_component(&brandmark/1, form: "icon", size: 12, tone: "tile")

      assert html =~ ~s(rx="8")
      assert html =~ ~s(d="M25 47 L39 17")
      refute html =~ ~s(d="M22 10 H12 V54 H22")
    end

    test "accent tone reads bracket/content colors from design tokens" do
      html = render_component(&brandmark/1, form: "icon", size: 32, tone: "accent")

      assert html =~ "var(--arb-live)"
      assert html =~ "var(--arb-text-primary)"
    end

    test "inverse tone renders dark brackets with 55% opacity contents" do
      html = render_component(&brandmark/1, form: "icon", size: 32, tone: "inverse")

      assert html =~ "var(--arb-live-ink)"
      assert html =~ "opacity: 0.55"
    end

    test "mono tone uses currentColor with 50% opacity contents" do
      html = render_component(&brandmark/1, form: "icon", size: 32, tone: "mono")

      assert html =~ "currentColor"
      assert html =~ "opacity: 0.5"
    end

    test "tile tone renders the lime tile background" do
      html = render_component(&brandmark/1, form: "icon", size: 64, tone: "tile")

      assert html =~ ~s(rx="8")
      assert html =~ "var(--arb-live)"
    end

    test "never mirrors the slash or rounds its caps" do
      html = render_component(&brandmark/1, form: "icon", size: 32, tone: "accent")

      assert html =~ ~s(d="M27 46 L37 18")
      refute html =~ "stroke-linecap=\"round\""
    end
  end

  describe "wordmark form" do
    test "renders live text plus bracket paths, not an image" do
      html = render_component(&brandmark/1, form: "wordmark", size: 160, tone: "accent")

      refute html =~ "<img"
      assert html =~ ">arbiter<"
      assert html =~ ~s(d="M38 7 H28 V41 H38")
      assert html =~ ~s(d="M162 7 H172 V41 H162")
    end

    test "uses stroke 4 above 140px rendered width" do
      html = render_component(&brandmark/1, form: "wordmark", size: 160, tone: "accent")

      assert html =~ ~s(stroke-width="4")
    end

    test "uses stroke 5 below 140px rendered width" do
      html = render_component(&brandmark/1, form: "wordmark", size: 130, tone: "accent")

      assert html =~ ~s(stroke-width="5")
    end

    test "is always lowercase" do
      html = render_component(&brandmark/1, form: "wordmark", size: 160, tone: "accent")

      assert html =~ ">arbiter<"
      refute html =~ ">Arbiter<"
    end

    test "falls back to icon-only below the 120px minimum width" do
      html = render_component(&brandmark/1, form: "wordmark", size: 100, tone: "accent")

      refute html =~ ">arbiter<"
      assert html =~ ~s(viewBox="0 0 64 64")
    end

    test "renders the word (not the icon fallback) between the 120px minimum and the 140px stroke breakpoint" do
      html = render_component(&brandmark/1, form: "wordmark", size: 130, tone: "accent")

      assert html =~ ">arbiter<"
      assert html =~ ~s(stroke-width="5")
    end
  end
end
