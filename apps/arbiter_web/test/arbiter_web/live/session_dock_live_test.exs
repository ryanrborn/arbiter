defmodule ArbiterWeb.SessionDockLiveTest do
  @moduledoc """
  The session dock (bd-dlc136, phase 1 of the session dock epic) — the shell
  only: the sticky bottom strip, its roster, the collapsed title bars and the
  empty expanded frame. No terminal; phase 2 (bd-14b11h) fills the frame.

  What this file can and cannot prove: `Phoenix.LiveViewTest` drives the dock
  as a real, separate LiveView process (`find_live_child/2`), so every
  server-side rule — one expanded at a time, dismiss is view-only, a hostile
  `localStorage` payload is re-validated — is provable here. That the dock's
  *DOM node and process survive a live navigation* is a client-side fact about
  `data-phx-sticky`; the structural half of it is asserted here and the
  behavioural half in `ArbiterWeb.SessionDockBrowserTest`.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Sessions
  alias Arbiter.Test.NoopRunner

  setup do
    Arbiter.Test.SessionEnv.sandbox("session-dock")
    :ok
  end

  defp launch!(opts \\ []) do
    {:ok, session} = Sessions.launch(Keyword.put_new(opts, :runner, NoopRunner))
    session
  end

  defp dock(conn, path \\ "/") do
    {:ok, view, _html} = live(conn, path)
    {view, find_live_child(view, "session-dock")}
  end

  defp open_roster(dock) do
    render_click(element(dock, "#session-dock-roster-toggle"))
    dock
  end

  describe "the shell" do
    test "renders on every dashboard page in live_session :default", %{conn: conn} do
      for path <- ["/", "/tasks", "/sessions", "/workers", "/usage", "/epics"] do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, "#session-dock"), "no dock on #{path}"
        assert has_element?(view, "#session-dock #session-dock-root"), "no dock strip on #{path}"
      end
    end

    # The whole navigation-survival mechanism is this one attribute: it is what
    # makes the client move the existing element into the incoming main
    # container instead of re-mounting the view. A `sticky: true` lost in a
    # refactor would silently degrade to a dock that re-mounts on every click.
    test "is rendered as a sticky nested LiveView", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-phx-sticky)
      assert html =~ ~s(id="session-dock")
    end

    test "is its own process, not the page's", %{conn: conn} do
      {view, dock} = dock(conn)

      assert dock.module == ArbiterWeb.SessionDockLive
      assert dock.pid != view.pid
    end

    test "reserves bottom room on the page so it covers nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#session-dock-offset")
    end
  end

  describe "the roster" do
    test "is collapsed until the bar is clicked", %{conn: conn} do
      launch!()
      {_view, dock} = dock(conn)

      refute has_element?(dock, "#session-dock-roster-panel")
      open_roster(dock)
      assert has_element?(dock, "#session-dock-roster-panel")
    end

    test "shows each session's resolved name, status and id (bd-o2vtsz)", %{conn: conn} do
      named = launch!(name: "refinement session")
      unnamed = launch!()

      {_view, dock} = dock(conn) |> then(fn {v, d} -> {v, open_roster(d)} end)

      assert has_element?(dock, "#session-dock-roster-#{named.id}", "refinement session")
      assert has_element?(dock, "#session-dock-roster-#{unnamed.id}")

      assert has_element?(
               dock,
               "#session-dock-roster-#{unnamed.id}",
               Arbiter.Sessions.DisplayName.short_id(unnamed.id)
             )
    end

    test "distinguishes ended sessions from running ones", %{conn: conn} do
      running = launch!()
      ended = launch!()
      {:ok, _} = Sessions.kill(ended.id)

      {_view, dock} = dock(conn)
      open_roster(dock)

      assert has_element?(dock, ~s(#session-dock-roster-#{running.id}[data-status="running"]))
      assert has_element?(dock, ~s(#session-dock-roster-#{ended.id}[data-status="ended"]))
    end

    test "says so when nothing has ever been launched", %{conn: conn} do
      {_view, dock} = dock(conn)
      open_roster(dock)

      assert has_element?(dock, "#session-dock-roster-empty")
      refute has_element?(dock, "#session-dock-roster-list")
    end

    test "picks up a session launched after the dock mounted", %{conn: conn} do
      {_view, dock} = dock(conn)
      later = launch!()

      open_roster(dock)
      assert has_element?(dock, "#session-dock-roster-#{later.id}")
    end
  end

  describe "opening, expanding and dismissing" do
    test "opening adds a title bar and closes the roster", %{conn: conn} do
      session = launch!(name: "one")
      {_view, dock} = dock(conn)
      open_roster(dock)

      render_click(element(dock, "#session-dock-open-#{session.id}"))

      assert has_element?(dock, "#session-dock-window-#{session.id}")
      assert has_element?(dock, "#session-dock-title-#{session.id}", "one")
      refute has_element?(dock, "#session-dock-roster-panel")
    end

    test "at most one window is expanded at a time", %{conn: conn} do
      a = launch!(name: "a")
      b = launch!(name: "b")
      {_view, dock} = dock(conn)

      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{a.id}"))
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{b.id}"))

      # Opening b expanded it, which must have collapsed a.
      assert has_element?(dock, ~s(#session-dock-window-#{b.id}[data-expanded="true"]))
      assert has_element?(dock, ~s(#session-dock-window-#{a.id}[data-expanded="false"]))

      render_click(element(dock, "#session-dock-title-#{a.id}"))

      assert has_element?(dock, ~s(#session-dock-window-#{a.id}[data-expanded="true"]))
      assert has_element?(dock, ~s(#session-dock-window-#{b.id}[data-expanded="false"]))
    end

    test "the title bar collapses the window it expanded", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      assert has_element?(dock, "#session-dock-frame-#{session.id}")

      render_click(element(dock, "#session-dock-title-#{session.id}"))

      refute has_element?(dock, "#session-dock-frame-#{session.id}")
      assert has_element?(dock, "#session-dock-title-#{session.id}")
    end

    # Phase 1's deliverable is the frame, not what goes in it. A terminal
    # appearing here early would mean phase 2 landed in the wrong phase.
    test "the expanded window is an empty frame — no xterm, no /session socket",
         %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      html = render(dock)

      assert has_element?(dock, "#session-dock-frame-#{session.id}")
      refute html =~ "xterm"
      refute html =~ "SessionTerminal"
      refute html =~ "phx-update=\"ignore\""
    end

    test "dismissing removes the window without touching the session", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      render_click(element(dock, "#session-dock-dismiss-#{session.id}"))

      refute has_element?(dock, "#session-dock-window-#{session.id}")
      assert {:ok, %{status: :running, ended_at: nil}} = Sessions.get(session.id)

      # And it is still there to be opened again.
      open_roster(dock)
      assert has_element?(dock, "#session-dock-open-#{session.id}")
    end

    test "a window whose session ended stays open and keeps its title bar", %{conn: conn} do
      session = launch!(name: "goes away")
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      {:ok, _} = Sessions.kill(session.id)
      render(dock)

      assert has_element?(dock, "#session-dock-title-#{session.id}", "goes away")
    end
  end

  describe "persisted state" do
    test "every change is pushed to the client to store", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open_roster(dock)

      render_click(element(dock, "#session-dock-open-#{session.id}"))

      assert_push_event(dock, "session-dock:persist", %{open: [id], expanded: expanded})
      assert id == session.id
      assert expanded == session.id

      render_click(element(dock, "#session-dock-dismiss-#{session.id}"))
      assert_push_event(dock, "session-dock:persist", %{open: [], expanded: nil})
    end

    test "a restore payload reopens the windows it names", %{conn: conn} do
      a = launch!(name: "a")
      b = launch!(name: "b")
      {_view, dock} = dock(conn)

      render_hook(dock, "restore", %{"open" => [a.id, b.id], "expanded" => b.id})

      assert has_element?(dock, ~s(#session-dock-window-#{a.id}[data-expanded="false"]))
      assert has_element?(dock, ~s(#session-dock-window-#{b.id}[data-expanded="true"]))
    end

    # Storage is whatever the last version of this code, or a devtools console,
    # or a half-written write left behind. None of these may render a broken
    # dock — they all render an empty one.
    test "a hostile or stale restore payload renders an empty dock", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)

      for payload <- [
            %{},
            %{"open" => nil, "expanded" => nil},
            %{"open" => "not-a-list"},
            %{"open" => [123, %{"a" => 1}], "expanded" => 7},
            %{"open" => ["00000000-0000-0000-0000-000000000000"], "expanded" => "nope"},
            %{"open" => [session.id, session.id], "expanded" => "not-open"}
          ] do
        render_hook(dock, "restore", payload)
        assert render(dock) =~ "session-dock-root"
      end

      # The last payload names a real session twice with an expanded id that is
      # not in the list: one window, collapsed.
      assert has_element?(dock, ~s(#session-dock-window-#{session.id}[data-expanded="false"]))

      html = render(dock)
      assert length(Regex.scan(~r/id="session-dock-window-/, html)) == 1
    end

    test "restore drops ids for sessions that no longer exist", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)

      render_hook(dock, "restore", %{
        "open" => ["11111111-1111-1111-1111-111111111111", session.id],
        "expanded" => "11111111-1111-1111-1111-111111111111"
      })

      assert has_element?(dock, "#session-dock-window-#{session.id}")
      refute has_element?(dock, "#session-dock-window-11111111-1111-1111-1111-111111111111")

      # And the pruned list is written straight back, so the stale id is gone
      # from storage too rather than waiting for the next change.
      assert_push_event(dock, "session-dock:persist", %{open: [id], expanded: nil})
      assert id == session.id
    end

    test "restore caps how many windows a stored payload can open", %{conn: conn} do
      sessions = for _ <- 1..10, do: launch!()
      {_view, dock} = dock(conn)

      render_hook(dock, "restore", %{"open" => Enum.map(sessions, & &1.id), "expanded" => nil})

      html = render(dock)
      assert length(Regex.scan(~r/id="session-dock-window-/, html)) == 8
    end
  end

  describe "scope discipline" do
    test "/sessions and /sessions/:id still work and keep their own controls",
         %{conn: conn} do
      session = launch!(name: "untouched")

      {:ok, index, _html} = live(conn, ~p"/sessions")
      assert has_element?(index, "#session-#{session.id}")
      assert has_element?(index, "#launch-session")
      assert has_element?(index, "#kill-session-#{session.id}")

      {:ok, page, html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(page, "#session-dock")
      # The terminal and its colocated hook are phase 2's problem, untouched.
      assert html =~ "SessionTerminal"
    end
  end
end
