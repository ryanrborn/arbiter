defmodule ArbiterWeb.CoreComponents.ProviderIconTest do
  use ExUnit.Case, async: true

  use Phoenix.Component
  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents.ProviderIcon

  describe "provider_icon/1" do
    test "renders an svg for claude, titled with its display name" do
      html = render_component(&provider_icon/1, provider: "claude")

      assert html =~ "<svg"
      assert html =~ ~s(title="Claude")
      assert html =~ ~s(aria-label="Claude")
    end

    test "renders an svg for codex" do
      html = render_component(&provider_icon/1, provider: "codex")

      assert html =~ "<svg"
      assert html =~ ~s(title="Codex")
      assert html =~ ~s(aria-label="Codex")
    end

    test "renders an svg for gemini" do
      html = render_component(&provider_icon/1, provider: "gemini")

      assert html =~ "<svg"
      assert html =~ ~s(title="Gemini")
      assert html =~ ~s(aria-label="Gemini")
    end

    test "falls back to a generic icon for nil" do
      html = render_component(&provider_icon/1, provider: nil)

      assert html =~ "<svg"
      assert html =~ ~s(title="Unknown provider")
      assert html =~ ~s(aria-label="Unknown provider")
    end

    test "falls back to a generic icon for an unrecognized value" do
      html = render_component(&provider_icon/1, provider: "some-future-provider")

      assert html =~ ~s(title="Unknown provider")
    end
  end

  describe "display_name/1" do
    test "returns the display name for a known provider" do
      assert display_name("codex") == "Codex"
    end

    test "returns the fallback name for nil or unknown" do
      assert display_name(nil) == "Unknown provider"
      assert display_name("nope") == "Unknown provider"
    end
  end

  test "every registered agent type has a logo, so a new provider without one fails here" do
    known = ArbiterWeb.CoreComponents.ProviderIcon.__known_providers__()

    for provider <- Arbiter.Agents.valid_agent_types() do
      assert provider in known,
             "#{inspect(provider)} is a valid agent type but has no entry in " <>
               "ArbiterWeb.CoreComponents.ProviderIcon's logo map"
    end
  end
end
