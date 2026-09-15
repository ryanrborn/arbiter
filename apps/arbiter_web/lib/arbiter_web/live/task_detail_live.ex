defmodule ArbiterWeb.TaskDetailLive do
  @moduledoc """
  Per-task detail view at `/tasks/:id` — combines the resource record,
  any active worker, dependency edges, and recent audit-log versions
  into one page. Re-renders on `:task_lifecycle` and `:worker_lifecycle`
  events so the page stays current.

  Four operator actions live here — three behind their own hand-rolled modal
  (the `WorkspaceDetailLive` pattern), one a bare button — all writing through
  the same domain calls the CLI/MCP use:

    * **Edit** — the fields an operator authors: title, status (open ⇄
      in_progress), priority, difficulty, type, assignee, target branch,
      description and acceptance. Deliberately NOT editable here: `notes` /
      `qa_notes` / `deployment_notes` / `pr_body` (worker-authored
      deliverables — a stray dashboard edit would clobber a run's output),
      and the tracker/PR linkage fields (`tracker_ref`, `pr_ref`,
      `source_pr`), which are owned by the tracker and merge-queue
      machinery. Those stay `arb update` territory.
    * **Close** — the `:close` action, with an optional reason.
    * **Dispatch** — `Arbiter.Worker.Dispatch.dispatch/2`, offered only when
      no worker is attached and the task is open. It spends real API
      credits, so the modal requires an explicit acknowledgement checkbox
      before the server will call dispatch at all. Dispatch runs in
      `start_async/3`, not inline: it shells out to the provider CLI for the
      auth preflight, gates on quota, provisions a worktree and spawns the
      agent, which is far too long to hold the LiveView process for.
    * **Move to Ready** — the `:promote_to_ready` action (bd-b5wyjd), offered
      only while the task is unrefined and open. It flips `refined` and does
      nothing else: the card leaves the board's Backlog column and joins the
      Ready queue on the queue's own terms.

  ## Why promotion has no modal for the common case, and one gate

  The other three actions each destroy or spend something, so each asks first.
  Promotion spends nothing, and Ready is not a commitment — the scheduler still
  decides on the merits. So the common case is one click, and no confirmation
  is one fewer reason to leave work unrefined. It *is* one-way for now:
  `refined` is not on any action's accept list but this one's, so there is no
  de-refine path from the UI, CLI, REST or MCP. A demote path is a separate
  decision.

  Description and most other fields are deliberately *not* gated on being
  filled in — Backlog is a refinement surface, not a completeness checklist,
  and the operator reading the ticket is a better judge of "refined enough"
  than a field count.

  Acceptance criteria are the one exception (bd-7mbrlg): the follow-up-rate
  investigation found most issues carry none, which leaves ReviewGate's
  criteria guards with nothing to score. A `bug`/`feature`/`chore` with blank
  `acceptance` is refused by `:promote_to_ready` unless a waiver reason is
  given — `task`/`decision`/`epic` are exempt, and D0 (trivial) work is
  auto-waived. The plain click still handles every case that doesn't need a
  waiver; only a refusal opens the waiver modal below.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Agents
  alias Arbiter.Mergers
  alias Arbiter.Messages.Message
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Skills.Selection
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.DependencyGraph
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Issue.Version
  alias Arbiter.Tasks.ParentRefs
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers
  alias Arbiter.Usage.Budget
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Workers.Run
  alias ArbiterWeb.TaskForm
  require Ash.Query
  require Logger

  @tasks_topic "tasks"
  @workers_topic "workers"

  # The expanded transcript of a *running* run cannot come from
  # `Run.output_lines`: that column is written exactly twice — `[]` at run
  # start and the captured tail at run finish — so mid-run it is always
  # empty. While a running row is open the page follows that run's own
  # `worker:<task_id>` topic, the same feed `/workers/:id` renders, and keeps
  # the same 500-line tail the worker itself caps at.
  @live_line_cap 500
  @version_limit 20

  # The MESSAGES rail is a rail, not an archive: the newest slice is what an
  # operator reads, and a long-lived task can accumulate hundreds of rows.
  @message_limit 50

  # ---- relationship editing (bd-dmabmg) -----------------------------------

  # The add modal is phrased as a sentence *from this issue's point of view*
  # (design bd-dgh2xv §3.3): the operator picks "is blocked by", not
  # `(from, type, to)`. Each phrase carries everything needed to turn that
  # sentence back into an edge:
  #
  #   * `:type`   — the `Dependency` type written. Note that **both** blocking
  #     phrasings write `:depends_on` (§2.7): `:blocks` is its exact inverse
  #     and two ways to write one fact is how operators produce contradictory
  #     duplicates. Pre-existing `:blocks` rows still render and still remove.
  #   * `:invert` — false means `from` is this issue, true means `from` is the
  #     target. That is the whole from/to convention, stated once, here.
  #   * `:group`  — the `Dependencies.for_issue/1` group this phrase's edges
  #     land in, which is what the duplicate pre-check consults.
  @relationship_phrases [
    %{
      key: "is_blocked_by",
      label: "is blocked by",
      type: :depends_on,
      invert: false,
      group: :blocked_by
    },
    %{key: "blocks", label: "blocks", type: :depends_on, invert: true, group: :blocks},
    %{
      key: "is_parent_of",
      label: "is the parent of",
      type: :parent_of,
      invert: false,
      group: :children
    },
    %{
      key: "is_child_of",
      label: "is a child of",
      type: :parent_of,
      invert: true,
      group: :parents
    },
    %{
      key: "relates_to",
      label: "relates to",
      type: :relates_to,
      invert: false,
      group: :relates_to
    },
    %{
      key: "discovered_from",
      label: "was discovered from",
      type: :discovered_from,
      invert: false,
      group: :discovered_from
    },
    %{
      key: "conflicts_with",
      label: "conflicts with",
      type: :conflicts_with,
      invert: false,
      group: :conflicts_with
    }
  ]

  @default_relationship_phrase "is_blocked_by"

  # Ten rows is what fits under the search box without scrolling. The SQL
  # `LIKE` pulls a wider slice first because "open above closed" (§3.3) is an
  # Elixir-side sort — ranking after a `LIMIT 10` would rank whatever ten rows
  # the b-tree happened to hand back.
  @relationship_candidate_limit 10
  @relationship_search_slice 50

  @impl true
  def mount(%{"id" => task_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
    end

    {:ok,
     socket
     |> assign(:task_id, task_id)
     |> assign(:parent_refs, [])
     |> assign(:issue_label, "issue")
     |> assign(:worker_label, "worker")
     |> assign(:workspace_label, "workspace")
     |> assign(:rig_label, "repo")
     |> assign(:edit_modal, false)
     |> assign(:edit_error, nil)
     |> assign(:edit_params, %{})
     |> assign(:close_modal, false)
     |> assign(:close_error, nil)
     |> assign(:close_params, %{})
     |> assign(:promote_waiver_modal, false)
     |> assign(:promote_waiver_error, nil)
     |> assign(:promote_waiver_params, %{})
     |> assign(:dispatch_modal, false)
     |> assign(:dispatch_error, nil)
     |> assign(:dispatch_params, %{})
     |> assign(:dispatching, false)
     |> assign(:relationship_phrase_options, relationship_phrase_options())
     |> reset_relationship_form()
     |> assign(:rel_modal, false)
     |> assign(:rel_remove_entry, nil)
     |> assign(:rel_remove_warnings, [])
     |> assign(:rel_remove_error, nil)
     |> assign(:repo_options, [])
     |> assign(:repo_assignment_options, [])
     |> assign(:priority_options, TaskForm.priority_options())
     |> assign(:difficulty_options, TaskForm.difficulty_options())
     |> assign(:issue_type_options, TaskForm.issue_type_options())
     |> assign(:provider_options, provider_options())
     |> assign(:run_filter, "all")
     |> assign(:expanded_run, nil)
     |> assign(:live_run_id, nil)
     |> assign(:live_run_topic, nil)
     |> assign(:live_run_lines, [])
     |> assign(:messages, [])
     |> assign(:messages_topic, nil)
     |> assign(:expanded_messages, MapSet.new())
     |> refresh_all()}
  end

  @impl true
  def handle_info({:task_lifecycle, _event, %{id: id}}, %{assigns: %{task_id: id}} = socket) do
    {:noreply, refresh_all(socket)}
  end

  # Lifecycle events for other tasks can still affect this page's
  # dependency section (status of a target changed), so refresh on any.
  def handle_info({:task_lifecycle, _event, _other}, socket) do
    {:noreply, refresh_deps(socket)}
  end

  # The roster covers every run of this issue, not just the one dispatched
  # under its bare id — a reviewer broadcasts as `<id>#review`, a revise round
  # as `<id>#review#impl2`. Matching the bare id alone left those rows frozen
  # at whatever the last full page load saw. `base_task_id/1` strips any
  # synthetic suffix back to the issue, so each of them lands here.
  def handle_info({:worker_lifecycle, _event, %{task_id: worker_task_id}}, socket)
      when is_binary(worker_task_id) do
    if ReviewGate.base_task_id(worker_task_id) == socket.assigns.task_id do
      {:noreply,
       socket
       |> refresh_worker()
       |> refresh_runs()
       |> refresh_review_rounds()
       |> refresh_budget()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:worker_lifecycle, _event, _snap}, socket), do: {:noreply, socket}

  # Output for the run whose row is open, straight into its transcript — no
  # DB read, no GenServer hop. Runs other than the followed one broadcast on
  # topics this page never subscribed to, so the guard is belt-and-braces.
  def handle_info({:worker_output, worker_task_id, line}, socket)
      when is_binary(worker_task_id) and is_binary(line) do
    if socket.assigns[:live_run_topic] == output_topic(worker_task_id) do
      lines = Enum.take((socket.assigns.live_run_lines || []) ++ [line], -@live_line_cap)
      {:noreply, assign(socket, :live_run_lines, lines)}
    else
      {:noreply, socket}
    end
  end

  # Messages broadcast on the *workspace* topic (there is no per-task one), so
  # every message in this issue's workspace lands here. Refetch only when the
  # row actually concerns this issue — otherwise a chatty workspace would run a
  # query per unrelated message.
  def handle_info({:new_message, message}, socket) do
    if about_this_task?(message, socket.assigns.task_id) do
      {:noreply, refresh_messages(socket)}
    else
      {:noreply, socket}
    end
  end

  # Read/clear state is shown here, so a transition elsewhere (CLI, MCP, the
  # coordinator drawer) has to repaint these rows too.
  def handle_info({:message_read, message}, socket) do
    if about_this_task?(message, socket.assigns.task_id) do
      {:noreply, refresh_messages(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:mailbox_cleared, _workspace_id}, socket) do
    {:noreply, refresh_messages(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ---- run roster ----
  #
  # The roster absorbs the run index for this issue: filtering by role and
  # opening a transcript are socket-local state, never a navigation.

  @impl true
  def handle_event("filter_runs", %{"tab" => tab}, socket) do
    {:noreply,
     socket
     |> assign(:run_filter, tab)
     |> derive_roster()}
  end

  # Clicking the open row closes it — the chevron is a disclosure, not a link.
  def handle_event("toggle_run", %{"run" => run_id}, socket) do
    expanded = if socket.assigns.expanded_run == run_id, do: nil, else: run_id

    {:noreply,
     socket
     |> assign(:expanded_run, expanded)
     |> resync_live_run()}
  end

  # ---- messages ----
  #
  # A long body is clamped to a few lines so one verbose escalation can't push
  # the rest of the rail off-screen. Expansion is socket-local: it is a
  # disclosure, never a read acknowledgement.
  def handle_event("toggle_message", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_messages

    expanded =
      if MapSet.member?(expanded, id) do
        MapSet.delete(expanded, id)
      else
        MapSet.put(expanded, id)
      end

    {:noreply, assign(socket, :expanded_messages, expanded)}
  end

  # ---- acceptance criteria ----
  #
  # The checkboxes are the issue's own markdown: ticking one rewrites that
  # line's `- [ ]` marker in place and writes it back through the same
  # `Issue` update the CLI uses, so `arb show` reads the same state. Every
  # other line of the acceptance text is left byte-for-byte alone.

  def handle_event("toggle_criterion", %{"criterion" => index}, socket) do
    with %Issue{acceptance: acceptance} = task when is_binary(acceptance) <- socket.assigns.task,
         {index, ""} <- Integer.parse(index),
         {:ok, rewritten} <- toggle_criterion(acceptance, index) do
      case Ash.update(task, %{acceptance: rewritten}) do
        {:ok, _updated} ->
          {:noreply, refresh_all(socket)}

        {:error, err} ->
          {:noreply, put_flash(socket, :error, TaskForm.error_message(err))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # ---- edit ----

  def handle_event("open_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(edit_modal: true, edit_error: nil, edit_params: %{})
     |> assign(:repo_assignment_options, repo_assignment_options(socket.assigns.task))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, edit_modal: false, edit_error: nil, edit_params: %{})}
  end

  def handle_event("save_edit", %{"task" => params}, socket) do
    task = socket.assigns.task

    # Keep what was typed so a rejected save re-renders it rather than
    # snapping every field back to the persisted record.
    socket = assign(socket, :edit_params, params)

    with %Issue{} <- task,
         {:ok, title} <- fetch_title(params),
         {:ok, priority} <- fetch_priority(params, task.priority),
         {:ok, difficulty} <- fetch_difficulty(params) do
      attrs =
        %{
          title: title,
          priority: priority,
          difficulty: difficulty,
          description: TaskForm.trimmed(params["description"]),
          acceptance: TaskForm.trimmed(params["acceptance"]),
          assignee: TaskForm.trimmed(params["assignee"]),
          target_branch: TaskForm.trimmed(params["target_branch"]),
          repo: TaskForm.trimmed(params["repo"])
        }
        |> put_given(:status, params["status"])
        |> put_given(:issue_type, params["issue_type"])

      case Ash.update(task, attrs) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> assign(edit_modal: false, edit_error: nil, edit_params: %{})
           |> put_flash(:info, "Updated #{socket.assigns.issue_label}.")
           |> refresh_all()}

        {:error, err} ->
          {:noreply, assign(socket, :edit_error, TaskForm.error_message(err))}
      end
    else
      {:error, message} -> {:noreply, assign(socket, :edit_error, message)}
      _ -> {:noreply, socket}
    end
  end

  # ---- close ----

  def handle_event("open_close", _params, socket) do
    {:noreply, assign(socket, close_modal: true, close_error: nil, close_params: %{})}
  end

  def handle_event("cancel_close", _params, socket) do
    {:noreply, assign(socket, close_modal: false, close_error: nil, close_params: %{})}
  end

  def handle_event("close_task", params, socket) do
    close_params = Map.get(params, "close", %{})
    reason = close_params |> Map.get("reason") |> TaskForm.trimmed()
    socket = assign(socket, :close_params, close_params)

    case socket.assigns.task do
      %Issue{} = task ->
        case Ash.update(task, %{reason: reason}, action: :close) do
          {:ok, _closed} ->
            {:noreply,
             socket
             |> assign(close_modal: false, close_error: nil, close_params: %{})
             |> put_flash(:info, "Closed #{socket.assigns.issue_label}.")
             |> refresh_all()}

          {:error, err} ->
            {:noreply, assign(socket, :close_error, TaskForm.error_message(err))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ---- promote to Ready ----
  #
  # One write, no modal — UNLESS `:promote_to_ready` refuses for lack of
  # acceptance criteria (bd-7mbrlg), in which case the waiver modal below
  # opens instead of just flashing an error, since a waiver reason is the one
  # way to actually get past that refusal. Otherwise idempotent: a
  # double-click is harmless, and the button disappears on the re-render.

  def handle_event("promote_to_ready", _params, socket) do
    case socket.assigns.task do
      %Issue{refined: true} ->
        {:noreply, socket}

      %Issue{} = task ->
        case Ash.update(task, %{}, action: :promote_to_ready) do
          {:ok, _promoted} ->
            {:noreply,
             socket
             |> put_flash(:info, "Moved to Ready — the scheduler owns it now.")
             |> refresh_all()}

          {:error, err} ->
            if acceptance_criteria_error?(err) do
              {:noreply,
               assign(socket,
                 promote_waiver_modal: true,
                 promote_waiver_error: TaskForm.error_message(err),
                 promote_waiver_params: %{}
               )}
            else
              {:noreply, put_flash(socket, :error, TaskForm.error_message(err))}
            end
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_promote_waiver", _params, socket) do
    {:noreply,
     assign(socket,
       promote_waiver_modal: false,
       promote_waiver_error: nil,
       promote_waiver_params: %{}
     )}
  end

  def handle_event("promote_with_waiver", params, socket) do
    waiver_params = Map.get(params, "waiver", %{})
    reason = waiver_params |> Map.get("reason") |> TaskForm.trimmed()
    socket = assign(socket, :promote_waiver_params, waiver_params)

    case socket.assigns.task do
      %Issue{} = task when is_binary(reason) ->
        case Ash.update(task, %{acceptance_waived: reason}, action: :promote_to_ready) do
          {:ok, _promoted} ->
            {:noreply,
             socket
             |> assign(promote_waiver_modal: false, promote_waiver_error: nil)
             |> put_flash(:info, "Moved to Ready with a waiver — the scheduler owns it now.")
             |> refresh_all()}

          {:error, err} ->
            {:noreply, assign(socket, :promote_waiver_error, TaskForm.error_message(err))}
        end

      _ ->
        {:noreply,
         assign(socket, :promote_waiver_error, "Give a reason for waiving acceptance criteria.")}
    end
  end

  # ---- dispatch ----
  #
  # Dispatch spends real API credits, so the modal is the confirmation step:
  # the operator picks a provider + repo AND ticks the acknowledgement. An
  # un-acknowledged submit is refused here, before `Dispatch.dispatch/2` is
  # ever called.

  def handle_event("open_dispatch", _params, socket) do
    {:noreply,
     socket
     |> assign(dispatch_modal: true, dispatch_error: nil, dispatch_params: %{})
     |> assign(:repo_options, repo_options(socket.assigns.task))}
  end

  def handle_event("cancel_dispatch", _params, socket) do
    {:noreply, assign(socket, dispatch_modal: false, dispatch_error: nil, dispatch_params: %{})}
  end

  # A second submit while one is in flight would spend credits twice.
  def handle_event("dispatch", _params, %{assigns: %{dispatching: true}} = socket) do
    {:noreply, socket}
  end

  # `Dispatch.dispatch/2` shells out to the provider CLI for the auth preflight,
  # gates on quota, provisions a worktree and spawns the agent — seconds to tens
  # of seconds. Blocking the LiveView process on that would stall queued
  # lifecycle messages and risk the client giving up mid-dispatch, leaving the
  # operator unsure whether credits were spent. So it runs in `start_async/3`
  # with the modal held open in a pending state until the result lands.
  def handle_event("dispatch", %{"dispatch" => params}, socket) do
    socket = assign(socket, :dispatch_params, params)
    task_id = socket.assigns.task_id

    with :ok <- ensure_acknowledged(params["acknowledge"]),
         {:ok, opts} <- dispatch_opts(params) do
      {:noreply,
       socket
       |> assign(dispatching: true, dispatch_error: nil)
       |> start_async(:dispatch, fn -> Dispatch.dispatch(task_id, opts) end)}
    else
      {:error, message} -> {:noreply, assign(socket, :dispatch_error, message)}
    end
  end

  # ---- relationships: add / remove (bd-dmabmg) ----

  def handle_event("open_relationship_modal", _params, socket) do
    {:noreply, socket |> reset_relationship_form() |> assign(:rel_modal, true)}
  end

  def handle_event("cancel_relationship_modal", _params, socket) do
    {:noreply, assign(socket, :rel_modal, false)}
  end

  # One `phx-change` for the whole modal: the phrase select, the typeahead box
  # and the note all re-enter here, so the candidate list, its pre-checks and
  # the warnings are always computed from one consistent set of inputs.
  def handle_event("relationship_change", %{"rel" => params}, socket) do
    {:noreply, apply_relationship_params(socket, params)}
  end

  def handle_event("select_relationship_target", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:rel_target, relationship_candidate(socket, id))
     |> clear_relationship_error()
     |> refresh_relationship_warnings()}
  end

  def handle_event("clear_relationship_target", _params, socket) do
    {:noreply,
     socket
     |> assign(:rel_target, nil)
     |> clear_relationship_error()
     |> refresh_relationship_warnings()}
  end

  def handle_event("add_relationship", %{"rel" => params}, socket) do
    socket = apply_relationship_params(socket, params)

    case {socket.assigns.task, chosen_relationship_target_id(socket)} do
      {%Issue{} = task, target_id} when target_id != "" ->
        {:noreply, write_relationship(socket, task, target_id)}

      {%Issue{}, _blank} ->
        {:noreply,
         assign(
           socket,
           :rel_error,
           "Search for an #{socket.assigns.issue_label} to link, or paste its id."
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("open_remove_edge", %{"edge" => edge_id}, socket) do
    case find_relationship_entry(socket.assigns.relationship_groups, edge_id) do
      nil ->
        {:noreply, socket}

      entry ->
        {:noreply,
         socket
         |> assign(:rel_remove_entry, entry)
         |> assign(:rel_remove_error, nil)
         |> assign(:rel_remove_warnings, relationship_remove_warnings(entry))}
    end
  end

  def handle_event("cancel_remove_edge", _params, socket) do
    {:noreply, assign(socket, rel_remove_entry: nil, rel_remove_error: nil)}
  end

  # `Dependencies.remove/3` normalises "matched nothing" to `{:ok, 0}` (§4.4),
  # so an edge a second tab already removed is a success here, not an error —
  # the operator's intent ("this edge should not exist") is satisfied either
  # way, and `refresh_all/1` repaints the panel without it.
  def handle_event(
        "remove_edge",
        _params,
        %{assigns: %{rel_remove_entry: %{edge: edge}}} = socket
      ) do
    case Dependencies.remove(edge.from_issue_id, edge.to_issue_id, edge.type) do
      {:ok, _count} ->
        {:noreply,
         socket
         |> assign(rel_remove_entry: nil, rel_remove_error: nil, rel_remove_warnings: [])
         |> put_flash(:info, "Removed the relationship.")
         |> refresh_all()}

      {:error, reason} ->
        {:noreply, assign(socket, :rel_remove_error, relationship_error_message(reason))}
    end
  end

  def handle_event("remove_edge", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:dispatch, {:ok, {:ok, _result}}, socket) do
    {:noreply,
     socket
     |> assign(dispatching: false, dispatch_modal: false)
     |> assign(dispatch_error: nil, dispatch_params: %{})
     |> put_flash(:info, "Dispatched a #{socket.assigns.worker_label}.")
     |> refresh_all()}
  end

  def handle_async(:dispatch, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:dispatching, false)
     |> assign(:dispatch_error, "Dispatch failed: #{dispatch_failure(reason)}")
     |> refresh_all()}
  end

  # The task/worktree may have been left half-provisioned, so refresh rather
  # than assuming nothing happened.
  def handle_async(:dispatch, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:dispatching, false)
     |> assign(:dispatch_error, "Dispatch crashed: #{inspect(reason)}")
     |> refresh_all()}
  end

  # ---- form helpers ----

  defp fetch_title(params) do
    case TaskForm.trimmed(params["title"]) do
      nil -> {:error, "Title can't be empty."}
      title -> {:ok, title}
    end
  end

  defp fetch_priority(params, current) do
    case TaskForm.parse_int(params["priority"]) do
      {:ok, nil} -> {:ok, current}
      {:ok, priority} -> {:ok, priority}
      :error -> {:error, "Priority must be a number 0–4."}
    end
  end

  defp fetch_difficulty(params) do
    case TaskForm.parse_int(params["difficulty"]) do
      {:ok, difficulty} -> {:ok, difficulty}
      :error -> {:error, "Difficulty must be a number 0–4."}
    end
  end

  # Only send an enum-ish field when the form actually supplied one — a
  # partial POST must not blank out `status` or `issue_type`.
  defp put_given(attrs, key, value) do
    case TaskForm.trimmed(value) do
      nil -> attrs
      given -> Map.put(attrs, key, given)
    end
  end

  defp ensure_acknowledged(value) when value in ["true", true], do: :ok

  defp ensure_acknowledged(_),
    do: {:error, "Confirm you understand this spends API credits before dispatching."}

  # Mirrors `ArbiterWeb.Api.WorkerController.dispatch_opts/1`: a blank provider
  # means "use the workspace's configured agent", a named one overrides it, and
  # an unrecognized one is a hard error rather than a silent fallback
  # (bd-dcvo3n).
  defp dispatch_opts(params) do
    with {:ok, agent_opts} <- provider_opts(params["provider"]) do
      repo = TaskForm.trimmed(params["repo"])

      {:ok, Enum.reject([repo: repo] ++ agent_opts, fn {_k, v} -> is_nil(v) end)}
    end
  end

  defp provider_opts(provider) do
    case TaskForm.trimmed(provider) do
      nil ->
        {:ok, [start_claude: true]}

      given ->
        if given in Agents.valid_agent_types() do
          {:ok, [start_claude: true, agent_type: String.to_existing_atom(given)]}
        else
          {:error,
           "Unknown provider #{inspect(given)} — valid providers: " <>
             Enum.join(Agents.valid_agent_types(), ", ") <> "."}
        end
    end
  end

  defp provider_options do
    [{"Workspace default", ""}] ++ Enum.map(Agents.valid_agent_types(), &{&1, &1})
  end

  # The repo names this task could be dispatched against. Delegated to
  # `Dispatch.all_available_repos/1` rather than re-derived from the workspace
  # config, so the dropdown can't offer a repo whose configured path no longer
  # resolves — dispatch would reject it with `{:repo_not_found, repo}` after
  # the operator had already acknowledged the credit spend.
  defp repo_options(%Issue{} = task) do
    [{blank_repo_label(task), ""}] ++ Enum.map(Dispatch.all_available_repos(task), &{&1, &1})
  end

  defp repo_options(_), do: [{"Workspace default", ""}]

  # What "leave it blank" actually means for THIS task. Once a task carries its
  # own repo (bd-2jum8j), an empty per-dispatch choice binds that repo rather
  # than the workspace's sole-repo auto-select, and the label must say so —
  # otherwise the modal reads as if it were about to ignore the assignment.
  defp blank_repo_label(%Issue{repo: repo}) when is_binary(repo) and repo != "",
    do: "Task default (#{repo})"

  defp blank_repo_label(_), do: "Workspace default"

  # The edit modal's "which repo does this task belong to?" select (bd-2jum8j).
  # Same resolvable-only source as `repo_options/1`, but blank means "no
  # assignment" rather than "let dispatch decide this once". The task's own
  # current repo is always kept in the list even when it no longer resolves —
  # otherwise opening the modal on a task with a stale assignment would render
  # a select that silently clears it on save.
  defp repo_assignment_options(%Issue{repo: current} = task) do
    available = Dispatch.all_available_repos(task)

    names =
      if present?(current) and current not in available,
        do: available ++ [current],
        else: available

    [{"— unassigned —", ""}] ++ Enum.map(names, &{&1, &1})
  end

  defp repo_assignment_options(_), do: [{"— unassigned —", ""}]

  defp dispatch_failure(:no_repo_configured),
    do:
      "no repo is configured for this workspace — add one to the workspace's " <>
        "repo_paths config (or :arbiter, :repo_paths) first."

  defp dispatch_failure({:repo_not_found, repo}),
    do: "repo #{inspect(repo)} isn't in any configured repo_paths."

  defp dispatch_failure({:ambiguous_repo, repos}),
    do:
      "several repos are configured (#{Enum.join(repos, ", ")}) — pick one explicitly, " <>
        "or Edit to assign this task a repo so every dispatch binds it."

  # bd-2aslx6 (#1428): the Dispatch button always sets `start_claude: true`
  # (see provider_opts/1), so this is the surface an operator hits when a task
  # already has a live agent session. Without a named message it rendered as a
  # raw `Dispatch failed: {:agent_session_active, "bd-..."}` tuple.
  defp dispatch_failure({:agent_session_active, _task_id}),
    do:
      "this task already has a live agent session — wait for it to finish, or stop " <>
        "the worker before dispatching again."

  defp dispatch_failure(reason), do: inspect(reason)

  # ---- data ----

  defp acceptance_criteria_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %{field: :acceptance} -> true
      _ -> false
    end)
  end

  defp acceptance_criteria_error?(_), do: false

  defp refresh_all(socket) do
    socket
    |> refresh_task()
    |> refresh_budget()
    |> refresh_workspace()
    |> refresh_worker()
    |> refresh_runs()
    |> refresh_review_rounds()
    |> refresh_deps()
    |> refresh_versions()
    |> refresh_skills()
    |> refresh_messages()
    |> follow_messages()
  end

  defp refresh_task(socket) do
    task =
      case Ash.get(Issue, socket.assigns.task_id, load: [:child_total, :child_closed]) do
        {:ok, task} -> task
        {:error, _} -> nil
      end

    socket
    |> assign(:task, task)
    |> assign(:acceptance_items, acceptance_items(task && task.acceptance))
  end

  # bd-8j9i9p (design bd-9jj5lf §3): worker spend so far, the percentile range
  # it is read against, and which of the three threshold states that lands in.
  # Best-effort on purpose — a ledger read that fails costs the header its
  # cost line, not the page.
  defp refresh_budget(%{assigns: %{task: %Issue{} = task}} = socket) do
    budget =
      try do
        Budget.assess(task)
      rescue
        e ->
          Logger.warning("Failed to assess spend for #{task.id}: #{inspect(e)}")
          nil
      end

    assign(socket, :budget, budget)
  end

  defp refresh_budget(socket), do: assign(socket, :budget, nil)

  # The effective post-layering skill set (workspace -> repo -> issue) a
  # dispatch of this issue would carry right now — the same resolution the
  # dispatch path runs, so the rail can't drift from what a worker gets.
  defp refresh_skills(%{assigns: %{task: %Issue{} = task, workspace: workspace}} = socket) do
    skills =
      try do
        [task: task, workspace: workspace]
        |> Selection.resolve()
        |> Enum.map(&%{name: &1.skill.name, activation: &1.activation})
      rescue
        e ->
          Logger.warning("Failed to resolve skills for #{task.id}: #{inspect(e)}")
          []
      end

    assign(socket, :skills, skills)
  end

  defp refresh_skills(socket), do: assign(socket, :skills, [])

  defp refresh_workspace(%{assigns: %{task: %Issue{workspace_id: ws_id}}} = socket)
       when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> assign(socket, :workspace, ws)
      _ -> assign(socket, :workspace, nil)
    end
  end

  defp refresh_workspace(socket), do: assign(socket, :workspace, nil)

  # ---- messages ----
  #
  # Everything addressed to (`to_ref`) or about (`task_ref`) this issue:
  # coordinator directions to its worker, worker escalations back up, sibling
  # flags. Until now these only surfaced in the global coordinator drawer (all
  # issues mixed together) or `arb message inbox`.
  #
  # Strictly display: the panel reads through `Message.for_task/2`, which never
  # stamps `read_at`/`cleared_at`. Opening an issue page must not silently
  # drain the coordinator's triage queue, so read state is *rendered*, never
  # changed here.
  defp refresh_messages(socket) do
    messages =
      try do
        Message.for_task(socket.assigns.task_id, limit: @message_limit)
      rescue
        e ->
          Logger.warning("Failed to load messages for #{socket.assigns.task_id}: #{inspect(e)}")
          []
      end

    assign(socket, :messages, messages)
  end

  # Messages broadcast on `"messages:<workspace_id>"` and nothing finer — there
  # is no per-task topic, and this ticket is not the place to invent one (see
  # bd-cpt2ej). So the page follows its issue's workspace feed and filters on
  # arrival. The workspace id only exists once the issue row has loaded, which
  # is why this runs from `refresh_all/1` rather than `mount/3`; re-running it
  # is a no-op unless the issue moved workspace.
  defp follow_messages(%{assigns: %{task: %Issue{workspace_id: ws_id}}} = socket)
       when is_binary(ws_id) do
    topic = Message.topic(ws_id)
    current = socket.assigns[:messages_topic]

    cond do
      not connected?(socket) ->
        socket

      current == topic ->
        socket

      true ->
        if current, do: Phoenix.PubSub.unsubscribe(Arbiter.PubSub, current)
        Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)
        assign(socket, :messages_topic, topic)
    end
  end

  defp follow_messages(socket), do: socket

  defp about_this_task?(message, task_id) when is_binary(task_id) do
    Map.get(message, :to_ref) == task_id or Message.task_ref(message) == task_id
  end

  defp about_this_task?(_message, _task_id), do: false

  defp refresh_worker(socket) do
    snap =
      case Worker.whereis(socket.assigns.task_id) do
        nil -> nil
        pid -> safe_state(pid)
      end

    assign(socket, :worker, snap)
  end

  defp safe_state(pid) do
    Worker.state(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @empty_relationship_groups %{
    blocked_by: [],
    blocks: [],
    parents: [],
    children: [],
    relates_to: [],
    discovered_from: [],
    discovered: [],
    conflicts_with: []
  }

  defp refresh_deps(socket) do
    groups =
      try do
        Dependencies.for_issue(socket.assigns.task_id)
      rescue
        _ -> @empty_relationship_groups
      end

    socket
    |> assign(:relationship_groups, groups)
    |> assign(:parent_refs, parent_refs(socket.assigns[:task]))
  end

  # bd-38of5i: the "↳ Part of <epic>" banner under the title. It rides on
  # `refresh_deps/1` rather than `refresh_task/1` because it is an *edge*
  # rollup: it has to repaint when a *sibling* closes, which arrives as a
  # lifecycle event for some other task, and that is the one refresh those
  # events run.
  defp parent_refs(%Issue{} = task), do: ParentRefs.for_issue(task)
  defp parent_refs(_task), do: []

  # ---- relationship editing: state, typeahead, pre-checks, warnings ----
  #
  # bd-dmabmg (design bd-dgh2xv §2.1-§2.7, §3.3). Every write here goes through
  # `Arbiter.Tasks.Dependencies`, which owns the guards; nothing below writes an
  # edge itself. The pre-checks and warnings are advisory duplicates of the
  # facade's own rules, run early so the operator finds out before committing —
  # the facade re-runs them inside its transaction, which is what actually
  # holds.

  defp relationship_phrase_options, do: Enum.map(@relationship_phrases, &{&1.label, &1.key})

  defp relationship_phrase(key),
    do: Enum.find(@relationship_phrases, hd(@relationship_phrases), &(&1.key == key))

  defp normalize_phrase_key(key) do
    if Enum.any?(@relationship_phrases, &(&1.key == key)),
      do: key,
      else: @default_relationship_phrase
  end

  # `invert: false` means this issue is the edge's `from`; `invert: true` means
  # the target is. This is the only place the from/to convention appears.
  defp relationship_endpoints(%{invert: false}, this_id, target_id), do: {this_id, target_id}
  defp relationship_endpoints(%{invert: true}, this_id, target_id), do: {target_id, this_id}

  defp reset_relationship_form(socket) do
    socket
    |> assign(:rel_phrase, @default_relationship_phrase)
    |> assign(:rel_query, "")
    |> assign(:rel_note, "")
    |> assign(:rel_target, nil)
    |> assign(:rel_candidates, [])
    |> assign(:rel_warnings, [])
    |> assign(:rel_error, nil)
    |> assign(:rel_cycle_path, [])
  end

  defp clear_relationship_error(socket), do: assign(socket, rel_error: nil, rel_cycle_path: [])

  defp apply_relationship_params(socket, params) do
    phrase = params |> Map.get("phrase", socket.assigns.rel_phrase) |> normalize_phrase_key()
    query = Map.get(params, "query", socket.assigns.rel_query)

    # Changing the phrase changes what a pick would *mean* (and whether it is
    # legal at all); changing the query changes what is on offer. Either way
    # the previous pick is no longer what the operator is looking at, so drop
    # it rather than write an edge they had stopped composing.
    target =
      if phrase == socket.assigns.rel_phrase and query == socket.assigns.rel_query,
        do: socket.assigns.rel_target,
        else: nil

    socket
    |> assign(:rel_phrase, phrase)
    |> assign(:rel_query, query)
    |> assign(:rel_note, Map.get(params, "note", socket.assigns.rel_note))
    |> assign(:rel_target, target)
    |> clear_relationship_error()
    |> refresh_relationship_candidates()
    |> refresh_relationship_warnings()
  end

  # A pick from the list wins; failing that the raw search text is treated as a
  # pasted id, which is how a cross-workspace id reaches the facade and earns
  # its named rejection (§2.4).
  defp chosen_relationship_target_id(%{assigns: %{rel_target: %Issue{id: id}}}), do: id
  defp chosen_relationship_target_id(%{assigns: %{rel_query: query}}), do: String.trim(query)

  defp write_relationship(socket, %Issue{} = task, target_id) do
    phrase = relationship_phrase(socket.assigns.rel_phrase)
    {from_id, to_id} = relationship_endpoints(phrase, task.id, target_id)
    opts = [created_by: "dashboard", notes: TaskForm.trimmed(socket.assigns.rel_note)]

    case Dependencies.add(from_id, to_id, phrase.type, opts) do
      {:ok, _edge} ->
        socket
        |> reset_relationship_form()
        |> assign(:rel_modal, false)
        |> put_flash(:info, "#{task.id} #{phrase.label} #{target_id}.")
        |> refresh_all()

      {:error, reason} ->
        socket
        |> assign(:rel_error, relationship_error_message(reason, task.id, target_id, phrase))
        |> assign(:rel_cycle_path, relationship_cycle_path(reason, from_id, to_id, phrase.type))
    end
  end

  # Two facade rejections get re-worded rather than passed through, because
  # both of the facade's own messages name the raw `(type, from, to)` triple
  # this modal exists to hide (§3.3):
  #
  #   * the resource's `unique_edge` identity, which surfaces as a generic
  #     invalid changeset — "already linked" is the useful reading, and it is
  #     the same wording the typeahead greys a candidate with;
  #   * the cycle, whose path is rendered underneath as linked ids instead.
  #
  # `:not_found` and `:cross_workspace` already read as plain sentences about
  # the ids the operator typed, so they pass through unchanged.
  defp relationship_error_message(reason, this_id, target_id, phrase) do
    {from_id, to_id} = relationship_endpoints(phrase, this_id, target_id)

    cond do
      duplicate_edge?(from_id, to_id, phrase.type) ->
        "#{this_id} already #{phrase.label} #{target_id} — they are already linked."

      match?({:cyclic, _message}, reason) ->
        "That would create a dependency cycle — everything on this path would " <>
          "end up waiting on itself:"

      true ->
        relationship_error_message(reason)
    end
  end

  defp relationship_error_message({_reason, message}) when is_binary(message), do: message
  defp relationship_error_message(other), do: TaskForm.error_message(other)

  defp duplicate_edge?(from_id, to_id, type) do
    edges =
      Dependency
      |> Ash.Query.filter(from_issue_id == ^from_id and to_issue_id == ^to_id and type == ^type)
      |> Ash.read!()

    edges != []
  end

  # Acceptance #9 wants the cycle *named*, with every id on the path clickable.
  # The facade's message already spells the walk out, but re-deriving the list
  # is what lets the template link each id instead of shipping a linkified
  # parse of an error string.
  defp relationship_cycle_path({:cyclic, _message}, from_id, to_id, type) do
    if DependencyGraph.gating?(type) do
      {type, from_id, to_id}
      |> DependencyGraph.normalize()
      |> DependencyGraph.candidate_cycle(DependencyGraph.gating_edges(:all))
      |> case do
        {:error, {:cyclic, cycle}} -> cycle
        _ -> []
      end
    else
      []
    end
  end

  defp relationship_cycle_path(_reason, _from_id, _to_id, _type), do: []

  # ---- typeahead ----

  defp refresh_relationship_candidates(%{assigns: %{task: %Issue{} = task}} = socket) do
    candidates =
      case String.trim(socket.assigns.rel_query) do
        "" ->
          []

        query ->
          task
          |> search_relationship_targets(query)
          |> Enum.map(&relationship_candidate_entry(&1, socket))
      end

    assign(socket, :rel_candidates, candidates)
  end

  defp refresh_relationship_candidates(socket), do: assign(socket, :rel_candidates, [])

  # Server-side `LIKE` over id + title, the same shape `AuditLogLive` uses;
  # SQLite's `LIKE` is ASCII-case-insensitive, so no extra capability is
  # needed. Scoped to the issue's own workspace (§2.4 — a cross-workspace edge
  # is refused anyway, so offering one would be a trap) and with the issue
  # itself excluded (a self-edge is refused by the resource).
  defp search_relationship_targets(%Issue{} = task, query) do
    pattern = "%#{query}%"
    workspace_id = task.workspace_id
    self_id = task.id

    Issue
    |> Ash.Query.filter(workspace_id == ^workspace_id and id != ^self_id)
    |> Ash.Query.filter(like(id, ^pattern) or like(title, ^pattern))
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(@relationship_search_slice)
    |> Ash.read!()
    |> Enum.sort_by(&{relationship_rank(&1), &1.id})
    |> Enum.take(@relationship_candidate_limit)
  end

  defp relationship_rank(%Issue{status: :closed}), do: 1
  defp relationship_rank(_issue), do: 0

  defp relationship_candidate_entry(%Issue{} = candidate, socket),
    do: %{issue: candidate, reason: relationship_block_reason(candidate, socket)}

  defp relationship_block_reason(%Issue{} = candidate, socket) do
    phrase = relationship_phrase(socket.assigns.rel_phrase)
    {from_id, to_id} = relationship_endpoints(phrase, socket.assigns.task.id, candidate.id)

    cond do
      already_linked?(socket.assigns.relationship_groups, phrase.group, candidate.id) ->
        "already linked"

      Dependencies.would_cycle?(from_id, to_id, phrase.type) ->
        "would create a dependency cycle"

      true ->
        nil
    end
  end

  # Duplicate detection reads the *grouped* view rather than raw rows, so a
  # pre-existing `blocks(x, this)` counts as "already blocked by x" even though
  # the UI would write the `depends_on` inverse (§2.7).
  defp already_linked?(groups, group, id),
    do: groups |> Map.get(group, []) |> Enum.any?(&(&1.issue_id == id))

  # Only a selectable candidate can be picked: a hand-rolled click on a greyed
  # row is a no-op rather than a way around the pre-check.
  defp relationship_candidate(socket, id) do
    Enum.find_value(socket.assigns.rel_candidates, fn
      %{issue: %Issue{id: ^id} = issue, reason: nil} -> issue
      _ -> nil
    end)
  end

  # ---- warnings (informational; they never disable the submit) ----

  defp refresh_relationship_warnings(socket),
    do: assign(socket, :rel_warnings, relationship_add_warnings(socket))

  defp relationship_add_warnings(%{
         assigns: %{task: %Issue{} = task, rel_target: %Issue{} = target, rel_phrase: key}
       }) do
    phrase = relationship_phrase(key)
    gating_add_warnings(phrase, task, target) ++ auto_close_add_warnings(phrase, task, target)
  end

  defp relationship_add_warnings(_socket), do: []

  # §2.1. Both warnings concern the endpoint the edge *gates* — the `from` of
  # the `depends_on` row, which is this issue for "is blocked by" and the
  # target for "blocks". They are mutually exclusive: an `:in_progress` issue
  # is not in the dispatch queue, which only admits open+refined cards.
  defp gating_add_warnings(%{type: :depends_on, invert: invert}, task, target) do
    gated = if invert, do: target, else: task

    cond do
      gated.status == :in_progress -> [in_progress_warning(gated)]
      dispatchable?(gated) -> [dispatch_queue_warning(gated)]
      true -> []
    end
  end

  defp gating_add_warnings(_phrase, _task, _target), do: []

  # §2.2. `maybe_auto_close/1` fires once every `:parent_of` child is closed,
  # so attaching an already-closed child to a parent whose other children are
  # all closed completes it — and the facade now runs that re-evaluation on
  # every edge write, which is exactly why the operator is told first.
  defp auto_close_add_warnings(%{type: :parent_of, invert: invert}, task, target) do
    {parent, child} = if invert, do: {target, task}, else: {task, target}
    parent = load_child_rollup(parent)

    if auto_close_completes?(parent, child), do: [auto_close_warning(parent)], else: []
  end

  defp auto_close_add_warnings(_phrase, _task, _target), do: []

  defp relationship_remove_warnings(%{edge: %Dependency{} = edge}),
    do: gating_remove_warnings(edge) ++ auto_close_remove_warnings(edge)

  defp relationship_remove_warnings(_entry), do: []

  # The mirror of §2.1: dropping the last unclosed gating edge puts the gated
  # issue back in the queue.
  defp gating_remove_warnings(%Dependency{type: type} = edge)
       when type in [:depends_on, :blocks] do
    {dependent, dependency} = DependencyGraph.normalize(edge)

    with {:ok, %Issue{status: :open, refined: true} = gated} <- Ash.get(Issue, dependent),
         [] <- Enum.reject(gating_blockers(dependent), &(&1.issue_id == dependency)) do
      [
        %{
          key: "dispatchable",
          text: "#{gated.id} becomes dispatchable; Autopilot may pick it up within ~15s.",
          link: nil
        }
      ]
    else
      _ -> []
    end
  end

  defp gating_remove_warnings(_edge), do: []

  defp auto_close_remove_warnings(%Dependency{type: :parent_of} = edge) do
    with {:ok, parent} <- Ash.get(Issue, edge.from_issue_id, load: [:child_total, :child_closed]),
         {:ok, child} <- Ash.get(Issue, edge.to_issue_id),
         true <- auto_close_completes_without?(parent, child) do
      [auto_close_warning(parent)]
    else
      _ -> []
    end
  end

  defp auto_close_remove_warnings(_edge), do: []

  defp auto_close_completes?(
         %Issue{auto_close: true, status: status} = parent,
         %Issue{status: :closed}
       )
       when status != :closed,
       do: (parent.child_closed || 0) == (parent.child_total || 0)

  defp auto_close_completes?(_parent, _child), do: false

  defp auto_close_completes_without?(
         %Issue{auto_close: true, status: status} = parent,
         %Issue{} = child
       )
       when status != :closed do
    remaining_total = (parent.child_total || 0) - 1
    remaining_closed = (parent.child_closed || 0) - if(child.status == :closed, do: 1, else: 0)

    remaining_total > 0 and remaining_closed == remaining_total
  end

  defp auto_close_completes_without?(_parent, _child), do: false

  defp in_progress_warning(%Issue{} = issue) do
    %{
      key: "in-progress",
      text:
        "A worker is running on #{issue.id} right now — this will not stop it; " <>
          "it only applies to the next dispatch.",
      link: %{href: "/workers/#{issue.id}", label: "view the worker"}
    }
  end

  defp dispatch_queue_warning(%Issue{} = issue) do
    %{
      key: "dispatch-queue",
      text: "#{issue.id} is in the dispatch queue; this pulls it out within ~15s.",
      link: nil
    }
  end

  defp auto_close_warning(%Issue{} = parent) do
    %{
      key: "auto-close",
      text:
        "#{parent.id} has auto_close set and no other open children — " <>
          "this will close #{parent.id}.",
      link: nil
    }
  end

  defp dispatchable?(%Issue{status: :open, refined: true, id: id}), do: gating_blockers(id) == []
  defp dispatchable?(_issue), do: false

  defp gating_blockers(issue_id) do
    issue_id
    |> Dependencies.for_issue()
    |> Map.get(:blocked_by, [])
    |> Enum.filter(fn
      %{issue: %Issue{status: status}} -> status != :closed
      _entry -> false
    end)
  end

  defp load_child_rollup(%Issue{} = issue) do
    case Ash.load(issue, [:child_total, :child_closed]) do
      {:ok, loaded} -> loaded
      _ -> issue
    end
  end

  defp find_relationship_entry(groups, edge_id) do
    groups
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.edge.id == edge_id))
  end

  defp refresh_versions(socket) do
    query = Ash.Query.filter(Version, version_source_id == ^socket.assigns.task_id)

    versions =
      try do
        query
        |> Ash.Query.sort(version_inserted_at: :desc)
        |> Ash.Query.limit(@version_limit)
        |> Ash.read!()
      rescue
        _ -> []
      end

    # The stream is capped, so the panel meta has to say so — `20 transitions`
    # on an issue with 60 of them reads as the whole story and hides the fact
    # that `History →` is the only way to the rest.
    total =
      try do
        Ash.count!(query)
      rescue
        _ -> length(versions)
      end

    socket
    |> assign(:versions, versions)
    |> assign(:version_total, total)
  end

  defp refresh_runs(socket) do
    id = socket.assigns.task_id
    review_id = ReviewGate.reviewer_task_id(id)
    task_ids = [id, review_id]

    # `base_task_id` is the run's own record of which issue it belongs to, and
    # it is what reaches the deeper synthetic ids — a revise round runs as
    # `<id>#review#impl2`, a merge-queue fix pass under its own id again. The
    # literal `[id, <id>#review]` pair stays alongside it because the column is
    # nullable: runs recorded before it existed only match by task_id, and
    # dropping them would empty the roster for every historical issue.
    runs =
      try do
        Run
        |> Ash.Query.filter(task_id in ^task_ids or base_task_id == ^id)
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.read!()
      rescue
        e ->
          Logger.warning("Failed to load worker runs: #{inspect(e)}")
          []
      end

    usage_by_run =
      if runs == [] do
        %{}
      else
        run_ids = Enum.map(runs, & &1.id)

        try do
          UsageEvent
          |> Ash.Query.filter(worker_run_id in ^run_ids)
          |> Ash.Query.sort(inserted_at: :asc)
          |> Ash.read!()
          |> Enum.group_by(& &1.worker_run_id)
          |> Map.new(fn {run_id, events} ->
            costs = events |> Enum.map(& &1.cost_usd) |> Enum.reject(&is_nil/1)
            total_cost = if costs == [], do: nil, else: Enum.sum(costs)
            representative = List.first(events)
            {run_id, %{representative | cost_usd: total_cost}}
          end)
        rescue
          e ->
            Logger.warning("Failed to load usage events for worker runs: #{inspect(e)}")
            %{}
        end
      end

    socket
    |> assign(:runs, runs)
    |> assign(:usage_by_run, usage_by_run)
    |> assign(:issue_repo, issue_repo(runs, socket.assigns[:task]))
    |> assign(:prior_mr_refs, prior_mr_refs(runs, current_pr_ref(socket.assigns[:task])))
    |> derive_roster()
    |> resync_live_run()
  end

  # §4's right rail leads with `repo`. The task's own assignment (bd-2jum8j) is
  # the authoritative answer when it has one — it's what every future dispatch
  # will bind. Otherwise fall back to the most recent run that recorded a repo,
  # then to the workspace's configured repo when there is exactly one and the
  # answer is therefore unambiguous.
  defp issue_repo(_runs, %Issue{repo: repo}) when is_binary(repo) and repo != "", do: repo

  defp issue_repo(runs, %Issue{} = task) do
    case Enum.find_value(runs, &(present?(&1.repo) && &1.repo)) do
      repo when is_binary(repo) ->
        repo

      _ ->
        case Dispatch.all_available_repos(task) do
          [only] -> only
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  defp issue_repo(_runs, _task), do: nil

  defp output_topic(task_id), do: "worker:" <> task_id

  # Keep the page subscribed to exactly one worker feed: the one behind the
  # open row, and only while that run is still running with a live process.
  # Called wherever `@expanded_run` or `@runs` can change, so a run finishing
  # underneath an open row drops the follow and the row falls back to the
  # persisted tail `record_run_finished/1` just wrote.
  # Pre-existing complexity 12 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp resync_live_run(socket) do
    current = socket.assigns[:live_run_topic]

    target =
      case Enum.find(socket.assigns[:runs] || [], &(&1.id == socket.assigns[:expanded_run])) do
        %Run{id: id, status: :running, task_id: task_id} when is_binary(task_id) ->
          case Worker.whereis(task_id) do
            pid when is_pid(pid) -> {id, output_topic(task_id), pid}
            _ -> nil
          end

        _ ->
          nil
      end

    case target do
      nil ->
        if current, do: Phoenix.PubSub.unsubscribe(Arbiter.PubSub, current)
        assign(socket, live_run_id: nil, live_run_topic: nil, live_run_lines: [])

      {run_id, topic, pid} ->
        if socket.assigns.live and current != topic do
          if current, do: Phoenix.PubSub.unsubscribe(Arbiter.PubSub, current)
          Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)
        end

        # Seed from the worker's own snapshot so an opened row is full
        # immediately rather than filling in one broadcast at a time.
        assign(socket,
          live_run_id: run_id,
          live_run_topic: topic,
          live_run_lines: snapshot_output_lines(pid)
        )
    end
  end

  # `meta.output_lines` is the worker's mirror of the session buffer, already
  # oldest-first (`worker.ex` reverses it on the way in).
  defp snapshot_output_lines(pid) do
    case safe_state(pid) do
      %{meta: meta} when is_map(meta) ->
        Enum.take(Map.get(meta, :output_lines) || [], -@live_line_cap)

      _ ->
        []
    end
  end

  # Role tabs and the visible slice are pure functions of the loaded runs and
  # the active filter, so both a reload and a tab click land here.
  defp derive_roster(socket) do
    runs = socket.assigns.runs
    tabs = run_tabs(runs)

    # A filter whose role no longer has any runs (the last review run aged
    # out of the query) would strand the operator on an empty roster.
    filter =
      if Enum.any?(tabs, &(&1.value == socket.assigns.run_filter)),
        do: socket.assigns.run_filter,
        else: "all"

    socket
    |> assign(:run_tabs, tabs)
    |> assign(:run_filter, filter)
    |> assign(:visible_runs, filter_runs(runs, filter))
  end

  defp current_pr_ref(%Issue{pr_ref: pr_ref}), do: pr_ref
  defp current_pr_ref(_), do: nil

  # bd-6h4ia3: every distinct MR/PR ref a task's worker runs opened or adopted
  # over its history, most recent first (runs are already sorted that way),
  # excluding the task's current pr_ref (already shown above this list) so a
  # task resumed repeatedly against the same MR doesn't show it twice.
  defp prior_mr_refs(runs, current_pr_ref) do
    runs
    |> Enum.map(& &1.mr_ref)
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == current_pr_ref))
  end

  # ---- review-round summary (bd-9mqima) ----
  #
  # "Did review pass?" is answered by `Arbiter.ReviewGate.Round`, the durable
  # record ReviewGate writes per pass — NOT by aggregating `@runs` by role.
  # A reviewing pass that issued REQUEST_CHANGES exits 0 and records
  # `status: :completed` exactly like one that approved, so the run rows can
  # only ever count passes; and a pass that exhausted its budget without a
  # verdict is written as a synthetic `verdict: :timed_out` round the run row
  # knows nothing about. Reading runs here would render "approved" over a
  # rejection, which is the one mistake this line must never make.
  defp refresh_review_rounds(socket) do
    rounds =
      try do
        Round
        |> Ash.Query.filter(task_id == ^socket.assigns.task_id)
        |> Ash.Query.sort(round: :asc, inserted_at: :asc)
        |> Ash.read!()
      rescue
        e ->
          Logger.warning("Failed to load review-gate rounds: #{inspect(e)}")
          []
      end

    assign(socket, :review_summary, review_summary(rounds, socket.assigns[:runs] || []))
  end

  # nil means "no ReviewGate activity" — the panel renders no summary line at
  # all rather than an empty or speculative one.
  defp review_summary([], _runs), do: nil

  defp review_summary(rounds, runs) do
    # Rows arrive sorted (round asc, inserted_at asc), so the last `:review`
    # row IS the latest reviewer pass. `:impl` rows are revise passes within a
    # round and never carry a verdict, so they are not candidates.
    latest = rounds |> Enum.filter(&(&1.role == :review)) |> List.last()
    highest = rounds |> Enum.map(& &1.round) |> Enum.max()

    # A round whose reviewer pass left no row (or left one with no verdict) is
    # inconclusive, not approved — the gate reached a terminal it could not act
    # on. Saying so is the honest reading; `nil` flows through to that label.
    verdict = latest && latest.verdict
    run_id = latest && latest.run_id

    %{
      count: highest,
      round: (latest && latest.round) || highest,
      verdict: verdict,
      label: review_verdict_label(verdict),
      # Only offer the deep link when the round's own run is actually on this
      # page's roster — `run_id` is best-effort and can be nil or aged out.
      run_id: if(run_id && Enum.any?(runs, &(&1.id == run_id)), do: run_id)
    }
  end

  defp review_round_noun(1), do: "round"
  defp review_round_noun(_), do: "rounds"

  defp review_verdict_label(:approve), do: "approved"
  defp review_verdict_label(:request_changes), do: "changes requested"
  defp review_verdict_label(:timed_out), do: "timed out"
  defp review_verdict_label(_), do: "inconclusive"

  defp review_verdict_color(:approve), do: "var(--arb-live)"
  defp review_verdict_color(:request_changes), do: "var(--arb-fail-text)"
  defp review_verdict_color(_), do: "var(--arb-attention)"

  # Deep-link into RUNS through the panel's own existing events, so there is no
  # new client JS: clear any role filter that would be hiding the row, then
  # toggle it open.
  defp review_summary_click(%{run_id: nil}), do: nil

  defp review_summary_click(%{run_id: run_id}) do
    JS.push("filter_runs", value: %{tab: "all"})
    |> JS.push("toggle_run", value: %{run: run_id})
  end

  # ---- render ----

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
      <div class="p-4 sm:p-6 max-w-[1400px] mx-auto flex flex-col gap-[var(--space-4)]">
        <%!-- ── Toolbar ──────────────────────────────────────────────────
             Breadcrumb, the id itself and the issue's status chip. The whole
             crumb trail is one link up to the index — a per-segment crumb
             would be three links to two pages. --%>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex items-center gap-2 min-w-0 text-[11.5px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
            <.link
              navigate={~p"/tasks"}
              title="Up to the issues index"
              class="hover:text-[var(--text-title)] transition-colors"
            >
              Board / Issues /
            </.link>
            <code class="text-[var(--text-title)]">{@task_id}</code>
            <ArbiterWeb.CoreComponents.Core.copy_id id={@task_id} />
            <.status_chip :if={@task} status={@task.status} class="badge-sm" />
          </div>

          <%!-- Operator actions. A closed issue is terminal here: reopening
               it is `arb update` territory, not a dashboard button. --%>
          <div :if={@task && @task.status != :closed} class="flex items-center gap-2">
            <%!-- The one door out of Backlog. Gone the moment it is used —
                  there is no un-refine here, and nothing to click twice. --%>
            <ArbiterWeb.CoreComponents.Core.button
              :if={!@task.refined and @task.status == :open}
              size="sm"
              variant="primary"
              phx-click="promote_to_ready"
              title="Leave Backlog and join the Ready queue"
            >
              <%!-- The arrow trails the label ("Move to Ready →"), and the
                    `icon` slot is documented as a *leading* element, so it
                    goes in the inner block instead. --%>
              Move to Ready <ArbiterWeb.CoreComponents.Core.icon name="hero-arrow-right-mini" />
            </ArbiterWeb.CoreComponents.Core.button>
            <ArbiterWeb.CoreComponents.Core.button size="sm" phx-click="open_edit">
              <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-pencil-square-mini" /></:icon>
              Edit
            </ArbiterWeb.CoreComponents.Core.button>
            <%!-- Dispatch steps back while the task is unrefined: `Core.button`
                  allows one primary per region, and on a Backlog card that one
                  is promotion. Dispatching unrefined work stays possible — it
                  just stops being the thing the eye lands on. --%>
            <ArbiterWeb.CoreComponents.Core.button
              :if={is_nil(@worker)}
              size="sm"
              variant={if @task.refined, do: "primary", else: "secondary"}
              phx-click="open_dispatch"
            >
              <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-rocket-launch-mini" /></:icon>
              Dispatch
            </ArbiterWeb.CoreComponents.Core.button>
            <ArbiterWeb.CoreComponents.Core.button size="sm" variant="danger" phx-click="open_close">
              <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-x-circle-mini" /></:icon>
              Close
            </ArbiterWeb.CoreComponents.Core.button>
          </div>
        </div>

        <div>
          <h1
            :if={@task}
            class="text-[22px] font-semibold tracking-tight truncate"
            title={@task.title}
          >
            {@task.title}
          </h1>
          <h1 :if={!@task} class="text-[22px] font-semibold tracking-tight">
            {String.capitalize(@issue_label)} not found
          </h1>
          <div :if={@task} class="flex flex-wrap items-center gap-2 mt-1.5">
            <.priority_tag priority={@task.priority} class="badge-sm font-mono" />
            <.type_tag type={@task.issue_type} />
            <.difficulty_meter difficulty={@task.difficulty} />
            <span class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
              {difficulty_label(@task.difficulty)}
            </span>
            <%!-- Age, not wall-clock: "opened 2d ago · updated 41m ago" is the
                 question an operator actually asks of a header. --%>
            <span class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)] tabular-nums">
              opened {relative_age(@task.created_at)} · updated {relative_age(@task.updated_at)}
            </span>
          </div>

          <%!-- bd-8j9i9p (design bd-9jj5lf §3): what this issue has cost so far,
               against what issues like it usually cost. "worker spend", never
               "spent" — §7 keeps coordinator-session overhead out of both
               halves, and the tooltip says so. --%>
          <div
            :if={@task && @budget}
            id="task-spend"
            class="flex flex-wrap items-center gap-x-2 gap-y-1 mt-1.5 text-[11px] font-[family-name:var(--font-mono)]"
          >
            <span
              id="task-spend-figure"
              title="Worker spend: this issue's agent sessions and their review / fix-pass rounds. Excludes coordinator session overhead, which is metered per session and belongs to no single issue."
              class="text-[var(--text-label)]"
            >
              worker spend
              <span class="tabular-nums font-medium text-[var(--text-title)]">
                {money(@budget.spend)}
              </span>
            </span>
            <span id="task-spend-estimate" class="text-[var(--text-label)] tabular-nums">
              {estimate_label(@budget.estimate)}
            </span>
            <span
              :if={spend_chip_label(@budget.state)}
              id="task-spend-chip"
              data-state={@budget.state}
              title={spend_chip_title(@budget)}
              class={[
                "px-[7px] py-[1px] rounded-[var(--radius-chip)] border border-solid font-medium",
                @budget.state == :running_high &&
                  "border-[var(--arb-attention-edge)] bg-[var(--arb-attention-wash)] text-[var(--arb-attention)]",
                @budget.state == :over_budget &&
                  "border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[var(--arb-fail-text)]"
              ]}
            >
              {spend_chip_label(@budget.state)}
            </span>
          </div>

          <%!-- bd-38of5i (design bd-2s901b §7): what this issue is part of,
               at breadcrumb tier — directly under the title/type row, above
               the description. The RELATIONSHIPS panel also carries the same
               edge in its Parent group; this is the glanceable duplicate, on
               the theory that "which epic am I looking at a piece of" is a
               header question, not a panel one. --%>
          <.parent_links :if={@task} id="task-parents" parents={@parent_refs} class="mt-2" />
        </div>

        <%= if @task do %>
          <div class="flex flex-col gap-[var(--space-4)] lg:grid lg:grid-cols-[minmax(0,1fr)_340px] lg:items-start">
            <%!-- ══ Main column ═════════════════════════════════════════
                 Narrative order top-to-bottom. `contents` below `lg` folds
                 this wrapper into the outer flex column so the mobile
                 `order-*` values (per the design's narrow wireframe) still
                 apply across both groups; at `lg` it becomes its own flex
                 column so this group stacks independently of the rail,
                 using source order directly for the desktop order. --%>
            <div class="contents lg:flex lg:flex-col lg:gap-[var(--space-4)] lg:min-w-0">
              <.panel
                :if={present?(@task.description)}
                id="panel-description"
                title="DESCRIPTION"
                class="order-3"
              >
                <.markdown id="task-description-md" text={@task.description} />
              </.panel>

              <%!-- Acceptance criteria are real checkboxes, not decoration:
                 ticking one rewrites the markdown marker on the issue, so
                 `arb show` and the tracker read the same state back. The
                 #1636 waiver (bd-7mbrlg) is a sub-state of this same panel,
                 not a separate one, since it only ever applies to the
                 acceptance gate it waives. --%>
              <.panel
                :if={@acceptance_items != [] or present?(@task.acceptance_waived)}
                id="panel-acceptance"
                title="ACCEPTANCE"
                meta={acceptance_meta(@acceptance_items)}
                class="order-2"
              >
                <div class="flex flex-col gap-3">
                  <ul :if={@acceptance_items != []} class="flex flex-col gap-[7px]">
                    <li :for={item <- @acceptance_items} class="text-[12.5px] leading-snug">
                      <ArbiterWeb.CoreComponents.Forms.checkbox
                        :if={item.checkbox?}
                        name={"criterion-#{item.index}"}
                        id={"criterion-#{item.index}"}
                        label={item.text}
                        align="start"
                        checked={item.checked}
                        class={item.checked && "text-[var(--text-label)]"}
                        phx-click="toggle_criterion"
                        phx-value-criterion={item.index}
                      />
                      <span :if={!item.checkbox?} class="min-w-0 text-[var(--text-secondary)]">
                        {item.text}
                      </span>
                    </li>
                  </ul>

                  <div
                    :if={present?(@task.acceptance_waived)}
                    class={[
                      "flex flex-col gap-1",
                      @acceptance_items != [] && "border-t border-[var(--border-default)] pt-3"
                    ]}
                  >
                    <h3 class="text-[11px] font-medium text-[var(--text-label)]">
                      ACCEPTANCE WAIVED
                    </h3>
                    <p class="text-[12.5px] leading-snug text-[var(--text-secondary)]">
                      {@task.acceptance_waived}
                    </p>
                  </div>
                </div>
              </.panel>

              <%!-- bd-5lc99r: for a `task`-type directive the findings summary
                 in `notes` is the deliverable, so it gets its own panel with
                 a placeholder while still blank. --%>
              <.panel
                :if={@task.issue_type == :task}
                id="panel-findings"
                title="FINDINGS"
                class="order-7"
              >
                <.markdown id="task-findings-md" text={@task.notes} />
                <p :if={!present?(@task.notes)} class="text-[12px] italic text-[var(--text-label)]">
                  No findings recorded yet — the worker writes its results here before completing.
                </p>
              </.panel>

              <.panel
                :if={@task.issue_type != :task and present?(@task.notes)}
                id="panel-notes"
                title="NOTES"
                class="order-7"
              >
                <.markdown id="task-notes-md" text={@task.notes} />
              </.panel>

              <%!-- MERGE & REVIEW: PR/MR state plus target branch and body.
                 Ticket B (review-round summary) adds a compact round-summary
                 line here ("2 rounds · round 2: approved") that deep-links
                 into the matching RUNS rows — this is that panel's marked
                 spot, directly under the PR/target data list. --%>
              <.panel
                :if={
                  present?(@task.pr_ref) or present?(@task.target_branch) or
                    present?(@task.pr_body) or @prior_mr_refs != [] or @review_summary != nil
                }
                id="panel-merge-review"
                title="MERGE & REVIEW"
                class="order-4"
              >
                <div class="flex flex-col gap-3">
                  <.data_list class="text-[12.5px]">
                    <:item :if={present?(@task.pr_ref)} label="PR / MR">
                      <% pr_url = pr_url(@workspace, @task.pr_ref) %>
                      <a
                        :if={pr_url != ""}
                        href={pr_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="link link-hover text-xs font-mono text-primary inline-flex items-center gap-0.5"
                      >
                        {@task.pr_ref}
                        <ArbiterWeb.CoreComponents.icon
                          name="hero-arrow-top-right-on-square"
                          class="size-3"
                        />
                      </a>
                      <code :if={pr_url == ""} class="text-xs">{@task.pr_ref}</code>
                    </:item>
                    <:item :if={present?(@task.target_branch)} label="Target">
                      <code class="text-xs">{@task.target_branch}</code>
                    </:item>
                  </.data_list>

                  <%!-- Review-round summary (bd-9mqima). Sourced from
                     `review_gate_rounds` — the round record is the only place
                     the reviewer's actual verdict survives; the reviewer run's
                     own exit status cannot tell an APPROVE from a
                     REQUEST_CHANGES. Clicking deep-links into the RUNS row for
                     that exact pass via the panel's existing events. --%>
                  <div :if={@review_summary} class="flex flex-col gap-1">
                    <h3 class="text-[11px] font-medium text-[var(--text-label)]">Review</h3>
                    <button
                      id="review-round-summary"
                      type="button"
                      phx-click={review_summary_click(@review_summary)}
                      disabled={@review_summary.run_id == nil}
                      title={
                        if(@review_summary.run_id,
                          do: "Open this round's reviewer run in RUNS",
                          else: "The run for this round is no longer on this issue's roster"
                        )
                      }
                      class={[
                        "self-start inline-flex items-center gap-1.5 text-[12.5px]",
                        "font-[family-name:var(--font-mono)] text-left",
                        @review_summary.run_id && "cursor-pointer hover:underline"
                      ]}
                    >
                      <span class="text-[var(--text-secondary)]">
                        {@review_summary.count} {review_round_noun(@review_summary.count)}
                      </span>
                      <span class="text-[var(--text-label)]">·</span>
                      <span class="text-[var(--text-secondary)]">
                        round {@review_summary.round}:
                      </span>
                      <span style={"color: #{review_verdict_color(@review_summary.verdict)}"}>
                        {@review_summary.label}
                      </span>
                    </button>
                  </div>

                  <div :if={@prior_mr_refs != []} class="flex flex-col gap-1">
                    <h3 class="text-[11px] font-medium text-[var(--text-label)]">Prior MRs</h3>
                    <ul class="flex flex-col gap-0.5">
                      <li :for={ref <- @prior_mr_refs}>
                        <% ref_url = pr_url(@workspace, ref) %>
                        <a
                          :if={ref_url != ""}
                          href={ref_url}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="link link-hover text-xs font-mono text-primary inline-flex items-center gap-0.5"
                        >
                          {ref}
                          <ArbiterWeb.CoreComponents.icon
                            name="hero-arrow-top-right-on-square"
                            class="size-3"
                          />
                        </a>
                        <code :if={ref_url == ""} class="text-xs">{ref}</code>
                      </li>
                    </ul>
                  </div>

                  <div :if={present?(@task.pr_body)} class="flex flex-col gap-1">
                    <h3 class="text-[11px] font-medium text-[var(--text-label)]">PR description</h3>
                    <.markdown
                      id="task-pr-body-md"
                      text={@task.pr_body}
                      class="markdown-body--compact"
                    />
                  </div>
                </div>
              </.panel>

              <.panel
                :if={present?(@task.qa_notes) or present?(@task.deployment_notes)}
                id="panel-qa-deployment"
                title="QA & DEPLOYMENT"
                class="order-8"
              >
                <div class="flex flex-col gap-3">
                  <div :if={present?(@task.qa_notes)} class="flex flex-col gap-1">
                    <h3 class="text-[11px] font-medium text-[var(--text-label)]">QA notes</h3>
                    <.markdown
                      id="task-qa-notes-md"
                      text={@task.qa_notes}
                      class="markdown-body--compact"
                    />
                  </div>
                  <div :if={present?(@task.deployment_notes)} class="flex flex-col gap-1">
                    <h3 class="text-[11px] font-medium text-[var(--text-label)]">Deployment notes</h3>
                    <.markdown
                      id="task-deployment-notes-md"
                      text={@task.deployment_notes}
                      class="markdown-body--compact"
                    />
                  </div>
                </div>
              </.panel>

              <%!-- ── RUNS — the absorbed run index ───────────────────────
                   Every run that touched this issue (its own id plus the
                   review-gate's `#review` id) is a roster row here, and a row
                   expands in place to its transcript. Nothing navigates: the
                   old `/workers/history` index and `/workers/history/:id`
                   detail remain only as the cross-issue view and the
                   full-page permalink. --%>
              <.panel
                id="panel-runs"
                title="RUNS"
                meta={runs_meta(@runs, @usage_by_run)}
                padded={false}
                body_class="px-[18px] py-[var(--space-4)] flex flex-col gap-[10px]"
                class="order-9"
              >
                <:actions>
                  <.link
                    navigate={~p"/workers/history"}
                    class="text-[11.5px] text-[var(--text-label)] hover:text-[var(--text-title)] font-[family-name:var(--font-mono)]"
                  >
                    all runs →
                  </.link>
                </:actions>

                <ArbiterWeb.CoreComponents.Navigation.filter_tabs
                  :if={@runs != []}
                  tabs={@run_tabs}
                  active={@run_filter}
                  event="filter_runs"
                />

                <ArbiterWeb.CoreComponents.Feedback.empty_state
                  :if={@visible_runs == []}
                  icon="hero-cpu-chip"
                  detail={"arb dispatch #{@task_id}"}
                >
                  No runs of this kind on this issue yet.
                </ArbiterWeb.CoreComponents.Feedback.empty_state>

                <div :for={r <- @visible_runs} class="flex flex-col">
                  <.run_row
                    role={run_role(r)}
                    worker={run_worker_label(r)}
                    status={r.status}
                    outcome={run_outcome(r, @live_run_id, @live_run_lines)}
                    duration={humanize_run_duration(r.started_at, r.completed_at)}
                    cost={run_cost_label(Map.get(@usage_by_run, r.id))}
                    selected={@expanded_run == r.id}
                    expanded={@expanded_run == r.id}
                    class="cursor-pointer"
                    phx-click="toggle_run"
                    phx-value-run={r.id}
                    title="Expand this run's transcript in place"
                  />

                  <div
                    :if={@expanded_run == r.id}
                    class="mt-1 border border-[var(--border-default)] rounded-[var(--radius-field)] overflow-hidden"
                  >
                    <%!-- Live while the row is the followed one, the persisted
                         tail once the run has ended. --%>
                    <% lines = run_output_lines(r, @live_run_id, @live_run_lines) %>
                    <%!-- The facts the roster row deliberately drops (model,
                         session, exit code) live here, next to the output
                         they explain. --%>
                    <div class="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 border-b border-[var(--border-default)] bg-[var(--arb-panel-alt)] text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                      <code class="text-[var(--text-secondary)]">{r.task_id}</code>
                      <ArbiterWeb.CoreComponents.Core.copy_id
                        id={r.task_id}
                        dom_id={"copy-id-run-#{r.id}"}
                      />
                      <span :if={present?(r.repo)}>{r.repo}</span>
                      <span :if={present?(r.model)}>{r.model}</span>
                      <span>{length(lines)} lines</span>
                      <span>started {format_started(r.started_at)}</span>
                      <span :if={run_failed?(r)} class="text-[var(--arb-fail-text)]">
                        {run_failure_line(r)}
                      </span>
                      <span class="flex-1"></span>
                      <%!-- `@live_run_id` is set only when THIS run is still
                           running and its own worker process answered, so the
                           link can never point at a later run's session. --%>
                      <.link
                        :if={@live_run_id == r.id}
                        navigate={~p"/workers/#{r.task_id}"}
                        class="hover:text-[var(--text-title)]"
                      >
                        Open session
                      </.link>
                      <span
                        :if={@live_run_id != r.id}
                        class="opacity-50 cursor-not-allowed"
                        title="This run has ended — its live session is gone"
                      >
                        Open session
                      </span>
                      <.link
                        navigate={~p"/workers/history/#{r.id}"}
                        class="hover:text-[var(--text-title)]"
                      >
                        Full transcript
                      </.link>
                    </div>

                    <ArbiterWeb.CoreComponents.Feedback.empty_state :if={lines == []} icon={nil}>
                      {if r.status == :running,
                        do: "Waiting for the first line of output…",
                        else: "No output captured for this run."}
                    </ArbiterWeb.CoreComponents.Feedback.empty_state>

                    <.log_stream
                      :if={lines != []}
                      id={"run-transcript-#{r.id}"}
                      lines={transcript_lines(lines)}
                      live={r.status == :running}
                      time_width={44}
                      role_width={40}
                      max_height="24rem"
                      bare
                    />
                  </div>
                </div>
              </.panel>

              <%!-- ── ACTIVITY — the audit log folds in ───────────────────
                   These are the same `Issue` paper-trail transitions the
                   `/audit` page lists, filtered to this subject; the header
                   link opens that page with the same filter applied. --%>
              <.panel
                id="panel-activity"
                title="ACTIVITY"
                meta={activity_meta(@versions, @version_total)}
                padded={false}
                body_class="px-[18px] py-[var(--space-4)]"
                class="order-12"
              >
                <:actions>
                  <.link
                    navigate={~p"/audit?#{[entity_id: @task_id]}"}
                    class="text-[11.5px] text-[var(--text-label)] hover:text-[var(--text-title)] font-[family-name:var(--font-mono)]"
                  >
                    History →
                  </.link>
                </:actions>

                <ArbiterWeb.CoreComponents.Feedback.empty_state
                  :if={@versions == []}
                  icon="hero-clock"
                >
                  No history recorded yet. State transitions for this {@issue_label} appear here.
                </ArbiterWeb.CoreComponents.Feedback.empty_state>

                <.log_stream
                  :if={@versions != []}
                  id="task-activity"
                  lines={activity_lines(@versions)}
                  time_width={78}
                  max_height="22rem"
                />
              </.panel>
            </div>

            <%!-- ══ Right rail ══════════════════════════════════════════
                   State, at-a-glance. Same `contents`-below-`lg` scheme as
                   the main column: mobile `order-*` per the narrow
                   wireframe applies across both groups, and at `lg` this
                   wrapper becomes its own flex column stacking
                   independently of the main column, in source order. --%>
            <div class="contents lg:flex lg:flex-col lg:gap-[var(--space-4)] lg:min-w-0">
              <%!-- An issue accumulates runs — a main dispatch, review passes,
                   fix passes — so this block summarises the roster rather
                   than naming the one worker that happens to be attached. --%>
              <.panel
                id="panel-current-run"
                title="CURRENT RUN"
                meta={run_role_breakdown(@runs)}
                class="order-1"
              >
                <div class="flex flex-col gap-3">
                  <p class="text-[12.5px] text-[var(--text-secondary)]">
                    {run_count_summary(@runs)}
                  </p>

                  <div
                    :if={@worker}
                    class="flex flex-col gap-2 rounded-[var(--radius-field)] border border-[var(--border-default)] p-2.5"
                  >
                    <div class="flex items-center justify-between gap-2">
                      <span class="text-[11px] font-medium text-[var(--text-label)]">
                        {String.capitalize(@worker_label)}
                      </span>
                      <.status_chip status={@worker && @worker.status} class="badge-sm" />
                    </div>
                    <div class="flex items-center justify-between gap-2 text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                      <span>started {format_started(@worker && @worker.started_at)}</span>
                      <span :if={worker_activity(@worker)}>{worker_activity(@worker)}</span>
                    </div>
                    <.link
                      navigate={~p"/workers/#{@task_id}"}
                      class="text-[11.5px] text-[var(--arb-info)] hover:underline"
                    >
                      view full output →
                    </.link>
                  </div>

                  <div
                    :if={is_nil(@worker)}
                    class="flex flex-col gap-1 rounded-[var(--radius-field)] border border-dashed border-[var(--border-default)] p-2.5"
                  >
                    <p class="text-[12px] text-[var(--text-secondary)]">
                      No {@worker_label} running for this {@issue_label}.
                    </p>
                    <code class="text-[11px] text-[var(--text-label)]">
                      arb dispatch {@task_id}
                    </code>
                  </div>
                </div>
              </.panel>

              <%!-- bd-9so315: a merged-but-unverified task, and the record of
                    what was (or wasn't) observed once someone looked. Rendered
                    only for a task the flag applies to — every other task has
                    nothing to say here. --%>
              <.panel
                :if={@task.verify_after_deploy}
                id="panel-verification"
                title="POST-MERGE VERIFICATION"
                class="order-6"
              >
                <.data_list class="text-[12px]">
                  <:item label="Flagged">
                    <code class="text-xs">verify_after_deploy</code>
                  </:item>
                  <:item :if={@task.awaiting_verification_at} label="Parked">
                    <code class="text-xs">{format_audit_ts(@task.awaiting_verification_at)}</code>
                  </:item>
                  <:item :if={@task.verification_outcome} label="Outcome">
                    <code class="text-xs">{@task.verification_outcome}</code>
                  </:item>
                </.data_list>

                <p
                  :if={present?(@task.verification_evidence)}
                  class="mt-2 text-[12px] whitespace-pre-wrap text-[var(--text-secondary)]"
                >
                  {@task.verification_evidence}
                </p>

                <div :if={@task.status == :awaiting_verification} class="mt-3 space-y-1">
                  <p class="text-[12px] text-[var(--text-secondary)]">
                    Merged, but nothing has run the new code yet. Restart the server, observe
                    the new path once, then record what you saw:
                  </p>
                  <code class="block text-[11px] text-[var(--text-label)]" phx-no-curly-interpolation>
                    arb issue verify {@task_id} --observed "&lt;evidence&gt;"
                  </code>
                  <code class="block text-[11px] text-[var(--text-label)]" phx-no-curly-interpolation>
                    arb issue verify {@task_id} --failed "&lt;evidence&gt;"
                  </code>
                </div>
              </.panel>

              <%!-- RELATIONSHIPS: this issue's graph position, grouped by
                   semantic role rather than raw edge direction (bd-11r7e1) —
                   dependency edges plus parent/child progress (moved out of
                   MACHINE STATE, design finding #4) — all in one panel. The
                   `:actions` slot is reserved, empty, for bd-dgh2xv's future
                   add/remove-dependency affordance. --%>
              <.panel
                id="panel-relationships"
                title="RELATIONSHIPS"
                meta={relationships_meta(@relationship_groups)}
                class="order-5"
              >
                <:actions>
                  <%!-- bd-dmabmg: available at every status, Backlog included
                       (§2.5) — wiring edges before promotion is what avoids
                       the promote-then-block dispatch window. --%>
                  <button
                    type="button"
                    id="rel-add-open"
                    phx-click="open_relationship_modal"
                    class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-link)] hover:text-[var(--text-title)] transition-colors cursor-pointer"
                  >
                    + add
                  </button>
                </:actions>
                <div class="flex flex-col gap-3">
                  <.relationship_group
                    id="rel-blocked-by"
                    label="Blocked by"
                    entries={@relationship_groups.blocked_by}
                    gating={true}
                    awaiting_verification_hint={true}
                    task={@task}
                  />
                  <.relationship_group
                    id="rel-blocks"
                    label="Blocks"
                    entries={@relationship_groups.blocks}
                    gating={true}
                    task={@task}
                  />
                  <.relationship_group
                    id="rel-parents"
                    label="Parent"
                    entries={@relationship_groups.parents}
                    task={@task}
                  />

                  <div
                    :if={@relationship_groups.children != []}
                    id="rel-children"
                    data-role="relationship-group"
                    data-gating="false"
                    class="flex flex-col gap-1.5 border-t border-[var(--border-default)] pt-3"
                  >
                    <div class="flex items-center gap-2">
                      <span class="inline-block size-1.5 rounded-full bg-[var(--text-label)]" />
                      <h3 class="text-[11px] font-medium text-[var(--text-label)]">
                        Children ({@task.child_closed || 0}/{@task.child_total || 0} closed)
                      </h3>
                      <span
                        :if={@task.auto_close}
                        data-role="auto-close-marker"
                        class="badge badge-ghost badge-xs shrink-0"
                      >
                        auto_close: on
                      </span>
                    </div>
                    <div
                      class="h-1.5 w-full overflow-hidden rounded-full bg-[var(--surface-sunken)]"
                      role="progressbar"
                      aria-valuenow={child_progress_pct(@task)}
                      aria-valuemin="0"
                      aria-valuemax="100"
                    >
                      <div
                        class="h-full bg-[var(--arb-live)]"
                        style={"width: #{child_progress_pct(@task)}%"}
                      />
                    </div>
                    <ul class="flex flex-col gap-1.5">
                      <li
                        :for={entry <- @relationship_groups.children}
                        id={"rel-children-#{entry.edge.id}"}
                      >
                        <.relationship_row entry={entry} task={@task} />
                      </li>
                    </ul>
                  </div>

                  <.relationship_group
                    id="rel-related"
                    label="Related"
                    entries={@relationship_groups.relates_to}
                    task={@task}
                  />
                  <.relationship_group
                    id="rel-conflicts-with"
                    label="Conflicts with"
                    entries={@relationship_groups.conflicts_with}
                    task={@task}
                  />
                  <.relationship_group
                    id="rel-discovered-from"
                    label="Discovered from"
                    entries={@relationship_groups.discovered_from}
                    task={@task}
                  />

                  <p
                    :if={relationships_empty?(@relationship_groups)}
                    class="text-[11.5px] italic text-[var(--text-label)]"
                  >
                    No relationships recorded for this {@issue_label}.
                  </p>
                </div>
              </.panel>

              <%!-- Messages addressed to (`to_ref`) or about (`task_ref`) this
                   issue: coordinator directions to its worker, worker
                   escalations back up, sibling flags. Read/clear state is
                   rendered, never written — see `refresh_messages/1`. --%>
              <.panel
                id="panel-messages"
                title="MESSAGES"
                meta={message_panel_meta(@messages)}
                class="order-10"
              >
                <div :if={@messages == []} id="messages-empty">
                  <ArbiterWeb.CoreComponents.Feedback.empty_state icon="hero-envelope">
                    No messages for this {@issue_label} yet.
                  </ArbiterWeb.CoreComponents.Feedback.empty_state>
                </div>

                <ul :if={@messages != []} id="messages-list" class="flex flex-col gap-2">
                  <li
                    :for={m <- @messages}
                    id={"message-#{m.id}"}
                    data-role="message-row"
                    class={[
                      "rounded-[var(--radius-field)] border border-solid border-[var(--border-default)]",
                      "border-l-[length:var(--border-accent-width)] px-3 py-2",
                      "bg-[var(--surface-sunken)]",
                      message_accent(m.kind)
                    ]}
                  >
                    <div class="flex items-baseline justify-between gap-2">
                      <div class="flex items-baseline gap-2 flex-wrap min-w-0">
                        <span
                          data-kind={m.kind}
                          class="text-[10px] uppercase tracking-[0.08em] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
                        >
                          {m.kind}
                        </span>
                        <span
                          :if={message_state(m)}
                          data-role="message-state"
                          class="text-[10px] uppercase tracking-[0.08em] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]"
                        >
                          {message_state(m)}
                        </span>
                      </div>
                      <span
                        data-role="message-time"
                        class="shrink-0 text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
                      >
                        {relative_age(m.inserted_at)}
                      </span>
                    </div>

                    <p
                      :if={present?(m.subject)}
                      data-role="message-subject"
                      class="mt-0.5 text-[12.5px] font-medium text-[var(--text-title)]"
                    >
                      {m.subject}
                    </p>

                    <p
                      data-role="message-parties"
                      class="mt-0.5 text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]"
                    >
                      {m.from_ref || "?"} → {m.to_ref || "—"}
                    </p>

                    <div :if={present?(m.body)} class="mt-1.5">
                      <div class={[
                        !message_expanded?(@expanded_messages, m.id) &&
                          long_message_body?(m.body) && "max-h-24 overflow-hidden"
                      ]}>
                        <.markdown
                          id={"message-body-md-#{m.id}"}
                          text={m.body}
                          class="markdown-body--compact"
                        />
                      </div>
                      <button
                        :if={long_message_body?(m.body)}
                        type="button"
                        id={"message-toggle-#{m.id}"}
                        phx-click="toggle_message"
                        phx-value-id={m.id}
                        class="mt-1 text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-link)] cursor-pointer hover:underline"
                      >
                        {if message_expanded?(@expanded_messages, m.id),
                          do: "show less",
                          else: "show more"}
                      </button>
                    </div>
                  </li>
                </ul>
              </.panel>

              <%!-- MACHINE STATE, trimmed: status/priority/type/difficulty
                   already show in the header band (design finding #1), and
                   child progress now lives in RELATIONSHIPS. --%>
              <.panel
                id="panel-machine-state"
                title="MACHINE STATE"
                class="order-11"
              >
                <.data_list class="text-[12px]">
                  <:item :if={@issue_repo} label={String.capitalize(@rig_label)}>
                    <code class="text-xs">{@issue_repo}</code>
                  </:item>
                  <:item label={String.capitalize(@workspace_label)}>
                    <span :if={@workspace}>
                      {@workspace.name} <code class="text-xs">{@workspace.prefix}</code>
                    </span>
                    <span :if={!@workspace} class="italic text-[var(--text-label)]">(none)</span>
                  </:item>
                  <:item :if={present?(@task.assignee)} label="Assignee">
                    <code class="text-xs">{@task.assignee}</code>
                  </:item>
                  <:item :if={@task.tracker_type != :none} label="Tracker">
                    <% tracker_url = tracker_url(@workspace, @task.tracker_ref) %>
                    <a
                      :if={tracker_url != ""}
                      href={tracker_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="link link-hover text-xs font-mono text-primary"
                    >
                      {@task.tracker_type}:{@task.tracker_ref}
                    </a>
                    <code :if={tracker_url == ""} class="text-xs">
                      {@task.tracker_type}{if present?(@task.tracker_ref),
                        do: ":" <> @task.tracker_ref}
                    </code>
                  </:item>
                  <:item label="Created">
                    <code class="text-xs">{format_audit_ts(@task.created_at)}</code>
                  </:item>
                  <:item :if={@task.updated_at} label="Updated">
                    <code class="text-xs">{format_audit_ts(@task.updated_at)}</code>
                  </:item>
                  <:item :if={@task.closed_at} label="Closed">
                    <code class="text-xs">{format_audit_ts(@task.closed_at)}</code>
                  </:item>
                </.data_list>
              </.panel>

              <%!-- The post-layering skill set (workspace → repo → issue) a
                   dispatch of this issue would carry right now. --%>
              <.panel
                id="panel-skills"
                title="SKILLS"
                meta={"#{length(@skills)} active"}
                class="order-13"
              >
                <p :if={@skills == []} class="text-[11.5px] italic text-[var(--text-label)]">
                  No skills resolve for this {@issue_label}.
                </p>
                <ul :if={@skills != []} class="flex flex-col gap-1">
                  <li
                    :for={s <- @skills}
                    class="flex items-center justify-between gap-2 text-[11.5px] font-[family-name:var(--font-mono)]"
                  >
                    <code class="text-[var(--text-secondary)] truncate">{s.name}</code>
                    <span class="text-[10.5px] text-[var(--text-label)] shrink-0">
                      {s.activation}
                    </span>
                  </li>
                </ul>
              </.panel>
            </div>
          </div>
        <% else %>
          <.panel>
            <div class="flex flex-col items-center gap-2 py-6 text-center">
              <ArbiterWeb.CoreComponents.icon
                name="hero-question-mark-circle"
                class="size-12 text-base-content/30"
              />
              <p class="text-base-content/70">
                Task <code class="text-sm">{@task_id}</code> not found.
              </p>
            </div>
          </.panel>
        <% end %>

        <div>
          <ArbiterWeb.CoreComponents.Navigation.back_link href="/tasks" label="Back to board" />
        </div>
      </div>
      <%!-- Edit modal. Worker-authored fields (notes/qa_notes/deployment_notes/
           pr_body) and tracker/PR linkage are deliberately absent — see the
           moduledoc. --%>
      <div :if={@edit_modal && @task} class="modal modal-open" id="task-edit-modal">
        <div class="modal-box max-w-2xl">
          <h3 class="font-semibold text-lg mb-3">Edit {@issue_label}</h3>
          <.form
            for={%{}}
            as={:task}
            id="task-edit-form"
            phx-submit="save_edit"
            class="grid sm:grid-cols-2 gap-x-4"
          >
            <div class="sm:col-span-2">
              <.input
                name="task[title]"
                label="Title"
                value={TaskForm.value(@edit_params, "title", @task.title)}
              />
            </div>
            <.input
              type="select"
              name="task[status]"
              label="Status"
              options={TaskForm.editable_status_options(@task.status)}
              value={TaskForm.value(@edit_params, "status", to_string(@task.status))}
            />
            <.input
              type="select"
              name="task[issue_type]"
              label="Type"
              options={@issue_type_options}
              value={TaskForm.value(@edit_params, "issue_type", to_string(@task.issue_type))}
            />
            <.input
              type="select"
              name="task[priority]"
              label="Priority"
              options={@priority_options}
              value={TaskForm.value(@edit_params, "priority", to_string(@task.priority))}
            />
            <.input
              type="select"
              name="task[difficulty]"
              label="Difficulty"
              options={@difficulty_options}
              value={
                TaskForm.value(
                  @edit_params,
                  "difficulty",
                  if(@task.difficulty, do: to_string(@task.difficulty), else: "")
                )
              }
            />
            <.input
              name="task[assignee]"
              label="Assignee (optional)"
              value={TaskForm.value(@edit_params, "assignee", @task.assignee || "")}
              placeholder="who owns this"
            />
            <.input
              name="task[target_branch]"
              label="Target branch (optional)"
              value={TaskForm.value(@edit_params, "target_branch", @task.target_branch || "")}
              placeholder="defaults to the repo's main"
            />
            <.input
              type="select"
              name="task[repo]"
              label="Repo (optional)"
              options={@repo_assignment_options}
              value={TaskForm.value(@edit_params, "repo", @task.repo || "")}
            />
            <div class="sm:col-span-2">
              <.input
                type="textarea"
                name="task[description]"
                label="Description"
                value={TaskForm.value(@edit_params, "description", @task.description || "")}
                rows="6"
              />
            </div>
            <div class="sm:col-span-2">
              <.input
                type="textarea"
                name="task[acceptance]"
                label="Acceptance"
                value={TaskForm.value(@edit_params, "acceptance", @task.acceptance || "")}
                rows="4"
              />
            </div>
            <p :if={@edit_error} class="sm:col-span-2 text-sm text-error">{@edit_error}</p>
            <div class="sm:col-span-2 modal-action">
              <ArbiterWeb.CoreComponents.button
                type="button"
                phx-click="cancel_edit"
                class="btn btn-sm btn-ghost"
              >
                Cancel
              </ArbiterWeb.CoreComponents.button>
              <ArbiterWeb.CoreComponents.button
                type="submit"
                variant="primary"
                class="btn btn-sm btn-primary"
              >
                Save
              </ArbiterWeb.CoreComponents.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="cancel_edit"></div>
      </div>

      <%!-- Close modal --%>
      <div :if={@close_modal && @task} class="modal modal-open" id="task-close-modal">
        <div class="modal-box">
          <h3 class="font-semibold text-lg mb-3">Close {@issue_label}</h3>
          <p class="text-sm text-base-content/70 mb-3">
            Closing <code class="text-xs">{@task_id}</code>
            takes it out of the routing pool. The reason is recorded in the audit log.
          </p>
          <.form for={%{}} as={:close} id="task-close-form" phx-submit="close_task" class="space-y-2">
            <.input
              type="textarea"
              name="close[reason]"
              label="Reason (optional)"
              value={TaskForm.value(@close_params, "reason")}
              rows="3"
              placeholder="Why is this being closed? e.g. superseded by bd-other"
            />
            <p :if={@close_error} class="text-sm text-error">{@close_error}</p>
            <div class="modal-action">
              <ArbiterWeb.CoreComponents.button
                type="button"
                phx-click="cancel_close"
                class="btn btn-sm btn-ghost"
              >
                Cancel
              </ArbiterWeb.CoreComponents.button>
              <ArbiterWeb.CoreComponents.button type="submit" class="btn btn-sm btn-error">
                Close it
              </ArbiterWeb.CoreComponents.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="cancel_close"></div>
      </div>

      <%!-- Promote waiver modal (bd-7mbrlg). Opens only when a plain
           "promote_to_ready" click was refused for lack of acceptance
           criteria — a waiver reason is the one way past that refusal. --%>
      <div
        :if={@promote_waiver_modal && @task}
        class="modal modal-open"
        id="task-promote-waiver-modal"
      >
        <div class="modal-box">
          <h3 class="font-semibold text-lg mb-3">Promote without acceptance criteria</h3>
          <p class="text-sm text-base-content/70 mb-3">
            <code class="text-xs">{@task_id}</code>
            has no acceptance criteria, so ReviewGate has nothing to score it against.
            Add <code class="text-xs">acceptance</code>
            via Edit, or give a reason to promote anyway.
          </p>
          <.form
            for={%{}}
            as={:waiver}
            id="task-promote-waiver-form"
            phx-submit="promote_with_waiver"
            class="space-y-2"
          >
            <.input
              type="textarea"
              name="waiver[reason]"
              label="Waiver reason"
              value={TaskForm.value(@promote_waiver_params, "reason")}
              rows="2"
              placeholder="e.g. spike, no user-facing behavior"
            />
            <p :if={@promote_waiver_error} class="text-sm text-error">{@promote_waiver_error}</p>
            <div class="modal-action">
              <ArbiterWeb.CoreComponents.button
                type="button"
                phx-click="cancel_promote_waiver"
                class="btn btn-sm btn-ghost"
              >
                Cancel
              </ArbiterWeb.CoreComponents.button>
              <ArbiterWeb.CoreComponents.button type="submit" class="btn btn-sm btn-primary">
                Promote with waiver
              </ArbiterWeb.CoreComponents.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="cancel_promote_waiver"></div>
      </div>

      <%!-- Dispatch modal. The acknowledgement checkbox IS the confirmation
           step — the server refuses an un-acknowledged submit. --%>
      <div :if={@dispatch_modal && @task} class="modal modal-open" id="task-dispatch-modal">
        <div class="modal-box">
          <h3 class="font-semibold text-lg mb-1">Dispatch a {@worker_label}</h3>
          <p class="text-sm text-base-content/70 mb-3">
            Spawns an agent on <code class="text-xs">{@task_id}</code> in a fresh worktree.
          </p>

          <div role="alert" class="alert alert-warning py-2 mb-3">
            <ArbiterWeb.CoreComponents.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
            <span class="text-sm">
              This spends real <strong>API credits</strong>
              and may open a pull request. There is no undo beyond stopping the {@worker_label}.
            </span>
          </div>

          <.form
            for={%{}}
            as={:dispatch}
            id="task-dispatch-form"
            phx-submit="dispatch"
            class="space-y-2"
          >
            <.input
              type="select"
              name="dispatch[provider]"
              label="Provider"
              options={@provider_options}
              value={TaskForm.value(@dispatch_params, "provider")}
              disabled={@dispatching}
            />
            <.input
              type="select"
              name="dispatch[repo]"
              label="Repo"
              options={@repo_options}
              value={TaskForm.value(@dispatch_params, "repo")}
              disabled={@dispatching}
            />
            <.input
              type="checkbox"
              name="dispatch[acknowledge]"
              label="I understand this spends API credits."
              value={TaskForm.value(@dispatch_params, "acknowledge", false)}
              disabled={@dispatching}
            />
            <p
              :if={@dispatching}
              id="task-dispatch-pending"
              class="text-sm text-base-content/70 flex items-center gap-2"
            >
              <span class="loading loading-spinner loading-xs"></span>
              Dispatching — checking provider auth and quota, provisioning the worktree, spawning the agent. Don't close this tab.
            </p>
            <p :if={@dispatch_error} class="text-sm text-error">{@dispatch_error}</p>
            <div class="modal-action">
              <ArbiterWeb.CoreComponents.button
                type="button"
                phx-click="cancel_dispatch"
                class="btn btn-sm btn-ghost"
                disabled={@dispatching}
              >
                Cancel
              </ArbiterWeb.CoreComponents.button>
              <ArbiterWeb.CoreComponents.button
                type="submit"
                variant="primary"
                class="btn btn-sm btn-primary"
                disabled={@dispatching}
              >
                {if @dispatching, do: "Dispatching…", else: "Dispatch"}
              </ArbiterWeb.CoreComponents.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="cancel_dispatch"></div>
      </div>
      <%!-- Add-a-relationship modal (bd-dmabmg, design §3.3). Phrased as a
           sentence from this issue's point of view — "bd-x is blocked by …" —
           so the operator never meets the from/to convention that produces
           most wrong edges. --%>
      <div :if={@rel_modal && @task} class="modal modal-open" id="relationship-add-modal">
        <div class="modal-box max-w-xl">
          <h3 class="font-semibold text-lg mb-3">Add a relationship</h3>
          <.form
            for={%{}}
            as={:rel}
            id="relationship-add-form"
            phx-change="relationship_change"
            phx-submit="add_relationship"
            class="space-y-3"
          >
            <%!-- The id *is* the label: read top to bottom the control spells
                 out "bd-x … is blocked by …", which is the sentence the
                 operator is composing. --%>
            <.input
              type="select"
              name="rel[phrase]"
              id="rel-phrase"
              label={"#{@task_id}…"}
              options={@relationship_phrase_options}
              value={@rel_phrase}
            />

            <.input
              type="text"
              name="rel[query]"
              id="rel-query"
              label={"Which #{@issue_label}?"}
              value={@rel_query}
              autocomplete="off"
              phx-debounce="150"
              placeholder={"Search by id or title — or paste an #{@issue_label} id"}
            />

            <div
              :if={@rel_target}
              id="rel-selected"
              class="flex items-center gap-2 rounded-[var(--radius-field)] border border-[var(--border-default)] px-2 py-1.5"
            >
              <code class="text-xs text-[var(--text-title)]">{@rel_target && @rel_target.id}</code>
              <span class="truncate text-sm flex-1">{@rel_target && @rel_target.title}</span>
              <button
                type="button"
                id="rel-clear-target"
                phx-click="clear_relationship_target"
                class="text-[11px] text-[var(--text-link)] cursor-pointer"
              >
                change
              </button>
            </div>

            <ul
              :if={!@rel_target && @rel_candidates != []}
              id="rel-candidates"
              class="flex flex-col gap-1"
            >
              <li :for={candidate <- @rel_candidates} id={"rel-candidate-#{candidate.issue.id}"}>
                <button
                  :if={is_nil(candidate.reason)}
                  type="button"
                  phx-click="select_relationship_target"
                  phx-value-id={candidate.issue.id}
                  class="flex w-full items-center gap-2 rounded-[var(--radius-field)] px-2 py-1.5 text-left hover:bg-[var(--surface-sunken)] transition-colors cursor-pointer"
                >
                  <code class="text-xs text-[var(--text-label)] shrink-0">{candidate.issue.id}</code>
                  <span class="truncate text-sm flex-1">{candidate.issue.title}</span>
                  <span class={["badge badge-xs shrink-0", status_badge_class(candidate.issue.status)]}>
                    {candidate.issue.status}
                  </span>
                </button>
                <%!-- Greyed, not hidden: "why can't I pick this one" is the
                     question the pre-check exists to answer (§3.3). --%>
                <div
                  :if={candidate.reason}
                  data-role="rel-candidate-disabled"
                  class="flex flex-wrap items-center gap-2 rounded-[var(--radius-field)] px-2 py-1.5 opacity-50"
                >
                  <code class="text-xs text-[var(--text-label)] shrink-0">{candidate.issue.id}</code>
                  <span class="truncate text-sm flex-1">{candidate.issue.title}</span>
                  <span class="text-[11px] text-[var(--arb-attention)]">⚠ {candidate.reason}</span>
                </div>
              </li>
            </ul>

            <p
              :if={!@rel_target && @rel_candidates == [] && String.trim(@rel_query) != ""}
              id="rel-no-matches"
              class="text-[11.5px] italic text-[var(--text-label)]"
            >
              No {@issue_label} in this {@workspace_label} matches that. Submitting anyway will
              try the text as an id.
            </p>

            <.input
              type="textarea"
              name="rel[note]"
              id="rel-note"
              label="Note (optional)"
              value={@rel_note}
              rows="2"
              phx-debounce="300"
              placeholder="Why does this relationship exist?"
            />

            <div
              :for={warning <- @rel_warnings}
              id={"rel-warning-#{warning.key}"}
              data-role="rel-warning"
              class="rounded-[var(--radius-field)] border-l-[3px] border-l-[var(--arb-attention)] bg-[var(--surface-sunken)] px-2.5 py-2 text-[11.5px] text-[var(--text-secondary)]"
            >
              ⚠ {warning.text}
              <.link
                :if={warning.link}
                navigate={warning.link && warning.link.href}
                class="ml-1 underline text-[var(--text-link)]"
              >
                {warning.link && warning.link.label}
              </.link>
            </div>

            <div :if={@rel_error} id="rel-error" class="text-sm text-error">
              {@rel_error}
              <span :if={@rel_cycle_path != []} id="rel-cycle-path" class="block mt-1 text-xs">
                <span :for={{id, index} <- Enum.with_index(@rel_cycle_path)}>
                  <span :if={index > 0}>→</span>
                  <.link
                    navigate={~p"/tasks/#{id}"}
                    class="underline font-[family-name:var(--font-mono)]"
                  >
                    {id}
                  </.link>
                </span>
              </span>
            </div>

            <div class="modal-action">
              <ArbiterWeb.CoreComponents.button
                type="button"
                phx-click="cancel_relationship_modal"
                class="btn btn-sm btn-ghost"
              >
                Cancel
              </ArbiterWeb.CoreComponents.button>
              <%!-- Never disabled: every warning above is informational, and
                   the only hard blocks are the facade's four guards (§3.3). --%>
              <ArbiterWeb.CoreComponents.button
                type="submit"
                id="rel-submit"
                variant="primary"
                class="btn btn-sm btn-primary"
              >
                Add relationship
              </ArbiterWeb.CoreComponents.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="cancel_relationship_modal"></div>
      </div>

      <%!-- Remove confirm. Deliberately a modal and not `data-confirm`: this
           is where the mirror-image warnings get read. --%>
      <div
        :if={@rel_remove_entry && @task}
        class="modal modal-open"
        id="relationship-remove-modal"
      >
        <div class="modal-box">
          <h3 class="font-semibold text-lg mb-3">Remove this relationship</h3>
          <p class="text-sm text-base-content/70 mb-3">
            <code class="text-xs">{@task_id}</code>
            <span class="font-[family-name:var(--font-mono)]">
              {@rel_remove_entry && @rel_remove_entry.edge.type}
            </span>
            <code class="text-xs">{@rel_remove_entry && @rel_remove_entry.issue_id}</code>
            — the edge is deleted; neither {@issue_label} is otherwise changed.
          </p>
          <div
            :for={warning <- @rel_remove_warnings}
            id={"rel-remove-warning-#{warning.key}"}
            data-role="rel-warning"
            class="mb-2 rounded-[var(--radius-field)] border-l-[3px] border-l-[var(--arb-attention)] bg-[var(--surface-sunken)] px-2.5 py-2 text-[11.5px] text-[var(--text-secondary)]"
          >
            ⚠ {warning.text}
          </div>
          <p :if={@rel_remove_error} class="text-sm text-error">{@rel_remove_error}</p>
          <div class="modal-action">
            <ArbiterWeb.CoreComponents.button
              type="button"
              phx-click="cancel_remove_edge"
              class="btn btn-sm btn-ghost"
            >
              Cancel
            </ArbiterWeb.CoreComponents.button>
            <ArbiterWeb.CoreComponents.button
              type="button"
              id="rel-remove-confirm"
              phx-click="remove_edge"
              class="btn btn-sm btn-error"
            >
              Remove
            </ArbiterWeb.CoreComponents.button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="cancel_remove_edge"></div>
      </div>
    </Layouts.app>
    """
  end

  # ---- render helpers ----

  # A labeled group of relationship rows, omitted entirely when empty
  # (acceptance #1). `gating` distinguishes the two groups that actually
  # change dispatch (Blocked by / Blocks) from the informational rest
  # (acceptance #2); `data-gating` carries the same fact for tests.
  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:entries, :list, required: true)
  attr(:gating, :boolean, default: false)
  attr(:awaiting_verification_hint, :boolean, default: false)
  attr(:task, :map, required: true)

  defp relationship_group(assigns) do
    ~H"""
    <div
      :if={@entries != []}
      id={@id}
      data-role="relationship-group"
      data-gating={to_string(@gating)}
      class="flex flex-col gap-1.5 border-t border-[var(--border-default)] pt-3"
    >
      <div class="flex items-center gap-2">
        <span class={[
          "inline-block size-1.5 rounded-full",
          @gating && "bg-[var(--arb-fail)]",
          !@gating && "bg-[var(--text-label)]"
        ]} />
        <h3 class={[
          "text-[11px] font-medium",
          @gating && "text-[var(--arb-fail)]",
          !@gating && "text-[var(--text-label)]"
        ]}>
          {@label} ({length(@entries)})
        </h3>
      </div>
      <ul class="flex flex-col gap-1.5">
        <li :for={entry <- @entries} id={"#{@id}-#{entry.edge.id}"}>
          <.relationship_row
            entry={entry}
            task={@task}
            awaiting_verification_hint={@awaiting_verification_hint}
          />
        </li>
      </ul>
    </div>
    """
  end

  attr(:entry, :map, required: true)
  attr(:task, :map, required: true)
  attr(:awaiting_verification_hint, :boolean, default: false)

  defp relationship_row(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <div class="flex items-center gap-2">
        <span class="badge badge-ghost badge-xs font-mono shrink-0">{@entry.edge.type}</span>
        <.link navigate={~p"/tasks/#{@entry.issue_id}"} class="min-w-0 flex-1 group">
          <div class="flex items-center gap-2">
            <code class="text-xs text-base-content/60 shrink-0 group-hover:text-primary transition-colors">
              {@entry.issue_id}
            </code>
            <span
              :if={@entry.issue}
              class="truncate text-sm group-hover:text-primary transition-colors"
              title={@entry.issue.title}
            >
              {@entry.issue.title}
            </span>
          </div>
        </.link>
        <span
          :if={cross_workspace?(@entry.issue, @task)}
          data-role="cross-workspace-marker"
          class="badge badge-outline badge-xs shrink-0"
          title="cross-workspace edge — read-only here"
        >
          ⧉ other workspace
        </span>
        <span
          :if={@entry.issue && awaiting_verification_blocker?(@entry, @awaiting_verification_hint)}
          data-role="awaiting-verification-chip"
          class="badge badge-warning badge-xs shrink-0"
        >
          awaiting verification
        </span>
        <span
          :if={@entry.issue && !awaiting_verification_blocker?(@entry, @awaiting_verification_hint)}
          class={["badge badge-xs shrink-0", status_badge_class(@entry.issue.status)]}
        >
          {@entry.issue.status}
        </span>
        <%!-- Removal is confirmed in a modal rather than a `data-confirm`
             prompt, because the confirm is where the §2.1/§2.2 mirror
             warnings ("becomes dispatchable", "will close bd-parent") have to
             be read. Cross-workspace edges keep no ⨯: `remove/3` would happily
             delete one, but the panel renders them read-only (§2.4) and a
             half-editable row is worse than an honest one. --%>
        <button
          :if={!cross_workspace?(@entry.issue, @task)}
          type="button"
          id={"rel-remove-#{@entry.edge.id}"}
          phx-click="open_remove_edge"
          phx-value-edge={@entry.edge.id}
          title="Remove this relationship"
          aria-label={"Remove the relationship to #{@entry.issue_id}"}
          class="shrink-0 px-1 text-[13px] leading-none text-[var(--text-label)] hover:text-[var(--arb-fail)] transition-colors cursor-pointer"
        >
          ⨯
        </button>
      </div>
      <p
        :if={@entry.issue && awaiting_verification_blocker?(@entry, @awaiting_verification_hint)}
        data-role="awaiting-verification-hint"
        class="pl-6 text-[11px] text-[var(--text-secondary)]"
      >
        merged; waiting on someone to verify it — it blocks until verified.
        <code class="ml-1 text-[10.5px]">arb issue verify {@entry.issue_id}</code>
      </p>
      <details
        :if={present?(@entry.edge.notes) || present?(@entry.edge.created_by)}
        class="pl-6"
      >
        <summary class="cursor-pointer text-[10.5px] text-[var(--text-label)] select-none">
          notes
        </summary>
        <p :if={present?(@entry.edge.created_by)} class="text-[10.5px] text-[var(--text-secondary)]">
          by {@entry.edge.created_by}
        </p>
        <p
          :if={present?(@entry.edge.notes)}
          class="whitespace-pre-wrap text-[10.5px] text-[var(--text-secondary)]"
        >
          {@entry.edge.notes}
        </p>
      </details>
    </div>
    """
  end

  # ---- view helpers (status visuals + formatting) ----

  defp tracker_url(nil, _ref), do: ""
  defp tracker_url(_workspace, nil), do: ""
  defp tracker_url(_workspace, ""), do: ""

  defp tracker_url(%Workspace{} = workspace, ref) do
    Trackers.link_for_workspace(workspace, ref)
  rescue
    _ -> ""
  end

  defp pr_url(nil, _ref), do: ""
  defp pr_url(_workspace, nil), do: ""
  defp pr_url(_workspace, ""), do: ""

  defp pr_url(%Workspace{} = workspace, ref) do
    Mergers.link_for_workspace(workspace, ref)
  rescue
    _ -> ""
  end

  # Canonical directive-status mapping (matches dashboard + doctrine).
  defp status_badge_class(:open), do: "badge-success"
  defp status_badge_class(:in_progress), do: "badge-info"
  defp status_badge_class(:closed), do: "badge-ghost"
  defp status_badge_class(:awaiting_verification), do: "badge-warning"
  defp status_badge_class(_), do: ""

  # bd-5lc99r: a string field counts as present only when it is non-nil and not
  # blank after trimming — used to decide whether the findings/notes section has
  # real content to render.
  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false

  # ---- worker spend (bd-8j9i9p) --------------------------------------------

  # `Estimate: $3.00–$8.00 (p90 $9.00) · difficulty+type, n=77`. Basis and n
  # ride along always, not just on the coarse rungs: a `global, n=11` range and
  # a `difficulty+type, n=214` range should not read the same.
  defp estimate_label(nil), do: "no estimate yet"

  defp estimate_label(est) do
    "Estimate: #{money(est.p25)}\u2013#{money(est.p75)} (p90 #{money(est.p90)}) " <>
      "\u00b7 #{est.basis}, n=#{est.n}"
  end

  defp spend_chip_label(:running_high), do: "running high"
  defp spend_chip_label(:over_budget), do: "over budget"
  defp spend_chip_label(_state), do: nil

  defp spend_chip_title(%{state: :running_high, estimate: est}),
    do: "Past the p75 of what issues like this cost (#{money(est.p75)}) — informational."

  defp spend_chip_title(%{state: :over_budget, estimate: est}),
    do:
      "Past the p90 of what issues like this cost (#{money(est.p90)}). " <>
        "Nothing has been stopped; the coordinator has been told once."

  defp spend_chip_title(_budget), do: nil

  defp money(n) when is_number(n), do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)
  defp money(_n), do: "$?"

  defp difficulty_label(nil), do: "—"
  defp difficulty_label(d) when is_integer(d) and d in 0..5, do: "D#{d}"
  defp difficulty_label(_), do: "—"

  # Compact changeset summary for the timeline. Mirrors AuditLogLive.
  defp format_changes(changes) when is_map(changes) do
    changes
    |> Map.take(["status", "title", "priority", "tracker_type", "assignee"])
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end

  defp format_changes(_), do: ""

  defp format_audit_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_audit_ts(other), do: to_string(other)

  defp format_started(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_started(other), do: to_string(other)

  defp worker_activity_label(worker) do
    case Map.get(worker, :meta) do
      %{"activity" => %{"label" => label}} when is_binary(label) -> label
      %{activity: %{label: label}} when is_binary(label) -> label
      %{"activity" => label} when is_binary(label) -> label
      %{activity: label} when is_binary(label) -> label
      _ -> "working"
    end
  end

  defp run_cost_label(%UsageEvent{cost_usd: c}) when is_float(c) do
    "$#{:erlang.float_to_binary(c, decimals: 4)}"
  end

  defp run_cost_label(_), do: "—"

  defp humanize_run_duration(%DateTime{} = started_at, %DateTime{} = completed_at) do
    started_at |> DateTime.diff(completed_at, :second) |> abs() |> humanize_run_seconds()
  end

  defp humanize_run_duration(_, _), do: "—"

  defp humanize_run_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_run_seconds(s) when s < 3600, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  defp humanize_run_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  # ---- acceptance criteria ----

  # Markdown task-list markers, the shape `arb`/the trackers already write:
  # `- [ ] text`, `* [x] text`, `1. [ ] text`.
  @criterion_re ~r/^\s*(?:[-*+]|\d+\.)\s+\[([ xX])\]\s*(.*)$/

  # One entry per line of the acceptance text, carrying the line index so a
  # toggle can rewrite exactly that line and leave the rest untouched. Lines
  # that aren't task-list items render as prose.
  defp acceptance_items(nil), do: []

  defp acceptance_items(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      case Regex.run(@criterion_re, line) do
        [_, mark, body] ->
          %{index: index, checkbox?: true, checked: String.downcase(mark) == "x", text: body}

        _ ->
          %{index: index, checkbox?: false, checked: false, text: String.trim(line)}
      end
    end)
    |> Enum.reject(&(&1.text == "" and not &1.checkbox?))
  end

  defp acceptance_items(_), do: []

  defp acceptance_meta(items) do
    case Enum.filter(items, & &1.checkbox?) do
      [] -> nil
      boxes -> "#{Enum.count(boxes, & &1.checked)}/#{length(boxes)} checked"
    end
  end

  # Flip the marker on line `index`, byte-for-byte preserving every other
  # line (including indentation and any trailing markdown).
  defp toggle_criterion(text, index) when is_binary(text) and is_integer(index) do
    lines = String.split(text, "\n")

    case Enum.at(lines, index) do
      nil ->
        :error

      line ->
        case flip_marker(line) do
          {:ok, flipped} -> {:ok, lines |> List.replace_at(index, flipped) |> Enum.join("\n")}
          :error -> :error
        end
    end
  end

  defp flip_marker(line) do
    case Regex.run(@criterion_re, line, capture: :all_but_first) do
      [" ", _] ->
        {:ok, String.replace(line, "[ ]", "[x]", global: false)}

      [mark, _] when mark in ["x", "X"] ->
        {:ok, Regex.replace(~r/\[[xX]\]/, line, "[ ]", global: false)}

      _ ->
        :error
    end
  end

  # ---- run roster ----

  # Canonical tab order — `Arbiter.Workers.Run.worker_types/0` order, so a new
  # worker type shows up here as soon as it exists.
  # Handoff order, which is the order a run actually happens in — the
  # resource's own `worker_types` list is declaration order, not lifecycle
  # order. Anything the resource grows that isn't listed here still gets a
  # tab, appended after the known roles.
  @role_order ~w(main impl review fix_pass conflict)

  defp run_roles do
    known = Enum.map(Run.worker_types(), &Atom.to_string/1)
    @role_order ++ (known -- @role_order)
  end

  # `fix_pass` is a database value; the tab is prose.
  defp run_role_label(role), do: String.replace(role, "_", " ")

  defp run_role(%Run{worker_type: type}) when is_atom(type) and not is_nil(type),
    do: Atom.to_string(type)

  defp run_role(_), do: "main"

  # "All" plus one tab per role that actually has runs — an empty `conflict`
  # tab is a dead end, not a filter.
  defp run_tabs(runs) do
    counts = Enum.frequencies_by(runs, &run_role/1)

    [%{label: "All", value: "all", count: length(runs)}] ++
      Enum.flat_map(run_roles(), fn role ->
        case Map.get(counts, role) do
          nil -> []
          count -> [%{label: run_role_label(role), value: role, count: count}]
        end
      end)
  end

  defp filter_runs(runs, "all"), do: runs
  defp filter_runs(runs, role), do: Enum.filter(runs, &(run_role(&1) == role))

  # The roster's worker cell is 48px: the run's short id is the only handle
  # that fits, and the expanded header carries the full ids.
  defp run_worker_label(%Run{id: id}) when is_binary(id), do: String.slice(id, 0, 8)
  defp run_worker_label(_), do: "—"

  defp run_failed?(%Run{status: :failed}), do: true
  defp run_failed?(%Run{exit_code: code}) when is_integer(code) and code != 0, do: true
  defp run_failed?(_), do: false

  defp run_failure_line(%Run{} = run) do
    [
      run.exit_code && "exit #{run.exit_code}",
      present?(run.failure_reason) && run.failure_reason
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  # What the run produced, in the one column an operator scans. A failure
  # says why; anything else says how much it wrote — counting the live buffer
  # when this is the followed run, since a running row's persisted
  # `output_lines` is still the empty list written at start.
  defp run_outcome(%Run{} = run, live_run_id, live_lines) do
    lines = run_output_lines(run, live_run_id, live_lines)

    cond do
      outcome_reason?(run) -> run_failure_line(run)
      lines == [] and run.status == :running -> "streaming…"
      true -> "#{length(lines)} lines"
    end
  end

  # bd-8tjcms `:review_not_started` and bd-9zuvbh `:review_parked` are terminal
  # NON-failures, so `run_failed?/1` (correctly) says no about both — but the
  # recorded reason is still the only thing worth showing in this column: the
  # run itself produced nothing new to count, and "why is this sitting still"
  # is exactly what an operator is scanning for.
  @outcome_reason_statuses [:review_not_started, :review_parked]

  defp outcome_reason?(%Run{} = run) do
    (run_failed?(run) or run.status in @outcome_reason_statuses) and run_failure_line(run) != ""
  end

  # The one place that decides where a run's transcript comes from.
  defp run_output_lines(%Run{id: id}, live_run_id, live_lines) when id == live_run_id,
    do: live_lines

  defp run_output_lines(%Run{output_lines: lines}, _live_run_id, _live_lines), do: lines || []

  # Output lines carry no per-line timestamps, so the time gutter numbers them
  # instead — the same handle a `Full transcript` link uses.
  defp transcript_lines(lines) when is_list(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} -> %{time: to_string(number), role: "out", text: line} end)
  end

  defp run_count_summary([]), do: "No runs on this issue yet."
  defp run_count_summary([_one]), do: "1 run on this issue"
  defp run_count_summary(runs), do: "#{length(runs)} runs on this issue"

  # `9 total · 1 running · $3.42` — the three numbers that decide whether the
  # roster is worth opening. Spend is only shown once something has cost
  # something; a `$0.00` on an issue with no ledger rows reads as a fact.
  defp runs_meta(runs, usage_by_run) do
    running = Enum.count(runs, &(&1.status == :running))

    spend =
      runs
      |> Enum.map(&Map.get(usage_by_run, &1.id))
      |> Enum.map(fn
        %UsageEvent{cost_usd: cost} when is_float(cost) -> cost
        _ -> 0.0
      end)
      |> Enum.sum()

    [
      "#{length(runs)} total",
      running > 0 && "#{running} running",
      spend > 0.0 && "$#{:erlang.float_to_binary(spend, decimals: 2)}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  # Relative age, coarsest unit that still says something: `41m ago`, `2d ago`.
  defp relative_age(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      seconds < 60 -> "#{max(seconds, 0)}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp relative_age(_), do: "—"

  # ---- message display helpers ----

  # Clamp anything past a short preview. Lines, not bytes: a six-line body of
  # short bullets reads as long in a narrow rail, a single wrapped paragraph
  # of the same byte count does not — so both measures get a say.
  @message_preview_lines 6
  @message_preview_bytes 400

  defp long_message_body?(body) when is_binary(body) do
    byte_size(body) > @message_preview_bytes or
      length(String.split(body, "\n")) > @message_preview_lines
  end

  defp long_message_body?(_), do: false

  defp message_expanded?(expanded, id), do: MapSet.member?(expanded, id)

  # The rail header carries the count, and says so when the cap is what the
  # operator is seeing rather than the whole history.
  defp message_panel_meta([]), do: nil

  defp message_panel_meta(messages) when length(messages) < @message_limit,
    do: "#{length(messages)}"

  defp message_panel_meta(_messages), do: "latest #{@message_limit}"

  # Read/clear state, shown and never set from this page. nil means "nothing
  # worth a badge" — a read-but-uncleared row is the ordinary case.
  defp message_state(%{cleared_at: %DateTime{}}), do: "cleared"
  defp message_state(%{read_at: nil}), do: "unread"
  defp message_state(_), do: nil

  # Same accent vocabulary the coordinator drawer uses (ArbiterWeb.Layouts),
  # so a given kind reads the same colour wherever it is rendered.
  defp message_accent(:escalation), do: "border-l-[color:var(--arb-fail)]"
  defp message_accent(:failure), do: "border-l-[color:var(--arb-fail)]"
  defp message_accent(:completion), do: "border-l-[color:var(--arb-live)]"
  defp message_accent(:direction), do: "border-l-[color:var(--arb-attention)]"
  defp message_accent(:flag), do: "border-l-[color:var(--arb-attention)]"
  defp message_accent(_), do: "border-l-[color:var(--arb-info)]"

  defp run_role_breakdown([]), do: nil

  defp run_role_breakdown(runs) do
    counts = Enum.frequencies_by(runs, &run_role/1)

    run_roles()
    |> Enum.flat_map(fn role ->
      case Map.get(counts, role) do
        nil -> []
        count -> ["#{count} #{role}"]
      end
    end)
    |> Enum.join(" · ")
  end

  defp worker_activity(nil), do: nil

  defp worker_activity(worker) do
    cond do
      Map.get(worker, :claude_session?) && worker.status in [:idle, :running] ->
        worker_activity_label(worker)

      # Run over: the adjacent status chip already says what happened, so
      # don't show a frozen activity.
      Map.get(worker, :claude_session?) ->
        nil

      true ->
        step = Map.get(worker, :current_step)
        step && to_string(step)
    end
  end

  @displayed_relationship_groups [
    :blocked_by,
    :blocks,
    :parents,
    :children,
    :relates_to,
    :conflicts_with,
    :discovered_from
  ]

  defp relationships_meta(groups) do
    gating = length(groups.blocked_by) + length(groups.blocks)

    total =
      Enum.reduce(@displayed_relationship_groups, 0, fn key, acc ->
        acc + length(Map.get(groups, key, []))
      end)

    "#{gating} blocking · #{total} total"
  end

  defp relationships_empty?(groups) do
    Enum.all?(@displayed_relationship_groups, &(Map.get(groups, &1, []) == []))
  end

  defp cross_workspace?(nil, _task), do: false
  defp cross_workspace?(%Issue{workspace_id: ws}, %Issue{workspace_id: ws}), do: false
  defp cross_workspace?(%Issue{}, %Issue{}), do: true

  defp awaiting_verification_blocker?(%{issue: %Issue{status: :awaiting_verification}}, true),
    do: true

  defp awaiting_verification_blocker?(_entry, _hint), do: false

  defp child_progress_pct(%Issue{child_total: total, child_closed: closed})
       when is_integer(total) and total > 0 do
    round((closed || 0) / total * 100)
  end

  defp child_progress_pct(_task), do: 0

  # ---- activity stream ----

  # The same paper-trail transitions `/audit` lists, scoped to this subject
  # and shaped for the log stream: action in the role gutter, changed fields
  # as the payload.
  defp activity_lines(versions) do
    Enum.map(versions, fn v ->
      %{
        # §4 asks for relative time here (`41m ago · gate · …`) — the same
        # convention the header block above already uses.
        time: relative_age(v.version_inserted_at),
        role: to_string(v.version_action_name),
        text: activity_text(v)
      }
    end)
  end

  # The stream is the latest `@version_limit` transitions, not all of them.
  defp activity_meta(versions, total) do
    shown = length(versions)

    if is_integer(total) and total > shown,
      do: "latest #{shown} of #{total} transitions",
      else: "#{shown} transitions"
  end

  defp activity_text(v) do
    case format_changes(v.changes) do
      "" -> "—"
      changes -> changes
    end
  end
end
