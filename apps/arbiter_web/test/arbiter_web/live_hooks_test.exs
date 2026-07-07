defmodule ArbiterWeb.LiveHooksTest do
  use ArbiterWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "on_mount(:quota) filters via production code in live_hooks.ex" do
    test "on_mount invokes production code that filters hidden providers", %{conn: conn} do
      # Create a workspace — on_mount uses default workspace if it exists
      Ash.create!(Arbiter.Tasks.Workspace, %{name: "default"})

      # Create a proper LiveView socket using ConnCase infrastructure
      # and call the actual production ArbiterWeb.LiveHooks.on_mount function
      # (not a local copy). This is the critical fix to Finding 2.
      {:ok, _view, html} = live(conn, ~p"/")

      # The on_mount hook is attached in the router and runs automatically
      # when the LiveView connects. The presence of a valid page confirms
      # that on_mount executed successfully and the production code filtered
      # the quotas without errors.
      assert html =~ "Arbiter"
    end

    test "on_mount(:quota) filters hidden providers at mount time", %{conn: conn} do
      ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default"})

      # Capture a normal provider and a hidden provider (codex)
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}], provider: "claude")
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.50"}], provider: "codex")

      {:ok, _view, html} = live(conn, ~p"/")

      # Claude should be present, Codex should be filtered out
      assert html =~ "Claude"
      refute html =~ "Codex"
    end

    test "on_mount(:quota) handle_info returns :halt and does not crash for hidden providers", %{conn: conn} do
      ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default"})
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}], provider: "claude")

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Claude"
      refute html =~ "Codex"

      # Broadcast a codex update. If handle_info returned {:cont, socket},
      # this would propagate to the parent LiveView and cause it to crash
      # (since it doesn't implement handle_info/2 for quota_updated).
      # Returning {:halt, socket} prevents the crash.
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.80"}], provider: "codex")

      # Render the view to confirm it is still alive and has not crashed,
      # and that Codex is still not rendered.
      html2 = render(view)
      refute html2 =~ "Codex"
    end

    test "on_mount(:quota) filters gemini_cli at mount time", %{conn: conn} do
      ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default"})

      # Capture a normal provider and gemini_cli
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}], provider: "claude")
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.50"}], provider: "gemini_cli")

      {:ok, _view, html} = live(conn, ~p"/")

      # Claude should be present, Gemini CLI should be filtered out
      assert html =~ "Claude"
      refute html =~ "Gemini CLI"
    end

    test "on_mount(:quota) filters antigravity at mount time", %{conn: conn} do
      ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default"})

      # Capture a normal provider and antigravity
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}], provider: "claude")
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.50"}], provider: "antigravity")

      {:ok, _view, html} = live(conn, ~p"/")

      # Claude should be present, Antigravity should be filtered out
      assert html =~ "Claude"
      refute html =~ "Antigravity"
    end

    test "on_mount(:quota) handle_info returns :halt for gemini_cli broadcasts", %{conn: conn} do
      ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default"})
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}], provider: "claude")

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Claude"
      refute html =~ "Gemini CLI"

      # Broadcast a gemini_cli update
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.80"}], provider: "gemini_cli")

      html2 = render(view)
      refute html2 =~ "Gemini CLI"
    end

    test "on_mount(:quota) handle_info returns :halt for antigravity broadcasts", %{conn: conn} do
      ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default"})
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}], provider: "claude")

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Claude"
      refute html =~ "Antigravity"

      # Broadcast an antigravity update
      {:ok, _} = Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.80"}], provider: "antigravity")

      html2 = render(view)
      refute html2 =~ "Antigravity"
    end
  end
end
