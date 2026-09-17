defmodule ArbiterWeb.SessionDockLiveTest do
  @moduledoc """
  The session dock (bd-dlc136 phase 1, bd-9myzv8 phase 2): the sticky bottom
  strip, its roster, the collapsed title bars, and — since phase 2 — the one
  terminal that lives in whichever window is expanded.

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
  alias Arbiter.Usage.Event

  setup do
    Arbiter.Test.SessionEnv.sandbox("session-dock")
    # The dock's own Kill and `/sessions`' Launch run inside the LiveView
    # process, which has no access to the test's process dictionary and calls
    # `Sessions.launch/1` with no `:runner` — so the stub has to come from
    # application config or it would really shell out to `systemd-run`.
    put_env(:sessions_runner, NoopRunner)
    :ok
  end

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

  defp launch!(opts \\ []) do
    {:ok, session} = Sessions.launch(Keyword.put_new(opts, :runner, NoopRunner))
    session
  end

  # The info view's cost/tokens read the same canonical rollup `/sessions` and
  # `arb usage --by session` do, so it is driven by writing ledger rows rather
  # than by faking terminal bytes.
  defp create_event!(attrs) do
    base = %{
      task_id: nil,
      source: :coordinator_session,
      step: :other,
      provider: "claude",
      model: "claude-opus-4-7",
      occurred_at: DateTime.utc_now()
    }

    {:ok, event} = Ash.create(Event, Map.merge(base, attrs))
    event
  end

  # Open a window from the roster and leave it expanded — the state every
  # title-bar control is exercised from.
  defp open!(dock, session) do
    open_roster(dock)
    render_click(element(dock, "#session-dock-open-#{session.id}"))
    dock
  end

  defp open_menu!(dock, session) do
    render_click(element(dock, "#session-dock-menu-#{session.id}"))
    dock
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

    # The dock rides the live layout, which only wraps `live_session :default`.
    # A dead controller page therefore gets neither the dock nor the bottom
    # offset it exists to make room for — and must not get one without the
    # other, which is how a page ends up with a gap under nothing.
    test "is absent, offset and all, from dead controller pages", %{conn: conn} do
      html = conn |> get(~p"/about") |> html_response(200)

      refute html =~ ~s(id="session-dock")
      refute html =~ ~s(id="session-dock-offset")
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

  # bd-cdut29: launching without leaving whatever page the operator is on.
  # The form itself is `ArbiterWeb.SessionIndexLive.launch_form/1`, shared
  # with `/sessions` — these tests are about the dock's own wiring around it
  # (the New session toggle, routing a launch into the roster/expand state,
  # and the inline error the dock needs because a nested LiveView's flash
  # never reaches the host page), not a re-proof of the form's own fields or
  # the §8.3 gating, which `SessionIndexLiveTest` already covers exhaustively
  # against the identical markup.
  describe "launching from the roster" do
    test "the New session control is on every dashboard page", %{conn: conn} do
      for path <- ["/", "/tasks", "/sessions"] do
        {_view, dock} = dock(conn, path)
        assert has_element?(dock, "#session-dock-new-session"), "no New session on #{path}"
      end
    end

    test "is closed until the New session control is clicked", %{conn: conn} do
      {_view, dock} = dock(conn)

      refute has_element?(dock, "#session-dock-launch-panel")
      render_click(element(dock, "#session-dock-new-session"))
      assert has_element?(dock, "#session-dock-launch-panel")
      assert has_element?(dock, "#session-dock-launch-form")
    end

    test "a successful launch adds the session to the roster, expands its window, and closes the panel",
         %{conn: conn} do
      {_view, dock} = dock(conn)
      render_click(element(dock, "#session-dock-new-session"))

      dock
      |> form("#session-dock-launch-form", %{"name" => "filed from the dock"})
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.name == "filed from the dock"

      refute has_element?(dock, "#session-dock-launch-panel")
      assert has_element?(dock, ~s(#session-dock-title-#{session.id}[aria-expanded="true"]))
      open_roster(dock)
      assert has_element?(dock, "#session-dock-roster-#{session.id}")
    end

    test "expanding the launched window collapses whatever was expanded before it", %{
      conn: conn
    } do
      first = launch!(name: "already open")
      {_view, dock} = dock(conn)
      open!(dock, first)
      assert has_element?(dock, ~s(#session-dock-title-#{first.id}[aria-expanded="true"]))

      render_click(element(dock, "#session-dock-new-session"))
      dock |> form("#session-dock-launch-form") |> render_submit()

      assert [second] = Enum.reject(Sessions.list(), &(&1.id == first.id))
      assert has_element?(dock, ~s(#session-dock-title-#{second.id}[aria-expanded="true"]))
      refute has_element?(dock, ~s(#session-dock-title-#{first.id}[aria-expanded="true"]))
    end

    # Finding 1, bd-cdut29 review round 1: at the @max_open (8) cap the
    # front-take used to evict the *newly launched* window instead of the
    # oldest one, so the operator got no window for a session that really
    # did start, and lost the one they already had expanded, with no error
    # to explain either.
    test "launching at the eight-window cap still expands the new window", %{conn: conn} do
      already_open = for n <- 1..8, do: launch!(name: "s#{n}")
      {_view, dock} = dock(conn)

      render_hook(dock, "restore", %{
        "open" => Enum.map(already_open, & &1.id),
        "expanded" => List.first(already_open).id
      })

      render_click(element(dock, "#session-dock-new-session"))
      dock |> form("#session-dock-launch-form") |> render_submit()

      already_open_ids = Enum.map(already_open, & &1.id)
      assert [session] = Enum.reject(Sessions.list(), &(&1.id in already_open_ids))
      assert has_element?(dock, ~s(#session-dock-title-#{session.id}[aria-expanded="true"]))
      assert has_element?(dock, "#session-dock-terminal-#{session.id}")
      assert length(Regex.scan(~r/id="session-dock-window-/, render(dock))) == 8
    end

    test "the roster's launch panel offers the same workspace binding option as the index (§9.5)",
         %{conn: conn} do
      {:ok, workspace} =
        Ash.create(Arbiter.Tasks.Workspace, %{name: "acme-dock", prefix: "ad"})

      {_view, dock} = dock(conn)
      render_click(element(dock, "#session-dock-new-session"))

      assert has_element?(dock, "#session-dock-launch-workspace-id")
      assert render(dock) =~ workspace.name

      dock
      |> form("#session-dock-launch-form", %{"workspace_id" => workspace.id})
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.workspace_id == workspace.id
    end

    test "a failed launch is shown inline and opens no window", %{conn: conn} do
      put_env(:sessions_runner, Arbiter.Test.FailingSessionRunner)
      {_view, dock} = dock(conn)
      render_click(element(dock, "#session-dock-new-session"))

      html = dock |> form("#session-dock-launch-form") |> render_submit()

      assert html =~ "Could not launch"
      # The panel stays open with the error on it — nothing to reopen or
      # retype — and the roster gains no open window for it (a runner
      # failure still leaves an ended row for the audit trail, the same as
      # `SessionIndexLive`'s own failed-launch case; the window is what
      # "half-created" refers to here).
      assert has_element?(dock, "#session-dock-launch-panel")
      refute has_element?(dock, ~s([id^="session-dock-window-"]))
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

    # Phase 2 (bd-9myzv8): the frame is no longer empty. The terminal hook's
    # lifecycle is the dock's now, and it is the *expansion* that mounts it.
    test "the expanded window hosts the terminal hook, aimed at that session",
         %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      html = render(dock)
      pane = "#session-dock-terminal-#{session.id}"

      # A colocated hook is rendered under its module-qualified name.
      assert has_element?(dock, pane)
      assert html =~ ~s(phx-hook="ArbiterWeb.SessionDockLive.SessionTerminal")
      assert html =~ ~s(data-session-id="#{session.id}")

      # The hook owns this subtree; LiveView must never diff into it.
      assert has_element?(dock, ~s(#{pane}[phx-update="ignore"]))

      # And it is marked as a terminal, so window-level key handling elsewhere
      # on the dashboard can tell a keystroke meant for the agent from one
      # meant for the page.
      assert has_element?(dock, ~s(#{pane}[data-arb-terminal]))
    end

    test "the expanded window carries the hook-owned status strip", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      strip = "#session-dock-status-#{session.id}"

      assert has_element?(dock, strip)
      assert has_element?(dock, ~s(#{strip}[phx-update="ignore"]))
      assert has_element?(dock, ~s(#{strip} [data-role="state"]))
      assert has_element?(dock, ~s(#{strip} [data-role="usage"]))
      assert has_element?(dock, ~s(#{strip} [data-role="meta"]))
    end

    # The acceptance criterion the whole phase turns on: collapsing is what
    # tears the xterm down and closes the socket, and it does that by the pane
    # ceasing to exist — LiveView calls the hook's `destroyed()` for it.
    test "collapsing removes the terminal element entirely", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      assert has_element?(dock, "#session-dock-terminal-#{session.id}")

      render_click(element(dock, "#session-dock-title-#{session.id}"))

      refute has_element?(dock, "#session-dock-terminal-#{session.id}")
      refute has_element?(dock, "#session-dock-status-#{session.id}")
      assert has_element?(dock, "#session-dock-title-#{session.id}")
    end

    test "a strip of eight windows still holds exactly one terminal", %{conn: conn} do
      sessions = for n <- 1..8, do: launch!(name: "s#{n}")
      {_view, dock} = dock(conn)

      render_hook(dock, "restore", %{
        "open" => Enum.map(sessions, & &1.id),
        "expanded" => List.last(sessions).id
      })

      html = render(dock)

      assert length(Regex.scan(~r/id="session-dock-window-/, html)) == 8
      assert length(Regex.scan(~r/id="session-dock-terminal-/, html)) == 1
      assert has_element?(dock, "#session-dock-terminal-#{List.last(sessions).id}")
    end

    test "expanding another window moves the one terminal to it", %{conn: conn} do
      a = launch!(name: "a")
      b = launch!(name: "b")
      {_view, dock} = dock(conn)

      render_hook(dock, "restore", %{"open" => [a.id, b.id], "expanded" => a.id})

      assert has_element?(dock, "#session-dock-terminal-#{a.id}")
      refute has_element?(dock, "#session-dock-terminal-#{b.id}")

      render_click(element(dock, "#session-dock-title-#{b.id}"))

      refute has_element?(dock, "#session-dock-terminal-#{a.id}")
      assert has_element?(dock, "#session-dock-terminal-#{b.id}")
    end

    # §10.4 / bd-2zskbb, now on every page rather than only on /sessions/:id:
    # `ArbiterWeb.SessionSocket` trusts a loopback peer and the browser sends
    # no token, so off loopback a terminal here would be an inert pane that
    # silently never attaches.
    test "off loopback the window says so instead of mounting an inert terminal",
         %{conn: conn} do
      session = launch!(auth_mode: :seeded_credentials, remote_control: true)

      conn =
        Plug.Test.put_peer_data(conn, %{address: {192, 168, 1, 38}, port: 55_555, ssl_cert: nil})

      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      refute has_element?(dock, "#session-dock-terminal-#{session.id}")
      refute has_element?(dock, "#session-dock-status-#{session.id}")
      assert has_element?(dock, "#session-dock-remote-#{session.id}", "loopback-only")
    end

    # Phase 2 replaced the pane with a placeholder the moment the session
    # ended; phase 3 (bd-a292yj) keeps it, read-only, because the last output
    # is most interesting exactly then. What goes away is the *channel*: an
    # ended window has nothing attached and no status strip to paint.
    test "an ended session's window keeps its pane but attaches nothing", %{conn: conn} do
      session = launch!(name: "over")
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      assert has_element?(dock, "#session-dock-terminal-#{session.id}")
      assert has_element?(dock, "#session-dock-status-#{session.id}")

      {:ok, _ended} = Sessions.kill(session.id)
      render(dock)

      assert has_element?(dock, "#session-dock-terminal-#{session.id}[data-readonly]")
      refute has_element?(dock, "#session-dock-status-#{session.id}")
      assert has_element?(dock, "#session-dock-ended-#{session.id}")
    end

    # §6.3, moved here with the terminal: a terminal cannot reflow meaningfully
    # below ~80 columns, so a squeezed window scrolls its own container
    # sideways rather than shrinking the pane to illegibility. The *page* never
    # scrolls sideways — the dock is `position: fixed`, and one that overflowed
    # would give every page a horizontal scrollbar it never had.
    test "a squeezed window scrolls the terminal, not the page (§6.3)", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      assert has_element?(dock, "#session-dock-scroller-#{session.id}.overflow-x-auto")

      # `scripts/verify_session_terminal.mjs` checks in a real browser that
      # this floor really does fit 80 columns.
      assert has_element?(
               dock,
               ~s(#session-dock-terminal-#{session.id}[class*="min-w-[640px]"])
             )
    end

    # Moved here from `SessionLive` with the hook it watches. The failure it
    # exists for has no other symptom: a tab running an asset bundle from
    # before a deploy has no `.SessionTerminal` hook at all, so nothing mounts,
    # nothing connects, and the hook-painted strip sits on its server-rendered
    # "connecting…" forever.
    test "says so when the terminal never connects", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      refute has_element?(dock, "#session-dock-stalled-#{session.id}")

      send(dock.pid, {:terminal_stall_check, session.id})
      assert has_element?(dock, "#session-dock-stalled-#{session.id}")

      # A late join clears it: the message is advisory, not a verdict.
      render_hook(dock, "terminal_live", %{"id" => session.id})
      refute has_element?(dock, "#session-dock-stalled-#{session.id}")
    end

    test "a terminal that connected in time never mentions a stall", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      render_hook(dock, "terminal_live", %{"id" => session.id})
      send(dock.pid, {:terminal_stall_check, session.id})

      refute has_element?(dock, "#session-dock-stalled-#{session.id}")
    end

    # The stall check is armed by expanding, so a check for a window that is
    # no longer the expanded one must not fire a banner over the one that is.
    test "a stall check for a window that has since collapsed says nothing",
         %{conn: conn} do
      a = launch!(name: "a")
      b = launch!(name: "b")
      {_view, dock} = dock(conn)

      render_hook(dock, "restore", %{"open" => [a.id, b.id], "expanded" => a.id})
      render_click(element(dock, "#session-dock-title-#{b.id}"))

      send(dock.pid, {:terminal_stall_check, a.id})

      refute has_element?(dock, "#session-dock-stalled-#{a.id}")
      refute has_element?(dock, "#session-dock-stalled-#{b.id}")
    end

    # Off loopback there is no hook to stall — the window already explains
    # why, and a "Reload the page" banner on top of that cannot help
    # (bd-2zskbb).
    test "off loopback the stall banner never fires alongside the remote notice",
         %{conn: conn} do
      session = launch!(auth_mode: :seeded_credentials, remote_control: true)

      conn =
        Plug.Test.put_peer_data(conn, %{address: {192, 168, 1, 38}, port: 55_555, ssl_cert: nil})

      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      send(dock.pid, {:terminal_stall_check, session.id})

      refute has_element?(dock, "#session-dock-stalled-#{session.id}")
      assert has_element?(dock, "#session-dock-remote-#{session.id}")
    end

    # Dismiss is "forget this window", so the resume point goes with it: the
    # client's in-memory book is told, and re-opening later is a fresh
    # snapshot rather than a replay onto a screen nothing painted.
    test "dismissing tells the client to forget the resume point", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open_roster(dock)
      render_click(element(dock, "#session-dock-open-#{session.id}"))

      render_click(element(dock, "#session-dock-dismiss-#{session.id}"))

      assert_push_event(dock, "session-dock:forget", %{id: id})
      assert id == session.id
    end

    # The hook reports the channel's `exit` event up, because the row may not
    # be marked ended yet — the same reason `SessionLive` did (bd-bsdeb2).
    # Phase 3 (bd-a292yj) changed what that does to the pane: the last output
    # is most interesting exactly when the session dies, so the pane stays and
    # goes read-only rather than being replaced by a placeholder.
    test "an agent that exits under the hook freezes the window rather than emptying it",
         %{conn: conn} do
      session = launch!(name: "exits")
      {_view, dock} = dock(conn)
      open!(dock, session)

      render_hook(dock, "terminal_exited", %{"id" => session.id, "code" => 1})

      assert has_element?(dock, "#session-dock-terminal-#{session.id}[data-readonly]")
      assert has_element?(dock, "#session-dock-ended-#{session.id}")
      refute has_element?(dock, "#session-dock-unavailable-#{session.id}")
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

  describe "title-bar controls (phase 3, bd-a292yj)" do
    test "keep_alive is pinned and unpinned from the window's overflow", %{conn: conn} do
      session = launch!(name: "pinned")
      {_view, dock} = dock(conn)
      open!(dock, session)

      assert {:ok, %{keep_alive: false}} = Sessions.get(session.id)

      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-keep-alive-#{session.id}"))
      assert {:ok, %{keep_alive: true}} = Sessions.get(session.id)

      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-keep-alive-#{session.id}"))
      assert {:ok, %{keep_alive: false}} = Sessions.get(session.id)
    end

    # A one-click kill in a title bar that is always on screen is a different
    # risk profile from one on a page you navigated to deliberately, so the
    # confirmation the pages ask for is kept here — and it is literally the
    # same component, not a second copy that can drift.
    test "kill asks first, and a single click in the title bar ends nothing",
         %{conn: conn} do
      session = launch!(name: "not yet")
      {_view, dock} = dock(conn)
      open!(dock, session)

      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-kill-#{session.id}"))

      assert has_element?(dock, "#kill-session-modal")
      assert {:ok, %{status: :running}} = Sessions.get(session.id)

      render_click(element(dock, "#confirm-kill"))

      assert {:ok, %{status: :ended}} = Sessions.get(session.id)
      refute has_element?(dock, "#kill-session-modal")
    end

    test "cancelling the confirmation leaves the session running", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open!(dock, session)

      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-kill-#{session.id}"))
      render_click(element(dock, "#cancel-kill"))

      refute has_element?(dock, "#kill-session-modal")
      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end

    # Detach is "drop this browser's reader, leave the agent running", which
    # is exactly what collapsing already does — so it is the same handler,
    # named for what an operator came looking for.
    test "detach collapses the window and leaves the session running", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open!(dock, session)

      assert has_element?(dock, ~s(#session-dock-window-#{session.id}[data-expanded="true"]))

      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-detach-#{session.id}"))

      assert has_element?(dock, ~s(#session-dock-window-#{session.id}[data-expanded="false"]))
      refute has_element?(dock, "#session-dock-terminal-#{session.id}")
      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end

    # Every control carries its own session id, so the one that is *expanded*
    # is irrelevant to which session they act on.
    test "a control acts on its own window, not on the expanded one", %{conn: conn} do
      expanded = launch!(name: "expanded")
      other = launch!(name: "other")

      {_view, dock} = dock(conn)

      render_hook(dock, "restore", %{"open" => [expanded.id, other.id], "expanded" => expanded.id})

      open_menu!(dock, other)
      render_click(element(dock, "#session-dock-keep-alive-#{other.id}"))

      assert {:ok, %{keep_alive: true}} = Sessions.get(other.id)
      assert {:ok, %{keep_alive: false}} = Sessions.get(expanded.id)
    end

    # One click can raise both the open window's click-away and another
    # window's toggle, and the order is not ours to decide — so a close that
    # names the window it is closing is the only one that cannot close the
    # menu that click just opened.
    test "closing one window's overflow never closes another's", %{conn: conn} do
      a = launch!(name: "a")
      b = launch!(name: "b")

      {_view, dock} = dock(conn)
      render_hook(dock, "restore", %{"open" => [a.id, b.id], "expanded" => nil})

      open_menu!(dock, b)
      assert has_element?(dock, "#session-dock-menu-panel-#{b.id}")

      render_hook(dock, "close_menu", %{"id" => a.id})
      assert has_element?(dock, "#session-dock-menu-panel-#{b.id}")

      render_hook(dock, "close_menu", %{"id" => b.id})
      refute has_element?(dock, "#session-dock-menu-panel-#{b.id}")
    end

    test "an ended session's window offers neither kill nor keep_alive", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open!(dock, session)
      {:ok, _} = Sessions.kill(session.id)
      render(dock)

      open_menu!(dock, session)

      refute has_element?(dock, "#session-dock-kill-#{session.id}")
      refute has_element?(dock, "#session-dock-keep-alive-#{session.id}")
      assert has_element?(dock, "#session-dock-info-#{session.id}")
    end
  end

  describe "the info view" do
    test "shows the session's metadata without leaving the page", %{conn: conn} do
      session = launch!(name: "inspect me")
      {_view, dock} = dock(conn)
      open!(dock, session)

      refute has_element?(dock, "#session-dock-info-panel-#{session.id}")

      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-info-#{session.id}"))

      panel = "#session-dock-info-panel-#{session.id}"
      assert has_element?(dock, panel)
      assert has_element?(dock, panel, session.config_dir)
      assert has_element?(dock, panel, session.scope_unit)
      assert has_element?(dock, "#session-dock-keep-alive-value-#{session.id}", "false")
    end

    test "shows the session's cost and tokens", %{conn: conn} do
      session = launch!()
      {:ok, session} = Sessions.record_provider_session(session, "prov-dock-info")

      create_event!(%{
        session_id: "prov-dock-info",
        cost_usd: 1.25,
        tokens_in: 4000,
        tokens_out: 900
      })

      {_view, dock} = dock(conn)
      open!(dock, session)
      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-info-#{session.id}"))

      assert has_element?(dock, "#session-dock-usage-#{session.id}", "$1.25")
    end

    test "says so rather than showing $0.00 when the ledger has nothing yet",
         %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open!(dock, session)
      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-info-#{session.id}"))

      assert has_element?(dock, "#session-dock-usage-empty-#{session.id}")
    end

    # The panel is an overlay on the window's *frame*, and a collapsed window
    # has no frame on screen — so Info has to bring the window it was invoked
    # on with it, rather than arming a panel nobody can see (review finding 3).
    test "info on a collapsed window expands that window and shows its panel",
         %{conn: conn} do
      first = launch!(name: "collapsed")
      second = launch!(name: "expanded")

      {_view, dock} = dock(conn)
      open!(dock, first)
      open!(dock, second)

      # The second open took the expanded slot, so `first` is a title bar only.
      assert has_element?(dock, "#session-dock-window-#{second.id}[data-expanded=true]")
      assert has_element?(dock, "#session-dock-window-#{first.id}[data-expanded=false]")

      open_menu!(dock, first)
      render_click(element(dock, "#session-dock-info-#{first.id}"))

      assert has_element?(dock, "#session-dock-window-#{first.id}[data-expanded=true]")
      assert has_element?(dock, "#session-dock-info-panel-#{first.id}")
      refute has_element?(dock, "#session-dock-info-panel-#{second.id}")
    end

    # The info side is an *overlay*, never a replacement: unmounting the pane
    # would dispose the xterm and throw the scrollback away for the sake of
    # reading a config dir.
    test "flipping to info does not tear the terminal down", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open!(dock, session)

      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-info-#{session.id}"))

      assert has_element?(dock, "#session-dock-terminal-#{session.id}")
      assert has_element?(dock, "#session-dock-info-panel-#{session.id}")

      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-info-#{session.id}"))
      refute has_element?(dock, "#session-dock-info-panel-#{session.id}")
    end
  end

  # The dock mounts `layout: false` and renders no flash group, and a nested
  # LiveView's flash never reaches the host page's `<Layouts.app>` — so an
  # action that fails has to say so here or it says nothing at all (review
  # finding 2).
  describe "an action that fails" do
    test "a failed kill is reported in the dock, not swallowed", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open!(dock, session)

      refute has_element?(dock, "#session-dock-error")

      # The id no longer resolves — the same shape a kill takes when the row is
      # gone by the time the confirmation is answered.
      render_click(dock, "kill", %{"id" => Ecto.UUID.generate()})

      assert has_element?(dock, "#session-dock-error")
      refute has_element?(dock, "#kill-session-modal")

      render_click(element(dock, "#session-dock-error-dismiss"))
      refute has_element?(dock, "#session-dock-error")
    end

    test "a later success clears the notice", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open!(dock, session)

      render_click(dock, "kill", %{"id" => Ecto.UUID.generate()})
      assert has_element?(dock, "#session-dock-error")

      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-keep-alive-#{session.id}"))

      assert {:ok, %{keep_alive: true}} = Sessions.get(session.id)
      refute has_element?(dock, "#session-dock-error")
    end
  end

  describe "a session that ends while it is docked" do
    test "keeps its window and its pane, read-only, with the end reason shown",
         %{conn: conn} do
      session = launch!(name: "dies docked")
      {_view, dock} = dock(conn)
      open!(dock, session)

      assert has_element?(dock, "#session-dock-terminal-#{session.id}")

      {:ok, _} = Sessions.kill(session.id)
      render(dock)

      # The pane element is the same one, still mounted: LiveView leaves a
      # `phx-update="ignore"` subtree alone, so the scrollback in it survives.
      assert has_element?(dock, "#session-dock-terminal-#{session.id}")
      assert has_element?(dock, "#session-dock-terminal-#{session.id}[data-readonly]")
      assert has_element?(dock, "#session-dock-ended-#{session.id}", "killed")
      assert has_element?(dock, "#session-dock-end-reason-#{session.id}", "killed")
    end

    # There is nothing to attach to, so there must be no channel to attach
    # with: a read-only pane keeps its bytes, not its socket.
    test "the read-only pane carries no live status strip", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open!(dock, session)
      {:ok, _} = Sessions.kill(session.id)
      render(dock)

      refute has_element?(dock, "#session-dock-status-#{session.id}")
    end

    test "collapsing and re-expanding keeps the frozen pane", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open!(dock, session)
      {:ok, _} = Sessions.kill(session.id)
      render(dock)

      render_click(element(dock, "#session-dock-title-#{session.id}"))
      assert has_element?(dock, "#session-dock-terminal-#{session.id}")

      render_click(element(dock, "#session-dock-title-#{session.id}"))
      assert has_element?(dock, "#session-dock-terminal-#{session.id}")
    end

    test "dismissing it removes it from the dock and from persisted state",
         %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open!(dock, session)
      {:ok, _} = Sessions.kill(session.id)
      render(dock)

      render_click(element(dock, "#session-dock-dismiss-#{session.id}"))

      refute has_element?(dock, "#session-dock-window-#{session.id}")
      assert_push_event(dock, "session-dock:forget", %{id: _})
      assert_push_event(dock, "session-dock:persist", %{open: [], expanded: nil})
    end

    # Re-opening a dismissed, ended session is the "ended elsewhere" case
    # again: the pane it had was disposed with the window.
    test "re-opening a dismissed ended session does not pretend to have its scrollback",
         %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)
      open!(dock, session)
      {:ok, _} = Sessions.kill(session.id)
      render(dock)
      render_click(element(dock, "#session-dock-dismiss-#{session.id}"))

      open!(dock, session)

      refute has_element?(dock, "#session-dock-terminal-#{session.id}")
      assert has_element?(dock, "#session-dock-unavailable-#{session.id}")
    end
  end

  # A LiveView rejoin re-runs `mount/3`, so every window — and every note that
  # one of them is holding a dead pane — is gone server-side while the panes
  # themselves are still on screen. `restore` is how both come back.
  describe "a rejoin, with a frozen window on screen" do
    test "a client-reported frozen window keeps its read-only pane", %{conn: conn} do
      session = launch!()
      {:ok, _} = Sessions.kill(session.id)

      {_view, dock} = dock(conn)

      render_hook(dock, "restore", %{
        "open" => [session.id],
        "expanded" => session.id,
        "frozen" => [session.id]
      })

      assert has_element?(dock, "#session-dock-terminal-#{session.id}[data-readonly]")
      assert has_element?(dock, "#session-dock-ended-#{session.id}")
      refute has_element?(dock, "#session-dock-unavailable-#{session.id}")
    end

    # Same hostility as the rest of the payload: `localStorage` and the DOM are
    # both things a devtools console can write.
    test "a frozen claim about a session that is still running is dropped", %{conn: conn} do
      session = launch!()
      {_view, dock} = dock(conn)

      render_hook(dock, "restore", %{
        "open" => [session.id],
        "expanded" => session.id,
        "frozen" => [session.id]
      })

      refute has_element?(dock, "#session-dock-ended-#{session.id}")
      assert has_element?(dock, "#session-dock-status-#{session.id}")
    end

    test "a frozen claim about a window that is not open is dropped", %{conn: conn} do
      open_one = launch!()
      other = launch!()
      {:ok, _} = Sessions.kill(other.id)

      {_view, dock} = dock(conn)

      render_hook(dock, "restore", %{
        "open" => [open_one.id],
        "expanded" => open_one.id,
        "frozen" => [other.id]
      })

      refute has_element?(dock, "#session-dock-window-#{other.id}")
    end
  end

  describe "a session that ended before this browser session" do
    # Until transcript persistence (bd-5pelo2, phase 9) the dock has nothing
    # to replay for a session it never watched. Saying so — and pointing at
    # the index — is the honest answer; rendering an empty terminal is not.
    test "says its scrollback is unavailable and points at the index", %{conn: conn} do
      session = launch!(name: "over already")
      {:ok, _} = Sessions.kill(session.id)

      {_view, dock} = dock(conn)
      open!(dock, session)

      refute has_element?(dock, "#session-dock-terminal-#{session.id}")
      refute has_element?(dock, "#session-dock-status-#{session.id}")

      assert has_element?(dock, "#session-dock-unavailable-#{session.id}")
      assert has_element?(dock, ~s(#session-dock-unavailable-#{session.id} a[href="/sessions"]))
      assert has_element?(dock, "#session-dock-end-reason-#{session.id}", "killed")
    end

    test "its metadata and cost are still reachable from the info view", %{conn: conn} do
      session = launch!()
      {:ok, session} = Sessions.record_provider_session(session, "prov-dock-ended")
      {:ok, _} = Sessions.kill(session.id)

      create_event!(%{
        session_id: "prov-dock-ended",
        cost_usd: 0.5,
        tokens_in: 100,
        tokens_out: 50
      })

      {_view, dock} = dock(conn)
      open!(dock, session)
      open_menu!(dock, session)
      render_click(element(dock, "#session-dock-info-#{session.id}"))

      assert has_element?(dock, "#session-dock-info-panel-#{session.id}", session.config_dir)
      assert has_element?(dock, "#session-dock-usage-#{session.id}", "$0.50")
    end
  end

  describe "off loopback (§10.4, bd-2zskbb)" do
    defp remote(conn) do
      Plug.Test.put_peer_data(conn, %{address: {192, 168, 1, 38}, port: 55_555, ssl_cert: nil})
    end

    test "mode B with Remote Control is told about SSH forwarding first, Remote Control second",
         %{conn: conn} do
      session = launch!(auth_mode: :seeded_credentials, remote_control: true)

      {_view, dock} = dock(remote(conn))
      open!(dock, session)

      notice = "#session-dock-remote-#{session.id}"
      assert has_element?(dock, notice, "ssh -L 4848:127.0.0.1:4848")
      assert has_element?(dock, notice, "Remote Control")
      refute has_element?(dock, "#session-dock-terminal-#{session.id}")
    end

    test "mode B without --remote-control is told the precondition plainly",
         %{conn: conn} do
      session = launch!(auth_mode: :seeded_credentials, remote_control: false)

      {_view, dock} = dock(remote(conn))
      open!(dock, session)

      notice = "#session-dock-remote-#{session.id}"
      assert has_element?(dock, notice, "ssh -L 4848:127.0.0.1:4848")
      assert has_element?(dock, notice, "not enabled on this session")
    end

    test "mode A is told to forward the port, with no Remote Control offer",
         %{conn: conn} do
      session =
        launch!(auth_mode: :oauth_token, oauth_token: "sk-ant-oat01-SESSION-DOCK-TEST-TOKEN")

      {_view, dock} = dock(remote(conn))
      open!(dock, session)

      notice = "#session-dock-remote-#{session.id}"
      assert has_element?(dock, notice, "ssh -L 4848:127.0.0.1:4848")
      assert has_element?(dock, notice, "workspace token")
    end
  end

  describe "the fate of /sessions/:id (phase 3's decision)" do
    # Executed, not left half-done: the dock owns every per-session control,
    # so the route whose controls moved away is gone rather than left as a
    # page that can only point elsewhere.
    test "the per-session route no longer exists", %{conn: conn} do
      session = launch!()

      assert conn |> get("/sessions/#{session.id}") |> Map.fetch!(:status) == 404
    end

    test "/sessions still launches, names and lists — and opens into the dock",
         %{conn: conn} do
      ended = launch!(name: "finished")
      {:ok, _} = Sessions.kill(ended.id)

      {:ok, index, _html} = live(conn, ~p"/sessions")

      assert has_element?(index, "#launch-session")
      assert has_element?(index, "#launch-session-name")
      assert has_element?(index, "#session-#{ended.id}")

      render_click(element(index, "#open-in-dock-#{ended.id}"))
      assert_push_event(index, "session-dock:open", %{id: id})
      assert id == ended.id
    end

    test "launching hands the new session straight to the dock", %{conn: conn} do
      {:ok, index, _html} = live(conn, ~p"/sessions")

      render_submit(element(index, "#launch-session-form"), %{"name" => "born in the dock"})

      assert_push_event(index, "session-dock:open", %{id: id})
      assert {:ok, %{name: "born in the dock"}} = Sessions.get(id)
    end
  end
end
