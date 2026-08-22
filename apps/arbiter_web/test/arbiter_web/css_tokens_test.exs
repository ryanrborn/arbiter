defmodule ArbiterWeb.CssTokensTest do
  @moduledoc """
  Characterization test for the design-token retheme: asserts the compiled
  daisyUI theme blocks and the extra design tokens are present in app.css,
  since ExUnit can't otherwise exercise a CSS-only change.
  """
  use ExUnit.Case, async: true

  @css_path Path.expand("../../assets/css/app.css", __DIR__)

  setup do
    {:ok, css: File.read!(@css_path)}
  end

  test "dark daisyUI theme uses the design-system base ramp", %{css: css} do
    assert css =~ "name: \"dark\";"
    assert css =~ "--color-base-100: oklch(20.5% 0.014 258)"
    assert css =~ "--color-base-200: oklch(19% 0.014 258)"
    assert css =~ "--color-base-300: oklch(30% 0.014 258)"
    assert css =~ "--color-primary: oklch(84% 0.19 130)"
    assert css =~ "--border: 1px;"
    assert css =~ "--depth: 0;"
  end

  test "dark is the default daisyUI theme and light is opt-in", %{css: css} do
    [dark_block, light_block] =
      ~r/@plugin "\.\.\/vendor\/daisyui-theme" \{(.*?)\n\}/s
      |> Regex.scan(css, capture: :all_but_first)
      |> Enum.map(&hd/1)

    assert dark_block =~ ~s(name: "dark";)
    assert dark_block =~ "default: true;"
    assert dark_block =~ "prefersdark: false;"

    assert light_block =~ ~s(name: "light";)
    assert light_block =~ "default: false;"
    assert light_block =~ "prefersdark: false;"
  end

  test "extra design tokens are present as plain custom properties", %{css: css} do
    assert css =~ "--arb-canvas: oklch(16.5% 0.014 258)"
    assert css =~ "--arb-text-primary: oklch(96% 0.006 258)"
    assert css =~ "--arb-live: oklch(84% 0.19 130)"
    assert css =~ "--row-table: 34px"
    assert css =~ "--radius-panel: 4px"
    assert css =~ "--dur-hover: 150ms"
    assert css =~ "[data-theme=\"light\"]"
  end

  test "Geist and Geist Mono are loaded" do
    assert @css_path
           |> File.read!()
           |> String.contains?("fonts.googleapis.com")

    assert File.read!(@css_path) =~ "Geist"
    assert File.read!(@css_path) =~ "Geist+Mono"
  end
end
