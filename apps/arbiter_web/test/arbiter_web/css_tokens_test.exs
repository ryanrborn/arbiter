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

  test "light is the ambient daisyUI default and dark opts in via prefers-color-scheme", %{
    css: css
  } do
    [dark_block, light_block] =
      ~r/@plugin "\.\.\/vendor\/daisyui-theme" \{(.*?)\n\}/s
      |> Regex.scan(css, capture: :all_but_first)
      |> Enum.map(&hd/1)

    # Dark must NOT be `default: true` — that generates a zero-specificity
    # `:where(:root)` fallback that wins ties unpredictably against anything
    # that disturbs the cascade (e.g. a browser extension toggling
    # `color-scheme`). Dark instead opts in via `prefersdark`, which daisyUI
    # compiles to a real (non-`:where`) `@media (prefers-color-scheme: dark)`
    # rule.
    assert dark_block =~ ~s(name: "dark";)
    assert dark_block =~ "default: false;"
    assert dark_block =~ "prefersdark: true;"

    assert light_block =~ ~s(name: "light";)
    assert light_block =~ "default: true;"
    assert light_block =~ "prefersdark: false;"
  end

  test "extra design tokens: light is the :root baseline, dark is explicitly scoped", %{
    css: css
  } do
    # `:root` (unscoped) is the true fallback and must carry the LIGHT ramp,
    # not dark — a bare `:root` has real specificity and previously made dark
    # the ambient "whatever's left" default.
    assert css =~ "--arb-canvas: oklch(96.5% 0.005 258)"
    assert css =~ "--arb-text-primary: oklch(22% 0.014 258)"

    # Dark is redefined under an explicit, equally-scoped attribute selector...
    assert css =~ "[data-theme=\"dark\"]"

    dark_attr_block =
      Regex.run(~r/\[data-theme="dark"\]\s*\{(.*?)\n\}/s, css, capture: :all_but_first)
      |> hd()

    assert dark_attr_block =~ "--arb-canvas: oklch(16.5% 0.014 258)"
    assert dark_attr_block =~ "--arb-text-primary: oklch(96% 0.006 258)"
    assert dark_attr_block =~ "--arb-live: oklch(84% 0.19 130)"

    # ...and under a guarded prefers-color-scheme fallback, so "system" theme
    # actually follows the OS/browser preference (an explicit light choice
    # still wins via the :not() guard).
    assert css =~ "@media (prefers-color-scheme: dark)"

    media_block =
      Regex.run(
        ~r/@media \(prefers-color-scheme: dark\)\s*\{\s*:root:not\(\[data-theme="light"\]\)\s*\{(.*?)\n  \}/s,
        css,
        capture: :all_but_first
      )
      |> hd()

    assert media_block =~ "--arb-canvas: oklch(16.5% 0.014 258)"
    assert media_block =~ "--arb-text-primary: oklch(96% 0.006 258)"

    assert css =~ "--row-table: 34px"
    assert css =~ "--radius-panel: 4px"
    assert css =~ "--dur-hover: 150ms"
  end

  test "Geist and Geist Mono are loaded" do
    assert @css_path
           |> File.read!()
           |> String.contains?("fonts.googleapis.com")

    assert File.read!(@css_path) =~ "Geist"
    assert File.read!(@css_path) =~ "Geist+Mono"
  end
end
