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
          quota_on_exhaustion: :ask
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
        >
          content
        </Layouts.app>
        """
      end,
      assigns
    )
  end

  describe "app/1 — nav" do
    test "renders the 9 nav entries in the new order, with renamed labels" do
      html = render_app()

      order = [
        "Board",
        "Issues",
        "Workers",
        "Merge queue",
        "Workspaces",
        "Skills",
        "Loop",
        "Usage",
        "Audit"
      ]

      indices = Enum.map(order, fn label -> :binary.match(html, label) |> elem(0) end)

      assert indices == Enum.sort(indices)
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

  describe "app/1 — flash" do
    test "renders flash via the toast group, not the old flash_group" do
      html = render_app(%{flash: %{"info" => "Saved"}})

      assert html =~ "Saved"
      assert html =~ "toast-group"
    end
  end
end
