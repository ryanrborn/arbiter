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

    socket =
      if expanded_id, do: expand_window(socket, expanded_id), else: collapse_window(socket)

    {:noreply, socket |> assign(:open_ids, open_ids) |> persist()}
  end

  def handle_event("toggle_roster", _params, socket) do
    # Re-read on the way open: a session launched from `/sessions` since this
    # dock mounted has no lifecycle broadcast of its own to announce itself.
    socket =
      if socket.assigns.roster_open?, do: socket, else: load_sessions(socket)

    {:noreply, assign(socket, :roster_open?, not socket.assigns.roster_open?)}
  end

  def handle_event("open", %{"id" => id}, socket) do
    socket = load_sessions(socket)

    if Enum.any?(socket.assigns.sessions, &(&1.id == id)) do
      open_ids = Enum.take(Enum.uniq(socket.assigns.open_ids ++ [id]), @max_open)

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
      {:noreply, socket}
    end
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
     |> push_event("session-dock:forget", %{id: id})
     |> persist()}
  end

  @impl true
  def handle_info({:session_ended, _session_id}, socket) do
    {:noreply, load_sessions(socket)}
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

  # Expanding is what mounts a terminal, so it is also what re-arms the watch
  # for one that never connects.
  defp expand_window(socket, id) do
    if connected?(socket), do: Process.send_after(self(), {:terminal_stall_check, id}, @stall_ms)

    socket
    |> assign(:expanded_id, id)
    |> assign(:terminal_live?, false)
    |> assign(:terminal_stalled?, false)
  end

  defp collapse_window(socket) do
    socket
    |> assign(:expanded_id, nil)
    |> assign(:terminal_live?, false)
    |> assign(:terminal_stalled?, false)
  end

  # Whether there is anything to attach to, re-decided on every render, so a
  # session that ends under an open window swaps to the placeholder live.
  defp attachable?(session, exited) do
    session.status == :running and not MapSet.member?(exited, session.id)
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
      <.roster
        open?={@roster_open?}
        sessions={@sessions}
        open_ids={@open_ids}
        running_count={@running_count}
      />

      <.window
        :for={session <- @open_sessions}
        session={session}
        expanded?={@expanded_id == session.id}
        attachable?={attachable?(session, @exited)}
        loopback?={@loopback?}
        stalled?={@terminal_stalled? and @expanded_id == session.id}
      />
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".SessionTerminal">
      import { createSessionTerminal } from "@/js/session_terminal.mjs"
      import { forgetResume, rememberResume, resumeFrom } from "@/js/session_dock.mjs"

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
          this.state = "connecting"

          this.terminal = createSessionTerminal(this.el, {
            sessionId: this.sessionId,
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
            onMeta: (meta) => this.setMeta(meta),
            onUsage: (payload) => this.setUsage(payload),
            onExit: (payload) => {
              this.state = "ended"
              this.setState("ended")
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

          this.terminal.focus()
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

        setMeta(meta) {
          if (!this.statusEl || !meta) return
          const slot = this.statusEl.querySelector('[data-role="meta"]')
          if (!slot) return
          if (meta.error) {
            slot.textContent = meta.error
            return
          }
          const clients = meta.attached_clients
          slot.textContent =
            `${meta.cols}x${meta.rows}` + (clients > 1 ? ` · ${clients} clients` : "")
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

  defp roster(assigns) do
    ~H"""
    <div class="pointer-events-auto flex flex-col justify-end shrink basis-[268px] min-w-[8.5rem] max-w-[268px]">
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

      <button
        type="button"
        id="session-dock-roster-toggle"
        phx-click="toggle_roster"
        aria-expanded={to_string(@open?)}
        aria-controls="session-dock-roster-panel"
        class={[
          "flex items-center gap-2 px-3 h-[var(--session-dock-strip-height)] w-full cursor-pointer",
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
    </div>
    """
  end

  attr :session, :any, required: true
  attr :expanded?, :boolean, required: true
  attr :attachable?, :boolean, required: true
  attr :loopback?, :boolean, required: true
  attr :stalled?, :boolean, required: true

  defp window(assigns) do
    assigns = assign(assigns, :terminal?, assigns.expanded? and assigns.attachable?)

    ~H"""
    <div
      id={"session-dock-window-#{@session.id}"}
      data-expanded={to_string(@expanded?)}
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
      <div
        :if={@expanded?}
        id={"session-dock-frame-#{@session.id}"}
        role="region"
        aria-label={"Session #{DisplayName.resolve(@session)}"}
        class={[
          "flex flex-col h-[min(52vh,380px)] overflow-hidden",
          "border border-b-0 border-solid border-[var(--border-default)]",
          "rounded-t-[var(--radius-panel)] bg-[var(--surface-panel)] shadow-lg"
        ]}
      >
        <%!-- The status strip is chrome, pinned outside the xterm element so
              it can never fight the fit for rows (§6.3). Its contents are
              hook-owned — so LiveView is told to keep out of them, and so it
              is only rendered when there is a hook to own it. --%>
        <div
          :if={@terminal? and @loopback?}
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
                become a LiveView diff. --%>
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

        <%!-- Not inside the status strip: that is `phx-update="ignore"` and
              hook-owned, and this is precisely the case where there may be no
              hook to own it. --%>
        <div
          :if={@stalled? and @terminal? and @loopback?}
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
          :if={@terminal? and @loopback?}
          id={"session-dock-scroller-#{@session.id}"}
          class="flex grow min-h-0 overflow-x-auto bg-[var(--arb-term-bg,#16181d)]"
        >
          <div
            id={"session-dock-terminal-#{@session.id}"}
            phx-hook=".SessionTerminal"
            phx-update="ignore"
            data-arb-terminal
            data-session-id={@session.id}
            class="grow min-w-[640px] p-1.5"
          >
          </div>
        </div>

        <%!-- §10.4: `ArbiterWeb.SessionSocket` trusts a loopback peer and the
              browser sends no token, so a `/session` connect from here would
              just fail silently. Say so up front instead of mounting a
              terminal that never attaches (bd-2zskbb). --%>
        <div
          :if={@attachable? and not @loopback?}
          id={"session-dock-remote-#{@session.id}"}
          class="grow min-h-0 flex flex-col items-center justify-center gap-1.5 px-4 text-center text-[11px] text-[var(--text-body)] font-[family-name:var(--font-mono)]"
        >
          <.icon name="hero-lock-closed" class="size-5 text-[var(--text-label)]" />
          <p>This session's terminal is loopback-only by design.</p>
          <p class="text-[var(--text-label)]">
            Reaching it from another device is Remote Control's job.
          </p>
        </div>

        <div
          :if={not @attachable?}
          id={"session-dock-inactive-#{@session.id}"}
          class="grow min-h-0 flex items-center justify-center px-4 text-center text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
        >
          Nothing to attach to — this session is no longer running.
        </div>
      </div>

      <div class={[
        "flex items-center gap-1.5 pl-3 pr-1 h-[var(--session-dock-strip-height)]",
        "border border-b-0 border-solid border-[var(--border-default)]",
        "bg-[var(--surface-chrome)]",
        not @expanded? && "rounded-t-[var(--radius-panel)]"
      ]}>
        <span
          class={[
            "size-1.5 rounded-full shrink-0",
            if(@session.status == :running,
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
          title={DisplayName.resolve(@session)}
          class="grow min-w-0 text-left text-[12px] font-medium text-[var(--text-title)] truncate cursor-pointer bg-transparent border-0"
        >
          {DisplayName.resolve(@session)}
        </button>

        <button
          type="button"
          id={"session-dock-dismiss-#{@session.id}"}
          phx-click="dismiss"
          phx-value-id={@session.id}
          aria-label={"Dismiss #{DisplayName.resolve(@session)}"}
          class="shrink-0 flex items-center justify-center size-[22px] rounded-[var(--radius-field)] cursor-pointer bg-transparent border-0 text-[var(--text-label)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-card)]"
        >
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </div>
    </div>
    """
  end
end
