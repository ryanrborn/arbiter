defmodule ArbiterWeb.UsageLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ArbiterWeb.QuotaFixtures

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "usage-#{System.unique_integer([:positive])}", prefix: "usg"})

    {:ok, ws: ws}
  end

  defp new_issue!(ws, title) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    issue
  end

  defp event!(attrs) do
    base = %{
      repo: "arbiter",
      step: :work,
      occurred_at: DateTime.utc_now(),
      model: "sonnet"
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  test "renders header, stat row, and the by-task table", %{conn: conn, ws: ws} do
    single = new_issue!(ws, "Collapse duplicate status helpers")
    reworked = new_issue!(ws, "Loop proposal queue: apply / reject")

    event!(%{
      task_id: single.id,
      workspace_id: ws.id,
      cost_usd: 0.42,
      tokens_in: 30_000,
      tokens_out: 8_400
    })

    event!(%{
      task_id: reworked.id,
      workspace_id: ws.id,
      cost_usd: 0.60,
      tokens_in: 40_000,
      tokens_out: 10_000
    })

    event!(%{
      task_id: reworked.id,
      workspace_id: ws.id,
      cost_usd: 0.28,
      tokens_in: 10_000,
      tokens_out: 4_000
    })

    {:ok, _view, html} = live(conn, ~p"/usage")

    assert html =~ "Usage"
    assert html =~ "Total spend"
    assert html =~ "$1.30"
    assert html =~ "Rework tasks"
    assert html =~ single.id
    assert html =~ "Collapse duplicate status helpers"
    assert html =~ reworked.id
  end

  test "rework metrics collapse ReviewGate synthetic task ids to the base task", %{
    conn: conn,
    ws: ws
  } do
    task = new_issue!(ws, "Probe task two")
    now = DateTime.utc_now()

    event!(%{
      task_id: task.id,
      workspace_id: ws.id,
      step: :work,
      cost_usd: 2.0,
      occurred_at: DateTime.add(now, -20, :minute)
    })

    event!(%{
      task_id: "#{task.id}#review",
      workspace_id: ws.id,
      step: :work,
      cost_usd: 1.0,
      occurred_at: DateTime.add(now, -10, :minute)
    })

    event!(%{
      task_id: "#{task.id}#review",
      workspace_id: ws.id,
      step: :review,
      cost_usd: 0.5,
      occurred_at: now
    })

    {:ok, _view, html} = live(conn, ~p"/usage")

    assert html =~ "$3.50"
    assert [_] = Regex.scan(~r/Probe task two/, html)
    assert html =~ "$1.00"
    refute html =~ "$2.00"
  end

  test "switching to the By model tab renders per-model bars", %{conn: conn, ws: ws} do
    task = new_issue!(ws, "Some task")
    event!(%{task_id: task.id, workspace_id: ws.id, model: "claude-sonnet-4-6", cost_usd: 1.0})
    event!(%{task_id: task.id, workspace_id: ws.id, model: "claude-opus-4-6", cost_usd: 0.5})

    {:ok, view, _html} = live(conn, ~p"/usage")

    html =
      view
      |> element("button[phx-value-tab=by_model]")
      |> render_click()

    assert html =~ "Sonnet"
    assert html =~ "Opus"
  end

  test "switching to the By repo tab renders per-repo bars", %{conn: conn, ws: ws} do
    task = new_issue!(ws, "Some task")
    event!(%{task_id: task.id, workspace_id: ws.id, repo: "arbiter", cost_usd: 1.0})
    event!(%{task_id: task.id, workspace_id: ws.id, repo: "apex-api", cost_usd: 0.4})

    {:ok, view, _html} = live(conn, ~p"/usage")

    html =
      view
      |> element("button[phx-value-tab=by_repo]")
      |> render_click()

    assert html =~ "arbiter"
    assert html =~ "apex-api"
  end

  test "changing the range segmented control reloads data", %{conn: conn, ws: ws} do
    task = new_issue!(ws, "Old task")

    event!(%{
      task_id: task.id,
      workspace_id: ws.id,
      cost_usd: 5.0,
      occurred_at: DateTime.add(DateTime.utc_now(), -40, :day)
    })

    {:ok, view, _html} = live(conn, ~p"/usage")

    html =
      view
      |> element("button[phx-value-option='all']")
      |> render_click()

    assert html =~ "$5.00"

    html =
      view
      |> element("button[phx-value-option='7d']")
      |> render_click()

    refute html =~ "$5.00"
  end

  # bd-481sz7 round 2, finding 4: agy rows carry `cost_usd: nil` (subscription,
  # not a priced API) — before this fix the dashboard folded that nil to 0.0
  # and rendered "$0.00" (Total spend, By task, By model), contradicting the
  # CLI/API's "n/a" for the same all-agy window.
  test "an all-agy window (unpriced rows) never renders $0.00 for spend", %{conn: conn, ws: ws} do
    task = new_issue!(ws, "agy-only task")

    event!(%{
      task_id: task.id,
      workspace_id: ws.id,
      model: "gemini-3.8-flash-low",
      cost_usd: nil,
      tokens_in: 4_000,
      tokens_out: 250
    })

    {:ok, view, html} = live(conn, ~p"/usage")

    [_, total_spend_value] =
      Regex.run(~r/Total spend\s*<\/span><span[^>]*>\s*([^<]+?)\s*<\/span>/s, html)

    assert total_spend_value == "—"

    by_model_html =
      view
      |> element("button[phx-value-tab=by_model]")
      |> render_click()

    [_, model_bar_segment] = Regex.run(~r/(Flash.{0,700})/s, by_model_html)
    refute model_bar_segment =~ "$0.00"
    assert model_bar_segment =~ "—"
  end

  test "shows an empty state when there is no usage yet", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/usage")
    assert html =~ "Usage"
    assert html =~ "$0.00"
  end

  test "renders Rate limits and Rework panels", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/usage")
    assert html =~ "Rate limits"
    assert html =~ "Rework"
    assert html =~ "hairline is elapsed time"
  end

  test "stat row and spend/rate-limits panels use responsive grid layouts for mobile", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, ~p"/usage")
    # Stat row should stack 2x2 on mobile (grid-cols-2) and 4-across on desktop (sm:grid-cols-4)
    assert html =~ "grid-cols-2"
    assert html =~ "sm:grid-cols-4"

    # Spend/Rate-limits should stack vertically on mobile (grid-cols-1) and side-by-side on desktop
    assert html =~ "grid-cols-1"
    assert html =~ "lg:grid-cols-[minmax(0,1fr)_320px]"
  end

  describe "Rate limits panel with antigravity (bd-gukyy1)" do
    test "antigravity renders four bars in two labelled groups; claude stays a pair", %{
      conn: conn,
      ws: ws
    } do
      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

      antigravity_quota!(ws)

      {:ok, view, html} = live(conn, ~p"/usage")
      doc = LazyHTML.from_fragment(html)

      assert quota_bars(doc, "#usage-quota-claude") == 2
      assert quota_bars(doc, "#usage-quota-antigravity") == 4

      gemini = "#usage-quota-antigravity-gemini_models"
      claude_gpt = "#usage-quota-antigravity-claude_and_gpt_models"

      assert has_element?(view, gemini, "Gemini Models")
      assert has_element?(view, claude_gpt, "Claude and GPT models")
      assert quota_pcts(doc, gemini) == ["25%", "60%"]
      assert quota_pcts(doc, claude_gpt) == ["10%", "20%"]
      assert quota_labels(doc, gemini) == ["5h", "weekly"]
      assert quota_labels(doc, claude_gpt) == ["5h", "weekly"]
    end

    test "a stale antigravity reading is muted with the message in its title", %{
      conn: conn,
      ws: ws
    } do
      antigravity_quota!(ws, message: agy_missing_message())

      {:ok, view, _html} = live(conn, ~p"/usage")

      assert has_element?(view, "#usage-quota-antigravity [data-quota-bar][data-quota-stale]")

      refute has_element?(
               view,
               "#usage-quota-antigravity [data-quota-bar]:not([data-quota-stale])"
             )

      assert has_element?(view, "#usage-quota-antigravity [data-quota-note]", "stale")

      assert has_element?(
               view,
               ~s(#usage-quota-antigravity [data-quota-bar][title*="is not installed on this host"])
             )
    end

    test "a snapshot with no parseable buckets renders the single collapsed bar", %{
      conn: conn,
      ws: ws
    } do
      antigravity_quota!(ws, models: [])

      {:ok, _view, html} = live(conn, ~p"/usage")
      doc = LazyHTML.from_fragment(html)

      assert quota_bars(doc, "#usage-quota-antigravity") == 1
      assert quota_labels(doc, "#usage-quota-antigravity") == ["used"]
    end
  end

  defp quota_bars(doc, scope),
    do: doc |> LazyHTML.query("#{scope} [data-quota-bar]") |> Enum.count()

  defp quota_labels(doc, scope),
    do:
      doc
      |> LazyHTML.query("#{scope} [data-quota-label]")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))

  defp quota_pcts(doc, scope),
    do:
      doc
      |> LazyHTML.query("#{scope} [data-quota-pct]")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))
end
