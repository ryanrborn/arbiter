defmodule ArbiterWeb.SessionLive do
  @moduledoc """
  One coordinator session at `/sessions/:id`, with its terminal
  (bd-c76fu9, phase 5 of `docs/browser-hosted-coordinator-sessions.md` §6).

  ## The division of labour with the hook

  The terminal is **not** LiveView-rendered. `.SessionTerminal` owns that
  subtree (`phx-update="ignore"`) and talks to phase 4's channel directly,
  because LiveView's diffing is the wrong tool for an ANSI byte stream — every
  frame would become a diff against an element the hook is mutating anyway.
  What LiveView owns is the chrome around it: the header, the status strip's
  *container*, the actions, and the exit banner.

  §6.3 is explicit that the two must not contend for space, so the chrome is a
  fixed-height header and footer and the terminal gets the rest via a flex
  column. Nothing that updates frequently is rendered *over* the terminal: a
  HUD that reflowed on every update would fight the fit for rows.

  ## Narrow widths (§6.3)

  A terminal cannot reflow meaningfully below ~80 columns, so below that the
  pane is not shrunk — it keeps a floor width inside its own horizontal
  scroller (`#terminal-scroller`). The *page* never scrolls sideways; the
  terminal does. Mobile is a monitoring surface, and for real AFK work the
  answer is Remote Control (§8), not a bad phone terminal.

  ## Exit

  Two independent paths say the agent is gone, because they arrive at very
  different times. The channel's `exit` event is immediate and reaches the page
  through the hook (`agent_exited`); the row's own `:ended` status is whatever
  eventually reaped it, and is what the page's own Kill button produces.

  Either way the terminal is **replaced** by the "nothing to attach to"
  placeholder, live, without a reload (bd-3r2otb). It used to stay mounted so
  its scrollback could still be read, and on the live dashboard that read as a
  bug: the header said "Agent exited" above a full terminal that silently did
  nothing. Removing the element is also what closes the channel — the hook's
  `destroyed()` disposes the socket — so the page stops holding a reader open
  for a session that is over. Keeping the scrollback is not the page's job; the
  transcript is (§4.5).

  ## When the terminal never starts

  The hook reports reaching `live`, and the LiveView checks a few seconds after
  mount that it heard so. The failure this exists for has no other symptom: a
  tab that is running an asset bundle from before a deploy has no hook for
  `phx-hook=".SessionTerminal"` at all, so nothing mounts, nothing connects,
  and the hook-painted status strip sits on its server-rendered "connecting…"
  forever. That is indistinguishable from a slow server unless the page says
  so.

  Off-loopback (bd-2zskbb) is a different case decided at mount, not a stall:
  no `.SessionTerminal` hook is ever rendered there, so the stall check is
  skipped rather than firing a "Reload the page" banner that cannot help.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Sessions
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Data
  alias ArbiterWeb.Loopback
  alias ArbiterWeb.SessionIndexLive

  require Logger

  # Long enough that a slow first join is not called a failure, short enough
  # that an operator has not already started debugging the wrong thing.
  @stall_ms 8_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Sessions.get(id) do
      {:ok, session} ->
        if connected?(socket) do
          Process.send_after(self(), :terminal_stall_check, @stall_ms)
          # bd-bsdeb2 finding 4: the hook-driven `agent_exited` path only fires
          # when a `.SessionTerminal` hook is actually mounted and connected —
          # a session ended by the orphan reaper (AC 2) with no client hook
          # live (post-restart, or a stalled connect) would otherwise show
          # `running` until reload.
          Phoenix.PubSub.subscribe(Arbiter.PubSub, Sessions.lifecycle_topic())
        end

        {:ok,
         socket
         |> assign(:session, session)
         |> assign(:kill_candidate, nil)
         |> assign(:agent_exit, nil)
         |> assign(:terminal_live?, false)
         |> assign(:terminal_stalled?, false)
         |> assign(:loopback?, loopback_peer?(socket))
         |> put_terminal()}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "No such session.")
         |> push_navigate(to: ~p"/sessions")}
    end
  end

  @impl true
  def handle_event("detach", _params, socket) do
    # Best-effort: tell the hook to send an explicit `detach` before we go, so
    # the reader drops this client immediately rather than when the socket
    # notices. If the event loses the race with the navigation, the hook's
    # `destroyed()` disposes the socket anyway and the channel's `terminate/2`
    # detaches server-side. Either way the session keeps running.
    {:noreply,
     socket
     |> push_event("session:detach", %{})
     |> put_flash(:info, "Detached. The session is still running.")
     |> push_navigate(to: ~p"/sessions")}
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

  # From the hook: phase 4's `exit` channel event. Reload the row too — a
  # session that exited on its own may already have been marked ended.
  def handle_event("agent_exited", payload, socket) do
    session =
      case Sessions.get(socket.assigns.session.id) do
        {:ok, session} -> session
        {:error, :not_found} -> socket.assigns.session
      end

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:agent_exit, %{
       code: payload["code"],
       reason: payload["reason"]
     })
     |> put_terminal()}
  end

  # From the hook, the first time its stream reaches `live`. Only ever clears
  # the stall notice — a terminal that connects late is not a problem, it is
  # just late.
  def handle_event("terminal_live", _payload, socket) do
    {:noreply, socket |> assign(:terminal_live?, true) |> assign(:terminal_stalled?, false)}
  end

  @impl true
  def handle_info(:terminal_stall_check, socket) do
    # Off-loopback the LiveView socket connects fine but no `.SessionTerminal`
    # hook is ever rendered (bd-2zskbb) — there is nothing to stall, and the
    # remote notice already explains why, so this must not also fire the
    # "Reload the page" banner, which cannot help there.
    stalled? =
      socket.assigns.terminal? and socket.assigns.loopback? and not socket.assigns.terminal_live?

    {:noreply, assign(socket, :terminal_stalled?, stalled?)}
  end

  # From `Sessions.mark_ended/2` (Kill, an on-its-own exit, or the orphan
  # reaper) — repaint even when no `.SessionTerminal` hook is mounted to fire
  # `agent_exited` (bd-bsdeb2 finding 4).
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
    assign(socket, :terminal?, attachable?(socket.assigns.session, socket.assigns.agent_exit))
  end

  defp attachable?(session, agent_exit), do: session.status == :running and is_nil(agent_exit)

  # `ArbiterWeb.SessionSocket` (§10.4) trusts a loopback peer and nothing
  # else, with no token sent from the browser — so a `/session` connect from
  # off-loopback is a dead end no matter what this page does. Deciding it
  # here, before the hook ever mounts, means the operator sees why instead of
  # an inert terminal that silently never attaches (bd-2zskbb). `:peer_data`
  # is available on both the disconnected and connected mount once declared
  # in the `/live` socket's `connect_info` (`endpoint.ex`).
  defp loopback_peer?(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> Loopback.loopback?(address)
      _ -> true
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
              :if={attachable?(@session, @agent_exit)}
              id="detach-session"
              size="sm"
              variant="secondary"
              phx-click="detach"
            >
              Detach
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

        <.exit_banner session={@session} agent_exit={@agent_exit} />

        <Core.panel padded={false} body_class="flex flex-col">
          <%!-- The status strip is chrome, pinned outside the xterm element so
                it can never fight FitAddon for rows (§6.3). Its contents are
                hook-owned — so LiveView is told to keep out of them, and so it
                is only rendered when there is a hook to own it. Otherwise it
                would sit there reading "connecting…" forever above a pane that
                is never going to connect. --%>
          <div
            :if={@terminal? and @loopback?}
            id="terminal-status"
            phx-update="ignore"
            class="flex items-center gap-2 px-3 py-1.5 border-b border-[var(--border-default)] text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]"
          >
            <span data-role="state">connecting…</span>
            <%!-- Live cost HUD (§7.5, phase 7): hook-owned, same reason the
                  rest of this strip is — a value that updates every ~2s must
                  not become a LiveView diff. --%>
            <span data-role="usage" class="text-[var(--text-label)]"></span>
            <span data-role="meta" class="ml-auto text-[var(--text-label)]"></span>
          </div>

          <%!-- Not inside the status strip: that is `phx-update="ignore"` and
                hook-owned, and this is precisely the case where there may be
                no hook to own it. --%>
          <div
            :if={@terminal_stalled?}
            id="terminal-stalled"
            class="flex flex-wrap items-center gap-2 px-3 py-2 border-b border-[var(--border-default)] bg-[var(--surface-field)] text-[11px] text-[var(--text-body)]"
          >
            <.icon name="hero-exclamation-triangle" class="size-4 text-[var(--text-label)]" />
            <span>The terminal has not connected.</span>
            <%!-- A full page load on purpose: the likeliest cause is a tab
                  still running the asset bundle it loaded before the last
                  deploy, and a live navigation would not replace it. --%>
            <a
              href={~p"/sessions/#{@session.id}"}
              class="text-[var(--text-link)] no-underline hover:underline"
            >
              Reload the page
            </a>
          </div>

          <%!-- §6.3: a terminal cannot reflow below ~80 columns, so a narrow
                viewport scrolls this container rather than the page. --%>
          <div id="terminal-scroller" class="overflow-x-auto bg-[var(--arb-term-bg,#16181d)]">
            <div
              :if={@terminal? and @loopback?}
              id={"session-terminal-#{@session.id}"}
              phx-hook=".SessionTerminal"
              phx-update="ignore"
              data-session-id={@session.id}
              class="min-w-[640px] h-[min(70vh,640px)] p-2"
            >
            </div>

            <%!-- §10.4: `ArbiterWeb.SessionSocket` trusts a loopback peer and
                  sends no auth scheme for anything else, so a `/session`
                  connect from here would just fail silently — the browser
                  sends no token (`session_terminal.mjs`). Say so up front
                  instead of rendering a terminal that never attaches
                  (bd-2zskbb). --%>
            <div
              :if={@terminal? and not @loopback?}
              id="terminal-remote-notice"
              class="min-w-[640px] flex flex-col items-center gap-2 px-4 py-10 text-center text-[12px] text-[var(--text-body)] font-[family-name:var(--font-mono)]"
            >
              <.icon name="hero-lock-closed" class="size-5 text-[var(--text-label)]" />
              <p>This session's terminal is loopback-only by design.</p>
              <p
                :if={@session.auth_mode == :seeded_credentials and @session.remote_control}
                class="text-[var(--text-label)]"
              >
                Reach it from another device via Remote Control.
              </p>
              <p
                :if={@session.auth_mode == :seeded_credentials and not @session.remote_control}
                class="text-[var(--text-label)]"
              >
                Remote Control (mode B, launched with <code>--remote-control</code>) is the
                supported way to reach a session from another device — this one was not launched
                with it.
              </p>
              <p :if={@session.auth_mode != :seeded_credentials} class="text-[var(--text-label)]">
                This session runs under a workspace token (mode A), which does not support
                Remote Control. Reach it from this machine directly.
              </p>
            </div>

            <div
              :if={not @terminal?}
              id="terminal-inactive"
              class="min-w-[640px] px-4 py-10 text-center text-[12px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
            >
              Nothing to attach to — this session is no longer running.
            </div>
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

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SessionTerminal">
        import { createSessionTerminal } from "@/js/session_terminal.mjs"

        // The states the hook paints into #terminal-status. "reconnecting" is
        // the one that matters: it is what an operator sees across a
        // `systemctl --user restart arbiter` (RFC 10.1), and it has to say
        // "hold on" rather than look like a dead page.
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
            this.statusEl = document.getElementById("terminal-status")
            this.state = "connecting"

            this.terminal = createSessionTerminal(this.el, {
              sessionId: this.el.dataset.sessionId,
              onStatus: (state) => {
                this.state = state
                this.setState(state)
                // The page cannot see the channel, so it is told. Without this
                // a terminal that never starts is indistinguishable from one
                // that is merely slow, and the strip says "connecting…"
                // forever either way.
                if (state === "live") this.pushEvent("terminal_live", {})
              },
              onMeta: (meta) => this.setMeta(meta),
              onUsage: (payload) => this.setUsage(payload),
              onExit: (payload) => {
                this.state = "ended"
                this.setState("ended")
                this.pushEvent("agent_exited", payload || {})
              },
              onError: (err) => this.setMeta({ error: (err && err.code) || "error" })
            })

            // The page's Detach button is server-driven so it can redirect;
            // this is how it reaches the channel before the redirect happens.
            this.handleEvent("session:detach", () => this.terminal.detach())

            this.terminal.focus()
          },

          // A LiveView rejoin re-runs `mount/3` — `terminal_live?` is back to
          // false, the strip is re-rendered as "connecting…" and a fresh stall
          // check is armed — but it does *not* re-mount hooks. The terminal's
          // own `/session` socket is separate and usually never dropped, so
          // `onStatus` has nothing new to report and nothing re-announces the
          // state. Without this the page would tell the operator to reload a
          // terminal that is working.
          reconnected() {
            this.statusEl = document.getElementById("terminal-status")
            this.setState(this.state)
            if (this.state === "live") this.pushEvent("terminal_live", {})
          },

          destroyed() {
            if (this.terminal) this.terminal.dispose()
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

          // Each `usage` event carries the file's *cumulative* tokens and
          // latest known cost (§7.5, phase 7) — assigned, not accumulated,
          // so a tab that (re)attaches mid-session shows the right number on
          // its very next tick instead of resuming from zero or double
          // counting against a reader that restarted.
          setUsage(payload) {
            if (!this.statusEl || !payload) return
            const slot = this.statusEl.querySelector('[data-role="usage"]')
            if (!slot) return

            const tokensIn = payload.tokens_in || 0
            const tokensOut = payload.tokens_out || 0

            const tokens = `${formatTokens(tokensIn)} in / ${formatTokens(tokensOut)} out`
            const cost =
              typeof payload.cost_usd === "number" ? `$${payload.cost_usd.toFixed(2)}` : "cost unavailable"
            const marker = payload.estimated ? " (estimated)" : ""

            slot.textContent = `${tokens} · ${cost}${marker}`
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :session, :map, required: true
  attr :agent_exit, :any, required: true

  defp exit_banner(assigns) do
    ~H"""
    <div
      :if={@agent_exit || @session.status == :ended}
      id="session-exit"
      class="flex flex-wrap items-center gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-[var(--border-strong)] bg-[var(--surface-field)] text-[12px]"
    >
      <.icon name="hero-power" class="size-4 text-[var(--text-label)]" />
      <span class="font-medium text-[var(--text-body)]">Agent exited</span>

      <span :if={@agent_exit} class="font-[family-name:var(--font-mono)] text-[var(--text-label)]">
        code {@agent_exit.code}{exit_reason(@agent_exit.reason)}
      </span>

      <span
        :if={is_nil(@agent_exit) && @session.end_reason}
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

  defp exit_reason(nil), do: ""
  defp exit_reason(reason), do: " · #{reason}"
end
