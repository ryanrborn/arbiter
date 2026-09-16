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

  describe "Remote Control gating in the launch form (§8.3)" do
    test "mode B (the default) leaves the Remote Control checkbox enabled, no reason shown",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      refute has_element?(view, "#launch-session-remote-control[disabled]")
      refute has_element?(view, "#launch-session-remote-control-reason")
    end

    test "selecting mode A disables the checkbox and shows the reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      html =
        view
        |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
        |> render_change()

      assert html =~ ~s(id="launch-session-remote-control-reason")

      assert has_element?(view, "#launch-session-remote-control[disabled]")
    end

    test "switching back to mode B re-enables the checkbox", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      view
      |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
      |> render_change()

      assert has_element?(view, "#launch-session-remote-control[disabled]")

      view
      |> form("#launch-session-form", %{"auth_mode" => "seeded_credentials"})
      |> render_change()

      refute has_element?(view, "#launch-session-remote-control[disabled]")
    end

    test "launching under mode B with the box checked records remote_control: true",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert {:error, {:live_redirect, _}} =
               view
               |> form("#launch-session-form", %{
                 "auth_mode" => "seeded_credentials",
                 "remote_control" => "true"
               })
               |> render_submit()

      assert [session] = Sessions.list()
      assert session.auth_mode == :seeded_credentials
      assert session.remote_control == true
    end

    test "a submission that spoofs remote_control under mode A is still refused server-side",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      # The disabled attribute stops a normal click, but `render_submit/1`
      # posts whatever params it is given — proving `launch_defaults/1`'s own
      # clamp (not just the disabled checkbox) is what keeps this from ever
      # reaching a row. Mode A has no configured token in this test env, so
      # the launch itself fails (a pre-existing gap of this phase-5 form, not
      # this test's concern) — what matters is that `remote_control` was
      # never `true` on the row it left behind.
      view
      |> form("#launch-session-form", %{
        "auth_mode" => "oauth_token",
        "remote_control" => "true"
      })
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.auth_mode == :oauth_token
      assert session.remote_control == false
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
    # bd-9myzv8: the terminal moved into the dock, and there is deliberately
    # no second copy here — two hooks would be two xterms and two `/session`
    # sockets for one pane. `ArbiterWeb.SessionDockLiveTest` owns the terminal
    # itself now; this page owns the handover.
    test "has no terminal of its own — the session is handed to the dock", %{conn: conn} do
      session = launch!()

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#session-terminal-#{session.id}")
      refute has_element?(view, "#terminal-status")
      refute html =~ "SessionTerminal"

      assert has_element?(view, "#terminal-in-dock")
      assert_push_event(view, "session-dock:open", %{id: id})
      assert id == session.id
    end

    test "Show it asks the dock again, for a window that was dismissed", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert_push_event(view, "session-dock:open", %{id: _})

      render_click(element(view, "#open-in-dock"))

      assert_push_event(view, "session-dock:open", %{id: id})
      assert id == session.id
    end

    # The terminal client moved, and Detach was a terminal-client action:
    # "drop my reader, leave the session running". Collapsing or dismissing
    # the dock window is what does that now.
    test "no longer offers Detach, which belonged to the terminal", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute has_element?(view, "#detach-session")
      assert has_element?(view, "#kill-session")
      assert has_element?(view, "#toggle-keep-alive")
    end

    test "a non-loopback peer sees a notice instead of an inert terminal, with SSH tunnel as primary option and Remote Control as alternative (mode B, launched with --remote-control, bd-2zskbb)",
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
               "ssh -L"
             )

      assert has_element?(
               view,
               "#terminal-remote-notice",
               "Remote Control"
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
      assert has_element?(view, "#terminal-remote-notice", "ssh -L")

      assert has_element?(
               view,
               "#terminal-remote-notice",
               "not enabled on this session"
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
      assert has_element?(view, "#terminal-remote-notice", "ssh -L")
      assert has_element?(view, "#terminal-remote-notice", "workspace token")
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

    test "a loopback peer is pointed at the dock, with no extra banner (bd-2zskbb)", %{
      conn: conn
    } do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#terminal-in-dock")
      refute has_element?(view, "#terminal-remote-notice")
    end

    test "a session that no longer exists redirects back to the list", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/sessions"}}} =
               live(conn, ~p"/sessions/00000000-0000-0000-0000-000000000000")
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

    # The page's only notice that a session ended, now that no hook here
    # forwards the channel's own `exit` event: `Sessions.mark_ended/2`
    # broadcasts on the lifecycle topic (bd-bsdeb2 finding 4). An agent that
    # exits on its own lands here exactly as a Kill or the orphan reaper does.
    test "the page shows that the agent exited, live, without a reload", %{conn: conn} do
      session = launch!()

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")
      assert html =~ "running"
      refute html =~ "Agent exited"
      assert has_element?(view, "#terminal-in-dock")

      {:ok, _ended} = Sessions.mark_ended(session, "exited")

      html = render(view)

      assert html =~ "Agent exited"
      assert html =~ "ended"
      assert html =~ "exited"
      assert has_element?(view, "#session-exit")

      # bd-3r2otb: nothing to attach to, so the page stops pointing at a dock
      # window that could only say the same.
      refute has_element?(view, "#terminal-in-dock")
      assert has_element?(view, "#terminal-inactive")
    end

    test "an ended session is never handed to the dock", %{conn: conn} do
      session = launch!()
      {:ok, _} = Sessions.kill(session.id, runner: NoopRunner, reason: "reaped")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      refute_push_event(view, "session-dock:open", %{})
      refute has_element?(view, "#open-in-dock")
      assert has_element?(view, "#terminal-inactive")
    end

    test "killing from the page replaces the handover without a reload", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, "#terminal-in-dock")

      view |> element("#kill-session") |> render_click()
      view |> element("#confirm-kill") |> render_click()

      assert has_element?(view, "#terminal-inactive")
      refute has_element?(view, "#terminal-in-dock")
      assert has_element?(view, "#session-exit")
    end

    test "a session whose row is already ended says so without needing the hook",
         %{conn: conn} do
      session = launch!()
      {:ok, _} = Sessions.kill(session.id, runner: NoopRunner, reason: "reaped")

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, "#session-exit")
      assert html =~ "reaped"
      # Nothing to attach to, so nothing points at the dock either.
      refute has_element?(view, "#terminal-in-dock")
    end
  end
end
