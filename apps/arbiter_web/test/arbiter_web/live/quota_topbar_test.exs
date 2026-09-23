defmodule ArbiterWeb.QuotaTopbarTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace

  import ArbiterWeb.QuotaFixtures

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

  test "renders one labeled bar-pair per tracked provider (codex is filtered)", %{
    conn: conn,
    ws: ws
  } do
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

  test "the usage page shows one card group per tracked provider (codex is filtered)", %{
    conn: conn,
    ws: ws
  } do
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

  test "topbar filters gemini_cli but shows antigravity", %{conn: conn, ws: ws} do
    {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.5"}],
        provider: "gemini_cli"
      )

    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.5"}],
        provider: "codex"
      )

    antigravity_quota!(ws)

    {:ok, view, html} = live(conn, "/")

    assert html =~ "Claude"
    assert html =~ "Antigravity"
    refute html =~ "Gemini CLI"
    refute html =~ "Codex"
    assert has_element?(view, "#quota-topbar-antigravity", "Antigravity")
  end

  test "usage page filters gemini_cli but shows antigravity", %{conn: conn, ws: ws} do
    {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

    {:ok, _} =
      Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.5"}],
        provider: "gemini_cli"
      )

    antigravity_quota!(ws)

    {:ok, view, html} = live(conn, "/usage")

    assert html =~ "Claude"
    refute html =~ "Gemini CLI"
    assert has_element?(view, "#usage-quota-antigravity", "Antigravity")
  end

  describe "antigravity in the top bar (bd-gukyy1)" do
    test "stacks one row per provider, each with its two windows, beside the chrome", %{
      conn: conn,
      ws: ws
    } do
      {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])
      antigravity_quota!(ws)

      {:ok, view, html} = live(conn, "/")
      doc = LazyHTML.from_fragment(html)

      assert has_element?(view, "#quota-topbar.max-lg\\:hidden")
      assert has_element?(view, "#quota-topbar #quota-topbar-claude", "Claude")
      assert has_element?(view, "#quota-topbar #quota-topbar-antigravity", "Antigravity")
      assert bars(doc, "#quota-topbar") == 4
      assert bars(doc, "#quota-topbar-claude") == 2
      assert bars(doc, "#quota-topbar-antigravity") == 2

      assert labels(doc, "#quota-topbar-claude") == ["5h", "7d"]
      assert labels(doc, "#quota-topbar-antigravity") == ["5h", "weekly"]

      assert has_element?(view, "#appshell-live")
      assert has_element?(view, "#coordinator-inbox-trigger")
      assert has_element?(view, "#theme-toggle")
    end

    test "the antigravity bars carry the Gemini Models buckets", %{conn: conn, ws: ws} do
      antigravity_quota!(ws)

      {:ok, _view, html} = live(conn, "/")
      doc = LazyHTML.from_fragment(html)

      # gemini_models_5h is 25% used, gemini_models_weekly 60% used.
      assert pcts(doc, "#quota-topbar-antigravity") == ["25%", "60%"]
    end

    test "successive broadcasts update the one antigravity block in place", %{conn: conn, ws: ws} do
      {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, "#quota-topbar-antigravity")

      broadcast!(antigravity_quota!(ws, gemini_5h_remaining: 90.0))
      broadcast!(antigravity_quota!(ws, gemini_5h_remaining: 30.0))

      doc = view |> render() |> LazyHTML.from_fragment()
      assert doc |> LazyHTML.query("#quota-topbar-antigravity") |> Enum.count() == 1
      assert pcts(doc, "#quota-topbar-antigravity") == ["70%", "60%"]
    end

    test "a stale reading (non-nil message) is muted with the message in its title", %{
      conn: conn,
      ws: ws
    } do
      antigravity_quota!(ws, message: agy_missing_message())

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#quota-topbar-antigravity [data-quota-bar][data-quota-stale]")
      assert has_element?(view, "#quota-topbar-antigravity [data-quota-note]", "stale")

      assert has_element?(
               view,
               ~s(#quota-topbar-antigravity [data-quota-bar][title*="is not installed on this host"])
             )
    end

    test "a snapshot with no parseable buckets renders the single collapsed bar", %{
      conn: conn,
      ws: ws
    } do
      antigravity_quota!(ws, models: [])

      {:ok, _view, html} = live(conn, "/")
      doc = LazyHTML.from_fragment(html)

      assert bars(doc, "#quota-topbar-antigravity") == 1
      assert labels(doc, "#quota-topbar-antigravity") == ["used"]
    end
  end

  defp bars(doc, scope), do: doc |> LazyHTML.query("#{scope} [data-quota-bar]") |> Enum.count()

  defp labels(doc, scope),
    do:
      doc
      |> LazyHTML.query("#{scope} [data-quota-label]")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))

  defp pcts(doc, scope),
    do:
      doc
      |> LazyHTML.query("#{scope} [data-quota-bar] [data-quota-pct]")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))

  # The production fan-out `CloudCode.refresh/2` ends in: account → every
  # workspace it meters → `{:quota_updated, ws_id, view}`.
  defp broadcast!(row) do
    Arbiter.Quota.Broadcast.quota_updated(
      row.provider_account_id,
      Arbiter.Quota.CloudCode.view(row)
    )
  end
end
