defmodule ArbiterWeb.QuotaTopbarTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace

  setup do
    ws = Ash.create!(Workspace, %{name: "default"})
    {:ok, ws: ws}
  end

  test "renders exactly one bar-pair when only claude has been captured (no regression)", %{
    conn: conn,
    ws: ws
  } do
    {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Claude"
    refute html =~ "Codex"
  end

  test "renders one labeled bar-pair per tracked provider (codex is filtered)", %{conn: conn, ws: ws} do
    {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.5"}],
        provider: "codex"
      )

    {:ok, _view, html} = live(conn, "/")

    # Codex is filtered from the UI while dispatch is broken (bd-brr92u)
    assert html =~ "Claude"
    refute html =~ "Codex"
  end

  test "live-updates the matching provider's bar on a quota_updated broadcast", %{
    conn: conn,
    ws: ws
  } do
    {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

    {:ok, view, _html} = live(conn, "/")

    {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.9"}])

    html = render(view)
    assert html =~ "width: 90%"
  end

  test "the usage page shows one card group per tracked provider (codex is filtered)", %{conn: conn, ws: ws} do
    {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.5"}],
        provider: "codex"
      )

    {:ok, _view, html} = live(conn, "/usage")

    # Codex is filtered from the UI while dispatch is broken (bd-brr92u)
    assert html =~ "Claude"
    refute html =~ "Codex"
  end

  test "topbar filters gemini_cli and antigravity", %{conn: conn, ws: ws} do
    {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.5"}],
        provider: "gemini_cli"
      )

    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.6"}],
        provider: "antigravity"
      )

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Claude"
    refute html =~ "Gemini CLI"
    refute html =~ "Antigravity"
  end

  test "usage page filters gemini_cli and antigravity", %{conn: conn, ws: ws} do
    {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.5"}],
        provider: "gemini_cli"
      )

    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.6"}],
        provider: "antigravity"
      )

    {:ok, _view, html} = live(conn, "/usage")

    assert html =~ "Claude"
    refute html =~ "Gemini CLI"
    refute html =~ "Antigravity"
  end
end
