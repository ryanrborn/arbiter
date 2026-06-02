defmodule ArbiterWeb.GlobalBrandingLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Settings

  describe "mount" do
    test "renders the JSON editor + neutral-default preview", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/branding")

      assert html =~ "Branding settings"
      assert html =~ "JSON editor"
      # The neutral default wordmark/mark/favicon are previewed.
      assert html =~ "/images/arbiter-wordmark.png"
      assert html =~ "/images/arbiter-mark.png"
      assert html =~ "theme default"
    end
  end

  describe "live editing" do
    test "valid JSON updates the preview without saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/branding")

      new_json = ~s|{"name": "Eclipse", "accent": "oklch(58% 0.233 277.117)"}|
      html = render_change(view, "update_json", %{"branding" => %{"json" => new_json}})

      assert html =~ "Eclipse"
      assert html =~ "oklch(58% 0.233 277.117)"
      # Not persisted yet.
      {:ok, settings} = Settings.get()
      assert settings.branding == %{}
    end

    test "invalid JSON shows error, no save", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/branding")

      html = render_change(view, "update_json", %{"branding" => %{"json" => ~s({"name": )}})
      assert html =~ "invalid JSON"
    end
  end

  describe "save" do
    test "save writes branding to global settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/branding")

      new_json = ~s({"name": "Penumbral Arbiter", "wordmark": "/images/eclipse-wordmark.png"})
      render_change(view, "update_json", %{"branding" => %{"json" => new_json}})
      render_submit(view, "save", %{})

      {:ok, settings} = Settings.get()
      assert settings.branding["name"] == "Penumbral Arbiter"
      assert settings.branding["wordmark"] == "/images/eclipse-wordmark.png"
    end

    test "save with non-object JSON is rejected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/branding")

      render_change(view, "update_json", %{"branding" => %{"json" => ~s("just a string")}})
      render_submit(view, "save", %{})

      assert render(view) =~ "must be an object"
      {:ok, settings} = Settings.get()
      assert settings.branding == %{}
    end
  end

  describe "reset to defaults" do
    test "clears overrides back to the neutral default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/branding")

      render_change(view, "update_json", %{"branding" => %{"json" => ~s({"name": "X"})}})
      assert render(view) =~ "X"

      html = render_click(view, "reset", %{})
      # Back to the neutral default name in the preview top bar.
      assert html =~ ~s(alt="Arbiter")
    end
  end
end
