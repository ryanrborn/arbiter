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

      assert [first, second] = Regex.scan(~r/id="session-([-0-9a-f]+)"/, html, capture: :all_but_first)
      assert first == [newer.id]
      assert second == [older.id]
    end

    test "an ended session is shown as ended, with the reason it ended", %{conn: conn} do
      session = launch!()
      {:ok, _ended} = Sessions.kill(session.id, runner: NoopRunner, reason: "killed by hand")

      {:ok, view, html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#session-#{session.id}")
      assert html =~ "killed by hand"
    end
  end

  describe "launching" do
    test "the launch button provisions a session with the phase-5 defaults and opens it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#launch-session")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#launch-session") |> render_click()

      assert [session] = Sessions.list()
      assert to == "/sessions/#{session.id}"

      # §10.1 / the phase-5 scope: mode B, cross-workspace, dispatch off. The
      # full pre-launch options UI is phase 11.
      assert session.auth_mode == :seeded_credentials
      assert session.workspace_id == nil
      assert session.can_dispatch == false
      assert session.status == :running
    end

    test "a failed launch reports why and leaves the operator on the list", %{conn: conn} do
      put_env(:sessions_runner, Arbiter.Test.FailingSessionRunner)

      {:ok, view, _html} = live(conn, ~p"/sessions")

      html = view |> element("#launch-session") |> render_click()

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
