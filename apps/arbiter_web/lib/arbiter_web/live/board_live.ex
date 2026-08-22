defmodule ArbiterWeb.BoardLive do
  @moduledoc """
  The board — the home screen, and the only page that answers "what is the
  fleet doing" in one look.

  Five columns for where a piece of work actually sits: **Ready**, **Running**,
  **Needs you**, **Merge queue**, **Closed today**. They are stages, not
  statuses — the task FSM still only knows `open` / `in_progress` / `closed`,
  and every column is derived from worker state, review state and merge-queue
  membership by `Arbiter.Board.Snapshot`. Nothing here is stored, so nothing
  here can drift.

  ## Ready is a queue, not a parking lot

  The design handoff put a *drop to dispatch* zone at the foot of the Ready
  column: cards sat there until a human dragged each one into Running. This
  screen deliberately does not build that (bd-bqyeqa). An operator who must
  drag every card into flight is a scheduler made of a person, and a person is
  the one component here that cannot watch sixteen slots at once.

  Instead `Arbiter.Board.Scheduler` decides and `Arbiter.Board.Autopilot`
  dispatches: the top eligible Ready card is promoted whenever a worker slot
  frees up, gated on dependency blocks, file overlap with in-flight work, quota
  headroom and a pause switch. Every Ready card therefore carries a *reason*
  rather than a static state — `next up — dispatching...`, `2 ahead in queue`,
  `blocked — waiting on bd-9`, `blocked — quota exhausted`. A queue that
  explains itself is one an operator can leave alone.

  ## What drag is still for

  Drag remains a human action, for the moves only a human can decide:

    * **reordering within Ready** — the operator's hand-ranking leads the
      queue, so dragging a card to the top is how you override the machine's
      idea of what matters most without dispatching anything by hand;
    * **pulling a card out of Running** — stops the worker, and asks first,
      because that kills a live agent mid-thought;
    * **Needs-you review outcomes** — dropping a parked card on Ready sends
      the work back (the halted worker is discarded and the issue returns to
      the queue for the scheduler to re-decide); dropping it toward the merge
      queue lets it proceed (the parked worker un-parks and finishes its own
      way there). The worker FSM has the final say on both;
    * **merge-queue-adjacent moves** — dropping a merge-queue card out of the
      column stops the worker sitting on the merge request without touching
      the merge request itself.

  Dragging *into* Running is refused with an explanation. There is no hidden
  manual path into flight: if a card is not being promoted, the reason on its
  face is the thing to fix.

  ## Component shadowing

  `ArbiterWeb`'s html helpers import the redesigned component groups with
  exclusions where a name collides with the pre-redesign `core_components.ex`
  (`button/1`, `icon/1`, `input/1`, `select/1`, `empty_state/1`, ...). Those
  are called fully-qualified here so this screen gets the redesigned component
  and not the daisyUI one, until bd-3z2txy retires the shim.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Snapshot
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue
  alias Arbiter.Worker

  @tasks_topic "tasks"
  @workers_topic "workers"

  @coordinator_ref Message.coordinator_ref()

  # How many cards a column shows before it collapses into an "N more" row.
  @column_limit 8

  # Every call this LiveView makes out to another process is bounded. Nothing
  # on the render path may hang the operator's only view of the fleet.
  @scheduler_call_timeout_ms 2_000
  @stop_timeout_ms 5_000

  @columns [
    %{key: "ready", label: "Ready", tone: nil},
    %{key: "running", label: "Running", tone: "live"},
    %{key: "needs_you", label: "Needs you", tone: "attention"},
    %{key: "merge", label: "Merge queue", tone: nil},
    %{key: "closed", label: "Closed today", tone: nil}
  ]

  @impl true
  def mount(_params, _session, socket) do
    live? = connected?(socket)

    if live? do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Autopilot.topic())
      # Elapsed counters on Running cards, and the waiting times that make the
      # Needs-you column readable. Reassigns `:now` only — no reads.
      :timer.send_interval(1000, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:page_title, "Board")
     |> assign(:live, live?)
     |> assign(:now, DateTime.utc_now())
     |> assign(:filter, "")
     |> assign(:scope, "all")
     |> assign(:workspace, "all")
     |> assign(:ready_order, [])
     |> assign(:expanded, MapSet.new())
     |> assign(:confirm_stop, nil)
     |> assign(:columns, @columns)
     |> assign(:issue_label, "issue")
     |> assign(:worker_label, "worker")
     |> load_workspaces()
     |> subscribe_messages(live?)
     |> refresh_coordinator_inbox()
     |> refresh_board()}
  end

  # ---- live updates ---------------------------------------------------------

  @impl true
  def handle_info({:task_lifecycle, _event, _issue}, socket),
    do: {:noreply, refresh_board(socket)}

  def handle_info({:worker_lifecycle, _event, _snapshot}, socket),
    do: {:noreply, refresh_board(socket)}

  def handle_info({:board_dispatched, _task_id}, socket),
    do: {:noreply, refresh_board(socket)}

  def handle_info({:board_scheduler, _state}, socket),
    do: {:noreply, refresh_board(socket)}

  def handle_info({:new_message, _message}, socket),
    do: {:noreply, refresh_coordinator_inbox(socket)}

  def handle_info({:message_read, _message}, socket),
    do: {:noreply, refresh_coordinator_inbox(socket)}

  def handle_info({:mailbox_cleared, _workspace_id}, socket),
    do: {:noreply, refresh_coordinator_inbox(socket)}

  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---- toolbar --------------------------------------------------------------

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, assign(socket, :filter, filter)}

  def handle_event("scope", %{"option" => scope}, socket),
    do: {:noreply, assign(socket, :scope, scope)}

  def handle_event("workspace", %{"workspace" => id}, socket),
    do: {:noreply, assign(socket, :workspace, id)}

  def handle_event("expand", %{"column" => key}, socket),
    do: {:noreply, assign(socket, :expanded, MapSet.put(socket.assigns.expanded, key))}

  # ---- the scheduler switch -------------------------------------------------

  # One switch for the whole install, because there is one scheduler. Pausing
  # leaves in-flight work alone — it only stops the queue draining.
  def handle_event("toggle_scheduler", _params, socket) do
    if scheduler_running?() do
      case toggle_scheduler() do
        :ok ->
          {:noreply, refresh_board(socket)}

        {:error, _reason} ->
          {:noreply,
           put_flash(socket, :error, "The board scheduler didn't answer — try that again.")}
      end
    else
      {:noreply, put_flash(socket, :error, "The board scheduler isn't running on this install.")}
    end
  end

  # ---- drag: reordering Ready ----------------------------------------------

  # The operator's hand-ranking. It does not dispatch anything: it changes
  # which card the scheduler considers first, and the scheduler still has to
  # agree the card is eligible. Held in the session, not the database — a
  # ranking is a thing you are doing right now, not a property of the issue.
  def handle_event("reorder_ready", %{"order" => order}, socket) when is_list(order) do
    {:noreply,
     socket
     |> assign(:ready_order, Enum.filter(order, &is_binary/1))
     |> refresh_board()}
  end

  # ---- drag: one gesture, and what each landing means -----------------------

  # The client reports the whole gesture — this card, out of that column, into
  # this one — and the board decides what it means. Most landings mean
  # nothing; the ones that do are enumerated here, in the order a person
  # would read them.
  def handle_event("drag", %{"id" => id, "from" => from, "to" => to}, socket)
      when is_binary(id) and is_binary(from) and is_binary(to) do
    {:noreply, dropped(socket, id, from, to)}
  end

  def handle_event("drag", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_stop", _params, socket),
    do: {:noreply, assign(socket, :confirm_stop, nil)}

  def handle_event("confirm_stop", _params, %{assigns: %{confirm_stop: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_stop", _params, socket) do
    id = socket.assigns.confirm_stop

    socket =
      case stop_worker_now(id) do
        :ok ->
          put_flash(socket, :info, "Stopped the worker on #{id}.")

        {:error, :not_found} ->
          put_flash(socket, :error, "No worker registered for #{id}.")

        {:error, reason} ->
          put_flash(socket, :error, "Could not stop the worker on #{id}: #{inspect(reason)}")
      end

    {:noreply, socket |> assign(:confirm_stop, nil) |> refresh_board()}
  end

  # ---- coordinator mailbox --------------------------------------------------

  def handle_event("mark_read", %{"id" => id}, socket) do
    with {:ok, msg} <- Ash.get(Message, id),
         {:ok, _} <- Message.mark_read(msg) do
      {:noreply, refresh_coordinator_inbox(socket)}
    else
      _ -> {:noreply, refresh_coordinator_inbox(socket)}
    end
  end

  def handle_event("clear_coordinator", _params, socket) do
    _ = Message.clear_read(@coordinator_ref)
    {:noreply, refresh_coordinator_inbox(socket)}
  end

  # ---- what a landing means ------------------------------------------------

  # A card released over the column it started in did nothing, whatever column
  # that is. This has to come first: without it a Running card picked up and
  # put straight back down falls through to the stop-the-worker prompt below,
  # which is one stray click from destroying live work the operator never
  # meant to touch.
  defp dropped(socket, _id, same, same), do: socket

  # Running is not a drop target. The whole point of the scheduler is that a
  # person does not decide *when* — so say what the card is waiting for
  # instead of pretending the drag did something.
  defp dropped(socket, id, _from, "running") do
    put_flash(
      socket,
      :error,
      "Running is the scheduler's column — #{id} goes in when a slot frees up and nothing " <>
        "blocks it. Its card says what it is waiting for."
    )
  end

  # Pulling a card out of Running kills a live agent mid-thought and throws
  # away whatever it had not yet written down, so the drag opens a question
  # rather than doing it.
  defp dropped(socket, id, "running", _to), do: assign(socket, :confirm_stop, id)

  # Send back. The parked worker is halted already, so nothing is interrupted
  # — it is discarded, and the issue goes back to open so the queue owns it
  # again. Deliberately not `Dispatch.resume/1`: sending work back to Ready
  # means the scheduler re-decides it on the merits, not that a stale session
  # picks up where it left off.
  defp dropped(socket, id, "needs_you", "ready"), do: requeue(socket, id, "Sent")

  # Proceed. The answer the worker was parked on is "carry on", so un-park it
  # and let it finish its own way to review and the merge queue. The FSM,
  # not the board, decides whether that is legal from where the card actually
  # sits — a review rejection parks at :failed and refuses.
  defp dropped(socket, id, "needs_you", to) when to in ["merge", "closed"] do
    case Worker.resume(id) do
      :ok ->
        socket
        |> put_flash(:info, "#{id} may proceed — the worker picked up where it parked.")
        |> refresh_board()

      {:error, {:invalid_transition, status, _}} ->
        put_flash(
          socket,
          :error,
          "#{id} is #{status} — there is nothing parked to let proceed. Decide it on the " <>
            "task instead."
        )

      {:error, reason} ->
        put_flash(socket, :error, "#{id} could not proceed: #{inspect(reason)}")
    end
  end

  # Out of the merge queue. The merge request itself is not touched — what
  # stops is the worker sitting on it — so this is reversible by re-opening
  # the task's merge from the task page.
  defp dropped(socket, id, "merge", "ready"), do: requeue(socket, id, "Pulled")

  defp dropped(socket, id, "merge", to) when to in ["needs_you", "closed"] do
    socket
    |> stop_worker(id)
    |> put_flash(:info, "Pulled #{id} out of the merge queue. Its merge request is untouched.")
    |> refresh_board()
  end

  # Everything else — a card dropped back where it came from, or onto a column
  # that implies no action. Silence is the right answer; a flash for every
  # stray drop trains the operator to ignore flashes.
  defp dropped(socket, _id, _from, _to), do: socket

  # Stop whatever worker holds the card and hand the issue back to the queue.
  defp requeue(socket, id, verb) do
    socket
    |> stop_worker(id)
    |> reopen(id)
    |> put_flash(:info, "#{verb} #{id} back to the queue — the scheduler decides it from there.")
    |> refresh_board()
  end

  defp stop_worker(socket, id) do
    _ = stop_worker_now(id)
    socket
  end

  # `Worker.stop/3` defaults to `:infinity`, and `GenServer.stop/3` *exits the
  # caller* when the worker is already gone (a `:noproc` race against
  # `whereis/1`) or dies for a reason other than the one asked for. Neither is
  # survivable here: this runs in the LiveView, which is the operator's only
  # view of the fleet, so a worker wedged in `terminate/2` must not be able to
  # take the board down with it or hang it forever.
  defp stop_worker_now(id) do
    Worker.stop(id, :normal, @stop_timeout_ms)
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Back to `:open` so `Snapshot` counts it as Ready again. A worker leaves its
  # task `:in_progress` on purpose (so a failure stays inspectable), which is
  # exactly the state that would otherwise strand the card in no column at all.
  defp reopen(socket, id) do
    with {:ok, issue} <- Ash.get(Issue, id),
         true <- issue.status != :open,
         {:ok, _} <- Ash.update(issue, %{status: :open}) do
      socket
    else
      _ -> socket
    end
  end

  # ---- reads ----------------------------------------------------------------

  # The board the *scheduler* sees, so the reasons on screen are the reasons it
  # is acting on — but derived *here*, in this LiveView, not fetched from the
  # autopilot. The only thing that process contributes to a board read is the
  # pause flag, and asking it for the whole snapshot would put every open
  # board behind one mailbox: behind each other, and behind whatever the
  # autopilot is doing. Dispatch broadcasts `:started` mid-flight, so the
  # boards refreshing on that would be queueing against the very promotion
  # they are refreshing to show.
  #
  # When the autopilot isn't running at all there is nothing to drain the
  # queue, which is exactly what `paused: true` renders.
  defp refresh_board(socket) do
    running? = scheduler_running?()
    paused? = not running? or scheduler_paused?()

    opts = [
      now: DateTime.utc_now(),
      ready_order: socket.assigns.ready_order,
      paused: paused?
    ]

    board = read_board(opts, socket.assigns.now)

    socket
    |> assign(:board, board)
    |> assign(:scheduler_running, running?)
    |> assign(:now, board.now)
  end

  # A read that raises must not take the page down — five empty columns and a
  # `paused` board say "we cannot see anything right now", which is true and
  # is the only honest thing to render.
  defp read_board(opts, now) do
    Snapshot.load(opts)
  rescue
    _ -> Snapshot.empty(now)
  catch
    :exit, _ -> Snapshot.empty(now)
  end

  defp scheduler_running? do
    Autopilot.running?(Autopilot)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Bounded and exit-safe for the same reason the read is: the switch is on the
  # board, and a scheduler that has just died or is slow to answer must leave
  # the operator with a board and a flash, not a dead LiveView.
  defp toggle_scheduler do
    if scheduler_paused?(),
      do: Autopilot.resume(Autopilot),
      else: Autopilot.pause(Autopilot)
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # A short budget and a caught exit, because this is on the render path: a
  # scheduler that cannot answer promptly is treated as one that is not
  # draining the queue, which is the reading that under-promises.
  defp scheduler_paused? do
    Autopilot.paused?(Autopilot, @scheduler_call_timeout_ms)
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  defp load_workspaces(socket) do
    workspaces =
      try do
        Arbiter.Tasks.Workspace |> Ash.read!() |> Enum.sort_by(& &1.name)
      rescue
        _ -> []
      end

    assign(socket, :workspaces, workspaces)
  end

  defp subscribe_messages(socket, false), do: socket

  defp subscribe_messages(socket, true) do
    for ws <- socket.assigns.workspaces,
        do: Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(ws.id))

    socket
  end

  # Two figures, not one: pending (unread — never seen) and outstanding (seen
  # but not cleared — still owes an action). Reading no longer empties the
  # queue, so "still open" needs its own number.
  defp refresh_coordinator_inbox(socket) do
    {inbox, outstanding} =
      try do
        {Message.inbox(@coordinator_ref), Message.outstanding(@coordinator_ref)}
      rescue
        _ -> {[], []}
      end

    socket
    |> assign(:coordinator_inbox, inbox)
    |> assign(:coordinator_outstanding_count, length(outstanding))
  end

  # ---- view-level filtering -------------------------------------------------
  #
  # The filter narrows what is *shown*; it never narrows what the scheduler
  # considers. Typing in a search box must not change which card gets
  # dispatched next.

  defp visible(assigns, cards, _key) do
    Enum.filter(cards, &matches?(&1, assigns))
  end

  defp matches?(card, assigns) do
    card = card_of(card)

    matches_workspace?(card, assigns.workspace) and matches_scope?(card, assigns.scope) and
      matches_filter?(card, assigns.filter)
  end

  # A Ready entry wraps its card; every other column is the card itself.
  defp card_of(%{card: %{} = card}), do: card
  defp card_of(card), do: card

  defp matches_workspace?(_card, "all"), do: true
  defp matches_workspace?(card, id), do: Map.get(card, :workspace_id) == id

  defp matches_scope?(_card, "all"), do: true

  # Arbiter has no web login, so "mine" cannot mean a person. It means work
  # that has not been handed to a named assignee — the operator's own pile.
  defp matches_scope?(card, "mine") do
    case Map.get(card, :assignee) do
      nil -> true
      "" -> true
      assignee -> assignee == @coordinator_ref
    end
  end

  defp matches_scope?(_card, _), do: true

  defp matches_filter?(_card, filter) when filter in [nil, ""], do: true

  defp matches_filter?(card, filter) do
    needle = String.downcase(String.trim(filter))

    haystack =
      [Map.get(card, :id), Map.get(card, :title)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    needle == "" or String.contains?(haystack, needle)
  end

  # ---- card routing ---------------------------------------------------------

  defp card_href("running", card), do: ~p"/workers/#{card.id}"
  defp card_href("needs_you", card), do: ~p"/workers/#{card.id}"
  defp card_href("merge", _card), do: ~p"/merge_queue"

  defp card_href(_column, card) do
    if String.starts_with?(to_string(card.id), "loop-"),
      do: ~p"/loop",
      else: ~p"/tasks/#{card.id}"
  end

  # ---- formatting -----------------------------------------------------------

  defp elapsed(nil, _now), do: nil

  defp elapsed(%DateTime{} = since, %DateTime{} = now) do
    secs = max(DateTime.diff(now, since, :second), 0)

    cond do
      secs < 60 -> "#{secs}s"
      secs < 3600 -> "#{div(secs, 60)}m"
      secs < 86_400 -> "#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m"
      true -> "#{div(secs, 86_400)}d"
    end
  end

  defp elapsed(_, _), do: nil

  defp clock(%DateTime{} = ts), do: Calendar.strftime(ts, "%H:%M")
  defp clock(_), do: ""

  defp relative(%DateTime{} = ts, %DateTime{} = now), do: "#{elapsed(ts, now)} ago"
  defp relative(_, _), do: ""

  defp quota_note(:ok), do: nil
  defp quota_note(nil), do: nil
  defp quota_note({:hold, reason}), do: reason
  defp quota_note(_), do: nil

  defp scheduler_label(%{paused: true}), do: "paused"
  defp scheduler_label(_), do: "auto"

  # The one column head that carries a hue is the one whose state is the
  # operator's problem.
  defp head_hue("live"), do: "var(--arb-live)"
  defp head_hue("attention"), do: "var(--arb-attention)"
  defp head_hue(_), do: nil

  defp mailbox_border(:escalation), do: "border-l-[color:var(--arb-fail)]"
  defp mailbox_border(:failure), do: "border-l-[color:var(--arb-fail)]"
  defp mailbox_border(:completion), do: "border-l-[color:var(--arb-live)]"
  defp mailbox_border(:direction), do: "border-l-[color:var(--arb-attention)]"
  defp mailbox_border(:flag), do: "border-l-[color:var(--arb-attention)]"
  defp mailbox_border(_), do: "border-l-[color:var(--arb-info)]"

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:ready, visible(assigns, assigns.board.ready, "ready"))
      |> assign(:running, visible(assigns, assigns.board.running, "running"))
      |> assign(:needs_you, visible(assigns, assigns.board.needs_you, "needs_you"))
      |> assign(:merge, visible(assigns, assigns.board.merge_queue, "merge"))
      |> assign(:closed, visible(assigns, assigns.board.closed_today, "closed"))

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas}>
      <div class="px-4 py-4 flex flex-col gap-4">
        <div
          id="board"
          class="border border-solid border-[var(--border-default)] rounded-[var(--radius-panel)] overflow-hidden bg-[var(--surface-page)]"
        >
          <%!-- ── Toolbar ─────────────────────────────────────────────── --%>
          <div class="flex items-center gap-3 h-[var(--toolbar-height)] px-4 border-b border-solid border-[var(--border-default)] bg-[var(--arb-canvas-sunken)]">
            <form id="board-workspace-form" phx-change="workspace" class="flex-none w-[136px]">
              <ArbiterWeb.CoreComponents.Forms.select
                name="workspace"
                size="sm"
                value={@workspace}
                options={[{"all workspaces", "all"} | Enum.map(@workspaces, &{&1.name, &1.id})]}
              />
            </form>

            <form id="board-filter-form" phx-change="filter" class="flex-none w-[260px]">
              <ArbiterWeb.CoreComponents.Forms.input
                name="filter"
                size="sm"
                mono={false}
                value={@filter}
                placeholder={"Filter #{plural(@issue_label)}"}
                key_hint="/"
                phx-debounce="150"
                icon={search_icon()}
              />
            </form>

            <.segmented_control options={["mine", "all"]} value={@scope} event="scope" />

            <span class="ml-auto flex items-center gap-2.5">
              <span
                id="board-slots"
                class="text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
              >
                {length(@board.running)} {plural(@worker_label)} · {@board.slots_free} slots free
              </span>

              <button
                id="board-scheduler-toggle"
                type="button"
                phx-click="toggle_scheduler"
                title={
                  if @board.paused,
                    do: "The queue is not draining. Resume to let the scheduler dispatch.",
                    else: "The scheduler is promoting Ready cards as slots free up."
                }
                class={[
                  "px-2 py-[3px] rounded-[var(--radius-chip)] border border-solid",
                  "text-[10px] font-medium font-[family-name:var(--font-mono)] uppercase tracking-[0.08em]",
                  if(@board.paused,
                    do:
                      "border-[color-mix(in_oklch,var(--arb-attention)_45%,transparent)] text-[var(--arb-attention)]",
                    else:
                      "border-[color-mix(in_oklch,var(--arb-live)_45%,transparent)] text-[var(--arb-live)]"
                  )
                ]}
              >
                scheduler {scheduler_label(@board)}
              </button>

              <ArbiterWeb.CoreComponents.Core.button
                variant="primary"
                size="sm"
                key_hint="C"
                phx-click={JS.navigate(~p"/tasks")}
              >
                New {@issue_label}
              </ArbiterWeb.CoreComponents.Core.button>
            </span>
          </div>

          <%!-- ── Columns ─────────────────────────────────────────────── --%>
          <div
            id="board-columns"
            phx-hook=".BoardDrag"
            class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-5 gap-px bg-[var(--arb-line-soft)] min-h-[560px]"
          >
            <%!-- Ready — the queue. Every card says why it is or isn't going. --%>
            <div
              id="board-column-ready"
              data-column="ready"
              class="bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px]"
            >
              <.column_head label="Ready" count={length(@ready)} tone={nil} />

              <div
                :for={entry <- Enum.take(@ready, limit(@expanded, "ready"))}
                id={"card-#{entry.card.id}"}
                class="contents"
              >
                <.link navigate={card_href("ready", entry.card)} class="contents">
                  <.task_card
                    id={entry.card.id}
                    title={entry.card.title || entry.card.id}
                    priority={entry.card.priority}
                    type={entry.card.issue_type}
                    difficulty={entry.card.difficulty}
                    activity={entry.reason}
                    accent={ready_accent(entry.state)}
                    draggable="true"
                    data-card={entry.card.id}
                    data-column="ready"
                  />
                </.link>
              </div>

              <.more
                :if={length(@ready) > limit(@expanded, "ready")}
                column="ready"
                count={length(@ready) - limit(@expanded, "ready")}
              />

              <%!-- Where the handoff put "drop to dispatch". The queue drains
                   itself, so what belongs here is the reason it might not. --%>
              <div
                id="board-ready-foot"
                class="mt-auto px-2 py-2 text-center rounded-[var(--radius-field)] border border-dashed border-[var(--border-strong)] text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              >
                {ready_foot(@board, @scheduler_running)}
              </div>
            </div>

            <%!-- Running — the machine's column. Drag out, never in. --%>
            <div
              id="board-column-running"
              data-column="running"
              class="bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px]"
            >
              <.column_head
                label="Running"
                count={"#{length(@running)} / #{@board.slots_total}"}
                tone="live"
              />

              <div
                :for={card <- Enum.take(@running, limit(@expanded, "running"))}
                id={"card-#{card.id}"}
                class="contents"
              >
                <.link navigate={card_href("running", card)} class="contents">
                  <.task_card
                    id={card.id}
                    title={card.title || card.id}
                    accent="live"
                    activity={card.activity}
                    footer={card.step && to_string(card.step)}
                    draggable="true"
                    data-card={card.id}
                    data-column="running"
                  >
                    <:status>
                      <span class="text-[10px] font-medium font-[family-name:var(--font-mono)] text-[var(--arb-live)] animate-[arb-pulse_var(--pulse-period)_var(--ease-in-out)_infinite]">
                        {elapsed(card.since, @now)}
                      </span>
                    </:status>
                  </.task_card>
                </.link>
              </div>

              <.more
                :if={length(@running) > limit(@expanded, "running")}
                column="running"
                count={length(@running) - limit(@expanded, "running")}
              />
            </div>

            <%!-- Needs you — the only column that moves because a person decided. --%>
            <div
              id="board-column-needs-you"
              data-column="needs_you"
              class="bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px]"
            >
              <.column_head label="Needs you" count={length(@needs_you)} tone="attention" />

              <div
                :for={card <- Enum.take(@needs_you, limit(@expanded, "needs_you"))}
                id={"card-#{card.id}"}
                class="contents"
              >
                <.task_card
                  id={card.id}
                  title={card.title || card.id}
                  accent={if card.status == :failed, do: "fail", else: "attention"}
                  activity={card.reason}
                  draggable="true"
                  data-card={card.id}
                  data-column="needs_you"
                >
                  <:status>
                    <span class={[
                      "text-[10px] font-medium font-[family-name:var(--font-mono)]",
                      if(card.status == :failed,
                        do: "text-[var(--arb-fail-text)]",
                        else: "text-[var(--arb-attention)]"
                      )
                    ]}>
                      {if card.status == :failed,
                        do: "failed",
                        else: "#{elapsed(card.since, @now)} waiting"}
                    </span>
                  </:status>
                  <:actions>
                    <.link navigate={card_href("needs_you", card)} class="contents">
                      <span class="px-2 py-[2px] rounded-[var(--radius-chip)] text-[10px] font-medium font-[family-name:var(--font-mono)] bg-[var(--arb-attention)] text-[var(--arb-attention-ink)]">
                        {if card.status == :failed, do: "retry", else: "answer"}
                      </span>
                    </.link>
                    <.link navigate={~p"/tasks/#{card.id}"} class="contents">
                      <span class="px-2 py-[2px] rounded-[var(--radius-chip)] text-[10px] font-medium font-[family-name:var(--font-mono)] border border-solid border-[var(--arb-done-edge)] text-[var(--text-secondary)]">
                        {@issue_label}
                      </span>
                    </.link>
                  </:actions>
                </.task_card>
              </div>

              <.more
                :if={length(@needs_you) > limit(@expanded, "needs_you")}
                column="needs_you"
                count={length(@needs_you) - limit(@expanded, "needs_you")}
              />
            </div>

            <%!-- Merge queue — done by the agent, held by the merger. --%>
            <div
              id="board-column-merge"
              data-column="merge"
              class="bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px]"
            >
              <.column_head label="Merge queue" count={length(@merge)} tone={nil} />

              <div
                :for={{card, i} <- Enum.with_index(Enum.take(@merge, limit(@expanded, "merge")))}
                id={"card-#{card.id}"}
                class="contents"
              >
                <.link navigate={card_href("merge", card)} class="contents">
                  <.task_card
                    id={card.id}
                    title={card.title || card.id}
                    accent={if i == 0, do: "info", else: nil}
                    activity={merge_activity(card)}
                    footer={elapsed(card.since, @now) && "#{elapsed(card.since, @now)} in queue"}
                    draggable="true"
                    data-card={card.id}
                    data-column="merge"
                  >
                    <:status>
                      <span class="text-[10px] font-medium font-[family-name:var(--font-mono)] text-[var(--arb-info)]">
                        #{i + 1} · {card.merger_status || "checks"}
                      </span>
                    </:status>
                  </.task_card>
                </.link>
              </div>

              <.more
                :if={length(@merge) > limit(@expanded, "merge")}
                column="merge"
                count={length(@merge) - limit(@expanded, "merge")}
              />
            </div>

            <%!-- Closed today — the day's evidence. No action on it. --%>
            <div
              id="board-column-closed"
              data-column="closed"
              class="bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px]"
            >
              <.column_head label="Closed today" count={length(@closed)} tone={nil} />

              <div
                :for={card <- Enum.take(@closed, limit(@expanded, "closed"))}
                id={"card-#{card.id}"}
                class="contents"
              >
                <.link navigate={card_href("closed", card)} class="contents">
                  <.task_card
                    id={card.id}
                    title={card.title || card.id}
                    muted
                    footer={"closed #{clock(card.closed_at)}"}
                    data-card={card.id}
                    data-column="closed"
                  />
                </.link>
              </div>

              <div
                :if={length(@closed) > limit(@expanded, "closed")}
                class="flex items-center justify-between px-[11px] py-[9px] rounded-[var(--radius-field)] border border-dashed border-[var(--arb-line)]"
              >
                <span class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                  {length(@closed) - limit(@expanded, "closed")} more
                </span>
                <.link
                  navigate={~p"/tasks"}
                  class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-link)]"
                >
                  →
                </.link>
              </div>
            </div>
          </div>
        </div>

        <%!-- ── Stop confirmation ───────────────────────────────────────
             Pulling a card out of Running kills a live agent. The drag opens
             this; only the button here stops anything. --%>
        <div
          :if={@confirm_stop}
          id="board-confirm-stop"
          class="flex items-center gap-3 px-4 py-3 rounded-[var(--radius-panel)] border border-solid border-[color-mix(in_oklch,var(--arb-fail)_45%,transparent)] bg-[var(--surface-card)]"
        >
          <span class="text-[12.5px] text-[var(--text-title)]">
            Stop the {@worker_label} on <code class="font-[family-name:var(--font-mono)]">{@confirm_stop}</code>? Its agent
            dies where it stands; the worktree and everything committed survive.
          </span>
          <span class="ml-auto flex items-center gap-2">
            <ArbiterWeb.CoreComponents.Core.button variant="ghost" size="sm" phx-click="cancel_stop">
              Cancel
            </ArbiterWeb.CoreComponents.Core.button>
            <ArbiterWeb.CoreComponents.Core.button variant="danger" size="sm" phx-click="confirm_stop">
              Stop {@worker_label}
            </ArbiterWeb.CoreComponents.Core.button>
          </span>
        </div>

        <%!-- ── Coordinator mailbox ─────────────────────────────────────
             Unread mailbox-family mail addressed to the coordinator: the
             upward channel of `arb inbox` / `arb msg`, live. It is not a
             board column — none of it is a task sitting in a stage — but it
             is the other thing addressed to the human, so it sits under the
             board rather than on another page. --%>
        <section
          id="coordinator-mailbox"
          class="rounded-[var(--radius-panel)] border border-solid border-[var(--border-default)] bg-[var(--surface-card)]"
        >
          <div class="flex items-center justify-between gap-2 px-4 h-[var(--toolbar-height)] border-b border-solid border-[var(--border-default)] bg-[var(--arb-canvas-sunken)]">
            <h2 class="flex items-center gap-2 text-[12.5px] font-medium text-[var(--text-title)]">
              Coordinator Mailbox
              <span class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--arb-attention)]">
                {length(@coordinator_inbox)} unread
              </span>
              <span
                id="coordinator-mailbox-outstanding"
                title="Seen but not yet cleared — the triage queue"
                class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              >
                {@coordinator_outstanding_count} outstanding
              </span>
            </h2>
            <button
              type="button"
              phx-click="clear_coordinator"
              title="Soft-clear the outstanding tail — already-read mail is marked cleared (retained), unread is kept"
              class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-link)]"
            >
              clear read
            </button>
          </div>

          <div :if={@coordinator_inbox == []} id="coordinator-mailbox-empty" class="p-4">
            <ArbiterWeb.CoreComponents.Feedback.empty_state
              icon="hero-inbox"
              detail="worker completions, failures and escalations land here in real time"
            >
              Inbox clear.
            </ArbiterWeb.CoreComponents.Feedback.empty_state>
          </div>

          <ul
            :if={@coordinator_inbox != []}
            id="coordinator-mailbox-list"
            class="flex flex-col gap-2 p-3 max-h-80 overflow-y-auto"
          >
            <li
              :for={m <- @coordinator_inbox}
              class={[
                "rounded-[var(--radius-field)] border border-solid border-[var(--arb-line-strong)]",
                "border-l-[length:var(--border-accent-width)] px-3 py-2 bg-[var(--arb-panel-alt)]",
                mailbox_border(m.kind)
              ]}
            >
              <div class="flex items-baseline justify-between gap-2">
                <div class="flex items-baseline gap-2 flex-wrap min-w-0">
                  <span class="text-[10px] uppercase tracking-[0.08em] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                    {m.kind}
                  </span>
                  <span class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]">
                    from {m.from_ref || "?"}
                  </span>
                  <.link
                    :if={Message.task_ref(m)}
                    navigate={~p"/tasks/#{Message.task_ref(m)}"}
                    class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-link)]"
                  >
                    {Message.task_ref(m)}
                  </.link>
                  <span :if={m.subject} class="text-[12.5px] font-medium text-[var(--text-title)]">
                    {m.subject}
                  </span>
                </div>
                <div class="flex items-center gap-2 shrink-0">
                  <span class="text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                    {relative(m.inserted_at, @now)}
                  </span>
                  <button
                    type="button"
                    phx-click="mark_read"
                    phx-value-id={m.id}
                    class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-link)]"
                  >
                    mark read
                  </button>
                </div>
              </div>
              <p
                :if={m.body not in [nil, ""]}
                class="mt-1.5 text-[12px] whitespace-pre-wrap text-[var(--text-secondary)]"
              >
                {m.body}
              </p>
            </li>
          </ul>
        </section>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".BoardDrag">
        // Drag is a human action, and only for the moves a human decides:
        // reorder within Ready, pull out of Running, hand a Needs-you or
        // merge-queue card to another stage. Dropping INTO Running is pushed
        // to the server so it can explain itself rather than silently no-op.
        export default {
          mounted() { this.wire() },
          updated() { this.wire() },
          wire() {
            if (this.wired) return
            this.wired = true
            const el = this.el

            el.addEventListener("dragstart", (e) => {
              const card = e.target.closest("[data-card]")
              if (!card) return
              this.dragging = {id: card.dataset.card, from: card.dataset.column}
              e.dataTransfer.effectAllowed = "move"
              try { e.dataTransfer.setData("text/plain", card.dataset.card) } catch (_) {}
            })

            el.addEventListener("dragover", (e) => {
              if (this.dragging) e.preventDefault()
            })

            el.addEventListener("drop", (e) => {
              const drag = this.dragging
              this.dragging = null
              if (!drag) return
              e.preventDefault()

              const column = e.target.closest("[data-column]")
              if (!column) return
              const to = column.dataset.column

              // Reordering Ready is the one gesture the client resolves on
              // its own, because only it knows where the cursor landed.
              if (to === "ready" && drag.from === "ready") {
                const ids = Array.from(column.querySelectorAll("[data-card]"))
                  .map((n) => n.dataset.card)
                const over = e.target.closest("[data-card]")
                const rest = ids.filter((id) => id !== drag.id)
                const at = over && over.dataset.card !== drag.id
                  ? rest.indexOf(over.dataset.card)
                  : rest.length
                rest.splice(at < 0 ? rest.length : at, 0, drag.id)
                this.pushEvent("reorder_ready", {order: rest})
                return
              }

              // Everything else is reported as-is. What a landing means is
              // the server's call, including "nothing".
              this.pushEvent("drag", {id: drag.id, from: drag.from, to: to})
            })
          },
        }
      </script>
    </Layouts.app>
    """
  end

  # ---- render helpers -------------------------------------------------------

  attr :label, :string, required: true
  attr :count, :any, required: true
  attr :tone, :any, default: nil

  defp column_head(assigns) do
    assigns = assign(assigns, :hue, head_hue(assigns.tone))

    ~H"""
    <div
      class="flex items-center justify-between pb-[9px] mb-[9px] border-b border-solid"
      style={
        if(@hue,
          do: "border-color: color-mix(in oklch, #{@hue} 38%, transparent)",
          else: "border-color: var(--arb-line-soft)"
        )
      }
    >
      <span
        class="text-[10.5px] font-medium uppercase tracking-[0.1em] font-[family-name:var(--font-mono)]"
        style={"color: #{@hue || "var(--text-secondary)"}"}
      >
        {@label}
      </span>
      <span
        class="text-[10.5px] font-medium font-[family-name:var(--font-mono)]"
        style={"color: #{@hue || "var(--text-label)"}"}
      >
        {@count}
      </span>
    </div>
    """
  end

  attr :column, :string, required: true
  attr :count, :integer, required: true

  defp more(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="expand"
      phx-value-column={@column}
      class="flex items-center justify-between px-[11px] py-[9px] rounded-[var(--radius-field)] border border-dashed border-[var(--arb-line)]"
    >
      <span class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
        {@count} more
      </span>
      <span class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-link)]">
        show
      </span>
    </button>
    """
  end

  # `Forms.input`'s `icon` is interpolated, not rendered as a component, so it
  # takes finished markup. Same span `Core.icon/1` builds: the Heroicon class
  # plus an explicit box, masked to the label colour.
  defp search_icon do
    Phoenix.HTML.raw(
      ~s|<span aria-hidden="true" class="hero-magnifying-glass" | <>
        ~s|style="width: 11px; height: 11px; background-color: var(--text-label);"></span>|
    )
  end

  defp limit(expanded, column) do
    if MapSet.member?(expanded, column), do: 1_000, else: @column_limit
  end

  defp ready_accent(:next), do: "live"
  defp ready_accent(:blocked), do: "attention"
  defp ready_accent(_), do: nil

  defp merge_activity(%{mr_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp merge_activity(_card), do: "waiting on checks"

  # The foot of the Ready column, where the handoff's drop zone used to be.
  defp ready_foot(%{paused: true}, false),
    do: "scheduler not running — nothing is draining this queue"

  defp ready_foot(%{paused: true}, _), do: "scheduler paused — resume to dispatch"

  defp ready_foot(%{promote: id}, _) when is_binary(id), do: "dispatching #{id}..."

  defp ready_foot(board, _) do
    case quota_note(board.quota) do
      nil ->
        if board.slots_free > 0,
          do: "queue drains automatically",
          else: "no free worker slot"

      note ->
        note
    end
  end
end
