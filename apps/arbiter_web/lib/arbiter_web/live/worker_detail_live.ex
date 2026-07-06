defmodule ArbiterWeb.WorkerDetailLive do
  @moduledoc """
  Per-worker detail view at `/workers/:task_id`. The richest single
  view of a worker: snapshot, captured Claude stdout (terminal-style
  with auto-scroll), the paired workflow Machine's step progress, the
  task's workspace context, and a Stop action.

  Subscribes to:
    * `"workers"`          — lifecycle events (started / stopped).
    * `"worker:<task-id>"`  — per-line stdout events.
    * `"messages:<ws_id>"`   — `{:new_message, _}` so the mailbox panel
                               updates live when direction/flags arrive.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Workers.Run
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Workflows.MachineState
  require Ash.Query
  require Logger

  @workers_topic "workers"
  # Live tail buffer cap. Keeps memory bounded on chatty children — older
  # lines roll off the head of the assign as new ones arrive. The worker
  # itself caps at a higher number (Arbiter.Worker.ClaudeSession.line_cap/0)
  # so a full reload after a refresh still shows reasonable history.
  @output_cap 200

  @impl true
  def mount(%{"task_id" => task_id}, _session, socket) do
    socket =
      socket
      |> assign(:task_id, task_id)
      |> assign(:live, connected?(socket))
      |> assign(:now, DateTime.utc_now())
      |> assign(:flash_message, nil)
      |> assign(:compose_body, "")
      |> assign(:worker_label, "worker")
      |> assign(:issue_label, "issue")
      |> assign(:repo_label, "repo")
      |> assign(:workspace_label, "workspace")
      |> assign(:pr_label, "pull request")
      |> refresh_all()
      |> seed_output_lines()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, output_topic(task_id))
      # Drives the live elapsed-time counter in the header. Only reassigns
      # :now — no DB reads or GenServer hops in the tick handler.
      :timer.send_interval(1000, self(), :tick)

      case workspace_id(socket) do
        ws when is_binary(ws) -> Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(ws))
        _ -> :ok
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_info({:worker_lifecycle, _event, _snap}, socket) do
    {:noreply, refresh_all(socket)}
  end

  def handle_info({:worker_output, _task_id, line}, socket) do
    {:noreply, append_output_line(socket, line)}
  end

  def handle_info({:new_message, _message}, socket) do
    {:noreply, refresh_mailbox(socket)}
  end

  def handle_info({:message_read, _message}, socket) do
    {:noreply, refresh_mailbox(socket)}
  end

  def handle_info({:mailbox_cleared, _workspace_id}, socket) do
    {:noreply, refresh_mailbox(socket)}
  end

  # Lightweight 1s tick: only advances the clock so the header's elapsed-time
  # counter stays live. No data reads here.
  def handle_info(:tick, socket) do
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("stop", _params, socket) do
    case Worker.stop(socket.assigns.task_id, :normal) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Stopped worker for issue #{socket.assigns.task_id}."
         )
         |> push_navigate(to: ~p"/")}

      {:error, :not_found} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Worker not registered (already gone?)."
         )}
    end
  end

  def handle_event("compose_change", %{"body" => body}, socket) do
    {:noreply, assign(socket, :compose_body, body)}
  end

  def handle_event("send_direction", %{"body" => body}, socket) do
    task_id = socket.assigns.task_id

    case {String.trim(body || ""), workspace_id(socket)} do
      {"", _} ->
        {:noreply, put_flash(socket, :error, "Direction body can't be empty.")}

      {_text, nil} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No workspace known for this issue; can't address a direction."
         )}

      {text, ws_id} ->
        case Message.send_mail(%{
               kind: :direction,
               from_ref: "admiral",
               to_ref: task_id,
               workspace_id: ws_id,
               body: text
             }) do
          {:ok, _msg} ->
            {:noreply,
             socket
             |> assign(:compose_body, "")
             |> put_flash(:info, "Direction sent to #{task_id}.")
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
    |> refresh_task()
    |> refresh_workspace()
    |> refresh_machine_state()
    |> refresh_mailbox()
    |> refresh_latest_run()
    |> refresh_usage()
  end

  # Most-recent Run row for this task, if any. Used to surface a link from
  # the live worker view to the historical post-mortem of a previous run on
  # the same task.
  defp refresh_latest_run(socket) do
    run =
      try do
        Run
        |> Ash.Query.filter(task_id == ^socket.assigns.task_id)
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!()
        |> List.first()
      rescue
        _ -> nil
      end

    assign(socket, :latest_run, run)
  end

  # Latest usage event(s) for this task — used to surface cost/tokens on the
  # detail page. Queries by task_id, ordered newest-first, capped at 5 rows
  # (one per recent session: work + optional review). Best-effort — nil on error.
  defp refresh_usage(socket) do
    events =
      try do
        UsageEvent
        |> Ash.Query.filter(task_id == ^socket.assigns.task_id)
        |> Ash.Query.sort(occurred_at: :desc)
        |> Ash.Query.limit(5)
        |> Ash.read!()
      rescue
        _ -> []
      end

    assign(socket, :usage_events, events)
  end

  # Unread mailbox-family messages (mailbox / direction / flag) addressed to
  # this task. Pure read — the operator marks them read explicitly.
  defp refresh_mailbox(socket) do
    mailbox =
      try do
        Message.inbox(socket.assigns.task_id)
      rescue
        _ -> []
      end

    assign(socket, :mailbox, mailbox)
  end

  # The task's workspace, needed to scope/address messages. nil when the task
  # row is gone (worker outlived its Issue, or a fresh ad-hoc run).
  defp workspace_id(%{assigns: %{task: %Issue{workspace_id: ws}}}) when is_binary(ws), do: ws
  defp workspace_id(_socket), do: nil

  defp refresh_snapshot(socket) do
    snap =
      case Worker.whereis(socket.assigns.task_id) do
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

  defp refresh_task(socket) do
    case Ash.get(Issue, socket.assigns.task_id) do
      {:ok, task} -> assign(socket, :task, task)
      _ -> assign(socket, :task, nil)
    end
  end

  defp refresh_workspace(%{assigns: %{task: %Issue{workspace_id: ws_id}}} = socket)
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
        |> Ash.Query.filter(task_id == ^socket.assigns.task_id)
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
    Worker.state(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp output_topic(task_id), do: "worker:" <> task_id

  # Seed the live output buffer from the worker's snapshot. Called on mount
  # (and whenever we deliberately want to resync from the source of truth);
  # routine `{:worker_output, _, line}` events append to this buffer rather
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
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <%!-- ── Header ───────────────────────────────────────────────── --%>
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div class="min-w-0">
            <div class="flex items-center gap-2 text-xs text-base-content/50">
              <.link navigate={~p"/"} class="link link-hover">Dashboard</.link>
              <.icon name="hero-chevron-right" class="size-3" />
              <span>{String.capitalize(@worker_label)} detail</span>
            </div>
            <h1 class="text-2xl font-bold tracking-tight flex items-center gap-2 mt-0.5">
              {String.capitalize(@worker_label)}
              <code class="text-base font-mono text-base-content/80">{@task_id}</code>
            </h1>
          </div>

          <div class="flex items-center gap-2">
            <span
              :if={@snapshot}
              class="badge badge-lg gap-1.5 font-mono tabular-nums bg-base-300 border-base-300"
              title="Elapsed since started"
            >
              <.icon name="hero-clock" class="size-4 text-base-content/60" />
              {humanize_seconds(runtime_seconds(@snapshot.started_at, @now))}
            </span>
            <span
              id="live-indicator"
              class={[
                "badge badge-sm gap-1.5 transition-colors duration-200",
                if(@live, do: "badge-success", else: "badge-warning")
              ]}
              title={
                if @live,
                  do: "WebSocket connected — output streams in real time",
                  else: "Static render — refresh the page to reconnect"
              }
            >
              <%= if @live do %>
                <span class="relative flex h-2 w-2">
                  <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-success-content opacity-75">
                  </span>
                  <span class="relative inline-flex h-2 w-2 rounded-full bg-success-content"></span>
                </span>
                live
              <% else %>
                <.icon name="hero-exclamation-triangle" class="size-3" /> stale (refresh)
              <% end %>
            </span>
          </div>
        </div>

        <%= if @snapshot do %>
          <%!-- ── Step progress stepper ──────────────────────────────── --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-3">
              <div class="flex items-center justify-between gap-2">
                <h2 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
                  <.icon name="hero-flag" class="size-4" /> Lifecycle
                </h2>
                <span class={["badge badge-sm", status_class(@snapshot.status)]}>
                  {status_label(@snapshot.status)}
                </span>
              </div>

              <%= if @snapshot.status == :failed do %>
                <div class="rounded-box bg-error/10 border border-error/30 p-3 flex items-center gap-2 text-sm text-error">
                  <.icon name="hero-x-circle" class="size-5 shrink-0" />
                  <span class="font-medium">
                    {String.capitalize(@worker_label)} failed — left the happy path before completion.
                  </span>
                </div>
              <% else %>
                <ul class="steps steps-vertical sm:steps-horizontal w-full">
                  <li
                    :for={step <- worker_flow()}
                    class={["step", flow_step_class(flow_state(step, @snapshot.status))]}
                    data-content={flow_step_marker(flow_state(step, @snapshot.status))}
                  >
                    <span class="text-xs sm:text-sm">{flow_step_label(step)}</span>
                  </li>
                </ul>
              <% end %>
            </div>
          </section>

          <%!-- ── Awaiting review panel ──────────────────────────────── --%>
          <section
            :if={@snapshot.status == :awaiting}
            class="card bg-warning/10 border border-warning/40 shadow-sm"
          >
            <div class="card-body p-4 gap-3">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h2 class="text-lg font-semibold flex items-center gap-2">
                  <.icon name="hero-eye" class="size-5 text-warning" /> Awaiting your review
                </h2>
                <span class="badge badge-warning gap-1.5">
                  <.icon name="hero-clock" class="size-3.5" /> Awaiting review
                </span>
              </div>
              <p class="text-sm text-base-content/70">
                This {@worker_label} has paused and is waiting for a human decision before it can proceed.
              </p>
              <%= if ref = mr_ref(@snapshot) do %>
                <a
                  href={ref}
                  target="_blank"
                  rel="noopener"
                  class="btn btn-sm btn-warning gap-1.5 w-fit transition-all duration-200 active:scale-95"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open {@pr_label}
                  <code class="font-mono text-xs opacity-80">{ref}</code>
                </a>
              <% else %>
                <p class="text-sm text-base-content/50 italic flex items-center gap-1.5">
                  <.icon name="hero-link-slash" class="size-4" /> No {@pr_label} ref recorded yet.
                </p>
              <% end %>
            </div>
          </section>

          <%!-- ── Snapshot detail ────────────────────────────────────── --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <div class="flex flex-wrap justify-between items-start gap-4">
                <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-2 text-sm">
                  <dt class="font-medium text-base-content/60">Status:</dt>
                  <dd>
                    <span class={["badge badge-sm", status_class(@snapshot.status)]}>
                      {status_label(@snapshot.status)}
                    </span>
                  </dd>
                  <%= if claude_session?(@snapshot) do %>
                    <dt class="font-medium text-base-content/60">Activity:</dt>
                    <dd>
                      <span class="badge badge-info badge-sm gap-1.5">
                        <span
                          :if={@snapshot.status == :running}
                          class="loading loading-ring loading-xs"
                        >
                        </span>
                        {live_activity(@snapshot)}
                      </span>
                    </dd>
                  <% else %>
                    <dt class="font-medium text-base-content/60">Current step:</dt>
                    <dd>
                      <code class="badge badge-ghost badge-sm font-mono">
                        {@snapshot.current_step}
                      </code>
                    </dd>
                  <% end %>
                  <dt class="font-medium text-base-content/60">{String.capitalize(@repo_label)}:</dt>
                  <dd><code class="font-mono text-xs">{@snapshot.repo}</code></dd>
                  <dt class="font-medium text-base-content/60">
                    {String.capitalize(@workspace_label)}:
                  </dt>
                  <dd>
                    <%= if @workspace do %>
                      {@workspace.name}
                      <span class="text-base-content/50">
                        (<code class="font-mono text-xs">{@workspace.prefix}</code>)
                      </span>
                    <% else %>
                      <span class="text-base-content/50">(none)</span>
                    <% end %>
                  </dd>
                  <dt class="font-medium text-base-content/60">Started:</dt>
                  <dd class="font-mono text-xs tabular-nums">{format_ts(@snapshot.started_at)}</dd>
                  <dt class="font-medium text-base-content/60">Elapsed:</dt>
                  <dd class="font-mono text-xs tabular-nums">
                    {humanize_seconds(runtime_seconds(@snapshot.started_at, @now))}
                  </dd>
                  <%= if exit_status = Map.get(@snapshot.meta || %{}, :exit_status) do %>
                    <dt class="font-medium text-base-content/60">Exit status:</dt>
                    <dd class="font-mono text-xs">{exit_status}</dd>
                  <% end %>
                  <%= if result = Map.get(@snapshot.meta || %{}, :result) do %>
                    <dt class="font-medium text-base-content/60">Result:</dt>
                    <dd class="font-mono text-xs">{inspect(result)}</dd>
                  <% end %>
                  <%= if reason = Map.get(@snapshot.meta || %{}, :failure_reason) do %>
                    <dt class="font-medium text-base-content/60">Failure:</dt>
                    <dd class="text-error font-mono text-xs">{inspect(reason)}</dd>
                  <% end %>
                </dl>

                <div class="flex flex-col gap-2 shrink-0">
                  <.link navigate={~p"/tasks/#{@task_id}"} class="btn btn-sm btn-ghost gap-1.5">
                    <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                    {String.capitalize(@issue_label)} detail
                  </.link>
                  <%= if @latest_run do %>
                    <.link
                      navigate={~p"/workers/history/#{@latest_run.id}"}
                      class="btn btn-sm btn-ghost gap-1.5"
                    >
                      <.icon name="hero-archive-box" class="size-4" /> Run history
                    </.link>
                  <% end %>
                  <%= if @snapshot.status in [:idle, :resuming, :running, :awaiting, :awaiting_review_gate, :awaiting_review] do %>
                    <button
                      phx-click="stop"
                      data-confirm={"Stop #{@worker_label} for #{@task_id}? Any active Claude subprocess will be terminated."}
                      class="btn btn-sm btn-error gap-1.5 transition-all duration-200 active:scale-95"
                    >
                      <.icon name="hero-stop-circle" class="size-4" /> Stop {@worker_label}
                    </button>
                  <% end %>
                </div>
              </div>
            </div>
          </section>

          <%!-- ── Execution context ─────────────────────────────────── --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <h2 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
                <.icon name="hero-cpu-chip" class="size-4" /> Execution context
              </h2>
              <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-2 text-sm">
                <dt class="font-medium text-base-content/60">Provider:</dt>
                <dd>
                  <code class="badge badge-ghost badge-sm font-mono">
                    {execution_provider(@snapshot)}
                  </code>
                </dd>
                <dt class="font-medium text-base-content/60">Model:</dt>
                <dd>
                  <%= if m = execution_model(@snapshot) do %>
                    <code class="font-mono text-xs" title={m}>
                      {Arbiter.Agents.ModelDisplay.short(m)}
                    </code>
                  <% else %>
                    <span class="text-base-content/40 italic text-xs">unknown</span>
                  <% end %>
                </dd>
                <%= if thinking = execution_thinking(@snapshot) do %>
                  <dt class="font-medium text-base-content/60">Reasoning effort:</dt>
                  <dd><code class="badge badge-ghost badge-sm font-mono">{thinking}</code></dd>
                <% end %>
                <%= if tier = execution_model_tier(@snapshot) do %>
                  <dt class="font-medium text-base-content/60">Model tier:</dt>
                  <dd><code class="badge badge-ghost badge-sm font-mono">{tier}</code></dd>
                <% end %>
                <%= for event <- @usage_events, event.step == :work do %>
                  <%= if cost = event.cost_usd do %>
                    <dt class="font-medium text-base-content/60">Run cost:</dt>
                    <dd class="font-mono text-xs">${:erlang.float_to_binary(cost, decimals: 4)}</dd>
                  <% end %>
                  <%= if tokens_in = event.tokens_in do %>
                    <dt class="font-medium text-base-content/60">Tokens:</dt>
                    <dd class="font-mono text-xs">
                      {tokens_in} in / {event.tokens_out || "?"} out
                      <%= if (event.cache_read_tokens || 0) > 0 do %>
                        · {event.cache_read_tokens} cached
                      <% end %>
                    </dd>
                  <% end %>
                <% end %>
              </dl>
            </div>
          </section>

          <%!-- ── Assigned task summary ─────────────────────────────── --%>
          <%= if @task do %>
            <section class="card bg-base-200 border border-base-300 shadow-sm">
              <div class="card-body p-4 gap-3">
                <h2 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
                  <.icon name="hero-bookmark" class="size-4" />
                  {String.capitalize(@issue_label)}: {@task.title}
                </h2>
                <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1.5 text-sm">
                  <%= if @task.target_branch do %>
                    <dt class="font-medium text-base-content/60">Target branch:</dt>
                    <dd><code class="font-mono text-xs">{@task.target_branch}</code></dd>
                  <% end %>
                  <%= if @task.difficulty do %>
                    <dt class="font-medium text-base-content/60">Difficulty:</dt>
                    <dd>
                      <span class="badge badge-ghost badge-sm font-mono">
                        D{@task.difficulty}
                      </span>
                    </dd>
                  <% end %>
                  <%= if @task.priority do %>
                    <dt class="font-medium text-base-content/60">Priority:</dt>
                    <dd>
                      <span class="badge badge-ghost badge-sm font-mono">
                        P{@task.priority}
                      </span>
                    </dd>
                  <% end %>
                  <%= if @task.issue_type do %>
                    <dt class="font-medium text-base-content/60">Type:</dt>
                    <dd>
                      <span class="badge badge-ghost badge-sm">
                        {@task.issue_type}
                      </span>
                    </dd>
                  <% end %>
                  <%= if tracker_display(@task) do %>
                    <dt class="font-medium text-base-content/60">Tracker:</dt>
                    <dd class="font-mono text-xs">{tracker_display(@task)}</dd>
                  <% end %>
                </dl>
              </div>
            </section>
          <% end %>

          <%!-- ── Worker metadata ───────────────────────────────────── --%>
          <%= if meta_has_details?(@snapshot.meta) do %>
            <section class="card bg-base-200 border border-base-300 shadow-sm">
              <div class="card-body p-4 gap-3">
                <h2 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
                  <.icon name="hero-information-circle" class="size-4" /> Metadata
                </h2>
                <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1.5 text-sm">
                  <%= if role = Map.get(@snapshot.meta || %{}, :role) do %>
                    <dt class="font-medium text-base-content/60">Role:</dt>
                    <dd><span class="badge badge-ghost badge-sm">{role}</span></dd>
                  <% end %>
                  <%= if Map.get(@snapshot.meta || %{}, :review_required) do %>
                    <dt class="font-medium text-base-content/60">Review gate:</dt>
                    <dd><span class="badge badge-warning badge-sm">required</span></dd>
                  <% end %>
                  <%= if path = Map.get(@snapshot.meta || %{}, :worktree_path) do %>
                    <dt class="font-medium text-base-content/60">Worktree:</dt>
                    <dd class="font-mono text-xs break-all">{path}</dd>
                  <% end %>
                  <%= if branch = Map.get(@snapshot.meta || %{}, :branch) do %>
                    <dt class="font-medium text-base-content/60">Branch:</dt>
                    <dd><code class="font-mono text-xs">{branch}</code></dd>
                  <% end %>
                  <%= if @snapshot.step_started_at do %>
                    <dt class="font-medium text-base-content/60">Step started:</dt>
                    <dd class="font-mono text-xs tabular-nums">
                      {format_ts(@snapshot.step_started_at)}
                    </dd>
                  <% end %>
                  <%= if reason = Map.get(@snapshot.meta || %{}, :stop_reason) do %>
                    <dt class="font-medium text-base-content/60">Stop reason:</dt>
                    <dd class="text-error text-xs font-mono">
                      {Map.get(reason, :summary) || inspect(reason)}
                    </dd>
                  <% end %>
                </dl>
              </div>
            </section>
          <% end %>

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
                <dd>{div(Watchdog.default_interval_ms(), 1000)}s</dd>

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

          <%!-- ── Live activity (claude-driven) ──────────────────────── --%>
          <%!-- A claude-driven worker does the real work in a streaming --%>
          <%!-- subprocess; its Driver never ticks the workflow Machine, so --%>
          <%!-- the fixed load_context→submit steps would sit frozen. Show --%>
          <%!-- the live activity derived from the stream instead (bd-c919xj). --%>
          <section
            :if={claude_session?(@snapshot)}
            class="card bg-base-200 border border-base-300 shadow-sm"
          >
            <div class="card-body p-4 gap-2">
              <h2 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
                <.icon name="hero-bolt" class="size-4" /> Live activity
              </h2>
              <div class="flex items-center gap-2">
                <span
                  :if={@snapshot.status == :running}
                  class="loading loading-ring loading-sm text-info"
                >
                </span>
                <span class="text-base font-medium">{live_activity(@snapshot)}</span>
              </div>
              <p class="text-xs text-base-content/50">
                Driven by a live Claude session — progress streams in the output below rather than
                advancing fixed workflow steps.
              </p>
            </div>
          </section>

          <%= if @machine_state && not claude_session?(@snapshot) do %>
            <section class="card bg-base-200 border border-base-300 shadow-sm">
              <div class="card-body p-4 gap-3">
                <h2 class="text-lg font-semibold flex items-center gap-2">
                  <.icon name="hero-cog-6-tooth" class="size-5 text-base-content/70" /> Workflow:
                  <code class="text-sm font-mono">
                    {short_module(@machine_state.workflow_module)}
                  </code>
                </h2>
                <div class="flex flex-wrap gap-1.5">
                  <span
                    :for={step <- @workflow_steps}
                    class={["badge", step_class(step, @machine_state)]}
                  >
                    {step}
                  </span>
                </div>
                <p class="text-xs text-base-content/60">
                  Machine status: <strong>{@machine_state.status}</strong>
                  · current step: <code class="font-mono">{@machine_state.current_step}</code>
                </p>
              </div>
            </section>
          <% end %>

          <%!-- ── Live output terminal ───────────────────────────────── --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm overflow-hidden">
            <div class="card-body p-0 gap-0">
              <div class="flex items-center justify-between gap-2 px-4 py-2.5 border-b border-base-300">
                <h2 class="text-sm font-medium flex items-center gap-2">
                  <.icon name="hero-command-line" class="size-4 text-base-content/70" /> Output
                  <span class="badge badge-ghost badge-sm font-mono tabular-nums">
                    {length(@output_lines)} lines
                  </span>
                </h2>
                <div
                  :if={@snapshot.status == :running}
                  class="flex items-center gap-1.5 text-xs text-info"
                >
                  <span class="relative flex h-2 w-2">
                    <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-info opacity-75">
                    </span>
                    <span class="relative inline-flex h-2 w-2 rounded-full bg-info"></span>
                  </span>
                  streaming
                </div>
              </div>

              <%= if @output_lines == [] do %>
                <div class="bg-neutral text-neutral-content/50 font-mono text-xs p-6 text-center italic">
                  (no output yet)
                </div>
              <% else %>
                <div
                  id="worker-output"
                  phx-hook="ScrollToBottom"
                  class="bg-neutral text-neutral-content font-mono text-xs overflow-x-auto max-h-[28rem] overflow-y-auto"
                >
                  <div
                    :for={{line, idx} <- Enum.with_index(@output_lines, 1)}
                    class="flex hover:bg-neutral-content/5 transition-colors"
                  >
                    <span class="select-none shrink-0 w-12 text-right pr-3 py-0.5 text-neutral-content/30 tabular-nums border-r border-neutral-content/10">
                      {idx}
                    </span>
                    <code class="flex-1 whitespace-pre-wrap break-all px-3 py-0.5">{line}</code>
                  </div>
                </div>
                <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
                  export default {
                    mounted() { this.el.scrollTop = this.el.scrollHeight; },
                    updated() { this.el.scrollTop = this.el.scrollHeight; }
                  }
                </script>
              <% end %>
            </div>
          </section>
        <% else %>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-8 items-center text-center gap-2">
              <.icon name="hero-signal-slash" class="size-10 text-base-content/30" />
              <p class="text-sm text-base-content/70">
                No {@worker_label} registered for {@issue_label} <code class="font-mono">{@task_id}</code>.
              </p>
              <p class="text-xs text-base-content/50">
                It may have stopped, or the Phoenix node was restarted since it ran.
              </p>
            </div>
          </section>
        <% end %>

        <%!-- ── Mailbox + compose ──────────────────────────────────── --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm" id="mailbox">
          <div class="card-body p-4 gap-4">
            <h2 class="text-lg font-semibold flex items-center gap-2">
              <.icon name="hero-inbox-arrow-down" class="size-5 text-base-content/70" /> Mailbox
              <span class="badge badge-ghost badge-sm">{length(@mailbox)} unread</span>
            </h2>

            <%= if @mailbox == [] do %>
              <div
                id="mailbox-empty"
                class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
              >
                <.icon name="hero-inbox" class="size-8 mx-auto text-base-content/30" />
                <p class="mt-2 text-sm text-base-content/60">No unread mail.</p>
              </div>
            <% else %>
              <ul class="flex flex-col gap-2" id="mailbox-list">
                <li
                  :for={m <- @mailbox}
                  class={[
                    "rounded-box bg-base-100 border-l-4 border border-base-300 p-3",
                    kind_border_class(m.kind)
                  ]}
                >
                  <div class="flex items-baseline justify-between gap-2">
                    <div class="flex items-baseline gap-2 flex-wrap min-w-0">
                      <span class={["badge badge-sm shrink-0", kind_badge_class(m.kind)]}>
                        {m.kind}
                      </span>
                      <span class="text-xs text-base-content/60">
                        from <code class="font-mono">{m.from_ref || "?"}</code>
                      </span>
                      <span :if={m.subject} class="text-sm font-medium truncate">{m.subject}</span>
                    </div>
                    <button
                      phx-click="mark_read"
                      phx-value-id={m.id}
                      class="btn btn-xs btn-ghost shrink-0"
                    >
                      Mark read
                    </button>
                  </div>
                  <p class="text-sm mt-1.5 whitespace-pre-wrap text-base-content/80">{m.body}</p>
                </li>
              </ul>
            <% end %>

            <form
              phx-submit="send_direction"
              phx-change="compose_change"
              class="flex flex-col gap-2 pt-2 border-t border-base-300"
            >
              <label class="text-sm font-medium flex items-center gap-1.5">
                <.icon name="hero-paper-airplane" class="size-4 text-base-content/60" />
                Send direction to <code class="font-mono">{@task_id}</code>
                (from coordinator)
              </label>
              <textarea
                name="body"
                rows="3"
                placeholder="e.g. check the API contract before refactoring"
                class="textarea textarea-bordered w-full text-sm"
              >{@compose_body}</textarea>
              <div>
                <button
                  type="submit"
                  class="btn btn-sm btn-primary gap-1.5 transition-all duration-200 active:scale-95"
                  disabled={is_nil(@workspace)}
                >
                  <.icon name="hero-paper-airplane" class="size-4" /> Send direction
                </button>
              </div>
            </form>
          </div>
        </section>

        <div>
          <.link navigate={~p"/"} class="link link-hover text-sm flex items-center gap-1 w-fit">
            <.icon name="hero-arrow-left" class="size-4" /> Back to dashboard
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp status_class(:idle), do: "badge-ghost"
  defp status_class(:resuming), do: "badge-info"
  defp status_class(:running), do: "badge-info"
  defp status_class(:awaiting), do: "badge-warning"
  defp status_class(:awaiting_review_gate), do: "badge-warning"
  defp status_class(:awaiting_review), do: "badge-warning"
  defp status_class(:completed), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(_), do: ""

  defp status_label(:idle), do: "Idle"
  defp status_label(:resuming), do: "Resuming"
  defp status_label(:running), do: "Running"
  defp status_label(:awaiting), do: "Awaiting"
  defp status_label(:awaiting_review_gate), do: "In review_gate"
  defp status_label(:awaiting_review), do: "Awaiting review"
  defp status_label(:completed), do: "Completed"
  defp status_label(:failed), do: "Failed"

  defp status_label(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  defp status_label(other), do: to_string(other)

  # Badge color + text for the last Mergers.get/1 result the Watchdog recorded.
  # An *approved* MR that still can't merge (#354, Phase 1) surfaces the *why*
  # ahead of the generic approval state. The block reason is read through
  # `Watchdog.effective_block_reason/1`, which only reports a block once the MR
  # is approved — so the ordinary pre-approval review window never shows a red
  # "Blocked" badge.
  defp approval_class(%{status: :merged}), do: "badge-success"
  defp approval_class(%{status: :closed}), do: "badge-error"

  defp approval_class(status) when is_map(status) do
    cond do
      Watchdog.effective_block_reason(status) -> "badge-error"
      Map.get(status, :approved) == true -> "badge-success"
      true -> "badge-warning"
    end
  end

  defp approval_class(_), do: "badge-warning"

  defp approval_label(%{status: :merged}), do: "Merged"
  defp approval_label(%{status: :closed}), do: "Closed"

  defp approval_label(status) when is_map(status) and not is_struct(status) do
    case Watchdog.effective_block_reason(status) do
      nil -> approval_label_default(status)
      reason -> block_reason_label(reason)
    end
  end

  defp approval_label(_), do: "Pending"

  defp approval_label_default(%{approved: true}), do: "Approved"
  defp approval_label_default(%{status: :open}), do: "Open · awaiting approval"

  defp approval_label_default(%{status: status}) when is_atom(status),
    do: status |> Atom.to_string() |> String.capitalize()

  defp approval_label_default(_), do: "Pending"

  # Human label for a Watchdog block reason (#354, Phase 1).
  defp block_reason_label(:conflict), do: "Blocked · conflict"
  defp block_reason_label(:behind_base), do: "Blocked · behind base"
  defp block_reason_label(:ci_failed), do: "Blocked · CI failed"
  defp block_reason_label(:needs_approval), do: "Blocked · needs approval"

  defp block_reason_label(:needs_nonauthor_approval),
    do: "Parked · awaiting human reviewer"

  defp block_reason_label(:draft), do: "Blocked · draft"
  defp block_reason_label(:blocked_other), do: "Blocked"
  defp block_reason_label(other), do: "Blocked · #{other}"

  # A claude-driven worker (a streaming Claude subprocess does the real work).
  # Flagged on meta at session-open. Such a worker's workflow Machine is never
  # ticked, so the fixed steps are meaningless — show live activity instead.
  defp claude_session?(%{meta: meta}) when is_map(meta),
    do: Map.get(meta, :claude_session) == true

  defp claude_session?(_), do: false

  defp live_activity(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :activity) do
      %{"label" => label} when is_binary(label) -> label
      %{label: label} when is_binary(label) -> label
      label when is_binary(label) -> label
      _ -> "working"
    end
  end

  defp live_activity(_), do: "working"

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

  # ---- shared visual helpers (mirrors DashboardLive for an identical look) ----

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second) |> max(0)
  end

  defp runtime_seconds(_, _), do: 0

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_ts(_), do: ""

  # An MR/PR ref is not currently persisted on the worker snapshot, so this
  # degrades to nil. When the dispatch flow starts stashing it in meta (under
  # :mr_ref or "mr_ref"), the awaiting-review link lights up automatically.
  defp mr_ref(%{meta: meta}) when is_map(meta) do
    Map.get(meta, :mr_ref) || Map.get(meta, "mr_ref")
  end

  defp mr_ref(_), do: nil

  # Ordered worker lifecycle for the step progress stepper. :failed is handled
  # separately in the template (it doesn't belong on the happy-path track).
  @worker_flow [:idle, :running, :awaiting, :completed]

  defp worker_flow, do: @worker_flow

  # Returns :done | :current | :todo for a step relative to the worker's
  # current status, so the template can mark the stepper.
  defp flow_state(step, status) do
    step_idx = Enum.find_index(@worker_flow, &(&1 == step))
    status_idx = Enum.find_index(@worker_flow, &(&1 == status))

    cond do
      is_nil(step_idx) or is_nil(status_idx) -> :todo
      step_idx < status_idx -> :done
      step_idx == status_idx -> :current
      true -> :todo
    end
  end

  # DaisyUI `step` modifier per flow state. Done/current light up primary;
  # todo stays neutral.
  defp flow_step_class(:done), do: "step-primary"
  defp flow_step_class(:current), do: "step-primary"
  defp flow_step_class(:todo), do: ""

  # Step marker glyph: a check for completed steps, otherwise the default index.
  defp flow_step_marker(:done), do: "✓"
  defp flow_step_marker(_), do: nil

  defp flow_step_label(:idle), do: "Idle"
  defp flow_step_label(:running), do: "Running"
  defp flow_step_label(:awaiting), do: "Awaiting review"
  defp flow_step_label(:completed), do: "Completed"

  # Notification-kind palette, matching the dashboard's mappings.
  defp kind_badge_class(:notification), do: "badge-info"
  defp kind_badge_class(:direction), do: "badge-warning"
  defp kind_badge_class(:flag), do: "badge-accent"
  defp kind_badge_class(_), do: "badge-ghost"

  defp kind_border_class(:notification), do: "border-l-info"
  defp kind_border_class(:direction), do: "border-l-warning"
  defp kind_border_class(:flag), do: "border-l-accent"
  defp kind_border_class(_), do: "border-l-base-300"

  # ---- execution context helpers ----------------------------------------

  # Provider: prefer the ACTUAL model provider synced from session (set once
  # the Claude init event arrives), then fall back to the routing config
  # stamped at spawn time (set before spawn via Worker.report).
  defp execution_provider(%{meta: meta}) when is_map(meta) do
    Map.get(meta, :provider) ||
      get_in(meta, [:routing_config, :provider]) ||
      "claude"
  end

  defp execution_provider(_), do: "claude"

  # Model: prefer the ACTUAL model from the running session (synced from the
  # Claude streaming init event — exact concrete model name), then fall back to
  # the configured model from the routing decision.
  defp execution_model(%{meta: meta}) when is_map(meta) do
    Map.get(meta, :model) || get_in(meta, [:routing_config, :model])
  end

  defp execution_model(_), do: nil

  defp execution_thinking(%{meta: meta}) when is_map(meta) do
    get_in(meta, [:routing_config, :thinking])
  end

  defp execution_thinking(_), do: nil

  defp execution_model_tier(%{meta: meta}) when is_map(meta) do
    get_in(meta, [:routing_config, :model_tier])
  end

  defp execution_model_tier(_), do: nil

  # Tracker ref display: "jira:ABC-123", "github:42", etc.
  defp tracker_display(%Issue{tracker_type: type, tracker_ref: ref})
       when not is_nil(ref) and ref != "" and type not in [nil, :none] do
    "#{type}:#{ref}"
  end

  defp tracker_display(_), do: nil

  # Whether the meta map has any details worth showing in the metadata section.
  defp meta_has_details?(nil), do: false

  defp meta_has_details?(meta) when is_map(meta) do
    Enum.any?(
      [:role, :review_required, :worktree_path, :branch, :stop_reason],
      &Map.has_key?(meta, &1)
    )
  end
end
