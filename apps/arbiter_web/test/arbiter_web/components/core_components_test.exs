defmodule ArbiterWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents

  describe "quota_marker/1" do
    test "positions the marker and exposes an aria-label" do
      html =
        render_component(&quota_marker/1, pct: 50, label: "50% of window elapsed (2.5h into 5h)")

      assert html =~ "left: 50%"
      assert html =~ "aria-label=\"50% of window elapsed (2.5h into 5h)\""
    end

    test "compact variant renders a plain line without a halo" do
      html = render_component(&quota_marker/1, pct: 33, label: "elapsed", compact: true)

      assert html =~ "left: 33%"
      refute html =~ "ring-"
    end

    test "non-compact variant adds a halo that flips with the base-100 theme token" do
      html = render_component(&quota_marker/1, pct: 33, label: "elapsed")

      assert html =~ "ring-1"
      assert html =~ "ring-base-100"
    end
  end
end
