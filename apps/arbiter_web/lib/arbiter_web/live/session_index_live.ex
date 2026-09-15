defmodule ArbiterWeb.SessionIndexLive do
  @moduledoc """
  The sessions list at `/sessions` (bd-c76fu9, phase 5 of
  `docs/browser-hosted-coordinator-sessions.md`).

  Every browser-hosted coordinator session Arbiter has ever launched, newest
  first, with the three fleet-level things an operator does to one: launch,
  open, and kill. Detach lives on the session page, because it is a *client*
  action — drop this browser's reader, leave the agent running — rather than a
  fleet one.

  ## Launch takes no options, deliberately

  Phase 11 owns the pre-launch options UI. This page launches with the
  defaults phase 3 already treats as the safe ones: mode B (seeded
  credentials, Amendment 2), cross-workspace, and `can_dispatch` **off** —
  §10.1's rule that a session cannot start workers until an operator says so.
  A button that quietly launched something with dispatch rights would be the
  wrong default to ship first.

  ## Kill is confirmed, and says what it takes with it

  `Arbiter.Sessions.kill/2` stops a real tmux server inside a real systemd
  scope; whatever the agent was mid-turn on is gone. So it is a two-step, and
  the confirmation names the session rather than asking "are you sure?".
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Sessions
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Data
  alias ArbiterWeb.CoreComponents.Domain
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Navigation

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:kill_candidate, nil)
     |> refresh()}
  end

  @impl true
  def handle_event("launch", _params, socket) do
    case Sessions.launch(launch_defaults()) do
      {:ok, session} ->
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, reason} ->
        Logger.error("SessionIndexLive: launch failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Could not launch a session: #{describe(reason)}")
         |> refresh()}
    end
  end

  def handle_event("confirm_kill", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :kill_candidate, Enum.find(socket.assigns.sessions, &(&1.id == id)))}
  end

  def handle_event("cancel_kill", _params, socket) do
    {:noreply, assign(socket, :kill_candidate, nil)}
  end

  def handle_event("kill", %{"id" => id}, socket) do
    socket =
      case Sessions.kill(id) do
        {:ok, _session} ->
          put_flash(socket, :info, "Session ended.")

        {:error, reason} ->
          Logger.error("SessionIndexLive: kill #{id} failed: #{inspect(reason)}")
          put_flash(socket, :error, "Could not end that session: #{describe(reason)}")
      end

    {:noreply, socket |> assign(:kill_candidate, nil) |> refresh()}
  end

  defp refresh(socket) do
    sessions = Sessions.list()

    socket
    |> assign(:sessions, sessions)
    |> assign(:running_count, Enum.count(sessions, &(&1.status == :running)))
  end

  # Phase 5's defaults; phase 11 replaces this with the options UI.
  defp launch_defaults do
    [auth_mode: :seeded_credentials, workspace_id: nil, can_dispatch: false]
  end

  defp describe({:provisioning_failed, reason}), do: "provisioning failed (#{inspect(reason)})"
  defp describe({:launch_failed, status, _out}), do: "the launch command exited #{status}"
  defp describe(reason), do: inspect(reason)

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
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <Domain.index_header
          icon="hero-command-line"
          title="Sessions"
          count={length(@sessions)}
          subtitle="Coordinator sessions Arbiter hosts. They live in their own systemd scope, so they survive an arbiter restart."
        >
          <:actions>
            <Core.button id="launch-session" variant="primary" phx-click="launch">
              <:icon><.icon name="hero-plus" class="size-4" /></:icon>
              Launch session
            </Core.button>
          </:actions>
        </Domain.index_header>

        <Core.panel
          title="All sessions"
          meta={"#{@running_count} running"}
          body_class="flex flex-col gap-3"
        >
          <div :if={@sessions == []} id="sessions-empty">
            <Feedback.empty_state
              icon="hero-command-line"
              detail="launching one scaffolds its own workspace, config dir and MCP token"
            >
              No coordinator sessions yet.
            </Feedback.empty_state>
          </div>

          <ul :if={@sessions != []} id="sessions-list" class="flex flex-col gap-2">
            <li
              :for={session <- @sessions}
              id={"session-#{session.id}"}
              class="flex flex-wrap items-center gap-3 px-3 py-2.5 rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--surface-card)]"
            >
              <Data.status_chip status={session.status} />

              <.link
                navigate={~p"/sessions/#{session.id}"}
                class="font-[family-name:var(--font-mono)] text-[12px] text-[var(--text-link)] no-underline hover:underline"
              >
                {short_id(session.id)}
              </.link>

              <span class="text-[12px] text-[var(--text-secondary)] truncate max-w-[26rem]">
                {session.cwd}
              </span>

              <span class="text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]">
                {session.provider} · {session.auth_mode} · {workspace_label(session)}{dispatch_label(
                  session
                )}
              </span>

              <span :if={session.end_reason} class="text-[11px] text-[var(--text-label)] italic">
                {session.end_reason}
              </span>

              <span class="ml-auto flex items-center gap-2">
                <.link navigate={~p"/sessions/#{session.id}"} class="no-underline">
                  <Core.button size="sm" variant="secondary">
                    {if session.status == :running, do: "Open", else: "View"}
                  </Core.button>
                </.link>

                <Core.button
                  :if={session.status == :running}
                  id={"kill-session-#{session.id}"}
                  size="sm"
                  variant="danger"
                  phx-click="confirm_kill"
                  phx-value-id={session.id}
                >
                  Kill
                </Core.button>
              </span>
            </li>
          </ul>
        </Core.panel>

        <Navigation.back_link />
      </div>

      <.kill_modal session={@kill_candidate} />
    </Layouts.app>
    """
  end

  @doc """
  The kill confirmation, shared with `ArbiterWeb.SessionLive`.

  Both pages can end a session and both must ask first, and a second copy of
  this markup is a second chance for one of them to stop asking.
  """
  attr :session, :any, required: true, doc: "the session to kill, or nil when closed"

  def kill_modal(assigns) do
    ~H"""
    <div :if={@session} id="kill-session-modal" class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-semibold text-lg mb-3">End this session?</h3>
        <p class="text-sm text-base-content/70 mb-3">
          <code class="text-xs">{short_id(@session.id)}</code>
          stops immediately: the tmux server is killed and its systemd scope is stopped, so
          whatever the agent is part-way through is lost. The session's transcript and
          workspace stay on disk.
        </p>
        <div class="modal-action">
          <Core.button id="cancel-kill" variant="ghost" size="sm" phx-click="cancel_kill">
            Cancel
          </Core.button>
          <Core.button
            id="confirm-kill"
            variant="danger"
            size="sm"
            phx-click="kill"
            phx-value-id={@session.id}
          >
            End it
          </Core.button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="cancel_kill"></div>
    </div>
    """
  end

  @doc "The first segment of a session UUID — enough to tell two apart on screen."
  def short_id(id) when is_binary(id), do: id |> String.split("-") |> hd()

  defp workspace_label(%{workspace_id: nil}), do: "cross-workspace"
  defp workspace_label(%{workspace_id: id}), do: id

  defp dispatch_label(%{can_dispatch: true}), do: " · can dispatch"
  defp dispatch_label(_session), do: ""
end
