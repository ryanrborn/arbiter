defmodule ArbiterWeb.SessionDockLive do
  @moduledoc """
  The session dock: a strip pinned to the bottom of every dashboard page, with
  a roster that expands into the session list and a collapsed title bar per
  opened session (bd-dlc136, phase 1 of the session dock epic).

  **Phase 1 is the shell only.** An expanded window is a correctly-sized empty
  frame; phase 2 (bd-14b11h) puts the terminal in it. Nothing here touches
  `ArbiterWeb.SessionLive` or its colocated terminal hook, and opening a
  session in the dock does not open a `/session` socket.

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

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Sessions.lifecycle_topic())
    end

    {:ok,
     socket
     |> assign(:roster_open?, false)
     |> assign(:open_ids, [])
     |> assign(:expanded_id, nil)
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

    {:noreply,
     socket
     |> assign(:open_ids, open_ids)
     |> assign(:expanded_id, expanded_id)
     |> persist()}
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
       |> assign(:expanded_id, id)
       |> assign(:roster_open?, false)
       |> persist()}
    else
      {:noreply, assign(socket, :roster_open?, false)}
    end
  end

  # One expanded at a time is the whole invariant: expanding is an assignment,
  # not a toggle-on, so whichever window was expanded collapses by construction.
  def handle_event("expand", %{"id" => id}, socket) do
    if id in socket.assigns.open_ids do
      {:noreply, socket |> assign(:expanded_id, id) |> persist()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("collapse", %{"id" => id}, socket) do
    if socket.assigns.expanded_id == id do
      {:noreply, socket |> assign(:expanded_id, nil) |> persist()}
    else
      {:noreply, socket}
    end
  end

  # Dismiss is a *view* action. It closes the window and forgets it; it never
  # kills or detaches the session, which stays exactly as it was and is still
  # in the roster to be opened again.
  def handle_event("dismiss", %{"id" => id}, socket) do
    open_ids = List.delete(socket.assigns.open_ids, id)
    expanded_id = if socket.assigns.expanded_id == id, do: nil, else: socket.assigns.expanded_id

    {:noreply,
     socket
     |> assign(:open_ids, open_ids)
     |> assign(:expanded_id, expanded_id)
     |> persist()}
  end

  @impl true
  def handle_info({:session_ended, _session_id}, socket) do
    {:noreply, load_sessions(socket)}
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
      />
    </div>
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

  defp window(assigns) do
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
          if(@expanded?,
            do: "basis-[28rem] max-w-[28rem] min-w-[13rem]",
            else: "basis-[11rem] max-w-[11rem] min-w-[5rem]"
          )
        ]
      }
    >
      <%!--
      Phase 1's deliverable: a correctly-sized, empty frame. Phase 2 (bd-14b11h)
      mounts the terminal inside it — deliberately not here, so the hook
      lifecycle and the geometry are somebody else's one problem. When it
      does, the scrollback container wants `data-dock-scroll` on it, the same
      as the roster panel: a sticky view is re-parented on every live
      navigation, and that is what resets a scroll offset.
      --%>
      <div
        :if={@expanded?}
        id={"session-dock-frame-#{@session.id}"}
        role="region"
        aria-label={"Session #{DisplayName.resolve(@session)}"}
        class={[
          "h-[min(52vh,380px)] overflow-hidden",
          "border border-b-0 border-solid border-[var(--border-default)]",
          "rounded-t-[var(--radius-panel)] bg-[var(--surface-panel)] shadow-lg"
        ]}
      >
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
