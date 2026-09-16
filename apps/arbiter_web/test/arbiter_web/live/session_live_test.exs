defmodule ArbiterWeb.SessionLiveTest do
  @moduledoc """
  The sessions list and the session page (bd-c76fu9, phase 5 acceptance
  criterion 4).

  The terminal itself is hook-owned and `phx-update="ignore"`, so what a
  LiveView test can prove is exactly the page chrome around it: that the list
  shows sessions and their state, that launch/open/detach/kill do what they
  say, that kill cannot happen without a confirmation, and that the page says
  so when the agent exits. The bytes are covered by the JS suite and by
  `ArbiterWeb.SessionTransportSocketTest`.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Sessions
  alias Arbiter.Test.NoopRunner

  setup do
    Arbiter.Test.SessionEnv.sandbox("session-live")
    put_env(:sessions_runner, NoopRunner)
    :ok
  end

  defp launch!(opts \\ []) do
    {:ok, session} = Sessions.launch(Keyword.put_new(opts, :runner, NoopRunner))
    session
  end

  # `:sessions_runner` is not one of `SessionEnv`'s keys, and the LiveView
  # calls `Sessions.launch/1` with no `:runner` option — it has to resolve the
  # stub from application config or it would really shell out to `systemd-run`.
  # `NoopRunner` rather than `SessionRunnerStub` because the caller is the
  # LiveView process, which has no access to the test's process dictionary.
  defp put_env(key, value) do
    previous = Application.fetch_env(:arbiter, key)
    Application.put_env(:arbiter, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:arbiter, key, old)
        :error -> Application.delete_env(:arbiter, key)
      end
    end)
  end

  describe "the sessions list" do
    test "is reachable from the app navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ ~s(href="/sessions")
    end

    test "shows an empty state when nothing has ever been launched", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#sessions-empty")
      refute has_element?(view, "#sessions-list")
    end

    test "lists sessions newest first with their status and a link to each", %{conn: conn} do
      older = launch!()
      newer = launch!()

      {:ok, view, html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#session-#{older.id}")
      assert has_element?(view, "#session-#{newer.id}")
      assert html =~ ~s(href="/sessions/#{newer.id}")

      assert [first, second] =
               Regex.scan(~r/id="session-([-0-9a-f]+)"/, html, capture: :all_but_first)

      assert first == [newer.id]
      assert second == [older.id]
    end

    test "shows the resolved display name, and the id stays reachable (bd-o2vtsz)", %{conn: conn} do
      named = launch!(name: "refinement session")
      unnamed = launch!()

      {:ok, view, html} = live(conn, ~p"/sessions")

      assert html =~ "refinement session"

      assert has_element?(
               view,
               "#session-#{named.id}-short-id",
               Arbiter.Sessions.DisplayName.short_id(named.id)
             )

      assert has_element?(
               view,
               "#session-#{unnamed.id}-short-id",
               Arbiter.Sessions.DisplayName.short_id(unnamed.id)
             )
    end

    test "an ended session is shown as ended, with the reason it ended", %{conn: conn} do
      session = launch!()
      {:ok, _ended} = Sessions.kill(session.id, runner: NoopRunner, reason: "killed by hand")

      {:ok, view, html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#session-#{session.id}")
      assert html =~ "killed by hand"
    end

    test "a session ending on its own (no Kill click) updates the list live, via PubSub (bd-bsdeb2)",
         %{conn: conn} do
      session = launch!()
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#session-#{session.id}", "running")

      # Simulate the Stream noticing a dead pane, or the periodic reaper
      # noticing a vanished scope — either way `mark_ended/2` is the one
      # place that runs, no Kill click involved.
      {:ok, _ended} = Sessions.mark_ended(session, "exited")

      assert render(view) =~ "exited"
      assert has_element?(view, "#session-#{session.id}", "ended")
    end
  end

  describe "launching" do
    test "the launch button provisions a session with the phase-5 defaults and opens it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#launch-session")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> form("#launch-session-form") |> render_submit()

      assert [session] = Sessions.list()
      assert to == "/sessions/#{session.id}"

      # §10.1 / the phase-5 scope: mode B, cross-workspace, dispatch off. The
      # full pre-launch options UI is phase 11.
      assert session.auth_mode == :seeded_credentials
      assert session.workspace_id == nil
      assert session.can_dispatch == false
      assert session.status == :running
      assert session.name == nil
    end

    test "an operator-supplied name reaches the session row (bd-o2vtsz)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert {:error, {:live_redirect, _}} =
               view
               |> form("#launch-session-form", %{"name" => "refinement session"})
               |> render_submit()

      assert [session] = Sessions.list()
      assert session.name == "refinement session"
    end

    test "a blank name launches with no name, same as leaving it empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert {:error, {:live_redirect, _}} =
               view |> form("#launch-session-form", %{"name" => "   "}) |> render_submit()

      assert [session] = Sessions.list()
      assert session.name == nil
    end

    test "a failed launch reports why and leaves the operator on the list", %{conn: conn} do
      put_env(:sessions_runner, Arbiter.Test.FailingSessionRunner)

      {:ok, view, _html} = live(conn, ~p"/sessions")

      html = view |> form("#launch-session-form") |> render_submit()

      assert html =~ "Could not launch"
      assert has_element?(view, "#launch-session")
    end
  end

  describe "killing" do
    test "kill asks for confirmation first and does nothing until it gets one", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions")

      refute has_element?(view, "#kill-session-modal")

      view |> element("#kill-session-#{session.id}") |> render_click()
      assert has_element?(view, "#kill-session-modal")

      # Still running: opening the confirmation is not the action.
      assert {:ok, %{status: :running}} = Sessions.get(session.id)

      view |> element("#cancel-kill") |> render_click()
      refute has_element?(view, "#kill-session-modal")
      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end

    test "confirming the kill ends the session and says so in the list", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions")

      view |> element("#kill-session-#{session.id}") |> render_click()
      html = view |> element("#confirm-kill") |> render_click()

      assert {:ok, %{status: :ended}} = Sessions.get(session.id)
      refute has_element?(view, "#kill-session-modal")
      assert html =~ "ended"
    end
  end

  describe "the session page" do
    test "hosts a hook-owned terminal that names the session it attaches to", %{conn: conn} do
      session = launch!()

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

      terminal = "#session-terminal-#{session.id}"
      assert has_element?(view, terminal)

      # The hook owns this subtree; LiveView must never diff into it.
      assert html =~ ~s(phx-update="ignore")
      assert html =~ ~s(data-session-id="#{session.id}")
      assert html =~ "SessionTerminal"

      # §6.3: page chrome must not fight the terminal for space, and a narrow
      # viewport scrolls the terminal rather than the page.
      assert has_element?(view, "#terminal-scroller")
      assert has_element?(view, "#terminal-status")

      # The live cost HUD slot (§7.5, phase 7): hook-owned, same as the rest
      # of the strip, updated from `usage` channel events rather than a
      # LiveView diff.
      assert has_element?(view, ~s(#terminal-status [data-role="usage"]))
    end

    test "a non-loopback peer sees a notice instead of an inert terminal, and is told Remote Control works (mode B, launched with --remote-control, bd-2zskbb)",
         %{conn: conn} do
      session = launch!(auth_mode: :seeded_credentials, remote_control: true)

      conn =
        Plug.Test.put_peer_data(conn, %{address: {192, 168, 1, 38}, port: 55_555, ssl_cert: nil})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#session-terminal-#{session.id}")
      refute has_element?(view, "#terminal-status")
      assert has_element?(view, "#terminal-remote-notice")
      assert has_element?(view, "#terminal-remote-notice", "loopback-only")

      assert has_element?(
               view,
               "#terminal-remote-notice",
               "Reach it from another device via Remote Control"
             )
    end

    test "a non-loopback peer under mode B but launched without --remote-control is told the precondition plainly rather than told it works (bd-2zskbb)",
         %{conn: conn} do
      session = launch!(auth_mode: :seeded_credentials, remote_control: false)

      conn =
        Plug.Test.put_peer_data(conn, %{address: {192, 168, 1, 38}, port: 55_555, ssl_cert: nil})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#session-terminal-#{session.id}")
      assert has_element?(view, "#terminal-remote-notice")
      assert has_element?(view, "#terminal-remote-notice", "this one was not launched with it")

      refute has_element?(
               view,
               "#terminal-remote-notice",
               "Reach it from another device via Remote Control."
             )
    end

    test "a non-loopback peer under a workspace token (mode A) is told Remote Control will not work either (bd-2zskbb)",
         %{conn: conn} do
      session =
        launch!(auth_mode: :oauth_token, oauth_token: "sk-ant-oat01-SESSION-LIVE-TEST-TOKEN")

      conn =
        Plug.Test.put_peer_data(conn, %{address: {192, 168, 1, 38}, port: 55_555, ssl_cert: nil})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#session-terminal-#{session.id}")
      assert has_element?(view, "#terminal-remote-notice")
      assert has_element?(view, "#terminal-remote-notice", "does not support Remote Control")
    end

    test "a non-loopback peer never sees the stall banner alongside the remote notice (bd-2zskbb)",
         %{conn: conn} do
      session = launch!(auth_mode: :seeded_credentials, remote_control: true)

      conn =
        Plug.Test.put_peer_data(conn, %{address: {192, 168, 1, 38}, port: 55_555, ssl_cert: nil})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#terminal-remote-notice")
      refute has_element?(view, "#terminal-stalled")

      # This is the case the ticket says "Refreshing does not help, and
      # cannot": the stall check must not fire the "Reload the page" banner
      # off-loopback, since there is no hook there to ever go live.
      send(view.pid, :terminal_stall_check)
      refute has_element?(view, "#terminal-stalled")
    end

    test "a loopback peer attaches exactly as before, with no extra banner (bd-2zskbb)", %{
      conn: conn
    } do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#session-terminal-#{session.id}")
      refute has_element?(view, "#terminal-remote-notice")
    end

    test "a narrow viewport scrolls the terminal, not the page (§6.3)", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # The container scrolls sideways...
      assert has_element?(view, "#terminal-scroller.overflow-x-auto")

      # ...and the pane keeps a floor width rather than shrinking the font to
      # illegibility. A terminal cannot reflow meaningfully below ~80 columns;
      # `scripts/verify_session_terminal.mjs` checks in a real browser that
      # this floor really does fit 80 of them.
      assert has_element?(
               view,
               ~s(#session-terminal-#{session.id}[class*="min-w-[640px]"])
             )
    end

    test "a session that no longer exists redirects back to the list", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/sessions"}}} =
               live(conn, ~p"/sessions/00000000-0000-0000-0000-000000000000")
    end

    test "detach leaves the session running and returns to the list", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert {:error, {:live_redirect, %{to: "/sessions"}}} =
               view |> element("#detach-session") |> render_click()

      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end

    test "keep_alive can be pinned and unpinned from the session page (§4.6 item 2)", %{
      conn: conn
    } do
      session = launch!()
      refute session.keep_alive

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      html = view |> element("#toggle-keep-alive") |> render_click()
      assert html =~ "Unpin keep_alive"
      assert {:ok, %{keep_alive: true}} = Sessions.get(session.id)

      html = view |> element("#toggle-keep-alive") |> render_click()
      assert html =~ "Pin keep_alive"
      assert {:ok, %{keep_alive: false}} = Sessions.get(session.id)
    end

    test "kill from the session page also needs a confirmation", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#kill-session-modal")
      view |> element("#kill-session") |> render_click()
      assert has_element?(view, "#kill-session-modal")
      assert {:ok, %{status: :running}} = Sessions.get(session.id)

      view |> element("#confirm-kill") |> render_click()
      assert {:ok, %{status: :ended}} = Sessions.get(session.id)
    end

    test "the page shows that the agent exited, and with what code", %{conn: conn} do
      session = launch!()

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")
      refute html =~ "Agent exited"

      # The hook forwards the channel's `exit` event; the row itself is only
      # updated by whatever reaps the session, which may be much later.
      html = render_hook(view, "agent_exited", %{"code" => 137, "reason" => "killed"})

      assert html =~ "Agent exited"
      assert html =~ "137"
      assert has_element?(view, "#session-exit")
    end

    test "the page's own status chip flips to ended too, when the row was already ended by the time the exit event arrives (bd-bsdeb2)",
         %{conn: conn} do
      session = launch!()

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")
      assert html =~ "running"

      # `Arbiter.Sessions.Stream` now runs `mark_ended/2` before broadcasting
      # the exit, so by the time the channel's `exit` event reaches the hook
      # and the hook forwards `agent_exited`, the row is already `:ended`.
      {:ok, _ended} = Sessions.mark_ended(session, "exited")

      html = render_hook(view, "agent_exited", %{"code" => nil, "reason" => "exited"})

      assert html =~ "ended"
      assert html =~ "exited"
    end

    test "an exit replaces the terminal with the nothing-to-attach-to state",
         %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, "#session-terminal-#{session.id}")

      render_hook(view, "agent_exited", %{"code" => 0, "reason" => nil})

      # bd-3r2otb: the page used to keep the dead pane mounted, so an operator
      # who killed a session was left looking at a terminal that no longer did
      # anything. Removing the element is also what closes the channel: the
      # hook's `destroyed()` disposes the socket.
      refute has_element?(view, "#session-terminal-#{session.id}")
      assert has_element?(view, "#terminal-inactive")

      # The strip is hook-owned, and there is no hook left to own it.
      refute has_element?(view, "#terminal-status")

      # ...and there is nothing left to detach from.
      refute has_element?(view, "#detach-session")
    end

    test "killing from the page replaces the terminal without a reload", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, "#session-terminal-#{session.id}")

      view |> element("#kill-session") |> render_click()
      view |> element("#confirm-kill") |> render_click()

      assert has_element?(view, "#terminal-inactive")
      refute has_element?(view, "#session-terminal-#{session.id}")
      assert has_element?(view, "#session-exit")
    end

    test "says so when the terminal never connects", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute has_element?(view, "#terminal-stalled")

      # The check the LiveView schedules for itself at mount. The live failure
      # this covers was a page whose hook never started at all — a tab running
      # an asset bundle from before the deploy — which the hook-painted status
      # strip reports as "connecting…" forever, with nothing to click and
      # nothing in the page to say why.
      send(view.pid, :terminal_stall_check)
      assert has_element?(view, "#terminal-stalled")

      # A late join clears it: the message is advisory, not a verdict.
      render_hook(view, "terminal_live", %{})
      refute has_element?(view, "#terminal-stalled")
    end

    test "a terminal that connected in time never mentions a stall", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_hook(view, "terminal_live", %{})
      send(view.pid, :terminal_stall_check)

      refute has_element?(view, "#terminal-stalled")
    end

    test "a session that was already over shows no hook-owned status strip",
         %{conn: conn} do
      session = launch!()
      {:ok, _} = Sessions.kill(session.id, runner: NoopRunner, reason: "reaped")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # The strip's text is painted by the hook, and no hook mounts here, so a
      # rendered strip would read "connecting…" forever directly above the
      # "nothing to attach to" placeholder.
      refute has_element?(view, "#terminal-status")
      assert has_element?(view, "#terminal-inactive")
    end

    test "a session whose row is already ended says so without needing the hook",
         %{conn: conn} do
      session = launch!()
      {:ok, _} = Sessions.kill(session.id, runner: NoopRunner, reason: "reaped")

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#session-exit")
      assert html =~ "reaped"
      # Nothing to attach to, so no terminal and no dangling channel.
      refute has_element?(view, "#session-terminal-#{session.id}")
    end
  end
end
