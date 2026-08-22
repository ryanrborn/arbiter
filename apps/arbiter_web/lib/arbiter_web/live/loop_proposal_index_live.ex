defmodule ArbiterWeb.LoopProposalIndexLive do
  @moduledoc """
  The loop-engineering proposal queue at `/loop` (Stage 2, bd-9j2g3x).

  What `arb loop analyze --propose` writes lands here for a human to read. The
  list shows one line per queued write — gist, state, and the evidence behind it
  (`Ni/Mt`: N incidents across M distinct tasks) — and the detail pane shows the
  full unified diff plus the apply / reject decision.

  Nothing on this page auto-applies, at any evidence level. `Apply` calls the
  same public domain API a human would (`Arbiter.Loop.apply_pending/2`), so the
  change leaves a normal paper-trail version attributed to the proposal id.
  `Reject` is soft: the row persists as `rejected` and keeps accumulating
  evidence, but never re-opens on its own.

  A finding below the evidence bar sits here as a `hypothesis`, showing what it
  still needs — it is deliberately not applicable until a later window
  reinforces it past the bar.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Loop

  @filters [
    {"live (proposed + hypothesis)", "live"},
    {"proposed", "proposed"},
    {"hypothesis", "hypothesis"},
    {"applied", "applied"},
    {"rejected", "rejected"},
    {"superseded", "superseded"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    # `Loop.pubsub_topic/0` carries every queue state change, including
    # fleet-wide rows with no workspace (which the `/events` stream cannot).
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Arbiter.PubSub, Loop.pubsub_topic())

    {:ok,
     socket
     |> assign(:live, connected?(socket))
     |> assign(:filter, "live")
     |> assign(:selected_id, nil)
     |> assign(:evidence_bar, Loop.evidence_bar(nil))
     # id => decided state (:applied | :rejected), for rows decided during
     # this session — kept visible and dimmed instead of vanishing the
     # instant a refresh would otherwise filter them out. See `decide/3`.
     |> assign(:decisions, %{})
     |> assign(:decision_toast, nil)
     |> refresh()}
  end

  @impl true
  def handle_event("filter", %{"state" => filter}, socket) do
    {:noreply, socket |> assign(:filter, normalize_filter(filter)) |> refresh()}
  end

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_id, id)}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, :selected_id, nil)}
  end

  def handle_event("apply", %{"id" => id}, socket) do
    case Loop.apply_pending(id, actor: "dashboard") do
      {:ok, row} ->
        {:noreply, socket |> decide(row, :applied) |> refresh()}

      # A double-click race (or a second click before the row's own apply
      # button disappears) hits the same proposal twice. The first click
      # already got what this one wants, so it stays a no-op — not an error.
      {:error, {:not_applicable, "state is applied" <> _}} ->
        {:noreply, refresh(socket)}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_message(reason)) |> refresh()}
    end
  end

  def handle_event("reject", %{"id" => id} = params, socket) do
    reason = params |> Map.get("reason", "") |> String.trim()
    opts = [actor: "dashboard"] ++ if(reason == "", do: [], else: [reason: reason])

    case Loop.reject_pending(id, opts) do
      {:ok, row} ->
        {:noreply,
         socket
         |> decide(row, :rejected)
         |> assign(:selected_id, nil)
         |> refresh()}

      # Same idempotency as apply/2 above — rejecting an already-decided row
      # is a no-op, not an error.
      {:error, {:not_applicable, "state is " <> _}} ->
        {:noreply, refresh(socket)}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_message(reason)) |> refresh()}
    end
  end

  def handle_event("dismiss_decision", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:decisions, Map.delete(socket.assigns.decisions, id))
     |> assign(:decision_toast, nil)
     |> refresh()}
  end

  @impl true
  def handle_info({:loop_proposal, _event, _id}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Records a just-made decision so `refresh/1` keeps the row in view (dimmed)
  # even once its new state falls outside the active filter, and arms the
  # undo toast that lets the operator drop it from view immediately instead
  # of waiting for the next natural refresh.
  defp decide(socket, row, state) do
    socket
    |> assign(:decisions, Map.put(socket.assigns.decisions, row.id, state))
    |> assign(:decision_toast, %{id: row.id, gist: row.gist, state: state})
  end

  defp refresh(socket) do
    rows = Loop.list_pending(state: states(socket.assigns.filter))
    rows = with_decided_rows(rows, socket.assigns.decisions)
    assign(socket, :rows, rows)
  end

  # A row just decided in this session that the active filter's fresh query
  # would otherwise have dropped (e.g. an :applied row while filtering
  # "live") is fetched and appended so it stays visible until dismissed.
  defp with_decided_rows(rows, decisions) do
    present = MapSet.new(rows, & &1.id)

    extra =
      decisions
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(present, &1))
      |> Enum.flat_map(fn id ->
        case Loop.get_pending(id) do
          {:ok, row} -> [row]
          {:error, _} -> []
        end
      end)

    rows ++ extra
  end

  defp decided?(decisions, id), do: Map.has_key?(decisions, id)

  # The `phx-change` payload is client-controlled, so a value outside the
  # select's options is normalized back to "live" rather than reaching
  # `String.to_existing_atom/1` and killing the LiveView with an ArgumentError.
  @filter_values Enum.map(@filters, &elem(&1, 1))

  defp normalize_filter(name) when is_binary(name) do
    if name in @filter_values, do: name, else: "live"
  end

  defp normalize_filter(_name), do: "live"

  defp states("live"), do: Loop.live_states()

  defp states(name) do
    case normalize_filter(name) do
      "live" -> Loop.live_states()
      valid -> [String.to_existing_atom(valid)]
    end
  end

  defp selected(rows, id), do: Enum.find(rows, &(&1.id == id))

  defp error_message(:not_found), do: "that proposal no longer exists"
  defp error_message({_code, message}) when is_binary(message), do: message
  defp error_message(other), do: "could not complete: #{inspect(other)}"

  defp state_badge(:proposed), do: "badge-warning"
  defp state_badge(:hypothesis), do: "badge-ghost"
  defp state_badge(:applied), do: "badge-success"
  defp state_badge(:rejected), do: "badge-error"
  defp state_badge(_), do: "badge-neutral"

  # Amendment D: what applying this would add to every future dispatch, not what
  # it costs to apply once. Rendered next to the evidence counts so the standing
  # price is part of the same glance as the case for paying it.
  defp context_cost(tokens) when is_integer(tokens) and tokens > 0, do: "+#{tokens}ctx"
  defp context_cost(_), do: "free"

  defp toast_verb(:applied), do: "Applied"
  defp toast_verb(:rejected), do: "Rejected"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :selected, selected(assigns.rows, assigns.selected_id))

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} quotas={@quotas}>
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <div :if={@decision_toast} class="fixed top-4 right-4 z-50 w-80 sm:w-96">
          <.toast
            id="decision-toast"
            tone="info"
            action="Undo"
            dismiss_key=""
            phx-click="dismiss_decision"
            phx-value-id={@decision_toast.id}
          >
            {toast_verb(@decision_toast.state)}:
            <span class="font-medium">{@decision_toast.gist}</span>
          </.toast>
        </div>

        <.index_header
          icon="hero-beaker"
          title="Loop proposals"
          count={length(@rows)}
          subtitle="Queued writes the loop-analysis pass proposed. Nothing applies itself — an operator decides."
        >
          <:actions>
            <div class="flex items-center gap-2">
              <.live_badge live={@live} />
              <form phx-change="filter">
                <select name="state" class="select select-sm select-bordered">
                  <option :for={{label, value} <- filters()} value={value} selected={@filter == value}>
                    {label}
                  </option>
                </select>
              </form>
            </div>
          </:actions>
        </.index_header>

        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <.empty_state :if={@rows == []} id="loop-proposals-empty" icon="hero-beaker">
              Nothing queued in this view. The evidence bar is {@evidence_bar.min_incidents} incident(s) across {@evidence_bar.min_distinct_tasks} distinct task(s) — findings below it
              wait here as hypotheses until a later window reinforces them.
            </.empty_state>

            <ul :if={@rows != []} id="loop-proposals" class="flex flex-col gap-1.5">
              <li
                :for={row <- @rows}
                data-decided={Map.get(@decisions, row.id)}
                class={[
                  "rounded-box border bg-base-100 px-3 py-2",
                  if(row.id == @selected_id,
                    do: "border-primary",
                    else: "border-base-300"
                  ),
                  decided?(@decisions, row.id) && "opacity-60"
                ]}
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0 space-y-1">
                    <p class="text-sm font-medium break-words">{row.gist}</p>
                    <div class="flex flex-wrap items-center gap-1.5 text-xs">
                      <span class={["badge badge-sm", state_badge(row.state)]}>{row.state}</span>
                      <span class="badge badge-sm badge-outline">{row.kind}</span>
                      <span class="badge badge-sm badge-outline">{row.scope}</span>
                      <span
                        class="font-mono text-base-content/60"
                        title="incidents / distinct tasks"
                      >
                        {row.evidence_count}i/{row.distinct_tasks}t
                      </span>
                      <span
                        class={[
                          "font-mono",
                          if(row.context_cost_tokens > 0,
                            do: "text-warning",
                            else: "text-base-content/40"
                          )
                        ]}
                        title="recurring context added to every dispatch if applied"
                      >
                        {context_cost(row.context_cost_tokens)}
                      </span>
                      <span :if={row.target} class="text-base-content/50 truncate">
                        {row.target}
                      </span>
                    </div>
                  </div>
                  <.button
                    phx-click="select"
                    phx-value-id={row.id}
                    class="btn btn-xs btn-ghost shrink-0"
                  >
                    Review
                  </.button>
                </div>
              </li>
            </ul>
          </div>
        </section>

        <section
          :if={@selected}
          id="loop-proposal-detail"
          class="card bg-base-200 border border-base-300 shadow-sm"
        >
          <div class="card-body p-4 gap-3">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <h2 class="font-semibold text-sm break-words">{@selected.gist}</h2>
                <p class="text-xs text-base-content/50 font-mono mt-1 break-all">
                  {@selected.id} · {@selected.fingerprint}
                </p>
              </div>
              <.button phx-click="close" class="btn btn-xs btn-ghost shrink-0">Close</.button>
            </div>

            <dl class="grid grid-cols-2 sm:grid-cols-4 gap-2 text-xs">
              <div>
                <dt class="text-base-content/50">Evidence</dt>
                <dd class="font-mono">
                  {@selected.evidence_count} incident(s) / {@selected.distinct_tasks} task(s)
                </dd>
              </div>
              <div>
                <dt class="text-base-content/50">Context cost</dt>
                <dd class={[
                  "font-mono",
                  if(@selected.context_cost_tokens > 0, do: "text-warning")
                ]}>
                  {context_cost(@selected.context_cost_tokens)}
                </dd>
              </div>
              <div>
                <dt class="text-base-content/50">Target metric</dt>
                <dd class="font-mono">{@selected.target_metric || "—"}</dd>
              </div>
              <div>
                <dt class="text-base-content/50">Baseline</dt>
                <dd class="font-mono">{@selected.baseline || "—"}</dd>
              </div>
              <div>
                <dt class="text-base-content/50">Origin</dt>
                <dd class="font-mono break-all">{@selected.origin}</dd>
              </div>
            </dl>

            <p
              :if={Loop.inapplicable_reason(@selected)}
              class="text-xs text-warning flex items-start gap-1"
            >
              <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
              <span>{Loop.inapplicable_reason(@selected)}</span>
            </p>

            <div>
              <p class="text-xs text-base-content/50 mb-1">Unified diff</p>
              <pre
                :if={@selected.diff not in [nil, ""]}
                class="text-xs bg-base-300/40 rounded-box p-3 overflow-x-auto whitespace-pre"
              ><code>{@selected.diff}</code></pre>
              <p :if={@selected.diff in [nil, ""]} class="text-xs text-base-content/60">
                No diff — this proposal carries a payload, not a patch.
              </p>
            </div>

            <div :if={@selected.payload not in [nil, %{}]}>
              <p class="text-xs text-base-content/50 mb-1">Payload</p>
              <pre class="text-xs bg-base-300/40 rounded-box p-3 overflow-x-auto"><code>{inspect(@selected.payload, pretty: true)}</code></pre>
            </div>

            <div
              :if={@selected.state not in [:applied, :rejected]}
              class="flex flex-wrap items-end gap-2 border-t border-base-300 pt-3"
            >
              <.button
                :if={Loop.applicable?(@selected)}
                phx-click="apply"
                phx-value-id={@selected.id}
                variant="primary"
                class="btn btn-sm btn-primary"
              >
                <.icon name="hero-check" class="size-4" /> Apply
              </.button>

              <%!-- The id rides on `phx-value-id` rather than a hidden input
              named "id", which would override the form element's own DOM id. --%>
              <form
                phx-submit="reject"
                phx-value-id={@selected.id}
                class="flex items-end gap-2 grow"
              >
                <input
                  type="text"
                  name="reason"
                  placeholder="reason (optional)"
                  class="input input-sm input-bordered grow"
                />
                <button type="submit" class="btn btn-sm btn-ghost">Reject</button>
              </form>
            </div>

            <p :if={@selected.rejection_reason} class="text-xs text-base-content/60">
              Rejected: {@selected.rejection_reason}
            </p>
          </div>
        </section>

        <.back_link />
      </div>
    </Layouts.app>
    """
  end

  defp filters, do: @filters
end
