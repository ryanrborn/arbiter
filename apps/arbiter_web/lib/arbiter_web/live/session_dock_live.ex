defmodule ArbiterWeb.SessionDockLive do
  @moduledoc """
  The session dock: a strip pinned to the bottom of every dashboard page, with
  a roster that expands into the session list and a collapsed title bar per
  opened session (bd-dlc136, phase 1 of the session dock epic).

  ## The terminal (phase 2, bd-9myzv8)

  **The expanded window holds the one live xterm and the one `/session`
  socket.** There is no per-window terminal: the pane is rendered only for
  whichever window is expanded, and "one expanded at a time" is already a
  server-side invariant, so "at most one xterm and one socket" falls out of
  the markup rather than out of bookkeeping. Collapsing removes the element,
  LiveView calls the hook's `destroyed()`, and that disposes both.

  Expanding builds a *fresh* xterm, so the resume point cannot live in it. It
  lives in `assets/js/session_dock.mjs`'s in-memory resume book, keyed by
  session id, and the join carries it as `last_seq` — which is why a window
  that was collapsed for ten minutes replays what it missed instead of
  re-snapshotting.

  §10.4 / bd-2zskbb applies here too, and now on every page rather than only
  on `/sessions/:id`: `ArbiterWeb.SessionSocket` trusts a loopback peer and the
  browser sends no token, so off loopback the window says so instead of
  mounting a pane that silently never attaches. The answer is handed in as a
  `live_render(..., session:)` value from `layouts/live.html.heex`, because
  `get_connect_info/2` is root-and-mount only and this is a nested child.

  ## The controls, and the page that used to hold them (phase 3, bd-a292yj)

  The dock is now the session. `keep_alive`, Detach, Kill, the metadata and the
  cost figure all live in a window's title bar or its overflow, and
  `/sessions/:id` — which used to own them — is **gone**, route and all. That
  was phase 3's one decision to execute: keeping the page meant two surfaces
  owning the same controls, and two surfaces that own the same control drift.
  `/sessions` stays as the index (name at launch, the whole history, and Kill
  as a fleet act). Two controls are deliberately on both surfaces: Kill, which
  goes through `SessionIndexLive.kill_modal/1` on both so there is a single
  confirmation rather than two that can diverge, and — since phase 4,
  bd-cdut29 — launch itself, through `SessionIndexLive.launch_form/1` and
  `launch_defaults/1`, so starting a session from the dock is the same one
  implementation `/sessions`' own launch button calls, not a second launcher.

  Kill keeps its confirm step *here in particular*. A title bar that is on
  screen on every page is a different risk profile from a page an operator
  navigated to deliberately; a cursor crosses this strip all day.

  Detach is not a second implementation of anything: dropping this browser's
  reader and leaving the agent running is exactly what collapsing already does
  (the pane goes, so the xterm and its socket go), so the menu item routes
  straight into `collapse`.

  ## Windows whose session has ended

  An ended session's window **stays, read-only, with its final scrollback and
  the end reason**, until the operator dismisses it. The last output is most
  interesting exactly when the session dies, and auto-closing throws it away.
  So the pane is not unmounted on an end — unmounting is what disposes the
  xterm — it is *frozen*: `data-readonly` reaches the `phx-update="ignore"`
  element (LiveView merges `data-*` onto ignored nodes and then runs the hook's
  `updated()`), the hook calls the terminal's `setReadOnly`, and the stream had
  already refused stdin from the moment the channel reported `exit`. A frozen
  window keeps its pane through a collapse too, hidden rather than removed —
  "until dismissed" means what it says. It holds no socket, so eight of them
  cost eight xterms and zero connections.

  A **LiveView rejoin** is the one thing a frozen pane cannot ride out on its
  own: a rejoin re-runs `mount/3`, renders the dock empty, and that patch
  destroys every window element and every xterm in one before `restore` puts
  them back. A live pane recovers from that by replaying its stream from
  `last_seq`; a dead one has no stream left. So the client keeps both halves —
  which sessions are frozen and the text their pane held — in
  `assets/js/session_dock.mjs`, alongside the resume book and for the same
  reason (in memory, never `localStorage`: after a full reload there is no
  window to restore into, and "this ended before this browser session" is then
  the true answer). `restore` carries the frozen list and re-validates it like
  everything else in that payload, and a pane rebuilt frozen opens no socket at
  all — it is painted from the kept text and says the styling is gone.

  This is the one thing the dock cannot serve alone. A session that ended in a
  *previous* browser session has no scrollback here to show and none to fetch
  until transcript persistence lands (bd-5pelo2, phase 9). Its window says so
  and points at `/sessions`, rather than rendering an empty terminal that reads
  like a live one with nothing on it: the two cases are named, never blurred.

  Nothing about the transport changed. `ArbiterWeb.SessionSocket`'s topic was
  already keyed to the session id rather than to a LiveView process
  (`endpoint.ex:18-26`), precisely so a client can reattach from somewhere
  else; a dock window is exactly that case.

  ## Why this is a LiveView and not a component

  It is rendered once, from `layouts/live.html.heex`, as
  `live_render(@socket, __MODULE__, id: "session-dock", sticky: true)`. Sticky
  is the whole mechanism: on a `live_redirect` within `live_session :default`
  the client moves this element into the incoming main container rather than
  re-rendering it, so the dock keeps its process, its DOM node, its hooks and
  its scroll position across navigation.

  A sticky child is a separate process with its own mount and **does not see
  the parent's assigns**, and the `live_session`'s `on_mount` hooks do not run
  for it (a nested render carries only the module's own lifecycle). So it
  reads sessions itself and subscribes to `Arbiter.Sessions.lifecycle_topic/0`
  itself. It still keeps a catch-all `handle_info/2`, because the topics it
  subscribes to are shared.

  ## Where the open/expanded state lives

  Which sessions are open, in what order, and which one is expanded is a
  *browser* preference, not fleet state: the dashboard is loopback-only and
  single-operator (§10.4), so there is no user record to hang it on and no
  cross-device case to serve. It lives in `localStorage`, owned by the
  `SessionDock` hook in `assets/js/session_dock.mjs`, which pushes it back up
  on mount and writes it whenever the server says it changed.

  Every read is treated as hostile: storage can be empty, disabled, full, or
  hold whatever a previous version of this code (or a person with a devtools
  console) left there. `handle_event("restore", ...)` therefore re-validates
  the payload against the sessions that actually exist and drops the rest,
  and the hook's own read/write are wrapped. An unreadable store renders an
  empty dock, never a broken page.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Sessions
  alias Arbiter.Sessions.DisplayName
  alias ArbiterWeb.CoreComponents.Data
  alias ArbiterWeb.SessionIndexLive
  alias ArbiterWeb.SessionUsage

  require Logger

  # A dock holding more windows than this is not a dock, and the cap is also
  # what stops a hand-edited `localStorage` value from making the server walk
  # an unbounded list.
  @max_open 8

  # Long enough that a slow first join is not called a failure, short enough
  # that an operator has not already started debugging the wrong thing. Moved
  # here from `ArbiterWeb.SessionLive` with the hook it watches: the failure it
  # exists for — a tab running an asset bundle from before a deploy, which has
  # no `.SessionTerminal` hook to mount at all — is no less real in the dock,
  # and has no other symptom than a strip that says "connecting…" forever.
  @stall_ms 8_000

  # How often an *open* info panel re-pulls the usage ledger. Same figure and
  # the same reasoning as `ArbiterWeb.SessionIndexLive`'s:
  # `Arbiter.Sessions.UsageIngest` only sweeps every 5 minutes by default, so
  # polling faster buys nothing — this just has to be "a panel left open
  # catches the next sweep". The timer only exists while the panel does.
  @usage_refresh_ms 30_000

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Sessions.lifecycle_topic())
    end

    {:ok,
     socket
     |> assign(:roster_open?, false)
     |> assign(:open_ids, [])
     |> assign(:expanded_id, nil)
     |> assign(:exited, MapSet.new())
     # Windows whose pane is mounted but whose session has since ended: the
     # xterm stays, read-only, holding the scrollback it had when the agent
     # went (bd-a292yj). See `freeze_pane/2`.
     |> assign(:frozen, MapSet.new())
     |> assign(:menu_id, nil)
     |> assign(:info_id, nil)
     |> assign(:info_usage, nil)
     |> assign(:usage_refresh_ref, nil)
     |> assign(:kill_candidate, nil)
     # The New session panel (bd-cdut29): `ArbiterWeb.SessionIndexLive.launch_form/1`
     # embedded here rather than a second launcher. `launch_error` is its own
     # inline failure, separate from `error_message` below — a launch failure
     # belongs on the form the operator is looking at, not the dock's general
     # banner, and it must survive `dismiss_error` and vice versa.
     |> assign(:launch_open?, false)
     |> assign(:launch_auth_mode, "seeded_credentials")
     |> assign(:workspaces, SessionIndexLive.workspaces())
     |> assign(:launch_error, nil)
     # The dock's own error notice. It cannot use `put_flash/3`: this view
     # mounts `layout: false` and a nested LiveView's flash never reaches the
     # host page's `<Layouts.app flash={@flash}>`, so a failed kill would
     # otherwise be silent (bd-a292yj review, finding 2).
     |> assign(:error_message, nil)
     |> assign(:loopback?, Map.get(session, "loopback?", true))
     |> assign(:terminal_live?, false)
     |> assign(:terminal_stalled?, false)
     |> load_sessions(), layout: false}
  end

  # -- events -----------------------------------------------------------------

  # The hook's first word after it has read `localStorage`. Nothing is trusted:
  # ids that are not strings, are not sessions, or repeat are dropped, and the
  # expanded id has to be one of the survivors.
  @impl true
  def handle_event("restore", params, socket) do
    socket = load_sessions(socket)
    known = MapSet.new(socket.assigns.sessions, & &1.id)

    open_ids =
      params
      |> Map.get("open", [])
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and MapSet.member?(known, &1)))
      |> Enum.uniq()
      |> Enum.take(@max_open)

    expanded_id =
      case Map.get(params, "expanded") do
        id when is_binary(id) -> if id in open_ids, do: id
        _other -> nil
      end

    # Which windows are holding a *dead* pane is the other half of the state a
    # rejoin resets (bd-a292yj). The client reads it off the panes themselves
    # and says so here; without it a rejoin would quietly relabel an ended
    # window "its output is unavailable" while its scrollback was on screen.
    # Trusted no further than the rest of this payload: it has to be an open
    # window, and the row has to actually be over.
    frozen =
      params
      |> Map.get("frozen", [])
      |> List.wrap()
      |> Enum.filter(fn id ->
        is_binary(id) and id in open_ids and
          not attachable?(Map.fetch!(socket.assigns.sessions_by_id, id), MapSet.new())
      end)
      |> MapSet.new()

    socket =
      if expanded_id, do: expand_window(socket, expanded_id), else: collapse_window(socket)

    {:noreply, socket |> assign(:open_ids, open_ids) |> assign(:frozen, frozen) |> persist()}
  end

  def handle_event("toggle_roster", _params, socket) do
    # Re-read on the way open: a session launched from `/sessions` since this
    # dock mounted has no lifecycle broadcast of its own to announce itself.
    socket =
      if socket.assigns.roster_open?, do: socket, else: load_sessions(socket)

    {:noreply, assign(socket, :roster_open?, not socket.assigns.roster_open?)}
  end

  # New session (bd-cdut29). The panel and the roster panel are independent —
  # opening one does not close the other — since there is nothing conflicting
  # about seeing the roster while filling in a name.
  def handle_event("toggle_launch", _params, socket) do
    {:noreply,
     socket
     |> assign(:launch_open?, not socket.assigns.launch_open?)
     |> assign(:launch_error, nil)}
  end

  # Same params-to-state mapping `SessionIndexLive` uses for its own copy of
  # this form (see `SessionIndexLive.launch_form/1`), so the disabled-checkbox
  # gating (§8.3) behaves identically on both surfaces.
  def handle_event("validate_launch", params, socket) do
    {:noreply, assign(socket, :launch_auth_mode, SessionIndexLive.launch_auth_mode_param(params))}
  end

  # `SessionIndexLive.launch_defaults/1` is the same params-to-opts logic the
  # index page's launch button uses — not a second implementation of the
  # phase-5 defaults or the §8.3 remote-control clamp, just called from here
  # too. On success the new session goes straight into the roster and takes
  # the expanded slot, the same as clicking Open on a row already does
  # (`expand_window/2` is what enforces one-expanded-at-a-time). On failure
  # `open_ids` is left untouched, so no window opens for it — a runner
  # failure can still leave an ended row for the audit trail (same as
  # `SessionIndexLive`'s own launch failure), but that is a history entry,
  # never something live sitting half-built in the roster.
  def handle_event("launch", params, socket) do
    case Sessions.launch(SessionIndexLive.launch_defaults(params)) do
      {:ok, session} ->
        socket = load_sessions(socket)
        open_ids = open_window_ids(socket.assigns.open_ids, session.id)

        {:noreply,
         socket
         |> assign(:open_ids, open_ids)
         |> expand_window(session.id)
         |> assign(:launch_open?, false)
         |> assign(:launch_error, nil)
         |> assign(:roster_open?, false)
         |> persist()}

      {:error, reason} ->
        Logger.error("SessionDockLive: launch failed: #{inspect(reason)}")

        {:noreply,
         assign(
           socket,
           :launch_error,
           "Could not launch a session: #{SessionIndexLive.describe(reason)}"
         )}
    end
  end

  def handle_event("open", %{"id" => id}, socket) do
    socket = load_sessions(socket)

    if Enum.any?(socket.assigns.sessions, &(&1.id == id)) do
      open_ids = open_window_ids(socket.assigns.open_ids, id)

      {:noreply,
       socket
       |> assign(:open_ids, open_ids)
       |> expand_window(id)
       |> assign(:roster_open?, false)
       |> persist()}
    else
      {:noreply, assign(socket, :roster_open?, false)}
    end
  end

  # One expanded at a time is the whole invariant: expanding is an assignment,
  # not a toggle-on, so whichever window was expanded collapses by construction.
  # The terminal follows it, because the pane is only rendered for the expanded
  # window — so this is also what tears one xterm down and builds the next.
  def handle_event("expand", %{"id" => id}, socket) do
    if id in socket.assigns.open_ids do
      {:noreply, socket |> expand_window(id) |> persist()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("collapse", %{"id" => id}, socket) do
    if socket.assigns.expanded_id == id do
      {:noreply, socket |> collapse_window() |> persist()}
    else
      {:noreply, close_menu(socket)}
    end
  end

  # Detach is "drop this browser's reader, leave the agent running" — which is
  # exactly what collapsing does, since collapsing is what removes the pane and
  # so disposes the xterm and its `/session` socket. So this is not a second
  # implementation of anything: it is the same handler under the name an
  # operator comes looking for (it was `SessionLive`'s `detach` before the
  # terminal moved to the dock).
  def handle_event("detach", params, socket), do: handle_event("collapse", params, socket)

  # -- the window's own controls (phase 3, bd-a292yj) -------------------------
  #
  # Every one of them carries its own `phx-value-id`, so which window happens
  # to be expanded has nothing to do with which session they act on.

  def handle_event("toggle_menu", %{"id" => id}, socket) do
    {:noreply, assign(socket, :menu_id, if(socket.assigns.menu_id == id, do: nil, else: id))}
  end

  # Carries the id it is closing, and closes nothing else. One click can raise
  # both this (from the open window's click-away) and `toggle_menu` (from
  # another window's button), and the order the two arrive in is not ours to
  # decide — so "close A" must not be able to close the B that was just opened.
  def handle_event("close_menu", %{"id" => id}, socket) do
    if socket.assigns.menu_id == id, do: {:noreply, close_menu(socket)}, else: {:noreply, socket}
  end

  def handle_event("close_menu", _params, socket), do: {:noreply, close_menu(socket)}

  # The info side of a window: the session's metadata and the ledger's
  # cost/tokens, so neither costs a navigation away from whatever the operator
  # was reading. It is an *overlay*, never a replacement for the pane — see
  # `window/1`.
  def handle_event("toggle_info", %{"id" => id}, socket) do
    socket = close_menu(socket)

    if socket.assigns.info_id == id do
      {:noreply, close_info(socket)}
    else
      # The panel is an overlay on the window's own frame, and a collapsed
      # window has no frame on screen. So Info expands the window it was
      # invoked on rather than arming a panel nobody can see and a "Hide info"
      # label for it (bd-a292yj review, finding 3).
      socket =
        if id in socket.assigns.open_ids and socket.assigns.expanded_id != id do
          socket |> expand_window(id) |> persist()
        else
          socket
        end

      {:noreply,
       socket
       |> assign(:info_id, id)
       |> load_info_usage()
       |> schedule_usage_refresh()}
    end
  end

  def handle_event("toggle_keep_alive", %{"id" => id}, socket) do
    socket = close_menu(socket)

    case Map.fetch(socket.assigns.sessions_by_id, id) do
      {:ok, session} -> {:noreply, set_keep_alive(socket, session)}
      :error -> {:noreply, socket}
    end
  end

  # Kill keeps its confirm step here precisely *because* the dock is always on
  # screen: a one-click kill in a title bar an operator's cursor crosses all
  # day is a different risk profile from one on a page they navigated to
  # deliberately. The confirmation is `SessionIndexLive.kill_modal/1` itself,
  # not a second copy of it.
  def handle_event("confirm_kill", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> close_menu()
     |> assign(:kill_candidate, Map.get(socket.assigns.sessions_by_id, id))}
  end

  def handle_event("cancel_kill", _params, socket) do
    {:noreply, assign(socket, :kill_candidate, nil)}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, clear_dock_error(socket)}
  end

  def handle_event("kill", %{"id" => id}, socket) do
    socket =
      case Sessions.kill(id) do
        {:ok, _ended} ->
          clear_dock_error(socket)

        {:error, reason} ->
          Logger.error("SessionDockLive: kill #{id} failed: #{inspect(reason)}")
          put_dock_error(socket, "Could not end that session: #{describe(reason)}")
      end

    # Freeze *before* re-reading: `live_pane?/2` asks whether there was a pane
    # a moment ago, which is a question only the pre-kill row can answer.
    {:noreply,
     socket
     |> assign(:kill_candidate, nil)
     |> freeze_pane(id)
     |> load_sessions()}
  end

  # From the hook, the first time its stream reaches `live`. Only ever clears
  # the stall notice — a terminal that connects late is not a problem, it is
  # just late.
  def handle_event("terminal_live", %{"id" => id}, socket) do
    if socket.assigns.expanded_id == id do
      {:noreply, socket |> assign(:terminal_live?, true) |> assign(:terminal_stalled?, false)}
    else
      {:noreply, socket}
    end
  end

  # From the hook: phase 4's `exit` channel event. It arrives well before
  # anything marks the row ended — often before anything does at all — and the
  # window has to stop offering a terminal for an agent that is gone
  # (bd-bsdeb2 finding 4, in `SessionLive` before this).
  def handle_event("terminal_exited", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> freeze_pane(id)
     |> assign(:exited, MapSet.put(socket.assigns.exited, id))
     |> load_sessions()}
  end

  # Dismiss is a *view* action. It closes the window and forgets it; it never
  # kills or detaches the session, which stays exactly as it was and is still
  # in the roster to be opened again.
  def handle_event("dismiss", %{"id" => id}, socket) do
    open_ids = List.delete(socket.assigns.open_ids, id)

    socket =
      if socket.assigns.expanded_id == id, do: collapse_window(socket), else: socket

    {:noreply,
     socket
     |> assign(:open_ids, open_ids)
     # Dismiss forgets the window entirely, client side and server side: the
     # resume point goes, and so does the note that this session's agent had
     # exited. Re-opening it later re-reads the row, which is the authority.
     |> assign(:exited, MapSet.delete(socket.assigns.exited, id))
     # Dismissing an ended window is the one way its read-only pane goes away
     # (bd-a292yj): the final scrollback is thrown out by an explicit act,
     # rather than by the session merely having ended.
     |> assign(:frozen, MapSet.delete(socket.assigns.frozen, id))
     |> close_menu()
     |> then(&if &1.assigns.info_id == id, do: close_info(&1), else: &1)
     |> push_event("session-dock:forget", %{id: id})
     |> persist()}
  end

  # `Arbiter.Sessions.mark_ended/2` — a Kill (from here, from `/sessions`, or
  # from `arb`), an agent that exited on its own, the orphan reaper. Whichever
  # it was, a window with a live pane keeps it: read-only, still holding the
  # last thing the agent printed, which is exactly the output worth reading.
  @impl true
  def handle_info({:session_ended, session_id}, socket) do
    {:noreply, socket |> freeze_pane(session_id) |> load_sessions()}
  end

  # Nothing mounted a `.SessionTerminal` in time. The likeliest cause has no
  # other symptom: a tab still running the asset bundle it loaded before the
  # last deploy has no such hook at all, so the strip sits at "connecting…"
  # forever and looks exactly like a slow server.
  def handle_info({:terminal_stall_check, id}, socket) do
    stalled? =
      socket.assigns.expanded_id == id and socket.assigns.loopback? and
        not socket.assigns.terminal_live?

    {:noreply, assign(socket, :terminal_stalled?, stalled?)}
  end

  # Only ever armed while an info panel is open, and re-armed by the pull
  # itself, so a closed panel costs no queries.
  def handle_info(:refresh_dock_usage, socket) do
    if socket.assigns.info_id do
      {:noreply, socket |> load_info_usage() |> schedule_usage_refresh()}
    else
      {:noreply, assign(socket, :usage_refresh_ref, nil)}
    end
  end

  # The lifecycle topic is shared, and a sticky child outlives the page it was
  # rendered from — anything else that lands here is not this view's business.
  def handle_info(_message, socket), do: {:noreply, socket}

  # -- state ------------------------------------------------------------------

  defp load_sessions(socket) do
    sessions = Sessions.list()
    by_id = Map.new(sessions, &{&1.id, &1})

    socket
    |> assign(:sessions, sessions)
    |> assign(:sessions_by_id, by_id)
    |> assign(:running_count, Enum.count(sessions, &(&1.status == :running)))
  end

  # Opening always keeps the id being opened, even at the @max_open cap: the
  # id being added is also about to be the one that gets expanded, so taking
  # from the *front* (evicting the newest) would silently drop the window an
  # operator just asked for while still collapsing whatever was open before it
  # (finding 1, bd-cdut29 review round 1). Taking from the tail evicts the
  # oldest window instead.
  defp open_window_ids(open_ids, id) do
    (open_ids ++ [id]) |> Enum.uniq() |> Enum.take(-@max_open)
  end

  # Expanding is what mounts a terminal, so it is also what re-arms the watch
  # for one that never connects.
  defp expand_window(socket, id) do
    if connected?(socket), do: Process.send_after(self(), {:terminal_stall_check, id}, @stall_ms)

    socket
    |> assign(:expanded_id, id)
    |> assign(:terminal_live?, false)
    |> assign(:terminal_stalled?, false)
    |> close_menu()
  end

  defp collapse_window(socket) do
    socket
    |> assign(:expanded_id, nil)
    |> assign(:terminal_live?, false)
    |> assign(:terminal_stalled?, false)
    |> close_menu()
    |> close_info()
  end

  defp close_menu(socket), do: assign(socket, :menu_id, nil)

  defp close_info(socket) do
    socket
    |> assign(:info_id, nil)
    |> assign(:info_usage, nil)
  end

  # Whether there is anything to *attach* to, re-decided on every render. Note
  # that this is not "is there a pane": a window whose session ended under it
  # keeps its pane, read-only, with nothing attached (`freeze_pane/2`).
  defp attachable?(session, exited) do
    session.status == :running and not MapSet.member?(exited, session.id)
  end

  # The moment an ended session's window stops being a client and becomes a
  # record (bd-a292yj). Only a window that actually has a pane on screen can
  # freeze: one that was collapsed when its session died has no scrollback to
  # keep, and pretending otherwise is the dishonest half of this feature.
  defp freeze_pane(socket, id) do
    if live_pane?(socket, id) do
      assign(socket, :frozen, MapSet.put(socket.assigns.frozen, id))
    else
      socket
    end
  end

  # Is there a live pane for this session right now? It has to be the expanded
  # window, the peer has to be on loopback (off it no terminal was ever
  # mounted, §10.4), and the row has to still read attachable — which it does
  # until whoever is calling this records the end.
  defp live_pane?(socket, id) do
    with true <- socket.assigns.expanded_id == id,
         true <- socket.assigns.loopback?,
         {:ok, session} <- Map.fetch(socket.assigns.sessions_by_id, id) do
      attachable?(session, socket.assigns.exited)
    else
      _other -> false
    end
  end

  defp set_keep_alive(socket, session) do
    case Sessions.set_keep_alive(session, not session.keep_alive) do
      {:ok, _updated} ->
        socket |> clear_dock_error() |> load_sessions()

      {:error, reason} ->
        Logger.error("SessionDockLive: set_keep_alive #{session.id} failed: #{inspect(reason)}")
        put_dock_error(socket, "Could not update keep_alive: #{describe(reason)}")
    end
  end

  # An error the operator has to see, said where they are looking: in the dock
  # itself. See the `:error_message` assign in `mount/3` for why this is not a
  # flash.
  defp put_dock_error(socket, message), do: assign(socket, :error_message, message)

  defp clear_dock_error(socket), do: assign(socket, :error_message, nil)

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(reason), do: inspect(reason)

  defp load_info_usage(socket) do
    session = Map.get(socket.assigns.sessions_by_id, socket.assigns.info_id)
    assign(socket, :info_usage, SessionUsage.for_session(session))
  end

  # Cancels any prior ref first, so re-opening a panel in a burst cannot stack
  # duplicate timers (`SessionIndexLive`'s bd-9mrzti finding 3, same shape).
  defp schedule_usage_refresh(socket) do
    if ref = socket.assigns[:usage_refresh_ref], do: Process.cancel_timer(ref)

    ref =
      if connected?(socket) and socket.assigns.info_id do
        Process.send_after(self(), :refresh_dock_usage, @usage_refresh_ms)
      end

    assign(socket, :usage_refresh_ref, ref)
  end

  defp persist(socket) do
    push_event(socket, "session-dock:persist", %{
      open: socket.assigns.open_ids,
      expanded: socket.assigns.expanded_id
    })
  end

  defp open_sessions(assigns) do
    Enum.flat_map(assigns.open_ids, fn id ->
      case Map.fetch(assigns.sessions_by_id, id) do
        {:ok, session} -> [session]
        :error -> []
      end
    end)
  end

  # -- markup -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :open_sessions, open_sessions(assigns))

    ~H"""
    <div
      id="session-dock-root"
      phx-hook="SessionDock"
      class="fixed bottom-0 left-0 right-0 z-30 flex items-end justify-start gap-2 px-3 pointer-events-none"
    >
      <%!-- Out of the flex row on purpose (`absolute`, so it sits above the
            strip rather than becoming another window in it) and
            `pointer-events-auto`, since the root is not — otherwise its
            dismiss button would be unclickable. --%>
      <div
        :if={@error_message}
        id="session-dock-error"
        role="alert"
        class={[
          "pointer-events-auto absolute bottom-full left-3 mb-2 max-w-[32rem] z-40",
          "flex items-start gap-2 px-2.5 py-1.5",
          "rounded-[var(--radius-panel)] border border-solid border-[var(--arb-fail-edge)]",
          "bg-[var(--arb-fail-wash)] shadow-lg",
          "text-[11.5px] text-[var(--arb-fail-text)]"
        ]}
      >
        <.icon name="hero-exclamation-triangle-micro" class="size-4 shrink-0 mt-px" />
        <span class="grow">{@error_message}</span>
        <button
          type="button"
          id="session-dock-error-dismiss"
          phx-click="dismiss_error"
          aria-label="Dismiss error"
          class="shrink-0 flex items-center justify-center size-[18px] rounded-[var(--radius-field)] cursor-pointer bg-transparent border-0 text-current opacity-70 hover:opacity-100"
        >
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </div>

      <.roster
        open?={@roster_open?}
        sessions={@sessions}
        open_ids={@open_ids}
        running_count={@running_count}
        launch_open?={@launch_open?}
        launch_auth_mode={@launch_auth_mode}
        workspaces={@workspaces}
        launch_error={@launch_error}
      />

      <.window
        :for={session <- @open_sessions}
        session={session}
        expanded?={@expanded_id == session.id}
        attachable?={attachable?(session, @exited)}
        frozen?={MapSet.member?(@frozen, session.id)}
        loopback?={@loopback?}
        stalled?={@terminal_stalled? and @expanded_id == session.id}
        menu_open?={@menu_id == session.id}
        info_open?={@info_id == session.id}
        usage={@info_usage}
      />
    </div>

    <%!-- Outside `#session-dock-root`, which is `pointer-events-none` so the
          strip never swallows clicks meant for the page underneath it — a
          modal rendered inside it would be unclickable. It is
          `SessionIndexLive.kill_modal/1` itself rather than a second copy:
          both surfaces end real sessions and both must ask first, and a
          duplicate is a second chance for one of them to stop asking. --%>
    <SessionIndexLive.kill_modal session={@kill_candidate} />

    <script :type={Phoenix.LiveView.ColocatedHook} name=".SessionTerminal">
      import { createSessionTerminal } from "@/js/session_terminal.mjs"
      import {
        finalScreenFor,
        forgetResume,
        markFrozen,
        rememberFinalScreen,
        rememberResume,
        resumeFrom
      } from "@/js/session_dock.mjs"

      // The states the hook paints into the window's status strip.
      // "reconnecting" is the one that matters: it is what an operator sees
      // across a `systemctl --user restart arbiter` (RFC 10.1), and it has to
      // say "hold on" rather than look like a dead page.
      const LABELS = {
        connecting: "connecting…",
        live: "live",
        reconnecting: "reconnecting…",
        detached: "detached",
        ended: "agent exited"
      }

      function formatTokens(n) {
        if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
        if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
        return String(n)
      }

      export default {
        mounted() {
          this.sessionId = this.el.dataset.sessionId
          this.statusEl = document.getElementById(`session-dock-status-${this.sessionId}`)

          // The server already knows this window is a record rather than a
          // client: its session ended under a previous xterm and a LiveView
          // rejoin has just rebuilt the element. Opening a `/session` socket
          // for it would only sit at "reconnecting…" against a dead session,
          // so this one is built read-only, painted from what the previous
          // xterm left behind, and never connects.
          const frozen = !!this.el.dataset.readonly
          this.state = frozen ? "ended" : "connecting"
          if (frozen) markFrozen(this.sessionId)

          this.terminal = createSessionTerminal(this.el, {
            sessionId: this.sessionId,
            readOnly: frozen,
            restoredText: frozen ? finalScreenFor(this.sessionId) : null,
            // The resume point the *previous* xterm for this session left
            // behind. A fresh terminal has none of its own — this is the
            // whole reason a window collapsed for ten minutes replays what it
            // missed instead of re-snapshotting from wherever the ring starts.
            lastSeq: resumeFrom(this.sessionId),
            onStatus: (state) => {
              this.state = state
              this.setState(state)
              // The dock cannot see the channel, so it is told. Without this a
              // terminal that never starts is indistinguishable from one that
              // is merely slow, and the strip says "connecting…" either way.
              if (state === "live") this.pushEvent("terminal_live", { id: this.sessionId })
            },
            onMeta: (meta, info) => this.setMeta(meta, info),
            onUsage: (payload) => this.setUsage(payload),
            onExit: (payload) => {
              this.state = "ended"
              this.setState("ended")
              // The pane stays — the last thing the agent printed is exactly
              // what is worth reading — but nothing typed into it can reach a
              // process that is gone (bd-a292yj).
              this.terminal.setReadOnly()
              markFrozen(this.sessionId)
              this.pushEvent("terminal_exited", { ...(payload || {}), id: this.sessionId })
            },
            onError: (err) => this.setMeta({ error: (err && err.code) || "error" }),
            // The documented way out of the keyboard trap
            // (`Ctrl/Cmd+Shift+Escape`, see `session_keys.mjs`). Focus lands on
            // the window's own title bar — a real, visible, focusable control —
            // so `Tab` from there continues into the page as usual.
            onReleaseFocus: () => this.releaseFocus()
          })

          // `sticky: true` keeps this element across a `live_redirect`, but
          // the client gets there by re-parenting it through a *detached*
          // container (`LiveSocket.replaceMain`). That zeroes `scrollTop` on
          // every scrollable node inside — xterm's viewport included, which
          // would scroll the buffer to the top of the scrollback — and it can
          // land the pane at a different size. Both are re-settled a frame
          // after the incoming view's patch has run.
          this.onNavigate = () => {
            // Synchronously, before the frame in which the browser dispatches
            // the `scroll` events the move produced — that is the last moment
            // xterm still holds the offset the operator was reading at.
            this.terminal.rememberScroll()

            requestAnimationFrame(() =>
              requestAnimationFrame(() => {
                if (!this.terminal) return
                this.terminal.restoreScroll()
                this.terminal.refit()
              })
            )
          }
          window.addEventListener("phx:navigate", this.onNavigate)

          // Dismiss is "forget this window", so the resume point goes with it:
          // re-opening later should be a fresh snapshot, not a replay from an
          // offset nothing on screen was painted at.
          this.onForget = this.handleEvent("session-dock:forget", ({ id }) => forgetResume(id))

          // Exposed on the element the same way, and for the same reason,
          // `app.js` exposes `window.liveSocket`: a terminal is the one thing
          // on this page with no DOM to read when something looks wrong — the
          // canvas renderer draws pixels, not text. It is also the seam
          // `scripts/verify_session_dock_terminal.mjs` reads the screen and
          // the geometry through, so the claims it makes are about the real
          // xterm rather than about a stand-in.
          this.el.__arbTerminal = this.terminal

          if (!frozen) this.terminal.focus()
        },

        // LiveView merges `data-*` attributes onto a `phx-update="ignore"`
        // element and then runs this, which is the only channel the server has
        // into a pane it is otherwise forbidden to touch. It is how a session
        // killed from the dock's own title bar, or reaped elsewhere, goes
        // read-only even when the channel never delivered an `exit`.
        updated() {
          if (!this.terminal || !this.el.dataset.readonly) return

          this.terminal.setReadOnly()
          markFrozen(this.sessionId)
        },

        // A LiveView rejoin re-runs `mount/3` — the strip is server-rendered as
        // "connecting…" again — but it does *not* re-mount hooks. The
        // terminal's own `/session` socket is separate and usually never
        // dropped, so `onStatus` has nothing new to report and nothing
        // re-announces the state.
        reconnected() {
          this.statusEl = document.getElementById(`session-dock-status-${this.sessionId}`)
          this.setState(this.state)
          if (this.state === "live") this.pushEvent("terminal_live", { id: this.sessionId })
        },

        // Collapsing the window removes this element, which is what closes the
        // socket and disposes the xterm. The resume point is the one thing
        // that has to outlive it.
        destroyed() {
          window.removeEventListener("phx:navigate", this.onNavigate)
          if (this.onForget) this.removeHandleEvent(this.onForget)
          if (!this.terminal) return

          // A dead pane has no stream to replay, so what it leaves behind is
          // its screen rather than an offset (bd-a292yj). A LiveView rejoin —
          // which re-renders the dock from an empty mount — is the one thing
          // that gets here with a window still open.
          if (this.terminal.readOnly()) {
            rememberFinalScreen(this.sessionId, this.terminal.snapshot())
          }

          rememberResume(this.sessionId, this.terminal.stream.lastSeq)
          this.terminal.dispose()
          this.terminal = null
          this.el.__arbTerminal = null
        },

        releaseFocus() {
          if (this.terminal) this.terminal.blur()
          const title = document.getElementById(`session-dock-title-${this.sessionId}`)
          if (title) title.focus()
        },

        setState(state) {
          if (!this.statusEl) return
          this.statusEl.dataset.state = state
          const slot = this.statusEl.querySelector('[data-role="state"]')
          if (slot) slot.textContent = LABELS[state] || state
        },

        // The pane's geometry, and whether it is this client's own.
        //
        // A pane is shared, and the last client to resize it wins (bd-4tjw34).
        // A client that lost renders at the pane's geometry rather than at the
        // one its own window would fit — which is the only way to render it
        // correctly — so the label says `adopted 120x40` rather than passing
        // the size off as this window's, and says what takes it back.
        setMeta(meta, info) {
          if (!this.statusEl || !meta) return
          const slot = this.statusEl.querySelector('[data-role="meta"]')
          if (!slot) return
          if (meta.error) {
            delete slot.dataset.adopted
            slot.title = ""
            slot.textContent = meta.error
            return
          }
          const adopted = !!(info && info.adopted)
          const clients = meta.attached_clients

          if (adopted) slot.dataset.adopted = "true"
          else delete slot.dataset.adopted

          slot.title = adopted
            ? "Another client resized this session's pane. Click or type here to take it back at this window's size."
            : ""
          slot.textContent =
            (adopted ? "adopted " : "") +
            `${meta.cols}x${meta.rows}` +
            (clients > 1 ? ` · ${clients} clients` : "")
        },

        // Each `usage` event carries the file's *cumulative* tokens and latest
        // known cost (§7.5, phase 7) — assigned, not accumulated, so a window
        // that (re)attaches mid-session shows the right number on its very next
        // tick instead of resuming from zero or double counting.
        setUsage(payload) {
          if (!this.statusEl || !payload) return
          const slot = this.statusEl.querySelector('[data-role="usage"]')
          if (!slot) return

          const tokensIn = payload.tokens_in || 0
          const tokensOut = payload.tokens_out || 0

          const tokens = `${formatTokens(tokensIn)} in / ${formatTokens(tokensOut)} out`
          const cost =
            typeof payload.cost_usd === "number"
              ? `$${payload.cost_usd.toFixed(2)}`
              : "cost unavailable"
          const marker = payload.estimated ? " (estimated)" : ""

          slot.textContent = `${tokens} · ${cost}${marker}`
        }
      }
    </script>
    """
  end

  attr :open?, :boolean, required: true
  attr :sessions, :list, required: true
  attr :open_ids, :list, required: true
  attr :running_count, :integer, required: true
  attr :launch_open?, :boolean, required: true
  attr :launch_auth_mode, :string, required: true
  attr :workspaces, :list, required: true
  attr :launch_error, :any, required: true

  defp roster(assigns) do
    ~H"""
    <div class="pointer-events-auto flex flex-col justify-end shrink basis-[268px] min-w-[8.5rem] max-w-[268px]">
      <%!-- New session (bd-cdut29): the exact same options `/sessions`
            launches with, opened without navigating away from wherever the
            operator is. See `SessionIndexLive.launch_form/1`. --%>
      <div
        :if={@launch_open?}
        id="session-dock-launch-panel"
        class={[
          "mb-1 px-2.5 py-2.5",
          "rounded-[var(--radius-panel)] border border-solid border-[var(--border-default)]",
          "bg-[var(--surface-card)] shadow-lg"
        ]}
      >
        <SessionIndexLive.launch_form
          prefix="session-dock-launch"
          launch_auth_mode={@launch_auth_mode}
          workspaces={@workspaces}
          error={@launch_error}
        />
      </div>

      <div
        :if={@open?}
        id="session-dock-roster-panel"
        data-dock-scroll
        class={[
          "mb-1 max-h-[min(58vh,420px)] overflow-y-auto",
          "rounded-t-[var(--radius-panel)] border border-solid border-[var(--border-default)]",
          "bg-[var(--surface-card)] shadow-lg"
        ]}
      >
        <p
          :if={@sessions == []}
          id="session-dock-roster-empty"
          class="px-3 py-4 text-[12px] text-[var(--text-secondary)]"
        >
          No coordinator sessions yet.
        </p>

        <ul :if={@sessions != []} id="session-dock-roster-list" class="flex flex-col">
          <li
            :for={session <- @sessions}
            id={"session-dock-roster-#{session.id}"}
            data-status={session.status}
            class={[
              "flex items-center gap-2 px-2.5 py-2 border-b border-solid border-[var(--border-default)] last:border-b-0",
              session.status != :running && "opacity-70"
            ]}
          >
            <Data.status_chip status={session.status} class="badge-xs shrink-0" />

            <span class="flex flex-col min-w-0 grow">
              <span class="text-[12px] text-[var(--text-primary)] truncate">
                {DisplayName.resolve(session)}
              </span>
              <span class="font-[family-name:var(--font-mono)] text-[10px] text-[var(--text-label)]">
                {DisplayName.short_id(session.id)}
              </span>
            </span>

            <button
              type="button"
              id={"session-dock-open-#{session.id}"}
              phx-click="open"
              phx-value-id={session.id}
              class={[
                "shrink-0 px-2 h-[22px] rounded-[var(--radius-field)] cursor-pointer",
                "border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)]",
                "text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              ]}
            >
              {if session.id in @open_ids, do: "Opened", else: "Open"}
            </button>
          </li>
        </ul>
      </div>

      <div class="flex items-stretch gap-1">
        <button
          type="button"
          id="session-dock-roster-toggle"
          phx-click="toggle_roster"
          aria-expanded={to_string(@open?)}
          aria-controls="session-dock-roster-panel"
          class={[
            "flex grow items-center gap-2 px-3 h-[var(--session-dock-strip-height)] cursor-pointer",
            "rounded-t-[var(--radius-panel)] border border-b-0 border-solid border-[var(--border-default)]",
            "bg-[var(--surface-chrome)] text-[12px] font-medium text-[var(--text-title)]",
            "hover:bg-[var(--surface-card)] transition-colors"
          ]}
        >
          <.icon name="hero-command-line-micro" class="size-4 shrink-0" />
          <span class="grow text-left">Sessions</span>
          <span
            id="session-dock-running-count"
            class="font-[family-name:var(--font-mono)] text-[10.5px] text-[var(--text-label)]"
          >
            {@running_count} running
          </span>
          <.icon
            name={if @open?, do: "hero-chevron-down-micro", else: "hero-chevron-up-micro"}
            class="size-4 shrink-0"
          />
        </button>

        <button
          type="button"
          id="session-dock-new-session"
          phx-click="toggle_launch"
          aria-expanded={to_string(@launch_open?)}
          aria-controls="session-dock-launch-panel"
          aria-label="New session"
          title="New session"
          class={[
            "shrink-0 flex items-center justify-center w-[var(--session-dock-strip-height)]",
            "h-[var(--session-dock-strip-height)] cursor-pointer",
            "rounded-t-[var(--radius-panel)] border border-b-0 border-solid border-[var(--border-default)]",
            "bg-[var(--surface-chrome)] text-[var(--text-secondary)]",
            "hover:bg-[var(--surface-card)] hover:text-[var(--text-primary)] transition-colors"
          ]}
        >
          <.icon name="hero-plus-micro" class="size-4 shrink-0" />
        </button>
      </div>
    </div>
    """
  end

  attr :session, :any, required: true
  attr :expanded?, :boolean, required: true
  attr :attachable?, :boolean, required: true
  attr :frozen?, :boolean, required: true
  attr :loopback?, :boolean, required: true
  attr :stalled?, :boolean, required: true
  attr :menu_open?, :boolean, required: true
  attr :info_open?, :boolean, required: true
  attr :usage, :any, required: true, doc: "the info panel's rollup, or nil"

  defp window(assigns) do
    assigns =
      assigns
      # A *live* pane: an xterm with a `/session` socket under it. Only the
      # expanded window ever has one, and only on loopback.
      |> assign(:live?, assigns.expanded? and assigns.attachable? and assigns.loopback?)
      # Any pane at all — live, or frozen at the last thing the agent printed.
      # A frozen pane outlives collapsing on purpose: the acceptance is "until
      # explicitly dismissed", and a collapse is not that. It holds no socket,
      # so eight of them cost eight xterms and zero connections.
      |> assign(
        :pane?,
        (assigns.expanded? and assigns.attachable? and assigns.loopback?) or assigns.frozen?
      )
      |> assign(:name, DisplayName.resolve(assigns.session))
      |> assign(:running?, assigns.session.status == :running and not assigns.frozen?)

    ~H"""
    <div
      id={"session-dock-window-#{@session.id}"}
      data-expanded={to_string(@expanded?)}
      data-status={@session.status}
      class={
        [
          "pointer-events-auto flex flex-col justify-end grow-0 shrink",
          # A full strip has to compress rather than run off the edge of the
          # page: a fixed-width row of eight windows plus the roster overflows
          # any laptop, and a `position: fixed` row that overflows takes the
          # whole document's horizontal scrollbar with it. Widths are a basis
          # and a ceiling, and the titles already truncate.
          #
          # The expanded basis is wider than phase 1's empty frame needed: a
          # terminal cannot reflow meaningfully below ~80 columns (§6.3), and
          # 28rem of pane was about 60 of them.
          if(@expanded?,
            do: "basis-[44rem] max-w-[44rem] min-w-[16rem]",
            else: "basis-[11rem] max-w-[11rem] min-w-[5rem]"
          )
        ]
      }
    >
      <%!-- A collapsed window still renders its frame when it holds a frozen
            pane, hidden rather than removed: unmounting it is what disposes
            the xterm, and disposing it is what throws the final scrollback
            away. `hidden` is `display: none`, so it costs no layout. --%>
      <div
        :if={@expanded? or @frozen?}
        id={"session-dock-frame-#{@session.id}"}
        role="region"
        aria-label={"Session #{@name}"}
        class={[
          "relative flex flex-col h-[min(52vh,380px)] overflow-hidden",
          "border border-b-0 border-solid border-[var(--border-default)]",
          "rounded-t-[var(--radius-panel)] bg-[var(--surface-panel)] shadow-lg",
          not @expanded? && "hidden"
        ]}
      >
        <%!-- The status strip is chrome, pinned outside the xterm element so
              it can never fight the fit for rows (§6.3). Its contents are
              hook-owned — so LiveView is told to keep out of them, and so it
              is only rendered when there is a hook to own it. A frozen pane
              has no channel and no live state to paint, so it gets the ended
              banner below instead. --%>
        <div
          :if={@live?}
          id={"session-dock-status-#{@session.id}"}
          phx-update="ignore"
          class={[
            "flex shrink-0 items-center gap-2 px-2.5 py-1",
            "border-b border-solid border-[var(--border-default)]",
            "text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]"
          ]}
        >
          <span data-role="state">connecting…</span>
          <%!-- Live cost HUD (§7.5, phase 7): hook-owned, same reason the rest
                of this strip is — a value that updates every ~2s must not
                become a LiveView diff. The info panel's figure is the ledger's
                own rollup and answers a different question (what this session
                has cost, including after it ended). --%>
          <span data-role="usage" class="text-[var(--text-label)] truncate"></span>
          <span data-role="meta" class="ml-auto shrink-0 text-[var(--text-label)]"></span>
          <%!-- The keyboard rule, said out loud. An expanded terminal takes
                every key on purpose, so the one way back out has to be
                visible rather than folklore. --%>
          <span
            class="shrink-0 text-[var(--text-ghost,var(--text-label))]"
            title="The terminal takes every key while focused. Ctrl/Cmd+Shift+Escape gives the keyboard back to the page."
          >
            ⇧⌃⎋ frees
          </span>
        </div>

        <%!-- The session ended under this window (bd-a292yj). The pane below
              stays exactly as the agent left it, read-only; this says so, says
              why it ended, and offers the one act that throws it away. --%>
        <div
          :if={@frozen?}
          id={"session-dock-ended-#{@session.id}"}
          class={[
            "flex shrink-0 items-center gap-2 px-2.5 py-1",
            "border-b border-solid border-[var(--border-default)]",
            "bg-[var(--surface-field)]",
            "text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-body)]"
          ]}
        >
          <.icon name="hero-power-micro" class="size-3.5 shrink-0 text-[var(--text-label)]" />
          <span>Agent exited</span>
          <span :if={@session.end_reason} class="text-[var(--text-label)] truncate">
            {@session.end_reason}
          </span>
          <span class="ml-auto shrink-0 text-[var(--text-label)]">read-only</span>
        </div>

        <%!-- Not inside the status strip: that is `phx-update="ignore"` and
              hook-owned, and this is precisely the case where there may be no
              hook to own it. --%>
        <div
          :if={@stalled? and @live?}
          id={"session-dock-stalled-#{@session.id}"}
          class={[
            "flex shrink-0 flex-wrap items-center gap-1.5 px-2.5 py-1.5",
            "border-b border-solid border-[var(--border-default)]",
            "bg-[var(--surface-field)] text-[10.5px] text-[var(--text-body)]"
          ]}
        >
          <.icon name="hero-exclamation-triangle-micro" class="size-3.5 text-[var(--text-label)]" />
          <span>The terminal has not connected.</span>
          <%!-- A full page load on purpose: the likeliest cause is a tab still
                running the asset bundle it loaded before the last deploy, and
                a live navigation would not replace it. --%>
          <a href={~p"/sessions"} class="text-[var(--text-link)] no-underline hover:underline">
            Reload the page
          </a>
        </div>

        <%!-- §6.3: a terminal cannot reflow meaningfully below ~80 columns, so
              a squeezed window scrolls this container sideways rather than
              shrinking the pane to illegibility. The *page* never scrolls
              sideways — a `position: fixed` strip that overflowed would give
              every page a horizontal scrollbar it never had. --%>
        <div
          :if={@pane?}
          id={"session-dock-scroller-#{@session.id}"}
          class="flex grow min-h-0 overflow-x-auto bg-[var(--arb-term-bg,#16181d)]"
        >
          <%!-- `data-readonly` is the one thing that reaches a
                `phx-update="ignore"` element through a patch: LiveView merges
                `data-*` attributes onto an ignored node and then calls the
                hook's `updated()`, which is how a pane goes read-only without
                being re-created. The hook also does it from the channel's own
                `exit` event, whichever lands first. --%>
          <div
            id={"session-dock-terminal-#{@session.id}"}
            phx-hook=".SessionTerminal"
            phx-update="ignore"
            data-arb-terminal
            data-readonly={if @frozen?, do: "true"}
            data-session-id={@session.id}
            class="grow min-w-[640px] p-1.5"
          >
          </div>
        </div>

        <%!-- §10.4: `ArbiterWeb.SessionSocket` trusts a loopback peer and the
              browser sends no token, so a `/session` connect from here would
              just fail silently. Say so up front instead of mounting a
              terminal that never attaches (bd-2zskbb), and say what *does*
              work — an SSH port-forward is the supported way in (#1775). --%>
        <div
          :if={@attachable? and not @loopback?}
          id={"session-dock-remote-#{@session.id}"}
          class="grow min-h-0 flex flex-col items-center justify-center gap-1.5 px-4 text-center text-[11px] text-[var(--text-body)] font-[family-name:var(--font-mono)]"
        >
          <.icon name="hero-lock-closed" class="size-5 text-[var(--text-label)]" />
          <p>This session's terminal is loopback-only by design.</p>
          <p
            :if={@session.auth_mode == :seeded_credentials and @session.remote_control}
            class="text-[var(--text-label)]"
          >
            Forward the port over SSH: <code>ssh -L 4848:127.0.0.1:4848 &lt;host&gt;</code>
            (<.link
              href="https://github.com/ryanrborn/arbiter/blob/main/docs/remote-access.md"
              target="_blank"
              class="underline"
            >docs</.link>), or use Remote Control.
          </p>
          <p
            :if={@session.auth_mode == :seeded_credentials and not @session.remote_control}
            class="text-[var(--text-label)]"
          >
            Forward the port over SSH: <code>ssh -L 4848:127.0.0.1:4848 &lt;host&gt;</code>
            (<.link
              href="https://github.com/ryanrborn/arbiter/blob/main/docs/remote-access.md"
              target="_blank"
              class="underline"
            >docs</.link>). Remote Control (mode B, launched with <code>--remote-control</code>) is not enabled on this session.
          </p>
          <p :if={@session.auth_mode != :seeded_credentials} class="text-[var(--text-label)]">
            This session runs under a workspace token (mode A). Forward the port over SSH:
            <code>ssh -L 4848:127.0.0.1:4848 &lt;host&gt;</code>
            (<.link
              href="https://github.com/ryanrborn/arbiter/blob/main/docs/remote-access.md"
              target="_blank"
              class="underline"
            >docs</.link>).
          </p>
        </div>

        <%!-- Ended, and this dock never held its pane: either it ended before
              this browser session, or its window was dismissed and re-opened.
              Either way there is no scrollback here to show and none to fetch
              until transcript persistence lands (bd-5pelo2, phase 9) — so it
              says so and points at the index, rather than rendering an empty
              terminal that reads like a live one with nothing on it. --%>
        <div
          :if={not @pane? and not @attachable?}
          id={"session-dock-unavailable-#{@session.id}"}
          class="grow min-h-0 flex flex-col items-center justify-center gap-1.5 px-4 text-center text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
        >
          <.icon name="hero-power" class="size-5" />
          <p class="text-[var(--text-body)]">
            This session has ended{if @session.end_reason, do: " (#{@session.end_reason})"}.
          </p>
          <p>
            Its output is not available here — the dock was not watching it when it ended.
          </p>
          <.link
            navigate={~p"/sessions"}
            class="text-[var(--text-link)] no-underline hover:underline"
          >
            Ended sessions are listed on /sessions
          </.link>
        </div>

        <%!-- The info side of the window: an *overlay*, not a swap. Replacing
              the pane would unmount it, and unmounting it disposes the xterm —
              a config dir is not worth a scrollback. --%>
        <div
          :if={@info_open? and @expanded?}
          id={"session-dock-info-panel-#{@session.id}"}
          class={[
            "absolute inset-0 z-10 overflow-y-auto px-3 py-2.5",
            "bg-[var(--surface-panel)] text-[11px] font-[family-name:var(--font-mono)]"
          ]}
        >
          <div class="flex items-center gap-2 mb-2">
            <Data.status_chip status={@session.status} class="badge-xs shrink-0" />
            <span class="grow truncate text-[12px] font-medium text-[var(--text-title)]">
              {@name}
            </span>
            <button
              type="button"
              id={"session-dock-info-close-#{@session.id}"}
              phx-click="toggle_info"
              phx-value-id={@session.id}
              aria-label={"Close info for #{@name}"}
              class="shrink-0 flex items-center justify-center size-[22px] rounded-[var(--radius-field)] cursor-pointer bg-transparent border-0 text-[var(--text-label)] hover:text-[var(--text-primary)]"
            >
              <.icon name="hero-x-mark-micro" class="size-4" />
            </button>
          </div>

          <%!-- The ledger's own rollup, the same `Arbiter.Usage.summarize(by:
                :session)` `/sessions` and `arb usage --by session` read
                (`ArbiterWeb.SessionUsage`). Never a silent `$0.00` for a
                session the ledger has no rows for yet. --%>
          <p
            :if={@usage}
            id={"session-dock-usage-#{@session.id}"}
            class="mb-2 text-[var(--text-body)]"
          >
            {Data.format_tokens(@usage.tokens_in)} in / {Data.format_tokens(@usage.tokens_out)} out · {Data.format_usd(
              @usage.total_cost_usd
            )}<span :if={@usage.estimated}> (estimated)</span>
          </p>
          <p
            :if={!@usage}
            id={"session-dock-usage-empty-#{@session.id}"}
            class="mb-2 italic text-[var(--text-label)]"
          >
            no usage data
          </p>

          <dl class="grid grid-cols-1 gap-x-4 gap-y-1 text-[var(--text-label)]">
            <div class="flex gap-2">
              <dt class="min-w-[7rem] shrink-0">id</dt>
              <dd class="truncate text-[var(--text-body)]">{@session.id}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="min-w-[7rem] shrink-0">cwd</dt>
              <dd class="truncate text-[var(--text-body)]">{@session.cwd}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="min-w-[7rem] shrink-0">scope unit</dt>
              <dd class="truncate text-[var(--text-body)]">{@session.scope_unit}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="min-w-[7rem] shrink-0">config dir</dt>
              <dd class="truncate text-[var(--text-body)]">{@session.config_dir}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="min-w-[7rem] shrink-0">auth mode</dt>
              <dd class="text-[var(--text-body)]">{@session.auth_mode}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="min-w-[7rem] shrink-0">can dispatch</dt>
              <dd class="text-[var(--text-body)]">{@session.can_dispatch}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="min-w-[7rem] shrink-0">keep_alive</dt>
              <dd
                id={"session-dock-keep-alive-value-#{@session.id}"}
                class="text-[var(--text-body)]"
              >
                {@session.keep_alive}
              </dd>
            </div>
            <div :if={@session.end_reason} class="flex gap-2">
              <dt class="min-w-[7rem] shrink-0">end reason</dt>
              <dd class="truncate text-[var(--text-body)]">{@session.end_reason}</dd>
            </div>
          </dl>
        </div>
      </div>

      <div class={[
        "relative flex items-center gap-1.5 pl-3 pr-1 h-[var(--session-dock-strip-height)]",
        "border border-b-0 border-solid border-[var(--border-default)]",
        "bg-[var(--surface-chrome)]",
        not @expanded? && "rounded-t-[var(--radius-panel)]"
      ]}>
        <span
          class={[
            "size-1.5 rounded-full shrink-0",
            if(@running?,
              do: "bg-[var(--arb-live)]",
              else: "bg-[var(--text-ghost,var(--text-label))]"
            )
          ]}
          aria-hidden="true"
        >
        </span>

        <button
          type="button"
          id={"session-dock-title-#{@session.id}"}
          phx-click={if @expanded?, do: "collapse", else: "expand"}
          phx-value-id={@session.id}
          aria-expanded={to_string(@expanded?)}
          title={@name}
          class="grow min-w-0 text-left text-[12px] font-medium text-[var(--text-title)] truncate cursor-pointer bg-transparent border-0"
        >
          {@name}
        </button>

        <%!-- Why it is over, in the title bar, where a collapsed window can
              still say it (bd-a292yj). Truncated by design; the whole reason
              is in the tooltip and in the info side. --%>
        <span
          :if={not @running?}
          id={"session-dock-end-reason-#{@session.id}"}
          title={@session.end_reason || "ended"}
          class="shrink min-w-0 max-w-[7rem] truncate text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
        >
          {@session.end_reason || "ended"}
        </span>

        <.window_menu
          session={@session}
          name={@name}
          open?={@menu_open?}
          expanded?={@expanded?}
          running?={@running?}
          info_open?={@info_open?}
        />

        <button
          type="button"
          id={"session-dock-dismiss-#{@session.id}"}
          phx-click="dismiss"
          phx-value-id={@session.id}
          aria-label={"Dismiss #{@name}"}
          class="shrink-0 flex items-center justify-center size-[22px] rounded-[var(--radius-field)] cursor-pointer bg-transparent border-0 text-[var(--text-label)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-card)]"
        >
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc false
  # The window's overflow. A title bar 11rem wide cannot hold four controls, and
  # a kill button an operator's cursor crosses all day should not be one click
  # from the end of a session — so the per-session controls live one deliberate
  # click in, and Kill asks again after that.
  attr :session, :any, required: true
  attr :name, :string, required: true
  attr :open?, :boolean, required: true
  attr :expanded?, :boolean, required: true
  attr :running?, :boolean, required: true
  attr :info_open?, :boolean, required: true

  defp window_menu(assigns) do
    ~H"""
    <%!-- The click-away sits on the *wrapper*, not on the panel, and only
          while the menu is open. On the panel it would fire for a click on
          this window's own toggle button — which is outside the panel — and
          race the toggle into re-opening what the operator meant to close.
          Absent while closed, so an idle dock costs the page no listener and
          no event per click. --%>
    <div
      class="relative shrink-0"
      phx-click-away={if @open?, do: "close_menu"}
      phx-value-id={@session.id}
    >
      <button
        type="button"
        id={"session-dock-menu-#{@session.id}"}
        phx-click="toggle_menu"
        phx-value-id={@session.id}
        aria-haspopup="menu"
        aria-expanded={to_string(@open?)}
        aria-controls={"session-dock-menu-panel-#{@session.id}"}
        aria-label={"Controls for #{@name}"}
        class="flex items-center justify-center size-[22px] rounded-[var(--radius-field)] cursor-pointer bg-transparent border-0 text-[var(--text-label)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-card)]"
      >
        <.icon name="hero-ellipsis-horizontal-micro" class="size-4" />
      </button>

      <%!-- Opens *upward*: the dock is pinned to the bottom of the viewport,
            so a menu that dropped down would render off-screen. --%>
      <div
        :if={@open?}
        id={"session-dock-menu-panel-#{@session.id}"}
        role="menu"
        class={[
          "absolute bottom-full right-0 mb-1 z-40 w-[13rem] py-1",
          "rounded-[var(--radius-panel)] border border-solid border-[var(--border-default)]",
          "bg-[var(--surface-card)] shadow-lg"
        ]}
      >
        <button
          type="button"
          id={"session-dock-info-#{@session.id}"}
          role="menuitem"
          phx-click="toggle_info"
          phx-value-id={@session.id}
          class={menu_item_class()}
        >
          <.icon name="hero-information-circle-micro" class="size-4 shrink-0" />
          {if @info_open?, do: "Hide info", else: "Info & cost"}
        </button>

        <button
          :if={@running?}
          type="button"
          id={"session-dock-keep-alive-#{@session.id}"}
          role="menuitem"
          phx-click="toggle_keep_alive"
          phx-value-id={@session.id}
          class={menu_item_class()}
        >
          <.icon
            name={
              if @session.keep_alive, do: "hero-bookmark-slash-micro", else: "hero-bookmark-micro"
            }
            class="size-4 shrink-0"
          />
          {if @session.keep_alive, do: "Unpin keep_alive", else: "Pin keep_alive"}
        </button>

        <%!-- Detach is the same handler as collapse (see `handle_event/3`):
              dropping this browser's reader and leaving the agent running is
              what removing the pane already does. Only offered where there is
              a reader to drop. --%>
        <button
          :if={@running? and @expanded?}
          type="button"
          id={"session-dock-detach-#{@session.id}"}
          role="menuitem"
          phx-click="detach"
          phx-value-id={@session.id}
          class={menu_item_class()}
        >
          <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4 shrink-0" />
          Detach (leave it running)
        </button>

        <button
          :if={@running?}
          type="button"
          id={"session-dock-kill-#{@session.id}"}
          role="menuitem"
          phx-click="confirm_kill"
          phx-value-id={@session.id}
          class={[menu_item_class(), "text-[var(--text-danger,#e5484d)]"]}
        >
          <.icon name="hero-power-micro" class="size-4 shrink-0" /> Kill…
        </button>
      </div>
    </div>
    """
  end

  defp menu_item_class do
    [
      "flex w-full items-center gap-2 px-2.5 py-1.5 cursor-pointer",
      "bg-transparent border-0 text-left text-[11.5px] text-[var(--text-secondary)]",
      "hover:bg-[var(--surface-chrome)] hover:text-[var(--text-primary)]"
    ]
  end
end
