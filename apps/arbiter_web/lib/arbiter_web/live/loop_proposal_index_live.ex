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
    {"Live", "live"},
    {"Proposed", "proposed"},
    {"Hypothesis", "hypothesis"},
    {"Applied", "applied"},
    {"Rejected", "rejected"},
    {"Superseded", "superseded"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    # `Loop.pubsub_topic/0` carries every queue state change, including
    # fleet-wide rows with no workspace (which the `/events` stream cannot).
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Arbiter.PubSub, Loop.pubsub_topic())

    {:ok,
     socket
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
  def handle_event("filter", %{"tab" => filter}, socket) do
    # A decided row is only kept visible because it belongs to the filter it
    # was decided under (see `with_decided_rows/2`); switching filters means
    # a fresh query, so any decisions from the old view are dropped along
    # with it rather than leaking into whichever filter comes next.
    {:noreply,
     socket
     |> assign(:filter, normalize_filter(filter))
     |> assign(:decisions, %{})
     |> assign(:decision_toast, nil)
     |> refresh()}
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
      # button disappears) hits the same proposal twice.
      {:error, {:not_applicable, reason}} ->
        {:noreply, handle_not_applicable(socket, id, :applied, reason)}

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
      {:error, {:not_applicable, reason}} ->
        {:noreply, handle_not_applicable(socket, id, [:applied, :rejected], reason)}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_message(reason)) |> refresh()}
    end
  end

  # Clears every decision from this session, not just the one whose toast is
  # showing — `:decision_toast` only ever shows the most recent decision, but
  # `:decisions` accumulates, so a per-id delete would leave earlier rows
  # dimmed forever with no way to dismiss them. This control only hides
  # decided rows from view; it never reverts the underlying apply/reject.
  def handle_event("dismiss_decision", _params, socket) do
    {:noreply,
     socket
     |> assign(:decisions, %{})
     |> assign(:decision_toast, nil)
     |> refresh()}
  end

  @impl true
  def handle_info({:loop_proposal, _event, _id}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Records a just-made decision so `refresh/1` keeps the row in view (dimmed)
  # even once its new state falls outside the active filter, and arms the
  # dismiss toast that lets the operator drop decided rows from view
  # immediately instead of waiting for the next natural refresh. This never
  # reverts the write itself — see the `dismiss_decision` handler.
  defp decide(socket, row, state) do
    socket
    |> assign(:decisions, Map.put(socket.assigns.decisions, row.id, state))
    |> assign(:decision_toast, %{id: row.id, gist: row.gist, state: state})
  end

  # Re-reads the proposal rather than trusting the domain's error message
  # wording: `inapplicable_reason/1`'s prose is owned by `Arbiter.Loop`, not
  # a stable contract this LiveView should pattern-match on. If the row's
  # actual state already matches what this action wanted, the refusal was
  # just a double-click race and stays a no-op; otherwise it's a real
  # refusal and gets surfaced.
  defp handle_not_applicable(socket, id, expected_state, reason) do
    with {:ok, row} <- Loop.get_pending(id),
         true <- already_decided_as?(row.state, expected_state) do
      refresh(socket)
    else
      _ -> socket |> put_flash(:error, reason) |> refresh()
    end
  end

  defp already_decided_as?(state, expected) when is_list(expected), do: state in expected
  defp already_decided_as?(state, expected), do: state == expected

  defp refresh(socket) do
    rows = Loop.list_pending(state: states(socket.assigns.filter))
    rows = with_decided_rows(rows, socket.assigns.decisions)
    assign(socket, :rows, rows)
  end

  # A row just decided in this session that the active filter's fresh query
  # would otherwise have dropped (e.g. an :applied row while filtering
  # "live") is fetched and appended so it stays visible until dismissed.
  # Merged back in by `created_at` (descending, matching `list_pending/1`)
  # rather than tacked on at the end, so it stays where it was instead of
  # jumping to the bottom of the list.
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

    (rows ++ extra) |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  defp decided?(decisions, id), do: Map.has_key?(decisions, id)

  # The `phx-click` payload is client-controlled, so a value outside the
  # tabs' options is normalized back to "live" rather than reaching
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

  # Amendment D: what applying this would add to every future dispatch, not what
  # it costs to apply once. Rendered next to the evidence counts so the standing
  # price is part of the same glance as the case for paying it.
  defp context_cost(tokens) when is_integer(tokens) and tokens > 0, do: "+#{tokens}ctx"
  defp context_cost(_), do: "free"

  defp toast_verb(:applied), do: "Applied"
  defp toast_verb(:rejected), do: "Rejected"

  defp filter_tabs, do: Enum.map(@filters, fn {label, value} -> %{label: label, value: value} end)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :selected, selected(assigns.rows, assigns.selected_id))

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
        <div :if={@decision_toast} class="fixed top-24 right-4 z-50 w-80 sm:w-96">
          <ArbiterWeb.CoreComponents.Feedback.toast
            id="decision-toast"
            tone="info"
            action="Dismiss"
            dismiss_key=""
            phx-click="dismiss_decision"
          >
            {toast_verb(@decision_toast.state)}:
            <span class="font-medium">{@decision_toast.gist}</span>
          </ArbiterWeb.CoreComponents.Feedback.toast>
        </div>

        <ArbiterWeb.CoreComponents.Domain.index_header
          icon="hero-beaker"
          title="Loop proposals"
          count={length(@rows)}
          subtitle="Queued writes the loop-analysis pass proposed. Nothing applies itself — an operator decides."
        >
          <:actions>
            <div class="flex items-center gap-2">
              <ArbiterWeb.CoreComponents.Feedback.live_badge live={@live} />
              <ArbiterWeb.CoreComponents.Navigation.filter_tabs
                tabs={filter_tabs()}
                active={@filter}
                event="filter"
              />
            </div>
          </:actions>
        </ArbiterWeb.CoreComponents.Domain.index_header>

        <ArbiterWeb.CoreComponents.Core.panel>
          <div :if={@rows == []} id="loop-proposals-empty">
            <ArbiterWeb.CoreComponents.Feedback.empty_state icon="hero-beaker">
              Nothing queued in this view. The evidence bar is {@evidence_bar.min_incidents} incident(s) across {@evidence_bar.min_distinct_tasks} distinct task(s) — findings below it
              wait here as hypotheses until a later window reinforces them.
            </ArbiterWeb.CoreComponents.Feedback.empty_state>
          </div>

          <ul :if={@rows != []} id="loop-proposals" class="flex flex-col gap-1.5">
            <li
              :for={row <- @rows}
              data-decided={Map.get(@decisions, row.id)}
              class={[
                "rounded-[var(--radius-field)] border border-solid px-3 py-2",
                "bg-[var(--surface-card)]",
                if(row.id == @selected_id,
                  do: "border-[var(--accent-primary)]",
                  else: "border-[var(--border-default)]"
                ),
                decided?(@decisions, row.id) && "opacity-60"
              ]}
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0 space-y-1">
                  <p class="text-[12.5px] font-medium break-words text-[var(--text-title)]">
                    {row.gist}
                  </p>
                  <div class="flex flex-wrap items-center gap-1.5 text-xs">
                    <.status_chip status={row.state} />
                    <.type_tag type={row.kind} />
                    <.type_tag type={row.scope} />
                    <span
                      class="font-mono text-[11px] text-[var(--text-label)]"
                      title="incidents / distinct tasks"
                    >
                      {row.evidence_count}i/{row.distinct_tasks}t
                    </span>
                    <span
                      class={[
                        "font-mono text-[11px]",
                        if(row.context_cost_tokens > 0,
                          do: "text-[var(--arb-attention)]",
                          else: "text-[var(--text-label)]"
                        )
                      ]}
                      title="recurring context added to every dispatch if applied"
                    >
                      {context_cost(row.context_cost_tokens)}
                    </span>
                    <span :if={row.target} class="text-[11px] text-[var(--text-label)] truncate">
                      {row.target}
                    </span>
                  </div>
                </div>
                <ArbiterWeb.CoreComponents.Core.button
                  phx-click="select"
                  phx-value-id={row.id}
                  variant="ghost"
                  size="sm"
                  class="shrink-0"
                >
                  Review
                </ArbiterWeb.CoreComponents.Core.button>
              </div>
            </li>
          </ul>
        </ArbiterWeb.CoreComponents.Core.panel>

        <ArbiterWeb.CoreComponents.Core.panel :if={@selected} title={@selected.gist}>
          <:actions>
            <ArbiterWeb.CoreComponents.Core.button phx-click="close" variant="ghost" size="sm">
              Close
            </ArbiterWeb.CoreComponents.Core.button>
          </:actions>

          <div class="space-y-3">
            <p class="text-[11px] text-[var(--text-label)] font-mono break-all">
              {@selected.id} · {@selected.fingerprint}
            </p>

            <dl class="grid grid-cols-2 sm:grid-cols-4 gap-2 text-xs">
              <div>
                <dt class="text-[var(--text-label)]">Evidence</dt>
                <dd class="font-mono text-[var(--text-secondary)]">
                  {@selected.evidence_count} incident(s) / {@selected.distinct_tasks} task(s)
                </dd>
              </div>
              <div>
                <dt class="text-[var(--text-label)]">Context cost</dt>
                <dd class={[
                  "font-mono",
                  if(@selected.context_cost_tokens > 0,
                    do: "text-[var(--arb-attention)]",
                    else: "text-[var(--text-secondary)]"
                  )
                ]}>
                  {context_cost(@selected.context_cost_tokens)}
                </dd>
              </div>
              <div>
                <dt class="text-[var(--text-label)]">Target metric</dt>
                <dd class="font-mono text-[var(--text-secondary)]">
                  {@selected.target_metric || "—"}
                </dd>
              </div>
              <div>
                <dt class="text-[var(--text-label)]">Baseline</dt>
                <dd class="font-mono text-[var(--text-secondary)]">{@selected.baseline || "—"}</dd>
              </div>
              <div>
                <dt class="text-[var(--text-label)]">Origin</dt>
                <dd class="font-mono break-all text-[var(--text-secondary)]">{@selected.origin}</dd>
              </div>
            </dl>

            <p
              :if={Loop.inapplicable_reason(@selected)}
              class="text-xs text-[var(--arb-attention)] flex items-start gap-1"
            >
              <ArbiterWeb.CoreComponents.Core.icon name="hero-exclamation-triangle" size={16} />
              <span>{Loop.inapplicable_reason(@selected)}</span>
            </p>

            <div>
              <p class="text-xs text-[var(--text-label)] mb-1">Unified diff</p>
              <pre
                :if={@selected.diff not in [nil, ""]}
                class="text-xs bg-[var(--arb-canvas-sunken)] rounded-[var(--radius-field)] p-3 overflow-x-auto whitespace-pre"
              ><code>{@selected.diff}</code></pre>
              <p :if={@selected.diff in [nil, ""]} class="text-xs text-[var(--text-secondary)]">
                No diff — this proposal carries a payload, not a patch.
              </p>
            </div>

            <div :if={@selected.payload not in [nil, %{}]}>
              <p class="text-xs text-[var(--text-label)] mb-1">Payload</p>
              <pre class="text-xs bg-[var(--arb-canvas-sunken)] rounded-[var(--radius-field)] p-3 overflow-x-auto"><code>{inspect(@selected.payload, pretty: true)}</code></pre>
            </div>

            <div
              :if={@selected.state not in [:applied, :rejected]}
              class="flex flex-wrap items-end gap-2 border-t border-[var(--border-default)] pt-3"
            >
              <ArbiterWeb.CoreComponents.Core.button
                :if={Loop.applicable?(@selected)}
                phx-click="apply"
                phx-value-id={@selected.id}
                variant="primary"
                size="sm"
              >
                <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-check" size={16} /></:icon>
                Apply
              </ArbiterWeb.CoreComponents.Core.button>

              <%!-- The id rides on `phx-value-id` rather than a hidden input
              named "id", which would override the form element's own DOM id. --%>
              <form
                phx-submit="reject"
                phx-value-id={@selected.id}
                class="flex items-end gap-2 grow"
              >
                <ArbiterWeb.CoreComponents.Forms.input
                  name="reason"
                  placeholder="reason (optional)"
                  size="sm"
                  mono={false}
                  class="grow"
                />
                <ArbiterWeb.CoreComponents.Core.button type="submit" variant="ghost" size="sm">
                  Reject
                </ArbiterWeb.CoreComponents.Core.button>
              </form>
            </div>

            <p :if={@selected.rejection_reason} class="text-xs text-[var(--text-secondary)]">
              Rejected: {@selected.rejection_reason}
            </p>
          </div>
        </ArbiterWeb.CoreComponents.Core.panel>

        <ArbiterWeb.CoreComponents.Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end
end
