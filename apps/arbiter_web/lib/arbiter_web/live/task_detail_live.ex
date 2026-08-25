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

  ## Why promotion has no modal, and no gate

  The other three actions each destroy or spend something, so each asks first.
  Promotion spends nothing, and Ready is not a commitment — the scheduler still
  decides on the merits. So it is one click, and no confirmation is one fewer
  reason to leave work unrefined. It *is* one-way for now: `refined` is not on
  any action's accept list but this one's, so there is no de-refine path from
  the UI, CLI, REST or MCP. A demote path is a separate decision.

  It is deliberately *not* gated on the task being filled in. Backlog is a
  refinement surface, not a completeness checklist: the button is clickable
  with an empty description and no acceptance criteria, because the operator
  reading the ticket is a better judge of "refined enough" than a field count.
  A softer nudge may earn its place later; a hard gate would only teach people
  to type something into the box to get past it.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Agents
  alias Arbiter.Mergers
  alias Arbiter.Skills.Selection
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Issue.Version
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers
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

  @impl true
  def mount(%{"id" => task_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
    end

    {:ok,
     socket
     |> assign(:task_id, task_id)
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
     |> assign(:dispatch_modal, false)
     |> assign(:dispatch_error, nil)
     |> assign(:dispatch_params, %{})
     |> assign(:dispatching, false)
     |> assign(:repo_options, [])
     |> assign(:priority_options, TaskForm.priority_options())
     |> assign(:difficulty_options, TaskForm.difficulty_options())
     |> assign(:issue_type_options, TaskForm.issue_type_options())
     |> assign(:status_options, TaskForm.editable_status_options())
     |> assign(:provider_options, provider_options())
     |> assign(:run_filter, "all")
     |> assign(:expanded_run, nil)
     |> assign(:live_run_id, nil)
     |> assign(:live_run_topic, nil)
     |> assign(:live_run_lines, [])
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
      {:noreply, socket |> refresh_worker() |> refresh_runs()}
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
    {:noreply, assign(socket, edit_modal: true, edit_error: nil, edit_params: %{})}
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
          target_branch: TaskForm.trimmed(params["target_branch"])
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
  # One write, no modal. `:promote_to_ready` is idempotent, so a double-click
  # is harmless, and the button disappears on the re-render either way.

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
            {:noreply, put_flash(socket, :error, TaskForm.error_message(err))}
        end

      _ ->
        {:noreply, socket}
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
    [{"Workspace default", ""}] ++ Enum.map(Dispatch.all_available_repos(task), &{&1, &1})
  end

  defp repo_options(_), do: [{"Workspace default", ""}]

  defp dispatch_failure(:no_repo_configured),
    do:
      "no repo is configured for this workspace — add one to the workspace's " <>
        "repo_paths config (or :arbiter, :repo_paths) first."

  defp dispatch_failure({:repo_not_found, repo}),
    do: "repo #{inspect(repo)} isn't in any configured repo_paths."

  defp dispatch_failure({:ambiguous_repo, repos}),
    do: "several repos are configured (#{Enum.join(repos, ", ")}) — pick one explicitly."

  defp dispatch_failure(reason), do: inspect(reason)

  # ---- data ----

  defp refresh_all(socket) do
    socket
    |> refresh_task()
    |> refresh_workspace()
    |> refresh_worker()
    |> refresh_runs()
    |> refresh_deps()
    |> refresh_versions()
    |> refresh_skills()
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

  defp refresh_deps(socket) do
    id = socket.assigns.task_id

    {outbound, inbound} =
      try do
        all =
          Dependency
          |> Ash.Query.filter(from_issue_id == ^id or to_issue_id == ^id)
          |> Ash.read!()

        out = Enum.filter(all, &(&1.from_issue_id == id))
        ins = Enum.filter(all, &(&1.to_issue_id == id))

        # Look up the other-side issue for each row so the template can
        # show the target's title + status without an extra request per
        # edge.
        other_ids =
          (Enum.map(out, & &1.to_issue_id) ++ Enum.map(ins, & &1.from_issue_id))
          |> Enum.uniq()

        by_id =
          other_ids
          |> Enum.map(fn oid ->
            case Ash.get(Issue, oid) do
              {:ok, b} -> {oid, b}
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Map.new()

        {decorate(out, :to_issue_id, by_id), decorate(ins, :from_issue_id, by_id)}
      rescue
        _ -> {[], []}
      end

    socket
    |> assign(:outbound_deps, outbound)
    |> assign(:inbound_deps, inbound)
  end

  defp decorate(deps, side_key, by_id) do
    Enum.map(deps, fn d ->
      other = Map.get(by_id, Map.get(d, side_key))
      Map.put(d, :other_issue, other)
    end)
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

  # §4's right rail leads with `repo`. An `Issue` carries no repo column — the
  # checkout is chosen at dispatch — so the honest source is the most recent
  # run that recorded one, falling back to the workspace's configured repo
  # when there is exactly one and the answer is therefore unambiguous.
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
        </div>

        <%= if @task do %>
          <div class="grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_340px] gap-[var(--space-4)] items-start">
            <%!-- ══ Main column ═════════════════════════════════════════ --%>
            <div class="flex flex-col gap-[var(--space-4)] min-w-0">
              <.panel :if={present?(@task.description)} title="DESCRIPTION">
                <pre class="whitespace-pre-wrap break-words text-[12px] leading-relaxed font-[family-name:var(--font-mono)] text-[var(--arb-text-body)]">{@task.description}</pre>
              </.panel>

              <%!-- Acceptance criteria are real checkboxes, not decoration:
                   ticking one rewrites the markdown marker on the issue, so
                   `arb show` and the tracker read the same state back. --%>
              <.panel
                :if={@acceptance_items != []}
                title="ACCEPTANCE"
                meta={acceptance_meta(@acceptance_items)}
              >
                <ul class="flex flex-col gap-[7px]">
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
              </.panel>

              <%!-- bd-5lc99r: for a `task`-type directive the findings summary
                   in `notes` is the deliverable, so it gets its own panel with
                   a placeholder while still blank. --%>
              <.panel :if={@task.issue_type == :task} title="FINDINGS">
                <pre
                  :if={present?(@task.notes)}
                  class="whitespace-pre-wrap break-words text-[12px] leading-relaxed font-[family-name:var(--font-mono)] text-[var(--arb-text-body)]"
                >{@task.notes}</pre>
                <p :if={!present?(@task.notes)} class="text-[12px] italic text-[var(--text-label)]">
                  No findings recorded yet — the worker writes its results here before completing.
                </p>
              </.panel>

              <.panel :if={@task.issue_type != :task and present?(@task.notes)} title="NOTES">
                <pre class="whitespace-pre-wrap break-words text-[12px] leading-relaxed font-[family-name:var(--font-mono)] text-[var(--arb-text-body)]">{@task.notes}</pre>
              </.panel>

              <.panel
                :if={
                  present?(@task.pr_ref) or present?(@task.target_branch) or
                    present?(@task.pr_body) or @prior_mr_refs != []
                }
                title="MERGE"
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
                    <pre class="whitespace-pre-wrap break-words text-[11.5px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]">{@task.pr_body}</pre>
                  </div>
                </div>
              </.panel>

              <.panel
                :if={present?(@task.qa_notes) or present?(@task.deployment_notes)}
                title="QA & DEPLOYMENT"
              >
                <div class="flex flex-col gap-3">
                  <div :if={present?(@task.qa_notes)} class="flex flex-col gap-1">
                    <h3 class="text-[11px] font-medium text-[var(--text-label)]">QA notes</h3>
                    <pre class="whitespace-pre-wrap break-words text-[11.5px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]">{@task.qa_notes}</pre>
                  </div>
                  <div :if={present?(@task.deployment_notes)} class="flex flex-col gap-1">
                    <h3 class="text-[11px] font-medium text-[var(--text-label)]">Deployment notes</h3>
                    <pre class="whitespace-pre-wrap break-words text-[11.5px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]">{@task.deployment_notes}</pre>
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
                title="RUNS"
                meta={runs_meta(@runs, @usage_by_run)}
                padded={false}
                body_class="px-[18px] py-[var(--space-4)] flex flex-col gap-[10px]"
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
                title="ACTIVITY"
                meta={activity_meta(@versions, @version_total)}
                padded={false}
                body_class="px-[18px] py-[var(--space-4)]"
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

            <%!-- ══ Right rail ══════════════════════════════════════════ --%>
            <div class="flex flex-col gap-[var(--space-4)] min-w-0">
              <%!-- An issue accumulates runs — a main dispatch, review passes,
                   fix passes — so this block summarises the roster rather
                   than naming the one worker that happens to be attached. --%>
              <.panel title="CURRENT RUN" meta={run_role_breakdown(@runs)}>
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

              <.panel title="MACHINE STATE">
                <.data_list class="text-[12px]">
                  <:item :if={@issue_repo} label={String.capitalize(@rig_label)}>
                    <code class="text-xs">{@issue_repo}</code>
                  </:item>
                  <:item label="Status">
                    <.status_chip status={@task.status} class="badge-sm" />
                  </:item>
                  <:item label="Priority">
                    <.priority_tag priority={@task.priority} class="badge-sm font-mono" />
                  </:item>
                  <:item label="Difficulty">
                    <code class="text-xs">{difficulty_label(@task.difficulty)}</code>
                  </:item>
                  <:item label="Type"><code class="text-xs">{@task.issue_type}</code></:item>
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
                  <:item :if={(@task.child_total || 0) > 0} label="Children">
                    <code class="text-xs">
                      {@task.child_closed || 0}/{@task.child_total} closed
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

              <.panel title="DEPENDENCIES" meta={dependency_meta(@outbound_deps, @inbound_deps)}>
                <div class="flex flex-col gap-3">
                  <div class="flex flex-col gap-1.5">
                    <h3 class="text-[11px] font-medium text-[var(--text-label)]">
                      Blocked by ({length(@outbound_deps)})
                    </h3>
                    <p
                      :if={@outbound_deps == []}
                      class="text-[11.5px] italic text-[var(--text-label)]"
                    >
                      No outgoing dependencies.
                    </p>
                    <ul :if={@outbound_deps != []} class="flex flex-col gap-1.5">
                      <li :for={d <- @outbound_deps}>
                        <.dep_edge dep={d} other_id={d.to_issue_id} direction={:upstream} />
                      </li>
                    </ul>
                  </div>

                  <div class="flex flex-col gap-1.5 border-t border-[var(--border-default)] pt-3">
                    <h3 class="text-[11px] font-medium text-[var(--text-label)]">
                      Blocks ({length(@inbound_deps)})
                    </h3>
                    <p
                      :if={@inbound_deps == []}
                      class="text-[11.5px] italic text-[var(--text-label)]"
                    >
                      Nothing depends on this {@issue_label}.
                    </p>
                    <ul :if={@inbound_deps != []} class="flex flex-col gap-1.5">
                      <li :for={d <- @inbound_deps}>
                        <.dep_edge dep={d} other_id={d.from_issue_id} direction={:downstream} />
                      </li>
                    </ul>
                  </div>
                </div>
              </.panel>

              <%!-- The post-layering skill set (workspace → repo → issue) a
                   dispatch of this issue would carry right now. --%>
              <.panel title="SKILLS" meta={"#{length(@skills)} active"}>
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
              options={@status_options}
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
    </Layouts.app>
    """
  end

  # ---- render helpers ----

  attr(:dep, :map, required: true)
  attr(:other_id, :string, required: true)
  attr(:direction, :atom, required: true)

  defp dep_edge(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <ArbiterWeb.CoreComponents.icon
        name={if @direction == :upstream, do: "hero-arrow-up-right", else: "hero-arrow-down-left"}
        class="size-4 text-base-content/40 shrink-0"
      />
      <span class="badge badge-ghost badge-sm font-mono shrink-0">{@dep.type}</span>
      <.link navigate={~p"/tasks/#{@other_id}"} class="min-w-0 flex-1 group">
        <div class="flex items-center gap-2">
          <code class="text-xs text-base-content/60 shrink-0 group-hover:text-primary transition-colors">
            {@other_id}
          </code>
          <span
            :if={@dep.other_issue}
            class="truncate text-sm group-hover:text-primary transition-colors"
            title={@dep.other_issue.title}
          >
            {@dep.other_issue.title}
          </span>
        </div>
      </.link>
      <span
        :if={@dep.other_issue}
        class={["badge badge-xs shrink-0", status_badge_class(@dep.other_issue.status)]}
      >
        {@dep.other_issue.status}
      </span>
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
  defp status_badge_class(_), do: ""

  # bd-5lc99r: a string field counts as present only when it is non-nil and not
  # blank after trimming — used to decide whether the findings/notes section has
  # real content to render.
  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false

  defp difficulty_label(nil), do: "—"
  defp difficulty_label(d) when is_integer(d) and d in 0..4, do: "D#{d}"
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
      run_failed?(run) and run_failure_line(run) != "" -> run_failure_line(run)
      lines == [] and run.status == :running -> "streaming…"
      true -> "#{length(lines)} lines"
    end
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

  defp dependency_meta(outbound, inbound),
    do: "#{length(outbound)} up · #{length(inbound)} down"

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
