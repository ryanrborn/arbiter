defmodule ArbiterWeb.SessionLive do
  @moduledoc """
  One coordinator session at `/sessions/:id` (bd-c76fu9, phase 5 of
  `docs/browser-hosted-coordinator-sessions.md` §6).

  ## The terminal is not here any more (bd-9myzv8)

  Phase 2 of the session dock moved the colocated `.SessionTerminal` hook into
  `ArbiterWeb.SessionDockLive`'s expanded window, and there is deliberately no
  second copy: two hooks would be two xterms and two `/session` sockets for
  one pane, and the whole point of the dock is that the terminal outlives the
  page you were reading when you opened it.

  So this page hands the session *to* the dock — on mount, and again from
  `#open-in-dock` if the operator dismissed the window — and keeps what is
  genuinely about the row rather than about the byte stream: the status, the
  exit banner, `keep_alive`, Kill and the metadata. `/sessions/:id`'s eventual
  fate is phase 3's call, not this one's.

  `Detach` went with the terminal. It was a *terminal client* action — "drop
  my reader, leave the session running" — and this page no longer has a
  reader; collapsing or dismissing the dock window is what does that now.

  ## Exit

  Two independent paths say the agent is gone. The row's own `:ended` status
  is whatever eventually reaped it and is what this page's Kill button
  produces; `Arbiter.Sessions.mark_ended/2` broadcasts on the lifecycle topic,
  which is what repaints the page when the agent exits on its own. The
  immediate, channel-level `exit` event now reaches the dock instead, which is
  where the channel is.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Sessions
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Data
  alias ArbiterWeb.SessionIndexLive

  require Logger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Sessions.get(id) do
      {:ok, session} ->
        if connected?(socket) do
          # The one path that says "this session is over" now that no terminal
          # hook is mounted here to report the channel's own `exit` event: a
          # session killed elsewhere, or reaped as an orphan, would otherwise
          # read `running` until a reload (bd-bsdeb2 finding 4).
          Phoenix.PubSub.subscribe(Arbiter.PubSub, Sessions.lifecycle_topic())
        end

        {:ok,
         socket
         |> assign(:session, session)
         |> assign(:kill_candidate, nil)
         |> put_terminal()
         |> hand_to_dock()}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "No such session.")
         |> push_navigate(to: ~p"/sessions")}
    end
  end

  @impl true
  def handle_event("open_in_dock", _params, socket) do
    {:noreply, hand_to_dock(socket)}
  end

  def handle_event("confirm_kill", _params, socket) do
    {:noreply, assign(socket, :kill_candidate, socket.assigns.session)}
  end

  def handle_event("cancel_kill", _params, socket) do
    {:noreply, assign(socket, :kill_candidate, nil)}
  end

  def handle_event("toggle_keep_alive", _params, socket) do
    session = socket.assigns.session

    socket =
      case Sessions.set_keep_alive(session, not session.keep_alive) do
        {:ok, updated} ->
          assign(socket, :session, updated)

        {:error, reason} ->
          Logger.error("SessionLive: set_keep_alive #{session.id} failed: #{inspect(reason)}")
          put_flash(socket, :error, "Could not update keep_alive: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event("kill", _params, socket) do
    session = socket.assigns.session

    socket =
      case Sessions.kill(session.id) do
        {:ok, ended} ->
          socket |> assign(:session, ended) |> put_flash(:info, "Session ended.")

        {:error, reason} ->
          Logger.error("SessionLive: kill #{session.id} failed: #{inspect(reason)}")
          put_flash(socket, :error, "Could not end that session: #{inspect(reason)}")
      end

    {:noreply, socket |> assign(:kill_candidate, nil) |> put_terminal()}
  end

  # From `Sessions.mark_ended/2` (Kill, an on-its-own exit, or the orphan
  # reaper). Since the terminal moved to the dock this is the page's only
  # notice that a session ended (bd-bsdeb2 finding 4).
  @impl true
  def handle_info(
        {:session_ended, session_id},
        %{assigns: %{session: %{id: session_id}}} = socket
      ) do
    session =
      case Sessions.get(session_id) do
        {:ok, session} -> session
        {:error, :not_found} -> socket.assigns.session
      end

    {:noreply, socket |> assign(:session, session) |> put_terminal()}
  end

  def handle_info({:session_ended, _other_session_id}, socket), do: {:noreply, socket}

  # `ArbiterWeb.LiveHooks` subscribes every view to the coordinator mailbox and
  # quota topics and lets their messages fall through (`:cont`), so any page
  # with a `handle_info/2` of its own has to tolerate them.
  def handle_info(message, socket) do
    Logger.debug("SessionLive: unhandled message #{inspect(message)}")
    {:noreply, socket}
  end

  # Whether there is anything to attach to is re-decided on every change, so a
  # session that ends while the page is open swaps to the placeholder without a
  # reload (bd-3r2otb).
  defp put_terminal(socket) do
    assign(socket, :terminal?, socket.assigns.session.status == :running)
  end

  # Hand the session to the dock (bd-9myzv8). `push_event/3` reaches the client
  # as a `window` `phx:` event, which is exactly how `Phoenix.LiveView`'s own
  # `handleEvent` listens — so the `SessionDock` hook picks this up even though
  # the dock is a *sibling* sticky LiveView with its own process and its own
  # assigns. It answers by pushing `open` to that process, which is the same
  # path the roster's own Open button takes.
  #
  # Nothing is pushed for a session there is nothing to attach to: an ended
  # session would open a window that could only say so.
  defp hand_to_dock(socket) do
    if socket.assigns.terminal? do
      push_event(socket, "session-dock:open", %{id: socket.assigns.session.id})
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div class="p-4 sm:p-6 max-w-7xl mx-auto flex flex-col gap-4">
        <div class="flex flex-wrap items-center gap-3">
          <.link
            navigate={~p"/sessions"}
            class="text-[12px] text-[var(--text-link)] no-underline hover:underline"
          >
            &larr; Sessions
          </.link>

          <h1 class="font-[family-name:var(--font-mono)] text-[15px] text-[var(--text-title)]">
            {SessionIndexLive.short_id(@session.id)}
          </h1>

          <Data.status_chip status={@session.status} />

          <span class="text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)] truncate max-w-[24rem]">
            {@session.cwd}
          </span>

          <span class="ml-auto flex items-center gap-2">
            <Core.button
              :if={@session.status == :running}
              id="toggle-keep-alive"
              size="sm"
              variant="secondary"
              phx-click="toggle_keep_alive"
            >
              {if @session.keep_alive, do: "Unpin keep_alive", else: "Pin keep_alive"}
            </Core.button>

            <Core.button
              :if={@session.status == :running}
              id="kill-session"
              size="sm"
              variant="danger"
              phx-click="confirm_kill"
            >
              Kill
            </Core.button>
          </span>
        </div>

        <.exit_banner session={@session} />

        <%!-- The terminal moved to the dock (bd-9myzv8). This is not a
              placeholder for one: the session's pane is live in the strip at
              the bottom of *every* page, which is the whole point — reading
              another page while talking to a session no longer costs the
              connection. Arriving here opens it there. --%>
        <Core.panel padded={false} body_class="flex flex-col">
          <div
            :if={@terminal? and @loopback?}
            id="terminal-in-dock"
            class="flex flex-wrap items-center gap-2 px-4 py-6 text-[12px] text-[var(--text-body)]"
          >
            <.icon name="hero-command-line" class="size-5 text-[var(--text-label)]" />
            <span>This session's terminal is open in the dock, at the bottom of every page.</span>

            <Core.button id="open-in-dock" size="sm" variant="secondary" phx-click="open_in_dock">
              Show it
            </Core.button>
          </div>

          <%!-- §10.4: `ArbiterWeb.SessionSocket` trusts a loopback peer and
                sends no auth scheme for anything else, so a `/session` connect
                from here would just fail silently — the browser sends no token
                (`session_terminal.mjs`). Say so up front instead of pointing
                at a dock window that can never attach (bd-2zskbb). --%>
          <div
            :if={@terminal? and not @loopback?}
            id="terminal-remote-notice"
            class="flex flex-col items-center gap-2 px-4 py-10 text-center text-[12px] text-[var(--text-body)] font-[family-name:var(--font-mono)]"
          >
            <.icon name="hero-lock-closed" class="size-5 text-[var(--text-label)]" />
            <p>This session's terminal is loopback-only by design.</p>
            <p
              :if={@session.auth_mode == :seeded_credentials and @session.remote_control}
              class="text-[var(--text-label)]"
            >
              Forward the port over SSH: <code>ssh -L 4848:127.0.0.1:4848 &lt;host&gt;</code>
              (<.link
                href="https://github.com/anthropics/arbiter/blob/main/docs/remote-access.md"
                target="_blank"
                class="underline"
              >docs</.link>),
              or use Remote Control.
            </p>
            <p
              :if={@session.auth_mode == :seeded_credentials and not @session.remote_control}
              class="text-[var(--text-label)]"
            >
              Forward the port over SSH: <code>ssh -L 4848:127.0.0.1:4848 &lt;host&gt;</code>
              (<.link
                href="https://github.com/anthropics/arbiter/blob/main/docs/remote-access.md"
                target="_blank"
                class="underline"
              >docs</.link>).
              Remote Control (mode B, launched with <code>--remote-control</code>) is not enabled on this session.
            </p>
            <p :if={@session.auth_mode != :seeded_credentials} class="text-[var(--text-label)]">
              This session runs under a workspace token (mode A). Forward the port over SSH:
              <code>ssh -L 4848:127.0.0.1:4848 &lt;host&gt;</code>
              (<.link
                href="https://github.com/anthropics/arbiter/blob/main/docs/remote-access.md"
                target="_blank"
                class="underline"
              >docs</.link>).
            </p>
          </div>

          <div
            :if={not @terminal?}
            id="terminal-inactive"
            class="px-4 py-10 text-center text-[12px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
          >
            Nothing to attach to — this session is no longer running.
          </div>
        </Core.panel>

        <dl class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-1 text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
          <div class="flex gap-2">
            <dt class="min-w-[7rem]">scope unit</dt>
            <dd class="truncate">{@session.scope_unit}</dd>
          </div>
          <div class="flex gap-2">
            <dt class="min-w-[7rem]">config dir</dt>
            <dd class="truncate">{@session.config_dir}</dd>
          </div>
          <div class="flex gap-2">
            <dt class="min-w-[7rem]">auth mode</dt>
            <dd>{@session.auth_mode}</dd>
          </div>
          <div class="flex gap-2">
            <dt class="min-w-[7rem]">can dispatch</dt>
            <dd>{@session.can_dispatch}</dd>
          </div>
          <div class="flex gap-2">
            <dt class="min-w-[7rem]">keep_alive</dt>
            <dd id="keep-alive-value">{@session.keep_alive}</dd>
          </div>
        </dl>
      </div>

      <SessionIndexLive.kill_modal session={@kill_candidate} />
    </Layouts.app>
    """
  end

  attr :session, :map, required: true

  defp exit_banner(assigns) do
    ~H"""
    <div
      :if={@session.status == :ended}
      id="session-exit"
      class="flex flex-wrap items-center gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-[var(--border-strong)] bg-[var(--surface-field)] text-[12px]"
    >
      <.icon name="hero-power" class="size-4 text-[var(--text-label)]" />
      <span class="font-medium text-[var(--text-body)]">Agent exited</span>

      <span
        :if={@session.end_reason}
        class="font-[family-name:var(--font-mono)] text-[var(--text-label)]"
      >
        {@session.end_reason}
      </span>

      <.link
        navigate={~p"/sessions"}
        class="ml-auto text-[var(--text-link)] no-underline hover:underline"
      >
        Back to sessions
      </.link>
    </div>
    """
  end
end
