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

  # bd-clzkvp: the bars colour by the dispatch gate's pace verdict for the
  # linked account, and say whether the gate is holding or only would hold.
  describe "bar colour follows the gate's pace verdict" do
    defp link_account!(ws, quota_config) do
      account =
        Ash.create!(Arbiter.Accounts.ProviderAccount, %{
          provider: :claude,
          slug: "acct-#{System.unique_integer([:positive])}",
          quota_config: quota_config
        })

      Ash.create!(Arbiter.Accounts.WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :claude,
        provider_account_id: account.id
      })
    end

    # `u5` used 10% into the 5h window; `u7` used 29% into the 7d window.
    defp capture!(ws, u5, u7 \\ 0.01) do
      now = DateTime.to_unix(DateTime.utc_now())

      {:ok, _} =
        Quota.capture(ws.id, [
          {"anthropic-ratelimit-unified-5h-utilization", to_string(u5)},
          {"anthropic-ratelimit-unified-5h-reset", to_string(now + round(0.9 * 18_000))},
          {"anthropic-ratelimit-unified-5h-status", "allowed"},
          {"anthropic-ratelimit-unified-7d-utilization", to_string(u7)},
          {"anthropic-ratelimit-unified-7d-reset", to_string(now + round(0.71 * 604_800))},
          {"anthropic-ratelimit-unified-7d-status", "allowed"}
        ])
    end

    test "a paced account's 5h bar is red and holding, on the top bar and /usage", %{
      conn: conn,
      ws: ws
    } do
      link_account!(ws, %{"threshold_mode" => "paced"})
      capture!(ws, 0.4)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(
               view,
               "#quota-topbar-claude-5h[data-quota-state=red][data-quota-hold=enforcing]"
             )

      {:ok, usage, _html} = live(conn, "/usage")

      assert has_element?(
               usage,
               "#usage-quota-claude [data-quota-state=red][data-quota-hold=enforcing]"
             )
    end

    test "a flat account's bar is red at the paced thresholds but only would hold", %{
      conn: conn,
      ws: ws
    } do
      link_account!(ws, %{})
      capture!(ws, 0.4)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(
               view,
               "#quota-topbar-claude-5h[data-quota-state=red][data-quota-hold=not_enforcing]"
             )

      assert view |> element("#quota-topbar-claude-5h") |> render() =~ "(gate not enforcing)"
    end

    test "the account's floors reach the bar: 7d at 35% / 29% is red only if the gate holds", %{
      conn: conn,
      ws: ws
    } do
      link_account!(ws, %{"threshold_mode" => "paced", "weekly_paced_floor" => 0.4})
      capture!(ws, 0.01, 0.35)

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#quota-topbar-claude-7d[data-quota-state=amber]")
      refute has_element?(view, "#quota-topbar-claude-7d[data-quota-hold]")
    end

    test "a live update keeps the account's gate policy", %{conn: conn, ws: ws} do
      link_account!(ws, %{"threshold_mode" => "paced"})
      capture!(ws, 0.1)

      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, "#quota-topbar-claude-5h[data-quota-hold]")

      capture!(ws, 0.4)

      assert has_element?(
               view,
               "#quota-topbar-claude-5h[data-quota-state=red][data-quota-hold=enforcing]"
             )
    end
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
