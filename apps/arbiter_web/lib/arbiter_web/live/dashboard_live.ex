defmodule ArbiterWeb.DashboardLive do
  @moduledoc """
  Dashboard LiveView at `/` — real-time view of:

    * Active workers (name, current step, task, runtime)
    * Recent tasks (last 20 by `updated_at` desc)
    * Merge queue — branches integrating via `Arbiter.Mergers`
      (Direct/GitLab/GitHub): the workers parked at `:awaiting_review`, each
      with its open MR, approval status, and Watchdog poll activity. Live.
    * Admiral mailbox — unread mailbox-family messages addressed to the
      coordinator (`to_ref "admiral"`): completions, failures, escalations,
      flags, info. Read-acknowledge per message; clear drains the read tail.
      The dashboard counterpart of `arb inbox` / `arb msg`. Live.
    * Notifications feed — recent `:notification` broadcasts (read-only).
    * ReviewGate (review gate) — reviews in flight (authors parked at
      `:awaiting_review_gate`, enriched with their reviewer's live activity) plus
      the durable record of non-approve verdicts (recent `:escalation`
      messages, carrying the reviewer's findings). Approvals proceed straight to
      the merge queue, so they surface there, not here. Live.

  ## PubSub topics

  Subscribed at mount:
    * `"tasks"`     — `{:task_lifecycle, event, issue}` from
                      `Arbiter.Tasks.Issue.broadcast_lifecycle/2`.
    * `"workers"`  — `{:worker_lifecycle, event, snapshot}` from
                      `Arbiter.Worker.broadcast_lifecycle/2`.
    * `"messages:<workspace_id>"` — `{:new_message, message}` from
                      `Arbiter.Messages.Message.broadcast_new/1` and
                      `{:message_read, message}` from
                      `Arbiter.Messages.Message.broadcast_read/1`, one
                      subscription per workspace known at mount. Drives the
                      live notifications feed and the Admiral mailbox.

  Both topics fire on every relevant write. The LiveView refreshes the
  affected section by re-reading the data (deliberately naive — Phase 5
  can optimize once we have profile evidence that the simple refresh is
  too costly).
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Worker.Worktree
  alias Arbiter.Workers.Run
  require Ash.Query

  @tasks_topic "tasks"
  @workers_topic "workers"

  # The coordinator's mailbox recipient — the `to_ref` workers address reports
  # *up* to (completions/failures/escalations/info). Matches `arb inbox` and
  # the `arb prime` Admiral Inbox section.
  @admiral_ref "admiral"

  # Number of CURRENT (non-closed) directives shown in the dashboard's
  # recent-directives list. The landing shows only this current slice, capped;
  # the full, filterable history lives on the `/tasks` index ("See all").
  @recent_tasks_limit 8

  # Number of open epics (parent tasks) shown in the dashboard's current
  # campaigns section, capped. Each is a task with `:parent_of` children.
  @current_epics_limit 6

  # Number of escalations (ReviewGate verdicts) shown in the ReviewGate view.
  @recent_escalations_limit 10

  @impl true
  def mount(_params, _session, socket) do
    live? = connected?(socket)

    if live? do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
      # Drives live elapsed counters (active workers) and relative timestamps
      # (notifications). Only reassigns :now — no DB reads in the tick handler.
      :timer.send_interval(1000, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:now, DateTime.utc_now())
     |> assign(:live, live?)
     |> assign(:worker_label, "worker")
     |> assign(:repo_label, "repo")
     |> assign(:worktree_label, "worktree")
     |> assign(:issue_label, "issue")
     |> assign(:epic_label, "epic")
     |> assign(:workspace_label, "workspace")
     |> assign(:pr_label, "pull request")
     |> assign(:merge_queue_label, "merge queue")
     |> assign(:escalation_label, "escalation")
     |> refresh_workspaces()
     |> subscribe_messages(live?)
     |> refresh_notifications()
     |> refresh_admiral_inbox()
     |> refresh_rigs()
     |> refresh_workers()
     |> refresh_merge_queue()
     |> refresh_completed_runs()
     |> refresh_pending_reviews()
     |> refresh_escalations()
     |> refresh_recent_tasks()
     |> refresh_epics()}
  end

  @impl true
  def handle_info({:task_lifecycle, _event, _issue}, socket) do
    {:noreply,
     socket
     |> refresh_recent_tasks()
     |> refresh_epics()
     |> refresh_workspaces()}
  end

  def handle_info({:worker_lifecycle, _event, _snapshot}, socket) do
    {:noreply,
     socket
     |> refresh_workers()
     |> refresh_merge_queue()
     |> refresh_completed_runs()
     |> refresh_pending_reviews()
     |> refresh_workspaces()
     |> refresh_rigs()}
  end

  def handle_info({:new_message, _message}, socket) do
    {:noreply,
     socket
     |> refresh_notifications()
     |> refresh_admiral_inbox()
     |> refresh_escalations()}
  end

  def handle_info({:message_read, _message}, socket) do
    {:noreply, refresh_admiral_inbox(socket)}
  end

  # Lightweight 1s tick: only advances the clock so elapsed counters and
  # relative timestamps stay live. No data reads here.
  def handle_info(:tick, socket) do
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  # Acknowledge one Admiral-mailbox message: stamp read_at, drop it from the
  # unread list. Mirrors `arb inbox read <id>` and the per-worker mailbox.
  def handle_event("mark_read", %{"id" => id}, socket) do
    _ = Message.mark_read(id)
    {:noreply, refresh_admiral_inbox(socket)}
  end

  # Drain the read tail of the Admiral mailbox. Mirrors `arb inbox clear` /
  # `DELETE /api/messages?to_ref=admiral` — unread mail is left untouched.
  def handle_event("clear_admiral", _params, socket) do
    _ = Message.clear_read(@admiral_ref)
    {:noreply, refresh_admiral_inbox(socket)}
  end

  # ---- data ----

  defp refresh_workers(socket) do
    workers =
      try do
        Worker.list_children()
      rescue
        _ -> []
      end

    workspaces_by_id =
      socket.assigns[:workspaces_by_id] || index_workspaces(load_workspaces())

    workers =
      Enum.map(workers, fn p ->
        p
        |> Map.put(:workspace_name, workspace_label(workspaces_by_id, p.workspace_id))
        |> Map.put(:security_mode, security_mode(workspaces_by_id, p.workspace_id))
      end)

    assign(socket, :workers, workers)
  end

  # Resolve the worker permission mode (:auto | :strict | :bypass) for a
  # worker's workspace, so the dashboard can flag at a glance when a worker is
  # running under a non-default posture (e.g. :bypass, which skips all checks).
  # Falls back to the install-wide default when the workspace is unknown.
  defp security_mode(_workspaces_by_id, nil), do: SecurityPolicy.default().permissions.mode

  defp security_mode(workspaces_by_id, ws_id) do
    case Map.fetch(workspaces_by_id, ws_id) do
      {:ok, ws} -> SecurityPolicy.resolve(ws).permissions.mode
      :error -> SecurityPolicy.default().permissions.mode
    end
  rescue
    _ -> SecurityPolicy.default().permissions.mode
  end

  # The merge queue: branches integrating via Arbiter.Mergers.
  # Sourced live from workers parked at :awaiting_review — each has an open MR
  # (mr_ref + clickable merger_url), the last Mergers.get/1 result the Watchdog
  # recorded (:last_merger_status), and when it was last polled. Ordered
  # longest-waiting first so a stalled merge surfaces at the top of the queue.
  #
  # The merger *type* (Direct/GitLab/GitHub) is resolved from the worker's
  # workspace config rather than the snapshot — the resolved adapter module is
  # internal to the worker and not exposed on the snapshot.
  defp refresh_merge_queue(socket) do
    workspaces_by_id =
      socket.assigns[:workspaces_by_id] || index_workspaces(load_workspaces())

    merges =
      try do
        Worker.list_children()
      rescue
        _ -> []
      end
      |> Enum.filter(&(&1.status == :awaiting_review))
      |> Enum.map(fn p ->
        meta = p.meta || %{}

        %{
          task_id: p.task_id,
          workspace_name: workspace_label(workspaces_by_id, p.workspace_id),
          merger_type: merger_type(workspaces_by_id, p.workspace_id),
          mr_ref: p.mr_ref,
          merger_url: p.merger_url,
          merger_status: Map.get(meta, :last_merger_status),
          last_checked_at: Map.get(meta, :last_checked_at),
          since: p.step_started_at || p.started_at
        }
      end)
      |> Enum.sort_by(& &1.since, {:asc, DateTime})

    assign(socket, :merge_queue, merges)
  end

  # Resolve the merger strategy atom (:direct | :gitlab | :github) for a
  # worker's workspace. Falls back to :direct (the Workspace default) when the
  # workspace is unknown or unset.
  defp merger_type(_workspaces_by_id, nil), do: :direct

  defp merger_type(workspaces_by_id, ws_id) do
    case Map.fetch(workspaces_by_id, ws_id) do
      {:ok, ws} -> Workspace.merger_strategy(ws)
      :error -> :direct
    end
  rescue
    _ -> :direct
  end

  # ---- review_gate (review gate) ----

  # Reviews in flight right now: author workers parked at :awaiting_review_gate
  # while a distinct reviewer mind code-reviews their diff. Each is enriched
  # with the live activity of its reviewer (a sibling `<task>#review` worker,
  # matched via meta.reviews) so the operator can see what the review is doing,
  # not just that one is pending. Ordered longest-waiting first.
  defp refresh_pending_reviews(socket) do
    children =
      try do
        Worker.list_children()
      rescue
        _ -> []
      end

    workspaces_by_id =
      socket.assigns[:workspaces_by_id] || index_workspaces(load_workspaces())

    reviewers_by_task =
      children
      |> Enum.filter(fn p -> Map.get(p.meta || %{}, :role) == :reviewer end)
      |> Map.new(fn p -> {Map.get(p.meta || %{}, :reviews), p} end)

    pending =
      children
      |> Enum.filter(&(&1.status == :awaiting_review_gate))
      |> Enum.map(fn p ->
        %{
          task_id: p.task_id,
          workspace_name: workspace_label(workspaces_by_id, p.workspace_id),
          since: p.step_started_at || p.started_at,
          reviewer_activity: reviewer_activity(Map.get(reviewers_by_task, p.task_id))
        }
      end)
      |> Enum.sort_by(& &1.since, {:asc, DateTime})

    assign(socket, :pending_reviews, pending)
  end

  # Recent ReviewGate escalations: the durable record of non-approve verdicts
  # (REQUEST_CHANGES / inconclusive), newest first, fleet-wide. Carries the
  # reviewer's findings in :body. Read and unread alike — a ReviewGate verdict
  # stays in the history once the Admiral has seen it.
  defp refresh_escalations(socket) do
    escalations =
      try do
        Message.recent_escalations(@recent_escalations_limit)
      rescue
        _ -> []
      end

    assign(socket, :escalations, escalations)
  end

  defp refresh_completed_runs(socket) do
    runs =
      try do
        Run
        |> Ash.Query.filter(status in [:completed, :failed])
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(10)
        |> Ash.read!()
      rescue
        _ -> []
      end

    assign(socket, :completed_runs, runs)
  end

  # CURRENT directives only: the landing shows the open + in-progress slice,
  # newest-updated first, capped at . Closed directives are
  # never shown here — they live on the `/tasks` index ("See all"). This keeps
  # the landing bounded as the directive history grows unbounded.
  defp refresh_recent_tasks(socket) do
    tasks =
      Issue
      |> Ash.Query.filter(status != :closed)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@recent_tasks_limit)
      |> Ash.read!()

    blocked_counts = blocked_counts_for(Enum.map(tasks, & &1.id))

    tasks =
      Enum.map(tasks, fn b ->
        Map.put(b, :blocked_count, Map.get(blocked_counts, b.id, 0))
      end)

    assign(socket, :recent_tasks, tasks)
  end

  # CURRENT campaigns only: open epic tasks (issue_type == :epic), newest-updated
  # first, capped. Each is loaded with its `:parent_of` child-progress rollup for
  # the inline bar. The full, filterable task list lives on the `/tasks` index.
  defp refresh_epics(socket) do
    epic = :epic

    epics =
      try do
        Issue
        |> Ash.Query.filter(issue_type == ^epic and status != :closed)
        |> Ash.Query.load([:child_total, :child_closed])
        |> Ash.Query.sort(updated_at: :desc)
        |> Ash.Query.limit(@current_epics_limit)
        |> Ash.read!()
      rescue
        _ -> []
      end

    assign(socket, :epics, epics)
  end

  # For the given task ids, count how many of each task's `:depends_on` edges
  # point at a target issue that is NOT yet closed — i.e. how many open
  # blockers gate the task. One extra Dependency read + one Issue status read
  # scoped to the targets, keyed by the dependent (`from_issue_id`).
  #
  # NOTE (data hook): this only counts `:depends_on` edges. If you later want to
  # also surface inbound `:blocks` edges, add a second pass keyed on
  # `to_issue_id` here — the template already renders whatever count lands in
  # each task's `:blocked_count`.
  defp blocked_counts_for([]), do: %{}

  defp blocked_counts_for(task_ids) do
    deps =
      Arbiter.Tasks.Dependency
      |> Ash.Query.filter(type == :depends_on and from_issue_id in ^task_ids)
      |> Ash.Query.select([:from_issue_id, :to_issue_id])
      |> Ash.read!()

    target_ids = deps |> Enum.map(& &1.to_issue_id) |> Enum.uniq()

    closed_targets =
      case target_ids do
        [] ->
          MapSet.new()

        ids ->
          Issue
          |> Ash.Query.filter(id in ^ids and status == :closed)
          |> Ash.Query.select([:id])
          |> Ash.read!()
          |> MapSet.new(& &1.id)
      end

    deps
    |> Enum.reject(&MapSet.member?(closed_targets, &1.to_issue_id))
    |> Enum.reduce(%{}, fn dep, acc ->
      Map.update(acc, dep.from_issue_id, 1, &(&1 + 1))
    end)
  rescue
    _ -> %{}
  end

  # ---- notifications ----

  # Subscribe to each known workspace's message topic. Workspaces created
  # after mount won't be picked up until the next full page load — acceptable
  # for a dashboard that's typically left open on a stable set of workspaces.
  defp subscribe_messages(socket, false), do: socket

  defp subscribe_messages(socket, true) do
    (socket.assigns[:workspaces_by_id] || %{})
    |> Map.keys()
    |> Enum.each(&Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(&1)))

    socket
  end

  defp refresh_notifications(socket) do
    notifications =
      try do
        Message.recent_notifications(20)
      rescue
        _ -> []
      end

    assign(socket, :notifications, notifications)
  end

  # ---- admiral mailbox ----

  # Unread mailbox-family messages addressed to the Admiral, fleet-wide
  # (every workspace), oldest first — so the longest-waiting escalation sits
  # at the top of the queue. Mirrors `arb inbox` (the Admiral's unread view).
  defp refresh_admiral_inbox(socket) do
    inbox =
      try do
        Message.inbox(@admiral_ref)
      rescue
        _ -> []
      end

    assign(socket, :admiral_inbox, inbox)
  end

  # ---- workspaces ----

  defp refresh_workspaces(socket) do
    workspaces = load_workspaces()
    issues_by_workspace = group_issues_by_workspace_and_status()
    workers_by_workspace = group_workers_by_workspace()

    stats =
      Enum.map(workspaces, fn ws ->
        issue_counts = Map.get(issues_by_workspace, ws.id, %{})

        %{
          id: ws.id,
          name: ws.name,
          prefix: ws.prefix,
          tracker_type: get_in(ws.config || %{}, ["tracker", "type"]) || "none",
          workers: Map.get(workers_by_workspace, ws.id, 0),
          open: Map.get(issue_counts, :open, 0),
          in_progress: Map.get(issue_counts, :in_progress, 0),
          closed: Map.get(issue_counts, :closed, 0)
        }
      end)
      |> Enum.sort_by(& &1.name)

    socket
    |> assign(:workspaces, stats)
    |> assign(:workspaces_by_id, index_workspaces(workspaces))
  end

  defp load_workspaces do
    Ash.read!(Workspace)
  rescue
    _ -> []
  end

  defp index_workspaces(workspaces) do
    Map.new(workspaces, fn ws -> {ws.id, ws} end)
  end

  defp workspace_label(_workspaces_by_id, nil), do: "(none)"

  defp workspace_label(workspaces_by_id, ws_id) do
    case Map.fetch(workspaces_by_id, ws_id) do
      {:ok, ws} -> ws.name
      :error -> "(unknown)"
    end
  end

  defp group_issues_by_workspace_and_status do
    Issue
    |> Ash.Query.select([:id, :status, :workspace_id])
    |> Ash.read!()
    |> Enum.reduce(%{}, fn i, acc ->
      Map.update(acc, i.workspace_id, %{i.status => 1}, fn ws_counts ->
        Map.update(ws_counts, i.status, 1, &(&1 + 1))
      end)
    end)
  rescue
    _ -> %{}
  end

  defp group_workers_by_workspace do
    try do
      Worker.list_children()
    rescue
      _ -> []
    end
    |> Enum.reduce(%{}, fn p, acc ->
      Map.update(acc, p.workspace_id, 1, &(&1 + 1))
    end)
  end

  # ---- repos ----

  defp refresh_rigs(socket) do
    workspaces = socket.assigns[:workspaces_by_id] |> values_or_load()

    paths_by_repo = collect_repo_paths(workspaces)
    workers_by_repo = group_workers_by_repo()

    rigs =
      paths_by_repo
      |> Map.merge(repos_from_workers(workers_by_repo, paths_by_repo))
      |> Enum.map(fn {name, entry} ->
        path = entry.path

        worktree_count =
          case path do
            nil -> 0
            p when is_binary(p) -> safe_worktree_count(p)
          end

        %{
          name: name,
          path: path,
          source: entry.source,
          workers: Map.get(workers_by_repo, name, 0),
          worktrees: worktree_count
        }
      end)
      |> Enum.sort_by(& &1.name)

    assign(socket, :rigs, rigs)
  end

  defp values_or_load(nil), do: load_workspaces()
  defp values_or_load(%{} = m), do: Map.values(m)

  # Build {repo_name => %{path:, source:}} from every workspace's
  # config["repo_paths"] (or legacy "rig_paths") plus the application-env
  # fallback. Workspace entries win over app-env when names collide.
  defp collect_repo_paths(workspaces) do
    app_paths =
      :arbiter
      |> Application.get_env(:repo_paths, %{})
      |> Map.new(fn {name, raw} ->
        {name, %{path: RepoConfig.repo_path_from_config(raw), source: "(app)"}}
      end)

    workspaces
    |> Enum.reduce(app_paths, fn ws, acc ->
      ws_repo_paths =
        case ws.config do
          %{"repo_paths" => paths} when is_map(paths) -> paths
          %{"rig_paths" => paths} when is_map(paths) -> paths
          _ -> %{}
        end

      Enum.reduce(ws_repo_paths, acc, fn {name, raw}, acc ->
        Map.put(acc, name, %{path: RepoConfig.repo_path_from_config(raw), source: ws.name})
      end)
    end)
  end

  defp group_workers_by_repo do
    try do
      Worker.list_children()
    rescue
      _ -> []
    end
    |> Enum.reduce(%{}, fn p, acc ->
      repo = p.repo || "(none)"
      Map.update(acc, repo, 1, &(&1 + 1))
    end)
  end

  # A worker can be running against a repo name that isn't in any
  # `repo_paths` config (default-repo "unknown", a typo, or an inherited
  # legacy value). Surface those as well so the operator can see them.
  defp repos_from_workers(workers_by_repo, configured) do
    workers_by_repo
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(configured, &1))
    |> Map.new(fn name -> {name, %{path: nil, source: "(unconfigured)"}} end)
  end

  defp safe_worktree_count(path) do
    Worktree.list(path) |> length()
  rescue
    _ -> 0
  end

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds(_, _), do: 0

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp status_badge_class(:open), do: "badge badge-success"
  defp status_badge_class(:in_progress), do: "badge badge-info"
  defp status_badge_class(:closed), do: "badge badge-ghost"
  defp status_badge_class(_), do: "badge"

  defp difficulty_label(nil), do: "—"
  defp difficulty_label(d) when is_integer(d) and d in 0..4, do: "D#{d}"
  defp difficulty_label(_), do: "—"

  defp difficulty_badge_class(nil), do: "badge-ghost"
  defp difficulty_badge_class(0), do: "badge-success"
  defp difficulty_badge_class(1), do: "badge-info"
  defp difficulty_badge_class(2), do: "badge-secondary"
  defp difficulty_badge_class(3), do: "badge-warning"
  defp difficulty_badge_class(4), do: "badge-error"
  defp difficulty_badge_class(_), do: "badge-ghost"

  defp worker_status_class(:idle), do: "badge-ghost"
  defp worker_status_class(:resuming), do: "badge-info"
  defp worker_status_class(:running), do: "badge-info"
  defp worker_status_class(:awaiting), do: "badge-warning"
  defp worker_status_class(:awaiting_review_gate), do: "badge-warning"
  defp worker_status_class(:awaiting_review), do: "badge-warning"
  defp worker_status_class(:completed), do: "badge-success"
  defp worker_status_class(:failed), do: "badge-error"
  defp worker_status_class(_), do: ""

  defp worker_status_label(:idle), do: "Idle"
  defp worker_status_label(:resuming), do: "Resuming"
  defp worker_status_label(:running), do: "Running"
  defp worker_status_label(:awaiting), do: "Awaiting"
  defp worker_status_label(:awaiting_review_gate), do: "In review_gate"
  defp worker_status_label(:awaiting_review), do: "Awaiting review"
  defp worker_status_label(:completed), do: "Completed"
  defp worker_status_label(:failed), do: "Failed"

  defp worker_status_label(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  defp worker_status_label(other), do: to_string(other)

  defp run_status_class(:completed), do: "badge-success"
  defp run_status_class(:failed), do: "badge-error"
  defp run_status_class(:running), do: "badge-info"
  defp run_status_class(_), do: "badge-ghost"

  # Human label for the resolved merger strategy atom.
  defp merger_type_label(:direct), do: "Direct"
  defp merger_type_label(:gitlab), do: "GitLab"
  defp merger_type_label(:github), do: "GitHub"
  defp merger_type_label(other), do: other |> to_string() |> String.capitalize()

  # Worker permission-mode badge: ghost for the safe default (auto), warning
  # for strict (tighter, worth noticing), error for bypass (all checks off —
  # the operator should see that immediately).
  defp security_mode_label(:auto), do: "auto"
  defp security_mode_label(:strict), do: "strict"
  defp security_mode_label(:bypass), do: "bypass"
  defp security_mode_label(other), do: to_string(other)

  defp security_mode_class(:auto), do: "badge-ghost"
  defp security_mode_class(:strict), do: "badge-warning"
  defp security_mode_class(:bypass), do: "badge-error"
  defp security_mode_class(_), do: "badge-ghost"

  # Approval/merge state of an in-flight merge, derived from the last
  # Mergers.get/1 result the Watchdog recorded. Routes through Watchdog.classify/1
  # — the single approval-detection decision surface — so the dashboard label
  # can never drift from the Watchdog's own merge/fail logic. `nil` means the
  # Watchdog hasn't completed its first poll yet.
  defp merge_status_label(nil), do: "Awaiting first poll"

  defp merge_status_label(status) when is_map(status) do
    case Watchdog.effective_block_reason(status) do
      nil ->
        case Watchdog.classify(status) do
          :merged -> "Merged"
          :approved -> "Approved"
          :closed -> "Closed / rejected"
          :pending -> "In review"
        end

      reason ->
        block_reason_label(reason)
    end
  end

  defp merge_status_class(nil), do: "badge-ghost"

  defp merge_status_class(status) when is_map(status) do
    case Watchdog.effective_block_reason(status) do
      nil ->
        case Watchdog.classify(status) do
          :merged -> "badge-success"
          :approved -> "badge-success"
          :closed -> "badge-error"
          :pending -> "badge-info"
        end

      _reason ->
        "badge-error"
    end
  end

  # A blocked merge surfaces the *why* (#354, Phase 1) so an unmergeable PR is
  # never indistinguishable from one merely "in review".
  defp block_reason_label(:conflict), do: "Blocked · conflict"
  defp block_reason_label(:behind_base), do: "Blocked · behind base"
  defp block_reason_label(:ci_failed), do: "Blocked · CI failed"
  defp block_reason_label(:needs_approval), do: "Blocked · needs approval"

  defp block_reason_label(:needs_nonauthor_approval),
    do: "Parked · awaiting human reviewer"

  defp block_reason_label(:draft), do: "Blocked · draft"
  defp block_reason_label(:blocked_other), do: "Blocked"
  defp block_reason_label(other), do: "Blocked · #{other}"

  # Watchdog poll cadence, in seconds, for the merge-queue freshness line. The
  # per-workspace override isn't exposed on the snapshot, so we show the
  # default — the same value the worker detail view reports.
  defp poll_interval_seconds, do: div(Watchdog.default_interval_ms(), 1000)

  defp humanize_duration(%DateTime{} = started_at, %DateTime{} = ended_at) do
    started_at |> DateTime.diff(ended_at, :second) |> abs() |> humanize_seconds()
  end

  defp humanize_duration(_, _), do: "—"

  defp kind_badge_class(:notification), do: "badge-info"
  defp kind_badge_class(:direction), do: "badge-warning"
  defp kind_badge_class(:flag), do: "badge-accent"
  defp kind_badge_class(:escalation), do: "badge-error"
  defp kind_badge_class(:failure), do: "badge-error"
  defp kind_badge_class(:completion), do: "badge-success"
  defp kind_badge_class(:info), do: "badge-info"
  defp kind_badge_class(_), do: "badge-ghost"

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_ts(_), do: ""

  # Compact relative timestamp for the notifications feed. Stays live because
  # the caller passes @now, which the :tick handler advances each second.
  defp relative_time(%DateTime{} = ts, %DateTime{} = now) do
    seconds = DateTime.diff(now, ts, :second) |> max(0)

    cond do
      seconds < 10 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp relative_time(_, _), do: ""

  # An MR/PR ref is not currently persisted on the worker snapshot, so this
  # degrades to nil. When the dispatch flow starts stashing it in meta (under
  # :mr_ref or "mr_ref"), the awaiting-review link lights up automatically.
  defp mr_ref(%{meta: meta}) when is_map(meta) do
    Map.get(meta, :mr_ref) || Map.get(meta, "mr_ref")
  end

  defp mr_ref(_), do: nil

  # Ordered worker lifecycle for the inline step indicator. :failed is handled
  # separately in the template (it doesn't belong on the happy-path track).
  @worker_flow [:idle, :running, :awaiting, :completed]

  defp worker_flow, do: @worker_flow

  # Returns :done | :current | :todo for a step relative to the worker's
  # current status, so the template can color the inline step track.
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

  defp excerpt(nil), do: ""

  defp excerpt(body) when is_binary(body) do
    if String.length(body) > 80, do: String.slice(body, 0, 80) <> "…", else: body
  end

  # A claude-driven worker — a streaming Claude subprocess does the real work
  # and its workflow Machine is never ticked, so current_step sits frozen. Show
  # the live activity derived from the stream instead. See bd-c919xj.
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

  # A pending review's reviewer activity, or nil when the reviewer exposes no
  # live activity label (or there is no live reviewer). Unlike live_activity/1
  # this returns nil rather than a "working" default, so the template can choose
  # whether to render the reviewer line at all.
  defp reviewer_activity(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :activity) do
      %{"label" => label} when is_binary(label) -> label
      %{label: label} when is_binary(label) -> label
      label when is_binary(label) -> label
      _ -> nil
    end
  end

  defp reviewer_activity(_), do: nil

  # Derive the verdict an escalation represents from its subject. The ReviewGate
  # raises escalations with subjects of the form
  # "ReviewGate: changes requested for <task>" or
  # "ReviewGate: review inconclusive for <task>"; anything else falls back to a
  # neutral label so a non-ReviewGate escalation still renders sensibly.
  defp escalation_verdict_label(subject) when is_binary(subject) do
    cond do
      String.contains?(subject, "inconclusive") -> "Inconclusive"
      String.contains?(subject, "changes requested") -> "Changes requested"
      true -> "Escalation"
    end
  end

  defp escalation_verdict_label(_), do: "Escalation"

  defp escalation_verdict_class(subject) when is_binary(subject) do
    if String.contains?(subject, "inconclusive"), do: "badge-warning", else: "badge-error"
  end

  defp escalation_verdict_class(_), do: "badge-error"

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="p-6 max-w-7xl mx-auto space-y-6">
        <%!-- ── Header ───────────────────────────────────────────────── --%>
        <div class="flex items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Dashboard</h1>
            <p class="text-sm text-base-content/60">
              Operational view of active work across every {@workspace_label}.
            </p>
          </div>
          <span
            id="live-indicator"
            class={[
              "badge badge-sm gap-1.5 transition-colors duration-200",
              if(@live, do: "badge-success", else: "badge-warning")
            ]}
            title={
              if @live,
                do: "WebSocket connected — updates arrive in real time",
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

        <%!-- ── A. Stats bar ─────────────────────────────────────────── --%>
        <div class="stats stats-vertical lg:stats-horizontal w-full shadow bg-base-200 border border-base-300">
          <div class="stat">
            <div class="stat-figure text-success">
              <.icon name="hero-inbox-stack" class="size-7" />
            </div>
            <div class="stat-title">Open {cap_plural(@issue_label)}</div>
            <div class="stat-value text-success">{open_issue_total(@workspaces)}</div>
            <div class="stat-desc">across {length(@workspaces)} {plural(@workspace_label)}</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-info">
              <.icon name="hero-cpu-chip" class="size-7" />
            </div>
            <div class="stat-title">Active {cap_plural(@worker_label)}</div>
            <div class="stat-value text-info">{length(@workers)}</div>
            <div class="stat-desc">running right now</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-base-content/70">
              <.icon name="hero-building-office-2" class="size-7" />
            </div>
            <div class="stat-title">{cap_plural(@workspace_label)}</div>
            <div class="stat-value">{length(@workspaces)}</div>
            <div class="stat-desc">configured</div>
          </div>

          <%!-- Admiral Inbox: unread mailbox-family mail addressed to the
               coordinator (completions/failures/escalations/info). Links to
               the mailbox panel below. Live via the messages PubSub topic. --%>
          <a href="#admiral-mailbox" class="stat hover:bg-base-300/40 transition-colors">
            <div class={[
              "stat-figure",
              if(@admiral_inbox == [], do: "text-base-content/40", else: "text-warning")
            ]}>
              <.icon name="hero-envelope" class="size-7" />
            </div>
            <div class="stat-title">Coordinator Inbox</div>
            <div class={[
              "stat-value",
              if(@admiral_inbox == [], do: "text-base-content/40", else: "text-warning")
            ]}>
              {length(@admiral_inbox)}
            </div>
            <div class="stat-desc">{if @admiral_inbox == [], do: "all clear", else: "unread"}</div>
          </a>
        </div>

        <%!-- ── B + C. Active workers / Directive queue ──────────────── --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Active workers --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <div class="flex items-center justify-between">
                <h2 class="text-lg font-semibold flex items-center gap-2">
                  <.icon name="hero-bolt" class="size-5 text-info" />
                  Active {cap_plural(@worker_label)} ({length(@workers)})
                </h2>
                <.see_all_link navigate={~p"/workers"} />
              </div>

              <div
                :if={@workers == []}
                class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
              >
                <.icon name="hero-moon" class="size-8 mx-auto text-base-content/30" />
                <p class="mt-2 text-sm font-medium text-base-content/70">
                  No active {plural(@worker_label)}.
                </p>
                <p class="text-xs text-base-content/50">
                  Dispatched {plural(@worker_label)} appear here with live step progress
                  and elapsed time the moment work begins.
                </p>
              </div>

              <ul :if={@workers != []} id="active-workers" class="flex flex-col gap-3">
                <li
                  :for={p <- @workers}
                  class="rounded-box bg-base-100 border border-base-300 p-3 transition-colors duration-150 hover:border-info/50"
                >
                  <div class="flex items-center justify-between gap-2">
                    <.link
                      navigate={~p"/workers/#{p.task_id}"}
                      class="flex items-center gap-2 min-w-0 group"
                    >
                      <span class="relative flex h-2.5 w-2.5 shrink-0">
                        <span
                          :if={p.status == :running}
                          class="absolute inline-flex h-full w-full animate-ping rounded-full bg-info opacity-75"
                        >
                        </span>
                        <span class={[
                          "relative inline-flex h-2.5 w-2.5 rounded-full",
                          status_dot_class(p.status)
                        ]}>
                        </span>
                      </span>
                      <code class="text-xs font-semibold group-hover:text-info transition-colors truncate">
                        {p.task_id}
                      </code>
                    </.link>
                    <span class="text-xs font-mono text-base-content/70 tabular-nums shrink-0">
                      {humanize_seconds(runtime_seconds(p.started_at, @now))}
                    </span>
                  </div>

                  <div class="flex items-center justify-between gap-2 mt-1.5 text-xs text-base-content/60">
                    <span class="flex items-center gap-1.5 min-w-0">
                      <span class="truncate">{Map.get(p, :workspace_name) || "(none)"}</span>
                      <span
                        :if={Map.get(p, :security_mode)}
                        class={["badge badge-xs shrink-0", security_mode_class(p.security_mode)]}
                        title={"worker permission mode: #{p.security_mode}"}
                      >
                        {security_mode_label(p.security_mode)}
                      </span>
                    </span>
                    <%= if claude_session?(p) do %>
                      <span class="badge badge-info badge-sm gap-1.5 max-w-[55%]">
                        <span :if={p.status == :running} class="loading loading-ring loading-xs">
                        </span>
                        <span class="truncate">{live_activity(p)}</span>
                      </span>
                    <% else %>
                      <span class="badge badge-ghost badge-sm font-mono">{p.current_step}</span>
                    <% end %>
                  </div>

                  <%!-- Inline lifecycle track: idle → running → awaiting → completed --%>
                  <div class="flex items-center gap-1 mt-2.5">
                    <span
                      :for={step <- worker_flow()}
                      class="flex items-center gap-1 flex-1 last:flex-none"
                    >
                      <span
                        class={[
                          "h-1.5 flex-1 rounded-full transition-colors duration-300",
                          flow_bar_class(flow_state(step, p.status))
                        ]}
                        title={worker_status_label(step)}
                      >
                      </span>
                    </span>
                    <span class={["badge badge-sm ml-1 shrink-0", worker_status_class(p.status)]}>
                      {worker_status_label(p.status)}
                    </span>
                  </div>

                  <div
                    :if={p.status == :awaiting and mr_ref(p)}
                    class="mt-2 flex items-center gap-1 text-xs"
                  >
                    <.icon name="hero-arrow-top-right-on-square" class="size-3 text-warning" />
                    <code class="text-warning">{mr_ref(p)}</code>
                  </div>
                </li>
              </ul>
            </div>
          </section>

          <%!-- Directive queue --%>
          <section class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <div class="flex items-center justify-between">
                <h2 class="text-lg font-semibold flex items-center gap-2">
                  <.icon name="hero-queue-list" class="size-5 text-base-content/70" />
                  Current {cap_plural(@issue_label)} ({length(@recent_tasks)})
                </h2>
                <.see_all_link navigate={~p"/tasks"} />
              </div>

              <div
                :if={@recent_tasks == []}
                class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
              >
                <.icon
                  name="hero-clipboard-document-list"
                  class="size-8 mx-auto text-base-content/30"
                />
                <p class="mt-2 text-sm text-base-content/60">
                  No active {plural(@issue_label)} right now. Open and in-progress {plural(
                    @issue_label
                  )} surface here; closed ones live on the <.link
                    navigate={~p"/tasks"}
                    class="link link-hover text-primary"
                  >{@issue_label} index</.link>.
                </p>
              </div>

              <ul :if={@recent_tasks != []} id="recent-tasks" class="flex flex-col gap-1.5">
                <li
                  :for={b <- @recent_tasks}
                  class={[
                    "rounded-box border bg-base-100 px-3 py-2 transition-colors duration-150 hover:bg-base-300/40",
                    if(b.priority == 1,
                      do: "border-l-4 border-error bg-error/5",
                      else: "border-base-300"
                    )
                  ]}
                >
                  <div class="flex items-center gap-2">
                    <span class={[
                      "badge badge-sm font-mono shrink-0",
                      if(b.priority == 1, do: "badge-error", else: "badge-ghost")
                    ]}>
                      P{b.priority}
                    </span>
                    <span class={[
                      "badge badge-sm font-mono shrink-0",
                      difficulty_badge_class(b.difficulty)
                    ]}>
                      {difficulty_label(b.difficulty)}
                    </span>
                    <.link navigate={~p"/tasks/#{b.id}"} class="min-w-0 flex-1 group">
                      <div class="flex items-center gap-2">
                        <code class="text-xs text-base-content/60 shrink-0 group-hover:text-primary transition-colors">
                          {b.id}
                        </code>
                        <span
                          class="truncate text-sm group-hover:text-primary transition-colors"
                          title={b.title}
                        >
                          {b.title}
                        </span>
                      </div>
                    </.link>
                    <span
                      :if={Map.get(b, :blocked_count, 0) > 0}
                      class="badge badge-warning badge-sm gap-1 shrink-0"
                      title="Open blockers gating this directive"
                    >
                      <.icon name="hero-lock-closed" class="size-3" />
                      {Map.get(b, :blocked_count)} blocked
                    </span>
                    <span class={["badge badge-sm shrink-0", status_badge_class(b.status)]}>
                      {b.status}
                    </span>
                  </div>
                </li>
              </ul>
            </div>
          </section>
        </div>

        <%!-- ── C2. Campaigns (open epics) ───────────────────────────── --%>
        <%!-- Only OPEN epic tasks surface on the landing, capped. The full,
             filterable task list lives on the /tasks index. Each epic shows
             its `:parent_of` child-progress rollup. --%>
        <section id="epics-section" class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <div class="flex items-center justify-between">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-rectangle-stack" class="size-5 text-base-content/70" />
                Open {cap_plural(@epic_label)} ({length(@epics)})
              </h2>
              <.see_all_link navigate={~p"/tasks"} />
            </div>

            <div
              :if={@epics == []}
              id="epics-empty"
              class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
            >
              <.icon name="hero-rectangle-stack" class="size-8 mx-auto text-base-content/30" />
              <p class="mt-2 text-sm text-base-content/60">
                No open {plural(@epic_label)}. Parent {plural(@issue_label)} grouping related work appear here while active.
              </p>
            </div>

            <ul :if={@epics != []} id="epics" class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <li
                :for={e <- @epics}
                class="rounded-box bg-base-100 border border-base-300 p-3 transition-colors duration-150 hover:border-primary/40"
              >
                <.link navigate={~p"/tasks/#{e.id}"} class="group block">
                  <div class="flex items-center gap-2">
                    <span
                      class="truncate text-sm font-medium group-hover:text-primary transition-colors"
                      title={e.title}
                    >
                      {e.title}
                    </span>
                    <span class="text-xs font-mono tabular-nums text-base-content/60 shrink-0 ml-auto">
                      {e.child_closed}/{e.child_total}
                    </span>
                  </div>
                  <code class="text-xs text-base-content/50">{e.id}</code>
                  <progress
                    class="progress progress-success w-full mt-2 h-1.5"
                    value={e.child_closed}
                    max={max(e.child_total, 1)}
                  >
                  </progress>
                </.link>
              </li>
            </ul>
          </div>
        </section>

        <%!-- ── D. Admiral mailbox ───────────────────────────────────── --%>
        <%!-- Unread mailbox-family mail addressed to the coordinator
             ("admiral"): completions, failures, escalations, flags, info.
             Read-acknowledge per message; clear drains the read tail. The
             upward channel of `arb inbox` / `arb msg`, surfaced live. --%>
        <section id="admiral-mailbox" class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <div class="flex items-center justify-between gap-2">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-envelope" class="size-5 text-base-content/70" /> Coordinator Mailbox
                <span class={[
                  "badge badge-sm",
                  if(@admiral_inbox == [], do: "badge-ghost", else: "badge-warning")
                ]}>
                  {length(@admiral_inbox)} unread
                </span>
              </h2>
              <button
                phx-click="clear_admiral"
                class="btn btn-xs btn-ghost gap-1"
                data-confirm="Clear all already-read Coordinator mail? (unread is kept)"
                title="Drain the read tail — already-read mail is destroyed, unread is kept"
              >
                <.icon name="hero-trash" class="size-3.5" /> Clear read
              </button>
            </div>

            <div
              :if={@admiral_inbox == []}
              id="admiral-mailbox-empty"
              class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
            >
              <.icon name="hero-inbox" class="size-8 mx-auto text-base-content/30" />
              <p class="mt-2 text-sm text-base-content/60">
                Inbox clear. Worker completions, failures, and escalations addressed
                to the Coordinator land here in real time.
              </p>
            </div>

            <ul
              :if={@admiral_inbox != []}
              id="admiral-mailbox-list"
              class="flex flex-col gap-2 max-h-80 overflow-y-auto pr-1"
            >
              <li
                :for={m <- @admiral_inbox}
                class={[
                  "rounded-box bg-base-100 border border-base-300 border-l-4 px-3 py-2",
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
                    <.link
                      :if={m.directive_ref}
                      navigate={~p"/tasks/#{m.directive_ref}"}
                      class="text-xs link link-hover text-base-content/50"
                    >
                      [<code class="font-mono">{m.directive_ref}</code>]
                    </.link>
                    <span :if={m.subject} class="text-sm font-medium truncate">{m.subject}</span>
                  </div>
                  <div class="flex items-center gap-2 shrink-0">
                    <span
                      class="text-xs text-base-content/50 whitespace-nowrap"
                      title={format_ts(m.inserted_at)}
                    >
                      {relative_time(m.inserted_at, @now)}
                    </span>
                    <button
                      phx-click="mark_read"
                      phx-value-id={m.id}
                      class="btn btn-xs btn-ghost"
                    >
                      Mark read
                    </button>
                  </div>
                </div>
                <p
                  :if={m.body not in [nil, ""]}
                  class="text-sm mt-1.5 whitespace-pre-wrap text-base-content/80"
                >
                  {m.body}
                </p>
              </li>
            </ul>
          </div>
        </section>

        <%!-- ── E. Notifications feed ────────────────────────────────── --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <h2 class="text-lg font-semibold flex items-center gap-2">
              <.icon name="hero-bell-alert" class="size-5 text-base-content/70" />
              Notifications ({length(@notifications)})
            </h2>

            <div
              :if={@notifications == []}
              id="notifications-empty"
              class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
            >
              <.icon name="hero-bell-slash" class="size-8 mx-auto text-base-content/30" />
              <p class="mt-2 text-sm text-base-content/60">
                No notifications yet. {String.capitalize(@worker_label)} completions and
                system events appear here in real time.
              </p>
            </div>

            <ul
              :if={@notifications != []}
              id="notifications-feed"
              class="flex flex-col gap-2 max-h-80 overflow-y-auto pr-1"
            >
              <li
                :for={n <- @notifications}
                class={[
                  "flex items-start gap-3 rounded-box bg-base-100 border-l-4 px-3 py-2",
                  kind_border_class(n.kind)
                ]}
              >
                <span class={["badge badge-sm shrink-0 mt-0.5", kind_badge_class(n.kind)]}>
                  {n.kind}
                </span>
                <div class="min-w-0 flex-1">
                  <div class="flex items-baseline gap-2">
                    <span class="text-sm text-base-content/90 truncate">
                      {n.subject || excerpt(n.body)}
                    </span>
                    <code :if={n.from_ref} class="text-xs text-base-content/50 shrink-0">
                      {n.from_ref}
                    </code>
                  </div>
                </div>
                <span
                  class="text-xs text-base-content/50 whitespace-nowrap shrink-0"
                  title={format_ts(n.inserted_at)}
                >
                  {relative_time(n.inserted_at, @now)}
                </span>
              </li>
            </ul>
          </div>
        </section>

        <%!-- ── F. Workspaces / Warships as compact cards ────────────── --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <section id="workspaces-section" class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-building-office-2" class="size-5 text-base-content/70" />
                {cap_plural(@workspace_label)} ({length(@workspaces)})
              </h2>

              <p :if={@workspaces == []} class="text-sm text-base-content/60 italic">
                No {plural(@workspace_label)} configured yet.
              </p>

              <div :if={@workspaces != []} class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div
                  :for={ws <- @workspaces}
                  class="rounded-box bg-base-100 border border-base-300 p-3 transition-colors duration-150 hover:border-primary/40"
                >
                  <div class="flex items-center justify-between gap-2">
                    <span class="font-medium truncate" title={ws.name}>{ws.name}</span>
                    <code class="badge badge-ghost badge-sm font-mono shrink-0">{ws.prefix}</code>
                  </div>
                  <div class="text-xs text-base-content/50 mt-0.5">tracker: {ws.tracker_type}</div>
                  <div class="flex flex-wrap items-center gap-1.5 mt-2.5 text-xs">
                    <span class="badge badge-sm badge-info" title={"Active #{plural(@worker_label)}"}>
                      <.icon name="hero-cpu-chip" class="size-3 mr-0.5" />{ws.workers}
                    </span>
                    <span class="badge badge-sm badge-success" title={"Open #{plural(@issue_label)}"}>
                      {ws.open} open
                    </span>
                    <span class="badge badge-sm badge-ghost" title="In progress">
                      {ws.in_progress} active
                    </span>
                    <span class="badge badge-sm badge-ghost" title="Closed">{ws.closed} closed</span>
                  </div>
                </div>
              </div>
            </div>
          </section>

          <section id="repos-section" class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-4">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-server-stack" class="size-5 text-base-content/70" />
                {cap_plural(@repo_label)} ({length(@rigs)})
              </h2>

              <p :if={@rigs == []} class="text-sm text-base-content/60 italic">
                No {plural(@repo_label)} configured. Add entries to
                <code class="text-xs">:arbiter, :repo_paths</code>
                in config or to a {@workspace_label}'s <code class="text-xs">config["repo_paths"]</code>.
              </p>

              <div :if={@rigs != []} class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div
                  :for={repo <- @rigs}
                  class="rounded-box bg-base-100 border border-base-300 p-3 transition-colors duration-150 hover:border-secondary/40"
                >
                  <div class="flex items-center justify-between gap-2">
                    <code class="font-medium truncate" title={repo.name}>{repo.name}</code>
                    <span class="badge badge-ghost badge-sm shrink-0">{repo.source}</span>
                  </div>
                  <div
                    class="text-xs text-base-content/50 mt-0.5 truncate font-mono"
                    title={repo.path || "(no path)"}
                  >
                    {repo.path || "(no path)"}
                  </div>
                  <div class="flex flex-wrap items-center gap-1.5 mt-2.5 text-xs">
                    <span class="badge badge-sm badge-info" title={"Active #{plural(@worker_label)}"}>
                      <.icon name="hero-cpu-chip" class="size-3 mr-0.5" />{repo.workers}
                    </span>
                    <span class="badge badge-sm badge-ghost" title={cap_plural(@worktree_label)}>
                      {repo.worktrees} {plural(@worktree_label)}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </section>
        </div>

        <%!-- ── G. Completed workers ─────────────────────────────────── --%>
        <section class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <div class="flex items-center justify-between">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5 text-base-content/70" />
                Completed {cap_plural(@worker_label)} ({length(@completed_runs)})
              </h2>
              <.see_all_link navigate={~p"/workers/history"} />
            </div>

            <div
              :if={@completed_runs == []}
              id="completed-runs-empty"
              class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
            >
              <.icon name="hero-archive-box" class="size-8 mx-auto text-base-content/30" />
              <p class="mt-2 text-sm text-base-content/60">
                No completed {plural(@worker_label)} yet. Past runs appear here after the {@worker_label} finishes or fails.
              </p>
            </div>

            <div :if={@completed_runs != []} class="overflow-x-auto">
              <table class="table table-sm" id="completed-runs">
                <thead>
                  <tr class="text-base-content/60">
                    <th>{String.capitalize(@issue_label)}</th>
                    <th>Title</th>
                    <th>Status</th>
                    <th>Started</th>
                    <th class="text-right">Duration</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={r <- @completed_runs} class="hover:bg-base-300/40 transition-colors">
                    <td>
                      <.link navigate={~p"/workers/history/#{r.id}"} class="link link-hover">
                        <code class="text-xs">{r.task_id}</code>
                      </.link>
                    </td>
                    <td class="text-xs max-w-xs truncate" title={r.task_title || ""}>
                      {r.task_title || "—"}
                    </td>
                    <td>
                      <span class={["badge badge-sm", run_status_class(r.status)]}>{r.status}</span>
                    </td>
                    <td class="text-xs whitespace-nowrap">{format_ts(r.started_at)}</td>
                    <td class="text-xs text-right font-mono tabular-nums whitespace-nowrap">
                      {humanize_duration(r.started_at, r.completed_at)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>

        <%!-- ── H. Merge queue ───────────────────────────────────────── --%>
        <section id="merge-queue-section" class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <div class="flex items-center justify-between gap-2">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-arrow-path-rounded-square" class="size-5 text-primary" />
                {cap_plural(@merge_queue_label)} ({length(@merge_queue)})
                <span class="text-sm font-normal text-base-content/50">
                  — {plural(@pr_label)} integrating now
                </span>
              </h2>
              <.see_all_link navigate={~p"/merge_queue"} />
            </div>

            <div
              :if={@merge_queue == []}
              id="merge-queue-empty"
              class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-6 text-center"
            >
              <.icon name="hero-inbox" class="size-8 mx-auto text-base-content/30" />
              <p class="mt-2 text-sm text-base-content/60">
                No {plural(@pr_label)} integrating right now.
              </p>
              <p class="text-xs text-base-content/50">
                Branches awaiting review via {@merge_queue_label} (Direct, GitLab, GitHub)
                appear here with their approval status and Watchdog poll activity.
              </p>
            </div>

            <ul :if={@merge_queue != []} id="merge-queue" class="flex flex-col gap-3">
              <li
                :for={m <- @merge_queue}
                class="rounded-box bg-base-100 border border-base-300 p-3 transition-colors duration-150 hover:border-primary/50"
              >
                <div class="flex items-center justify-between gap-2">
                  <.link
                    navigate={~p"/workers/#{m.task_id}"}
                    class="flex items-center gap-2 min-w-0 group"
                  >
                    <span class="relative flex h-2.5 w-2.5 shrink-0">
                      <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-warning opacity-75">
                      </span>
                      <span class="relative inline-flex h-2.5 w-2.5 rounded-full bg-warning"></span>
                    </span>
                    <code class="text-xs font-semibold group-hover:text-primary transition-colors truncate">
                      {m.task_id}
                    </code>
                  </.link>
                  <div class="flex items-center gap-1.5 shrink-0">
                    <span class="badge badge-sm badge-ghost font-mono">
                      {merger_type_label(m.merger_type)}
                    </span>
                    <span class={["badge badge-sm", merge_status_class(m.merger_status)]}>
                      {merge_status_label(m.merger_status)}
                    </span>
                  </div>
                </div>

                <div class="flex items-center justify-between gap-2 mt-1.5 text-xs text-base-content/60">
                  <span class="truncate">{m.workspace_name}</span>
                  <span class="font-mono tabular-nums shrink-0" title="Time in queue">
                    {humanize_seconds(runtime_seconds(m.since, @now))} in queue
                  </span>
                </div>

                <div :if={m.mr_ref} class="flex items-center gap-1 mt-1.5 text-xs min-w-0">
                  <.icon name="hero-arrow-top-right-on-square" class="size-3 text-primary shrink-0" />
                  <a
                    :if={m.merger_url}
                    href={m.merger_url}
                    target="_blank"
                    rel="noopener"
                    class="link link-primary truncate"
                  >
                    {m.mr_ref}
                  </a>
                  <code :if={!m.merger_url} class="truncate text-base-content/70">{m.mr_ref}</code>
                </div>

                <%!-- Watchdog activity: poll cadence + freshness of the last check. --%>
                <div class="flex items-center gap-1.5 mt-2 pt-2 border-t border-base-300 text-xs text-base-content/50">
                  <.icon name="hero-eye" class="size-3 shrink-0" />
                  <span :if={m.last_checked_at}>
                    Watchdog checked {relative_time(m.last_checked_at, @now)} · every {poll_interval_seconds()}s
                  </span>
                  <span :if={!m.last_checked_at}>
                    Watchdog polling every {poll_interval_seconds()}s
                  </span>
                </div>
              </li>
            </ul>
          </div>
        </section>

        <%!-- ── I. ReviewGate (review gate) ────────────────────────────── --%>
        <%!-- The review gate: a separate reviewer mind code-reviews each diff
             before it merges. Two surfaces — reviews in flight right now
             (authors parked at :awaiting_review_gate), and the durable record of
             non-approve verdicts (escalations carrying the reviewer's findings).
             Approvals proceed straight to the merge queue, so they surface
             there and in Completed, not here. Live. --%>
        <section id="review_gate-section" class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-4">
            <h2 class="text-lg font-semibold flex items-center gap-2">
              <.icon name="hero-scale" class="size-5 text-warning" /> ReviewGate
              <span class="text-sm font-normal text-base-content/50">
                — code review before merge
              </span>
            </h2>

            <%!-- In review now: live reviews gating a merge. --%>
            <div class="space-y-2">
              <h3 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
                <.icon name="hero-magnifying-glass" class="size-4" />
                In review ({length(@pending_reviews)})
              </h3>

              <div
                :if={@pending_reviews == []}
                id="pending-reviews-empty"
                class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-4 text-center"
              >
                <p class="text-sm text-base-content/60">
                  No reviews in flight. When a {@worker_label} signals done in a {@workspace_label} that requires review, the ReviewGate spawns a reviewer and the {@issue_label} appears
                  here until a verdict lands.
                </p>
              </div>

              <ul :if={@pending_reviews != []} id="pending-reviews" class="flex flex-col gap-2">
                <li
                  :for={r <- @pending_reviews}
                  class="rounded-box bg-base-100 border border-base-300 border-l-4 border-warning p-3"
                >
                  <div class="flex items-center justify-between gap-2">
                    <.link
                      navigate={~p"/workers/#{r.task_id}"}
                      class="flex items-center gap-2 min-w-0 group"
                    >
                      <span class="relative flex h-2.5 w-2.5 shrink-0">
                        <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-warning opacity-75">
                        </span>
                        <span class="relative inline-flex h-2.5 w-2.5 rounded-full bg-warning"></span>
                      </span>
                      <code class="text-xs font-semibold group-hover:text-warning transition-colors truncate">
                        {r.task_id}
                      </code>
                    </.link>
                    <span
                      class="text-xs font-mono text-base-content/70 tabular-nums shrink-0"
                      title="Time in review_gate"
                    >
                      {humanize_seconds(runtime_seconds(r.since, @now))} in review
                    </span>
                  </div>

                  <div class="flex items-center justify-between gap-2 mt-1.5 text-xs text-base-content/60">
                    <span class="truncate">{r.workspace_name}</span>
                    <span
                      :if={r.reviewer_activity}
                      class="badge badge-warning badge-sm gap-1.5 max-w-[55%]"
                    >
                      <span class="loading loading-ring loading-xs"></span>
                      <span class="truncate">{r.reviewer_activity}</span>
                    </span>
                  </div>
                </li>
              </ul>
            </div>

            <%!-- Recent verdicts: durable record of escalated (non-approve)
                 reviews, with the reviewer's findings. --%>
            <div class="space-y-2">
              <h3 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
                <.icon name="hero-flag" class="size-4" />
                Recent {cap_plural(@escalation_label)} ({length(@escalations)})
              </h3>

              <div
                :if={@escalations == []}
                id="escalations-empty"
                class="rounded-box bg-base-100/50 border border-dashed border-base-300 p-4 text-center"
              >
                <p class="text-sm text-base-content/60">
                  No {plural(@escalation_label)}. A ReviewGate that requests changes or returns
                  an inconclusive verdict escalates here with the reviewer's findings — the
                  branch is parked, not merged.
                </p>
              </div>

              <ul :if={@escalations != []} id="escalations" class="flex flex-col gap-2">
                <li
                  :for={e <- @escalations}
                  class="rounded-box bg-base-100 border border-base-300 border-l-4 border-error px-3 py-2"
                >
                  <div class="flex items-baseline justify-between gap-2">
                    <div class="flex items-baseline gap-2 flex-wrap min-w-0">
                      <span class={["badge badge-sm shrink-0", escalation_verdict_class(e.subject)]}>
                        {escalation_verdict_label(e.subject)}
                      </span>
                      <.link
                        :if={e.directive_ref}
                        navigate={~p"/tasks/#{e.directive_ref}"}
                        class="text-xs link link-hover font-mono text-base-content/60"
                      >
                        {e.directive_ref}
                      </.link>
                      <span :if={e.subject} class="text-sm truncate">{e.subject}</span>
                    </div>
                    <span
                      class="text-xs text-base-content/50 whitespace-nowrap shrink-0"
                      title={format_ts(e.inserted_at)}
                    >
                      {relative_time(e.inserted_at, @now)}
                    </span>
                  </div>
                  <p
                    :if={e.body not in [nil, ""]}
                    class="text-xs mt-1.5 whitespace-pre-wrap text-base-content/70 line-clamp-3"
                  >
                    {e.body}
                  </p>
                </li>
              </ul>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers (labels + stats + status visuals) ----
  # `plural/1` and `cap_plural/1` come from `ArbiterWeb.Labels` (imported via
  # `ArbiterWeb`), shared with the index/detail pages.

  defp open_issue_total(workspaces) do
    Enum.reduce(workspaces, 0, fn ws, acc -> acc + Map.get(ws, :open, 0) end)
  end

  # Solid status dot color for the active-worker rows (mirrors the badge palette).
  defp status_dot_class(:running), do: "bg-info"
  defp status_dot_class(:awaiting), do: "bg-warning"
  defp status_dot_class(:completed), do: "bg-success"
  defp status_dot_class(:failed), do: "bg-error"
  defp status_dot_class(_), do: "bg-base-content/30"

  # Inline lifecycle-track segment color, given a step's state vs current status.
  defp flow_bar_class(:done), do: "bg-success"
  defp flow_bar_class(:current), do: "bg-info"
  defp flow_bar_class(:todo), do: "bg-base-300"

  # Left-accent border per notification kind, matching kind_badge_class/1.
  defp kind_border_class(:notification), do: "border-info"
  defp kind_border_class(:direction), do: "border-warning"
  defp kind_border_class(:flag), do: "border-accent"
  defp kind_border_class(:escalation), do: "border-error"
  defp kind_border_class(:failure), do: "border-error"
  defp kind_border_class(:completion), do: "border-success"
  defp kind_border_class(:info), do: "border-info"
  defp kind_border_class(_), do: "border-base-300"
end
