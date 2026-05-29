defmodule ArbiterWeb.PolecatDetailLive do
  @moduledoc """
  Per-polecat detail view at `/polecats/:bead_id`. The richest single
  view of a polecat: snapshot, captured Claude stdout (terminal-style
  with auto-scroll), the paired workflow Machine's step progress, the
  bead's workspace context, and a Stop action.

  Subscribes to:
    * `"polecats"`          — lifecycle events (started / stopped).
    * `"polecat:<bead-id>"`  — per-line stdout events.
    * `"messages:<ws_id>"`   — `{:new_message, _}` so the mailbox panel
                               updates live when direction/flags arrive.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat
  alias Arbiter.Polecat.Warden
  alias Arbiter.Polecats.Run
  alias Arbiter.Vernacular
  alias Arbiter.Workflows.MachineState
  require Ash.Query
  require Logger

  @polecats_topic "polecats"
  # Live tail buffer cap. Keeps memory bounded on chatty children — older
  # lines roll off the head of the assign as new ones arrive. The polecat
  # itself caps at a higher number (Arbiter.Polecat.ClaudeSession.line_cap/0)
  # so a full reload after a refresh still shows reasonable history.
  @output_cap 200

  @impl true
  def mount(%{"bead_id" => bead_id}, _session, socket) do
    socket =
      socket
      |> assign(:bead_id, bead_id)
      |> assign(:live, connected?(socket))
      |> assign(:flash_message, nil)
      |> assign(:compose_body, "")
      |> assign(:worker_label, Vernacular.label(:worker))
      |> assign(:issue_label, Vernacular.label(:issue))
      |> assign(:rig_label, Vernacular.label(:rig))
      |> assign(:workspace_label, Vernacular.label(:workspace))
      |> refresh_all()
      |> seed_output_lines()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @polecats_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, output_topic(bead_id))

      case workspace_id(socket) do
        ws when is_binary(ws) -> Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(ws))
        _ -> :ok
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_info({:polecat_lifecycle, _event, _snap}, socket) do
    {:noreply, refresh_all(socket)}
  end

  def handle_info({:polecat_output, _bead_id, line}, socket) do
    {:noreply, append_output_line(socket, line)}
  end

  def handle_info({:new_message, _message}, socket) do
    {:noreply, refresh_mailbox(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("stop", _params, socket) do
    case Polecat.stop(socket.assigns.bead_id, :normal) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Stopped #{Vernacular.label(:worker)} for #{Vernacular.label(:issue)} #{socket.assigns.bead_id}."
         )
         |> push_navigate(to: ~p"/")}

      {:error, :not_found} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "#{String.capitalize(Vernacular.label(:worker))} not registered (already gone?)."
         )}
    end
  end

  def handle_event("compose_change", %{"body" => body}, socket) do
    {:noreply, assign(socket, :compose_body, body)}
  end

  def handle_event("send_direction", %{"body" => body}, socket) do
    bead_id = socket.assigns.bead_id

    case {String.trim(body || ""), workspace_id(socket)} do
      {"", _} ->
        {:noreply, put_flash(socket, :error, "Direction body can't be empty.")}

      {_text, nil} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No #{Vernacular.label(:workspace)} known for this #{Vernacular.label(:issue)}; can't address a direction."
         )}

      {text, ws_id} ->
        case Message.send_mail(%{
               kind: :direction,
               from_ref: "admiral",
               to_ref: bead_id,
               workspace_id: ws_id,
               body: text
             }) do
          {:ok, _msg} ->
            {:noreply,
             socket
             |> assign(:compose_body, "")
             |> put_flash(:info, "Direction sent to #{bead_id}.")
             |> refresh_mailbox()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to send direction.")}
        end
    end
  end

  def handle_event("mark_read", %{"id" => id}, socket) do
    _ = Message.mark_read(id)
    {:noreply, refresh_mailbox(socket)}
  end

  # ---- data ----

  defp refresh_all(socket) do
    socket
    |> refresh_snapshot()
    |> refresh_bead()
    |> refresh_workspace()
    |> refresh_machine_state()
    |> refresh_mailbox()
    |> refresh_latest_run()
  end

  # Most-recent Run row for this bead, if any. Used to surface a link from
  # the live polecat view to the historical post-mortem of a previous run on
  # the same bead.
  defp refresh_latest_run(socket) do
    run =
      try do
        Run
        |> Ash.Query.filter(bead_id == ^socket.assigns.bead_id)
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!()
        |> List.first()
      rescue
        _ -> nil
      end

    assign(socket, :latest_run, run)
  end

  # Unread mailbox-family messages (mailbox / direction / flag) addressed to
  # this bead. Pure read — the operator marks them read explicitly.
  defp refresh_mailbox(socket) do
    mailbox =
      try do
        Message.inbox(socket.assigns.bead_id)
      rescue
        _ -> []
      end

    assign(socket, :mailbox, mailbox)
  end

  # The bead's workspace, needed to scope/address messages. nil when the bead
  # row is gone (polecat outlived its Issue, or a fresh ad-hoc run).
  defp workspace_id(%{assigns: %{bead: %Issue{workspace_id: ws}}}) when is_binary(ws), do: ws
  defp workspace_id(_socket), do: nil

  defp refresh_snapshot(socket) do
    snap =
      case Polecat.whereis(socket.assigns.bead_id) do
        nil ->
          nil

        pid ->
          case safe_state(pid) do
            %{} = s -> Map.put(s, :pid, pid)
            _ -> nil
          end
      end

    assign(socket, :snapshot, snap)
  end

  defp refresh_bead(socket) do
    case Ash.get(Issue, socket.assigns.bead_id) do
      {:ok, bead} -> assign(socket, :bead, bead)
      _ -> assign(socket, :bead, nil)
    end
  end

  defp refresh_workspace(%{assigns: %{bead: %Issue{workspace_id: ws_id}}} = socket)
       when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> assign(socket, :workspace, ws)
      _ -> assign(socket, :workspace, nil)
    end
  end

  defp refresh_workspace(socket), do: assign(socket, :workspace, nil)

  defp refresh_machine_state(socket) do
    ms =
      try do
        MachineState
        |> Ash.Query.filter(bead_id == ^socket.assigns.bead_id)
        |> Ash.Query.sort(updated_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!()
        |> List.first()
      rescue
        _ -> nil
      end

    workflow_steps = workflow_steps_for(ms)

    socket
    |> assign(:machine_state, ms)
    |> assign(:workflow_steps, workflow_steps)
  end

  defp workflow_steps_for(nil), do: []

  defp workflow_steps_for(%MachineState{workflow_module: name}) when is_binary(name) do
    try do
      mod = Module.safe_concat([name])

      if function_exported?(mod, :steps, 0) do
        Enum.map(mod.steps(), &Atom.to_string/1)
      else
        []
      end
    rescue
      _ -> []
    end
  end

  defp safe_state(pid) do
    Polecat.state(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp output_topic(bead_id), do: "polecat:" <> bead_id

  # Seed the live output buffer from the polecat's snapshot. Called on mount
  # (and whenever we deliberately want to resync from the source of truth);
  # routine `{:polecat_output, _, line}` events append to this buffer rather
  # than re-reading the snapshot, so the page updates with no GenServer hop.
  defp seed_output_lines(socket) do
    lines =
      case socket.assigns[:snapshot] do
        %{meta: meta} when is_map(meta) -> Map.get(meta, :output_lines, []) || []
        _ -> []
      end
      |> Enum.take(-@output_cap)

    assign(socket, :output_lines, lines)
  end

  defp append_output_line(socket, line) do
    lines =
      (socket.assigns[:output_lines] || [])
      |> Kernel.++([line])
      |> Enum.take(-@output_cap)

    assign(socket, :output_lines, lines)
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="p-6 max-w-7xl mx-auto">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold">
            {String.capitalize(@worker_label)} <code>{@bead_id}</code>
          </h1>
          <span class={[
            "badge badge-sm",
            if(@live, do: "badge-success", else: "badge-warning")
          ]}>
            <%= if @live do %>
              ● live
            <% else %>
              ⚠ stale (refresh)
            <% end %>
          </span>
        </div>

        <%= if @snapshot do %>
          <section class="card bg-base-200 p-4 mb-4">
            <div class="flex justify-between items-start">
              <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                <dt class="font-semibold">Status:</dt>
                <dd>
                  <span class={["badge", status_class(@snapshot.status)]}>
                    {status_label(@snapshot.status)}
                  </span>
                </dd>
                <dt class="font-semibold">Current step:</dt>
                <dd>{@snapshot.current_step}</dd>
                <dt class="font-semibold">{String.capitalize(@rig_label)}:</dt>
                <dd>{@snapshot.rig}</dd>
                <dt class="font-semibold">{String.capitalize(@workspace_label)}:</dt>
                <dd>
                  <%= if @workspace do %>
                    {@workspace.name}
                    <span class="text-base-content/60">
                      (<code>{@workspace.prefix}</code>)
                    </span>
                  <% else %>
                    <span class="text-base-content/60">(none)</span>
                  <% end %>
                </dd>
                <dt class="font-semibold">Started:</dt>
                <dd>{@snapshot.started_at}</dd>
                <%= if exit_status = Map.get(@snapshot.meta || %{}, :exit_status) do %>
                  <dt class="font-semibold">Exit status:</dt>
                  <dd>{exit_status}</dd>
                <% end %>
                <%= if result = Map.get(@snapshot.meta || %{}, :result) do %>
                  <dt class="font-semibold">Result:</dt>
                  <dd>{inspect(result)}</dd>
                <% end %>
                <%= if reason = Map.get(@snapshot.meta || %{}, :failure_reason) do %>
                  <dt class="font-semibold">Failure:</dt>
                  <dd class="text-error">{inspect(reason)}</dd>
                <% end %>
              </dl>

              <div class="flex flex-col gap-2">
                <.link navigate={~p"/beads/#{@bead_id}"} class="btn btn-sm btn-ghost">
                  ↗ Bead detail
                </.link>
                <%= if @latest_run do %>
                  <.link
                    navigate={~p"/polecats/history/#{@latest_run.id}"}
                    class="btn btn-sm btn-ghost"
                  >
                    ↗ Run history
                  </.link>
                <% end %>
                <%= if @snapshot.status in [:idle, :running, :awaiting, :awaiting_review] do %>
                  <button
                    phx-click="stop"
                    data-confirm={"Stop #{@worker_label} for #{@bead_id}? Any active Claude subprocess will be terminated."}
                    class="btn btn-sm btn-error"
                  >
                    Stop {@worker_label}
                  </button>
                <% end %>
              </div>
            </div>
          </section>

          <%= if @snapshot.mr_ref do %>
            <section class="card bg-base-200 p-4 mb-4" id="merge-review">
              <h2 class="text-lg font-semibold mb-2">Merge request</h2>
              <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                <dt class="font-semibold">MR:</dt>
                <dd>
                  <%= if @snapshot.merger_url do %>
                    <a
                      href={@snapshot.merger_url}
                      target="_blank"
                      rel="noopener"
                      class="link link-primary"
                    >
                      {@snapshot.mr_ref} ↗
                    </a>
                  <% else %>
                    <code>{@snapshot.mr_ref}</code>
                  <% end %>
                </dd>

                <% merger_status = Map.get(@snapshot.meta || %{}, :last_merger_status) %>
                <%= if merger_status do %>
                  <dt class="font-semibold">Approval:</dt>
                  <dd>
                    <span class={["badge badge-sm", approval_class(merger_status)]}>
                      {approval_label(merger_status)}
                    </span>
                  </dd>
                <% else %>
                  <dt class="font-semibold">Approval:</dt>
                  <dd class="text-base-content/60">awaiting first poll…</dd>
                <% end %>

                <dt class="font-semibold">Poll interval:</dt>
                <dd>{div(Warden.default_interval_ms(), 1000)}s</dd>

                <dt class="font-semibold">Last checked:</dt>
                <dd>
                  <%= case Map.get(@snapshot.meta || %{}, :last_checked_at) do %>
                    <% %DateTime{} = ts -> %>
                      {Calendar.strftime(ts, "%Y-%m-%d %H:%M:%S UTC")}
                    <% _ -> %>
                      <span class="text-base-content/60">never</span>
                  <% end %>
                </dd>
              </dl>
            </section>
          <% end %>

          <%= if @machine_state do %>
            <section class="card bg-base-200 p-4 mb-4">
              <h2 class="text-lg font-semibold mb-2">
                Workflow: <code class="text-sm">{short_module(@machine_state.workflow_module)}</code>
              </h2>
              <div class="flex flex-wrap gap-1">
                <%= for step <- @workflow_steps do %>
                  <span class={["badge", step_class(step, @machine_state)]}>
                    {step}
                  </span>
                <% end %>
              </div>
              <p class="text-xs text-base-content/60 mt-2">
                Machine status: <strong>{@machine_state.status}</strong>
                · current step: <code>{@machine_state.current_step}</code>
              </p>
            </section>
          <% end %>

          <section class="card bg-base-200 p-4">
            <h2 class="text-lg font-semibold mb-3">
              Output ({length(@output_lines)} lines)
            </h2>
            <%= if @output_lines == [] do %>
              <p class="text-base-content/60 italic">(no output yet)</p>
            <% else %>
              <pre
                id="polecat-output"
                phx-hook="ScrollToBottom"
                class="bg-neutral text-neutral-content font-mono p-3 rounded text-xs overflow-x-auto max-h-[28rem] overflow-y-auto"
              >{Enum.join(@output_lines, "\n")}</pre>
              <script
                :type={Phoenix.LiveView.ColocatedHook}
                name=".ScrollToBottom"
              >
                export default {
                  mounted() { this.el.scrollTop = this.el.scrollHeight; },
                  updated() { this.el.scrollTop = this.el.scrollHeight; }
                }
              </script>
            <% end %>
          </section>
        <% else %>
          <p class="text-base-content/60">
            No {@worker_label} registered for {@issue_label} <code>{@bead_id}</code>. It may have
            stopped, or the Phoenix node was restarted since it ran.
          </p>
        <% end %>

        <section class="card bg-base-200 p-4 mt-4" id="mailbox">
          <h2 class="text-lg font-semibold mb-3">
            Mailbox ({length(@mailbox)} unread)
          </h2>

          <%= if @mailbox == [] do %>
            <p class="text-base-content/60 italic" id="mailbox-empty">No unread mail.</p>
          <% else %>
            <ul class="flex flex-col gap-2 mb-4" id="mailbox-list">
              <%= for m <- @mailbox do %>
                <li class="border border-base-300 rounded p-2">
                  <div class="flex items-baseline justify-between gap-2">
                    <div class="flex items-baseline gap-2">
                      <span class="badge badge-sm">{m.kind}</span>
                      <span class="text-xs text-base-content/60">
                        from <code>{m.from_ref || "?"}</code>
                      </span>
                      <%= if m.subject do %>
                        <span class="text-sm font-medium">{m.subject}</span>
                      <% end %>
                    </div>
                    <button
                      phx-click="mark_read"
                      phx-value-id={m.id}
                      class="btn btn-xs btn-ghost"
                    >
                      Mark read
                    </button>
                  </div>
                  <p class="text-sm mt-1 whitespace-pre-wrap">{m.body}</p>
                </li>
              <% end %>
            </ul>
          <% end %>

          <form phx-submit="send_direction" phx-change="compose_change" class="flex flex-col gap-2">
            <label class="text-sm font-semibold">
              Send direction to <code>{@bead_id}</code> (from admiral)
            </label>
            <textarea
              name="body"
              rows="3"
              placeholder="e.g. check the API contract before refactoring"
              class="textarea textarea-bordered w-full text-sm"
            >{@compose_body}</textarea>
            <div>
              <button type="submit" class="btn btn-sm btn-primary" disabled={is_nil(@workspace)}>
                Send direction
              </button>
            </div>
          </form>
        </section>

        <div class="mt-6">
          <.link navigate={~p"/"} class="link link-hover">← Back to dashboard</.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp status_class(:idle), do: "badge-ghost"
  defp status_class(:running), do: "badge-info"
  defp status_class(:awaiting), do: "badge-warning"
  defp status_class(:awaiting_review), do: "badge-warning"
  defp status_class(:completed), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(_), do: ""

  defp status_label(:idle), do: "Idle"
  defp status_label(:running), do: "Running"
  defp status_label(:awaiting), do: "Awaiting"
  defp status_label(:awaiting_review), do: "Awaiting review"
  defp status_label(:completed), do: "Completed"
  defp status_label(:failed), do: "Failed"

  defp status_label(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  defp status_label(other), do: to_string(other)

  # Badge color + text for the last Mergers.get/1 result the Warden recorded.
  defp approval_class(%{status: :merged}), do: "badge-success"
  defp approval_class(%{status: :closed}), do: "badge-error"
  defp approval_class(%{approved: true}), do: "badge-success"
  defp approval_class(_), do: "badge-warning"

  defp approval_label(%{status: :merged}), do: "Merged"
  defp approval_label(%{status: :closed}), do: "Closed"
  defp approval_label(%{approved: true}), do: "Approved"
  defp approval_label(%{status: :open}), do: "Open · awaiting approval"

  defp approval_label(%{status: status}) when is_atom(status),
    do: status |> Atom.to_string() |> String.capitalize()

  defp approval_label(_), do: "Pending"

  # Color a workflow step based on whether it's done, current, or upcoming.
  defp step_class(step, %MachineState{completed_steps: completed, current_step: current}) do
    cond do
      step in (completed || []) -> "badge-success"
      step == current -> "badge-info"
      true -> "badge-ghost"
    end
  end

  defp step_class(_, _), do: "badge-ghost"

  defp short_module(name) when is_binary(name) do
    case String.split(name, ".") do
      [] -> name
      parts -> Enum.take(parts, -2) |> Enum.join(".")
    end
  end

  defp short_module(_), do: ""
end
