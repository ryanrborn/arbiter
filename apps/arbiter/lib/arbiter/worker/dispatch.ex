defmodule Arbiter.Worker.Dispatch do
  @moduledoc """
  Spawn a worker for a task and attach it to the `Arbiter.Workflows.Work`
  workflow via `Arbiter.Workflows.Machine`.

  This is the "go work this task" entry point — called by:

    * the `arb dispatch <task-id>` CLI command (via the REST API),
    * the `MergeQueue` GenServer (when re-dispatching follow-ups),
    * Phoenix LiveView dashboards that have a "send worker" button.

  Single responsibility: orchestrate the three steps needed to start a
  worker working on a task, in the right order, with the right cleanup if
  anything fails.

  ## Steps

  1. Load + validate the task. Task must not be `:closed`.
  2. Transition task to `:in_progress` (via the task's `:update` action,
     skipping the `:close` FSM path).
  3. Provision a git worktree on a per-task branch — skipped when the
     repo isn't in `:arbiter, :repo_paths` or `provision_worktree: false`.
  4. Start a worker under `Arbiter.Worker.Supervisor` for the task.
  5. **Optionally** spawn a Claude subprocess in the worktree via
     `ClaudeSession.start/1`. Opt-in via `start_claude: true` — defaults
     to `false` to avoid silent paid-API invocations. Requires a worktree.
  6. Attach `Arbiter.Workflows.Work` via `Workflows.Machine.attach/3`
     and start the machine.
  7. Start a `Arbiter.Worker.Driver` under the same supervisor — it
     ticks the machine forward and closes the task when the workflow
     completes. Skipped when `start_driver: false`.

  ## Returns

  ```
  {:ok, %{
    task: %Issue{},              # updated, status: :in_progress
    worker_pid: pid(),
    machine_id: String.t(),
    machine_pid: pid(),
    driver_pid: pid() | nil,     # nil if start_driver: false
    worktree_path: String.t() | nil,  # nil if repo unconfigured / opted out
    claude_port: port() | nil    # nil unless start_claude: true
  }}
  ```

  Or `{:error, reason}` for any step that fails. On error, partial work is
  best-effort-rolled-back (started worker is stopped; task status revert is
  NOT attempted because the user may want to inspect what happened).
  """

  alias Arbiter.Agents
  alias Arbiter.Agents.Preflight
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers
  alias Arbiter.Usage.Event
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.Driver
  alias Arbiter.Worker.ResumeContext
  alias Arbiter.Worker.StopReason
  alias Arbiter.Worker.TargetBranch
  alias Arbiter.Worker.Worktree
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.CodeReview
  alias Arbiter.Workflows.Machine
  alias Arbiter.Workflows.Work

  require Ash.Query

  @type dispatch_opts :: [
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          workflow_module: module(),
          start_driver: boolean(),
          start_claude: boolean(),
          claude_command: [String.t()] | nil,
          cleanup_worktree: boolean(),
          model: String.t() | nil,
          agent_type: atom() | nil,
          review: boolean(),
          security: map() | nil,
          security_mode: String.t() | atom() | nil,
          preflight: boolean(),
          probe_command: [String.t()] | nil,
          agent_adapter: module() | nil,
          depth: non_neg_integer()
        ]

  @type dispatch_result :: %{
          task: Issue.t(),
          worker_pid: pid(),
          machine_id: String.t(),
          machine_pid: pid(),
          driver_pid: pid() | nil,
          worktree_path: String.t() | nil,
          claude_port: port() | nil
        }

  @spec dispatch(String.t(), dispatch_opts()) :: {:ok, dispatch_result()} | {:error, term()}
  def dispatch(task_id, opts \\ []) when is_binary(task_id) do
    opts = normalize_opts(opts)

    with {:ok, task} <- load_task(task_id),
         :ok <- ensure_not_closed(task),
         :ok <- ensure_not_awaiting_review(task_id),
         :ok <- maybe_quota_gate(task, opts),
         {:ok, opts} <- maybe_resolve_repo_for_real_work(task, opts),
         :ok <- maybe_preflight(task, opts),
         {:ok, task} <- transition_to_in_progress(task, opts),
         {:ok, worktree_path} <- maybe_provision_worktree(task, opts),
         {:ok, worker_pid} <- start_worker(task, worktree_path, opts) do
      finish_dispatch(task, worker_pid, worktree_path, opts)
    else
      err -> err
    end
  end

  # Everything after `start_worker/3` succeeds — the worker is already
  # registered `:idle`, so a failure here must not be swallowed silently
  # (bd-bi5pn0). A step failing partway (e.g. a transient network/VPN outage
  # during the Claude subprocess spawn, or a workflow-machine attach failure)
  # previously left that `:idle` registration stranded forever: no retry, no
  # escalation, and the task stuck `:in_progress` — which also permanently
  # blackholed PRPatrol dedup for the underlying PR (it treats any non-closed
  # follow-up as "already handled"). On error, explicitly fail the worker
  # (`:idle` -> `:failed` is a valid FSM transition) with a `:spawn_failed`
  # `StopReason` and escalate to the Admiral, mirroring the
  # `realign_task_if_orphaned/2` pattern (bd-cgmidt) above.
  defp finish_dispatch(task, worker_pid, worktree_path, opts) do
    with {:ok, claude_port} <-
           maybe_start_claude(task, worker_pid, worktree_path, opts),
         {:ok, machine_id, machine_pid} <-
           attach_and_start_machine(task, worktree_path, opts),
         {:ok, driver_pid} <-
           maybe_start_driver(task, worker_pid, machine_id, machine_pid, worktree_path, opts),
         # bd-cgmidt: `ensure_not_closed/1` above is a front-of-pipeline check. An
         # async close (in production, the MergeQueue direct-strategy close of an
         # in-flight `{:worker_done}` from the just-stopped run) can land in the
         # window between that guard and `start_worker/3`, flipping the bead to
         # `:closed` AFTER the guard passed but as/just before the new worker is
         # attached — leaving a live worker orphaned on a `:closed` task (the
         # close's own StopWorker found no worker to stop). Re-assert here, now
         # that the worker is live, and realign a raced-closed bead.
         {:ok, task} <- realign_task_if_orphaned(task.id, worker_pid) do
      {:ok,
       %{
         task: task,
         worker_pid: worker_pid,
         machine_id: machine_id,
         machine_pid: machine_pid,
         driver_pid: driver_pid,
         worktree_path: worktree_path,
         claude_port: claude_port
       }}
    else
      {:error, reason} = err ->
        fail_spawned_worker(worker_pid, reason)
        err
    end
  end

  # Fail the just-started worker into `:failed` with a `:spawn_failed`
  # StopReason and raise an Admiral escalation, so the caller's error return
  # is never the *only* signal — the bead is not left silently stranded.
  # Best-effort: a dead worker (already terminated some other way) or a
  # notification hiccup must never mask the original dispatch error.
  defp fail_spawned_worker(worker_pid, reason) when is_pid(worker_pid) do
    if Process.alive?(worker_pid) do
      stop_reason = StopReason.spawn_failed(reason)
      snapshot = safe_worker_snapshot(worker_pid)

      _ = Worker.fail(worker_pid, stop_reason)
      CoordinatorNotifier.spawn_failed(snapshot, stop_reason)
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp fail_spawned_worker(_worker_pid, _reason), do: :ok

  defp safe_worker_snapshot(pid) do
    Worker.state(pid)
  rescue
    _ -> %{task_id: nil}
  catch
    :exit, _ -> %{task_id: nil}
  end

  @doc """
  Resume a stopped worker (bd-auma3z): re-attach a **fresh** agent to the
  task's **preserved** worktree, briefed with a git-derived summary of
  the prior worker's committed + uncommitted work, so it continues from where
  the stopped run left off instead of restarting from scratch.

  This is the explicit `arb resume <task>` path. It is provider-agnostic — no
  Claude/Gemini session-resume id; the continuity comes entirely from the
  preserved worktree state plus a `Arbiter.Worker.ResumeContext` briefing
  prepended to the standard work prompt (Admiral sign-off 2026-06-05, approach
  (b)).

  ## Steps

  1. Load + validate the task (must not be `:closed`).
  2. Refuse if a worker is still **actively** working the task — resume only
     applies to a stopped/failed/dead worker. Stop the active one first.
  3. Resolve the repo (explicit opt, else the task's most recent run's repo).
  4. Require the worktree to still exist on disk — `{:error,
     :no_outpost}` if it was cleaned up (nothing to resume; re-`dispatch` instead).
  5. Build the resume briefing from the worktree's git state.
  6. Stop any prior (failed) worker still resident for the task so a fresh
     `worker_run` starts cleanly rather than the new dispatch attaching to the
     dead one (which would skip the run row and collide on the registry key —
     the same class of bug fixed in the conflict-resolver).
  7. Delegate to `dispatch/2` with the resume markers set: it reuses the existing
     worktree (idempotent `Worktree.create`), prepends the briefing, links the
     new run to the prior via `resumed_from_run_id`, and passes the task's
     existing `pr_ref` so completion reuses any open PR rather than duplicating.

  Returns the same `{:ok, dispatch_result()}` / `{:error, reason}` shape as
  `dispatch/2`. Resume-specific errors: `{:error, :no_outpost}`,
  `{:error, {:acolyte_active, status}}`, `{:error, :repo_unknown}`.
  """
  @spec resume(String.t(), dispatch_opts()) :: {:ok, dispatch_result()} | {:error, term()}
  def resume(task_id, opts \\ []) when is_binary(task_id) do
    with {:ok, task} <- load_task(task_id),
         :ok <- ensure_not_closed(task),
         :ok <- ensure_not_active(task_id),
         {:ok, repo} <- resolve_resume_repo(task, opts),
         {:ok, worktree_path} <- resume_worktree(task, repo),
         target_branch <- resolve_target_branch(task, Keyword.put(opts, :repo, repo)),
         {:ok, context} <- ResumeContext.build(task, worktree_path, target_branch) do
      prior_run_id = latest_run_id(task_id)

      # bd-95lsjb: an auto-revise dispatch passes `:revise_feedback` — the
      # reviewer's PR-side feedback. Prepend it to the git-derived resume
      # briefing so the fresh worker addresses the feedback first, then
      # continues from the preserved worktree.
      context = prepend_revise_feedback(context, opts)

      # Free the registry slot: a stopped worker's worker lingers in :failed,
      # still registered under task_id. Without stopping it, dispatch/2's
      # start_worker would hit {:already_started, pid} and attach to the dead
      # one — no fresh run, no resumed_from_run_id. Stopping it does NOT touch
      # the worktree (terminate/2 never cleans up), so the worktree is preserved.
      _ = stop_prior_worker(task_id)

      resume_opts =
        opts
        |> Keyword.put(:repo, repo)
        |> Keyword.put(:start_claude, true)
        |> Keyword.put(:resume, true)
        |> Keyword.put(:resume_context, context)
        |> Keyword.put(:resumed_from_run_id, prior_run_id)
        |> Keyword.put(:existing_pr_ref, task.pr_ref)

      dispatch(task_id, resume_opts)
    end
  end

  defp prepend_revise_feedback(context, opts) do
    case Keyword.get(opts, :revise_feedback) do
      briefing when is_binary(briefing) and briefing != "" -> briefing <> (context || "")
      _ -> context
    end
  end

  @doc """
  Session-level resume (bd-1z7624, #472): re-spawn the worker continuing the
  task's PRIOR Claude session via `claude --print --resume <session_id>` in the
  SAME preserved worktree — NOT a fresh agent. This is the manual trigger for
  the automatic session-resume machinery from bd-t9uq25: it looks up the task's
  most-recent captured `session_id` (from the usage ledger) and threads it into
  the spawn, so the worker's first session opens with `--resume` and the prior
  session's full context is preserved.

  Distinct from `resume/2` (bd-auma3z), which attaches a *fresh* agent briefed
  with a git-derived summary. Session resume keeps the original mind; use it
  when the prior run stopped mid-task (token exhaustion, kill, crash-exit) and
  you want it to literally pick up where it left off — the same thing the
  `:exited_without_done` auto-resume does, triggered manually for a task.

  ## Steps

  1. Load + validate the task (must not be `:closed`).
  2. Refuse if a worker is still actively working the task — stop it first.
  3. Resolve the repo (explicit opt, else the task's most recent run's repo).
  4. Require the preserved worktree to still exist on disk (`{:error,
     :no_outpost}` if it was cleaned up — nothing to resume; dispatch fresh).
  5. Look up the most-recent captured `session_id` for the task. No session id
     on record → `{:error, :no_session}` (nothing to resume at the session
     level; dispatch fresh instead). We never silently start a fresh session.
  6. Stop any lingering prior worker so a fresh run row starts cleanly.
  7. Delegate to `dispatch/2` with `:resume_session_id` set — the worker injects
     `--resume <session_id>` into its first spawn and stashes the *pristine*
     argv, so the bd-t9uq25 auto-resume keeps working correctly on top.

  Returns the same `{:ok, dispatch_result()}` / `{:error, reason}` shape as
  `dispatch/2`. Session-resume-specific errors: `{:error, :no_outpost}`,
  `{:error, :no_session}`, `{:error, {:acolyte_active, status}}`,
  `{:error, :repo_unknown}`.
  """
  @spec resume_session(String.t(), dispatch_opts()) ::
          {:ok, dispatch_result()} | {:error, term()}
  def resume_session(task_id, opts \\ []) when is_binary(task_id) do
    with {:ok, task} <- load_task(task_id),
         :ok <- ensure_not_closed(task),
         :ok <- ensure_not_active(task_id),
         {:ok, repo} <- resolve_resume_repo(task, opts),
         {:ok, _worktree_path} <- resume_worktree(task, repo),
         {:ok, session_id} <- latest_session_id(task_id) do
      prior_run_id = latest_run_id(task_id)

      # Free the registry slot the same way resume/2 does: a stopped worker
      # lingers in :failed, still registered under task_id, and would make
      # dispatch/2 attach to the dead one instead of starting a fresh run.
      # Stopping it never touches the worktree, so it stays preserved.
      _ = stop_prior_worker(task_id)

      resume_opts =
        opts
        |> Keyword.put(:repo, repo)
        |> Keyword.put(:start_claude, true)
        |> Keyword.put(:resume, true)
        |> Keyword.put(:resume_session_id, session_id)
        |> Keyword.put(:resumed_from_run_id, prior_run_id)
        |> Keyword.put(:existing_pr_ref, task.pr_ref)

      dispatch(task_id, resume_opts)
    end
  end

  # Resume only applies to a stopped/failed/dead worker. If a worker is still
  # live in a working state, refuse rather than stomp in-flight work — the
  # operator should `arb worker stop` it first. A :failed (the stopped state)
  # or :completed worker, or no worker at all, is resumable.
  defp ensure_not_active(task_id) do
    case Worker.whereis(task_id) do
      nil ->
        :ok

      pid ->
        case safe_worker_status(pid) do
          status when status in [:failed, :completed, nil] -> :ok
          status -> {:error, {:acolyte_active, status}}
        end
    end
  end

  defp safe_worker_status(pid) do
    case Worker.state(pid) do
      %{status: status} -> status
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # The repo: an explicit opt wins; otherwise inherit the task's most recent run's
  # repo so `arb resume <task>` works without re-specifying it. No run + no opt is
  # an error — we can't resolve the worktree without knowing the repo.
  defp resolve_resume_repo(%Issue{id: task_id}, opts) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) and repo != "" ->
        {:ok, repo}

      _ ->
        case latest_run(task_id) do
          %Run{repo: repo} when is_binary(repo) and repo != "" -> {:ok, repo}
          _ -> {:error, :repo_unknown}
        end
    end
  end

  # Resolve the preserved worktree path for the task's per-task branch and require
  # it to exist on disk. A missing worktree means there's nothing to resume.
  defp resume_worktree(%Issue{} = task, repo) do
    case resolve_repo_path(task, repo) do
      repo_path when is_binary(repo_path) ->
        path = Worktree.worktree_path(BranchNamer.derive(task))
        if File.dir?(path), do: {:ok, path}, else: {:error, :no_outpost}

      _ ->
        {:error, :repo_unknown}
    end
  end

  defp stop_prior_worker(task_id) do
    case Worker.whereis(task_id) do
      nil -> :ok
      _pid -> Worker.stop(task_id, :normal)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp latest_run_id(task_id) do
    case latest_run(task_id) do
      %Run{id: id} -> id
      _ -> nil
    end
  end

  defp latest_run(nil), do: nil

  defp latest_run(task_id) when is_binary(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  # The most-recent captured upstream session id for the task, newest first.
  # Drawn from the usage ledger (`Arbiter.Usage.Event`), where the worker
  # persists each Claude session's `session_id` on its terminal `result` event.
  # The task_id filter is exact, so ReviewGate reviewer rows (which carry a
  # `#review` suffix) are excluded — we resume the author's session, not a
  # reviewer's. `{:error, :no_session}` when none was ever captured: the task
  # was never worked by a session-capable agent, so there is nothing to resume
  # at the session level (the caller must dispatch fresh).
  defp latest_session_id(task_id) when is_binary(task_id) do
    Event
    |> Ash.Query.filter(task_id == ^task_id and not is_nil(session_id))
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
    |> case do
      %Event{session_id: sid} when is_binary(sid) and sid != "" -> {:ok, sid}
      _ -> {:error, :no_session}
    end
  rescue
    _ -> {:error, :no_session}
  end

  # `review: true` is the convenience hook used by `arb review`: it forces the
  # review-only defaults so the caller doesn't have to spell out four flags in
  # tandem (and so the CLI/REST surface can't accidentally request, say, a
  # worktree on a review). Explicit opts still win — tests and advanced callers
  # can opt back out of any individual default.
  defp normalize_opts(opts) do
    case Keyword.get(opts, :review, false) do
      true ->
        opts
        |> Keyword.put_new(:workflow_module, CodeReview)
        |> Keyword.put_new(:provision_worktree, false)

      _ ->
        opts
    end
  end

  defp load_task(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, _} -> {:error, {:task_not_found, task_id}}
    end
  end

  defp ensure_not_closed(%Issue{status: :closed, id: id}), do: {:error, {:task_closed, id}}
  defp ensure_not_closed(_task), do: :ok

  # Invariant backstop for the dispatch window (bd-cgmidt): when a live worker has
  # just been attached to `task_id`, guarantee the bead is not `:closed`. A close
  # can land asynchronously between `ensure_not_closed/1` (checked once, at the
  # front of `dispatch/2`) and `start_worker/3` — e.g. the MergeQueue's
  # direct-strategy close of an in-flight `{:worker_done}` from the run the
  # operator just stopped. Because that close's `StopWorker` after-action fires
  # when no worker is registered yet (the old one torn down, the new one not
  # started), the freshly-started worker would otherwise be orphaned on a
  # `:closed` task — the 2026-07-08 lt-c9td4r failure.
  #
  # When the bead raced to `:closed` and the worker is still alive, atomically
  # reopen it (`:reopen` → `:in_progress`) so the live worker is realigned rather
  # than orphaned — the same recovery the operator had to perform by hand
  # (`task_reopen`). Otherwise the task is returned unchanged. Public (`@doc
  # false`) so the invariant is unit-testable in isolation.
  @doc false
  @spec realign_task_if_orphaned(String.t(), pid() | nil) ::
          {:ok, Issue.t()} | {:error, term()}
  def realign_task_if_orphaned(task_id, worker_pid) when is_binary(task_id) do
    with {:ok, task} <- load_task(task_id) do
      cond do
        task.status != :closed ->
          {:ok, task}

        not (is_pid(worker_pid) and Process.alive?(worker_pid)) ->
          # No live worker to realign — leave the legitimate close intact.
          {:ok, task}

        true ->
          require Logger

          Logger.warning(
            "Dispatch: task #{task_id} raced to :closed inside the dispatch window " <>
              "(a close landed after the not-closed guard); reopening to realign the " <>
              "live worker and avoid orphaning it on a closed task (bd-cgmidt)"
          )

          with {:ok, reopened} <- reopen_task(task),
               {:ok, in_progress} <- transition_to_in_progress(reopened, []) do
            {:ok, in_progress}
          end
      end
    end
  end

  defp reopen_task(%Issue{} = task) do
    case Ash.update(task, %{}, action: :reopen) do
      {:ok, reopened} -> {:ok, reopened}
      {:error, e} -> {:error, {:reopen_failed, e}}
    end
  end

  # Guard against re-dispatching a task whose worker is already parked at
  # :awaiting_review with an active Watchdog. A second dispatch in this state
  # would attach a new machine/driver to the live worker, disrupting the
  # Watchdog's PID watch and preventing the auto-close on MR merge.
  defp ensure_not_awaiting_review(task_id) do
    case Worker.whereis(task_id) do
      nil ->
        :ok

      pid ->
        case safe_worker_status(pid) do
          :awaiting_review -> {:error, {:task_awaiting_review, task_id}}
          _ -> :ok
        end
    end
  end

  # Quota-aware dispatch gate (bd-7cd38f). The single choke point where the fleet
  # dispatcher consults quota state before mutating any task/worktree/preflight
  # state. Placed after ensure_not_awaiting_review and before
  # maybe_resolve_repo_for_real_work so a HOLD costs nothing and covers every
  # dispatch path at once.
  #
  #   * `:allow`       → dispatch proceeds (headroom, or fail-open).
  #   * `{:hold, r}`   → enqueue the intent in the workspace's DispatchQueue and
  #                      return `{:error, {:quota_held, task_id}}` WITHOUT
  #                      transitioning the task — it drains later in priority
  #                      order. If the queue can't be reached, fail open (allow)
  #                      rather than drop the work.
  #   * `{:overage, s}`→ dispatch proceeds past the cap (`:continue`); record the
  #                      windowed overage spend + fire one alert per threshold
  #                      crossing, then allow.
  #
  # Fail-open guards: skipped on the drain re-dispatch (`skip_quota_gate: true`),
  # when the proxy is disabled (no quota data — e.g. test), and for a task with
  # no workspace. A nil snapshot is handled inside each gate impl.
  defp maybe_quota_gate(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :skip_quota_gate, false) == true -> :ok
      not Arbiter.Quota.proxy_enabled?() -> :ok
      not is_binary(task.workspace_id) -> :ok
      true -> run_quota_gate(task, opts)
    end
  end

  defp run_quota_gate(%Issue{workspace_id: ws_id} = task, opts) do
    workspace = load_workspace(task)
    gate = Arbiter.Quota.gate_for_workspace(workspace)
    quota = safe_quota_latest(ws_id)

    case gate.check(task, quota, workspace, opts) do
      :allow ->
        :ok

      {:hold, reason} ->
        case Arbiter.Workflows.DispatchQueue.hold(ws_id, task.id, opts, reason) do
          :ok ->
            {:error, {:quota_held, task.id}}

          {:error, hold_err} ->
            # The queue is unreachable — fail open so the work is not dropped.
            require Logger

            Logger.warning(
              "Dispatch: quota gate held #{task.id} but enqueue failed " <>
                "(#{inspect(hold_err)}); allowing dispatch to avoid dropping work"
            )

            :ok
        end

      {:overage, spend_usd} ->
        _ = Arbiter.Workflows.DispatchQueue.record_overage(ws_id, task, spend_usd)
        :ok
    end
  rescue
    e ->
      # A bug in the gate must never wedge dispatch — fail open.
      require Logger
      Logger.warning("Dispatch: quota gate crashed for #{task.id}: #{Exception.message(e)}")
      :ok
  end

  defp safe_quota_latest(ws_id) do
    Arbiter.Quota.latest(ws_id, "claude")
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp transition_to_in_progress(%Issue{status: :in_progress} = task, _opts), do: {:ok, task}

  defp transition_to_in_progress(%Issue{} = task, opts) do
    # bd-6xaaam: stamp review_only: true so SyncTracker/SyncFields skip
    # write-back for the in_progress transition and any later field update.
    attrs =
      if Keyword.get(opts, :review, false) do
        %{status: :in_progress, review_only: true}
      else
        %{status: :in_progress}
      end

    case Ash.update(task, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, e} -> {:error, {:transition_failed, e}}
    end
  end

  defp start_worker(%Issue{id: id, workspace_id: ws_id} = task, worktree_path, opts) do
    repo = Keyword.get(opts, :repo) || "unknown"
    meta = build_worker_meta(task, worktree_path, opts)

    case Worker.start(task_id: id, repo: repo, workspace_id: ws_id, meta: meta) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # A worker for this task is already registered. If it ended in a
        # terminal state (:failed / :completed) — the re-dispatch-a-failed-run
        # scenario (bd-d70whv) — stop the stale process so the registry slot
        # is freed, then start a fresh one. Without this, the new Claude
        # session runs inside a :failed worker and the "arb done" marker is
        # silently dropped by the FSM guard that excludes :failed.
        # A live worker in a working state is left as-is.
        case safe_worker_status(pid) do
          status when status in [:failed, :completed] ->
            _ = Worker.stop(pid, :normal)

            case Worker.start(task_id: id, repo: repo, workspace_id: ws_id, meta: meta) do
              {:ok, new_pid} -> {:ok, new_pid}
              {:error, reason} -> {:error, {:worker_start_failed, reason}}
            end

          _ ->
            {:ok, pid}
        end

      {:error, reason} ->
        {:error, {:worker_start_failed, reason}}
    end
  end

  # Seed the worker's :meta with everything its completion path needs to
  # integrate the branch when the worker finishes (see the arb-done handler in
  # `Arbiter.Worker`).
  #
  # When a worktree was provisioned we know the per-task branch and the repo
  # path (the local checkout where the target branch lives — the `repo_path`
  # the `Direct` merger runs `git merge --no-ff` inside). With no worktree
  # (repo unconfigured, or `provision_worktree: false`) there is nothing to
  # merge, so `:branch` stays absent and completion is a plain task close.
  defp build_worker_meta(%Issue{} = task, worktree_path, opts) do
    base =
      case Keyword.get(opts, :review, false) do
        true -> %{worktree_path: worktree_path, review_only: true}
        _ -> %{worktree_path: worktree_path}
      end

    # bd-5lc99r: stamp the directive's issue_type so the worker's completion path
    # can route a `task` type through the notes gate (no commit/review gate, no
    # PR) instead of the commit/review/merge path.
    base = Map.put(base, :issue_type, task.issue_type)

    base = maybe_put_resume_meta(base, opts)

    case worktree_path && resolve_repo_path(task, Keyword.get(opts, :repo)) do
      repo_path when is_binary(repo_path) ->
        Map.merge(base, %{
          branch: BranchNamer.derive(task),
          repo_path: repo_path,
          target_branch: resolve_target_branch(task, opts),
          merge_title: merge_title(task)
        })

      _ ->
        base
    end
  end

  # bd-auma3z: stamp the resume markers into the worker's :meta so (1) the
  # GenServer boots into `:resuming` rather than `:idle`, (2) `record_run_started`
  # links the new run to the prior one via `resumed_from_run_id`, and (3) the
  # completion path can reuse an already-open PR (`existing_pr_ref`) instead of
  # opening a duplicate. No-op on a normal fresh dispatch.
  defp maybe_put_resume_meta(base, opts) do
    case Keyword.get(opts, :resume, false) do
      true ->
        base
        |> Map.put(:resume, true)
        |> put_if_present(:resumed_from_run_id, Keyword.get(opts, :resumed_from_run_id))
        |> put_if_present(:existing_pr_ref, Keyword.get(opts, :existing_pr_ref))
        # bd-1z7624: session-level resume threads the prior session id so the
        # worker's first spawn opens with `claude --print --resume <id>`. nil on
        # a fresh dispatch or the bd-auma3z fresh-agent resume.
        |> put_if_present(:resume_session_id, Keyword.get(opts, :resume_session_id))

      _ ->
        base
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp merge_title(%Issue{id: id, title: title}) when is_binary(title) and title != "",
    do: "Merge #{id}: #{title}"

  defp merge_title(%Issue{id: id}), do: "Merge #{id}"

  defp attach_and_start_machine(%Issue{id: id}, worktree_path, opts) do
    workflow = Keyword.get(opts, :workflow_module, Work)
    vars = %{task_id: id, worktree_path: worktree_path, repo: Keyword.get(opts, :repo)}

    with {:ok, machine_id} <- Machine.attach(workflow, id, vars),
         {:ok, pid} <- Machine.start(machine_id) do
      {:ok, machine_id, pid}
    else
      err -> {:error, {:machine_start_failed, err}}
    end
  end

  # Provision a fresh git worktree on a per-task branch, cut from the upstream
  # tip of the resolved target branch (`origin/<target>`).
  #
  # The arbiter — not the worker — fetches from origin before creating the
  # worktree. The worker then starts on a clean, current branch with no git
  # plumbing in its context.
  #
  # Behaviour:
  #   - `provision_worktree: false` in opts → skip, return `{:ok, nil}`.
  #   - repo has no mapping in workspace config or Application env → skip,
  #     return `{:ok, nil}` (the default no-op stance).
  #   - Otherwise, derive a branch name and call `Worktree.create/3`, which
  #     `git fetch origin <target>` + `git worktree add -b <branch>
  #     origin/<target>`. A fetch or ref-resolve failure aborts with a clear
  #     error rather than silently falling back to a stale local base.
  #
  # ## Repo path lookup order
  #
  #   1. Task's workspace config (`workspace.config["repo_paths"][repo]`)
  #      — per-workspace, runtime-settable, owns the source of truth.
  #   2. Application env (`:arbiter, :repo_paths`) — global fallback,
  #      configured in `config/dev.exs` for dev convenience.
  #
  # First hit wins. This lets workspaces override the global default
  # without changing application config.
  defp maybe_provision_worktree(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :provision_worktree, true) == false ->
        {:ok, nil}

      # bd-5lc99r: a `task` issue type is non-reviewable ops/research/spike work
      # whose deliverable is a findings summary in `notes`, not a code change.
      # It needs no branch to merge, so skip worktree provisioning by default.
      # An explicit `provision_worktree: true` still forces one for the rare task
      # that genuinely needs a repo checkout to inspect.
      task.issue_type == :task and Keyword.get(opts, :provision_worktree) != true ->
        {:ok, nil}

      true ->
        repo = Keyword.get(opts, :repo)

        case resolve_repo_path(task, repo) do
          nil ->
            {:ok, nil}

          repo_path when is_binary(repo_path) ->
            branch = BranchNamer.derive(task)
            target_branch = resolve_target_branch(task, opts)

            case Worktree.create(repo_path, branch, target_branch) do
              {:ok, path} ->
                {:ok, path}

              {:error, {:git_failed, msg}} when is_binary(msg) ->
                if String.contains?(msg, "already exists") do
                  case Worktree.attach(repo_path, branch) do
                    {:ok, path} -> {:ok, path}
                    {:error, reason} -> {:error, {:worktree_failed, reason}}
                  end
                else
                  {:error, {:worktree_failed, {:git_failed, msg}}}
                end

              {:error, reason} ->
                {:error, {:worktree_failed, reason}}
            end
        end
    end
  end

  defp resolve_repo_path(_task, nil), do: nil

  defp resolve_repo_path(%Issue{workspace_id: ws_id}, repo) when is_binary(repo) do
    workspace_repo_path(ws_id, repo) || application_repo_path(repo)
  end

  # Resolve the integration branch — the branch the worktree is cut from and
  # the one the completed branch merges back into. Delegates to the shared
  # `Arbiter.Worker.TargetBranch` resolver so the worktree base computed here
  # and the PR base computed by the `MergeQueue` can never diverge (bd-b6rzoc).
  defp resolve_target_branch(%Issue{} = task, opts) do
    TargetBranch.resolve(task,
      base_branch: Keyword.get(opts, :base_branch),
      repo: Keyword.get(opts, :repo)
    )
  end

  defp workspace_repo_path(nil, _repo), do: nil

  defp workspace_repo_path(ws_id, repo) do
    case load_workspace_config(ws_id) do
      %{} = config ->
        find_repo_path(get_in(config, ["repo_paths"]), repo) ||
          find_repo_path(get_in(config, ["rig_paths"]), repo)

      _ ->
        nil
    end
  end

  defp repo_path_from_config(raw), do: RepoConfig.repo_path_from_config(raw)

  defp application_repo_path(repo) do
    find_repo_path(Application.get_env(:arbiter, :repo_paths, %{}), repo)
  end

  # Exact key match first (the common case). When that misses, fall back to a
  # normalized match (case-insensitive, underscore/hyphen-insensitive) — a
  # forge slug derived from a repo's actual GitHub name (e.g.
  # "owner/verus_server") must still resolve against a `repo_paths` entry
  # registered under a differently-separated key (e.g. "owner/verus-server").
  # See bd-6rioa4.
  defp find_repo_path(map, repo) when is_map(map) and is_binary(repo) do
    case Map.get(map, repo) do
      nil ->
        target = RepoConfig.normalize_slug(repo)

        Enum.find_value(map, fn {k, v} ->
          if RepoConfig.normalize_slug(k) == target, do: repo_path_from_config(v)
        end)

      raw ->
        repo_path_from_config(raw)
    end
  end

  defp find_repo_path(_map, _repo), do: nil

  defp load_workspace_config(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{config: %{} = config}} -> config
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Real-work repo resolution (bd-1ziw04): when start_claude: true the dispatch
  # MUST bind a repo — a no-repo idle stub does nothing and looks dispatched.
  #
  # Contract (approach b):
  #   * Explicit repo that resolves in :repo_paths → proceed.
  #   * Explicit repo that does NOT resolve     → {:error, {:repo_not_found, repo}}.
  #   * No repo, exactly one repo in :repo_paths  → auto-select, update opts.
  #   * No repo, zero repos in :repo_paths        → {:error, :no_repo_configured}.
  #   * No repo, multiple repos in :repo_paths    → {:error, {:ambiguous_repo, repos}}.
  #
  # The check fires only for `start_claude: true` dispatches; a dry/manual dispatch
  # (no agent) is allowed to park without a repo.
  defp maybe_resolve_repo_for_real_work(%Issue{} = task, opts) do
    case Keyword.get(opts, :start_claude, false) do
      false -> {:ok, opts}
      true -> resolve_repo_for_dispatch(task, opts)
    end
  end

  defp resolve_repo_for_dispatch(%Issue{} = task, opts) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) and repo != "" ->
        case resolve_repo_path(task, repo) do
          nil -> {:error, {:repo_not_found, repo}}
          _path -> {:ok, opts}
        end

      _ ->
        case all_available_repos(task) do
          [] -> {:error, :no_repo_configured}
          [sole] -> {:ok, Keyword.put(opts, :repo, sole)}
          repos -> {:error, {:ambiguous_repo, repos}}
        end
    end
  end

  # Enumerate all repo names that have a resolvable path, drawn from:
  #   1. The task's workspace config `repo_paths` map (or legacy `rig_paths`).
  #   2. The global Application env `:repo_paths` map.
  # Both sources are combined, de-duplicated, and sorted.
  defp all_available_repos(%Issue{workspace_id: ws_id}) do
    ws_repos =
      case load_workspace_config(ws_id) do
        %{"repo_paths" => rp} when is_map(rp) ->
          Enum.flat_map(rp, fn {k, v} ->
            if repo_path_from_config(v) != nil, do: [k], else: []
          end)

        %{"rig_paths" => rp} when is_map(rp) ->
          Enum.flat_map(rp, fn {k, v} ->
            if repo_path_from_config(v) != nil, do: [k], else: []
          end)

        _ ->
          []
      end

    app_repos =
      :arbiter
      |> Application.get_env(:repo_paths, %{})
      |> Enum.flat_map(fn {k, v} ->
        if repo_path_from_config(v) != nil, do: [k], else: []
      end)

    (ws_repos ++ app_repos) |> Enum.uniq() |> Enum.sort()
  end

  # Pre-flight auth check (bd-awi4nw): before transitioning the task and
  # dispatching a (paid, autonomous) worker, verify the agent CLI can
  # authenticate with a single cheap probe. If it can't — the confirmed
  # OAuth-expiry case where every spawn 401s — REFUSE to dispatch, escalate to the
  # Admiral with a re-auth remediation, and abort before any task/worktree state
  # is mutated.
  #
  # Only runs on the real-agent path: skipped unless `start_claude: true`, and
  # skipped when a `:claude_command` test override is in play (no real CLI to
  # probe) unless the caller injects a `:probe_command`. Opt out entirely with
  # `preflight: false`.
  defp maybe_preflight(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :preflight, true) == false ->
        :ok

      not Keyword.get(opts, :start_claude, false) ->
        :ok

      Keyword.has_key?(opts, :claude_command) and not Keyword.has_key?(opts, :probe_command) ->
        :ok

      true ->
        run_preflight(task, opts)
    end
  end

  defp run_preflight(%Issue{} = task, opts) do
    workspace = load_workspace(task)
    :ok = Agents.prepare(workspace, :agent)
    adapter = preflight_adapter(task, workspace, opts)

    # bd-5wchp1: if the CredentialWatchdog already knows this adapter's creds are
    # expired, refuse immediately without re-running the expensive probe. The
    # guard is skipped when the watchdog isn't running (returns false by default).
    if Arbiter.Agents.CredentialWatchdog.expired?(adapter) do
      reason = known_expired_stop_reason()
      CoordinatorNotifier.preflight_failed(preflight_snapshot(task, opts), reason)
      {:error, {:auth_check_failed, reason}}
    else
      # Route the probe through the same quota-capturing proxy a real spawn
      # uses (bd-5boun6) so `claude --print ping` updates quota state too.
      probe_opts = preflight_opts(opts) ++ anthropic_proxy_opts(adapter, workspace)

      case Preflight.check(adapter, probe_opts) do
        :ok ->
          :ok

        :skipped ->
          :ok

        {:error, reason} ->
          CoordinatorNotifier.preflight_failed(preflight_snapshot(task, opts), reason)
          {:error, {:auth_check_failed, reason}}
      end
    end
  end

  defp known_expired_stop_reason do
    %StopReason{
      category: :auth_expired,
      summary: "credentials known-expired (CredentialWatchdog flagged expiry)",
      remediation:
        "Re-authenticate the agent CLI (Claude: `claude` login; Gemini: refresh GEMINI_API_KEY), " <>
          "then re-dispatch. Check `arb inbox` for the original expiry escalation.",
      exit_status: nil,
      signal: nil
    }
  end

  # Resolve the workspace's worker adapter so we probe the CLI that will
  # actually be slung. Resolution order:
  #   1. `:agent_adapter` test override — lets tests stub the adapter.
  #   2. `:agent_type` explicit override — probe the forced provider.
  #   3. Workspace default — `Agents.for_workspace` reads `agent.type`.
  defp preflight_adapter(_task, workspace, opts) do
    case Keyword.get(opts, :agent_adapter) do
      mod when is_atom(mod) and not is_nil(mod) ->
        mod

      _ ->
        case Keyword.get(opts, :agent_type) do
          type when is_atom(type) and not is_nil(type) -> Agents.for_type(type)
          _ -> Agents.for_workspace(workspace)
        end
    end
  end

  defp preflight_opts(opts) do
    opts
    |> Keyword.take([:probe_command, :probe_env, :timeout_ms, :api_key, :model, :model_tier])
  end

  defp preflight_snapshot(%Issue{id: id, workspace_id: ws_id}, opts) do
    %{
      task_id: id,
      workspace_id: ws_id,
      repo: Keyword.get(opts, :repo),
      meta: %{}
    }
  end

  # Spawn a Claude subprocess in the worktree, attached to the worker.
  #
  # **Opt-in only.** Defaults to `start_claude: false` so callers must
  # explicitly authorize the (paid, autonomous) agent invocation. The CLI
  # surfaces this via the `--with-claude` flag on `arb dispatch`.
  #
  # Requires a worktree (Layer 3) — returns `{:error, :missing_worktree}`
  # if start_claude is true but worktree_path is nil. This prevents
  # silently launching Claude with `cd: nil`.
  #
  # The `:claude_command` opt is the test escape hatch: when set, it
  # overrides the default streaming `claude` argv so tests can spawn `echo`
  # or a script instead of the real Claude CLI.
  defp maybe_start_claude(_task, _worker_pid, _worktree_path, opts)
       when not is_list(opts) do
    {:ok, nil}
  end

  defp maybe_start_claude(%Issue{} = task, worker_pid, worktree_path, opts) do
    case Keyword.get(opts, :start_claude, false) do
      false ->
        {:ok, nil}

      true ->
        # Review dispatches skip worktree provisioning but still need a real
        # cwd for the Claude port. Fall back to the repo's local checkout so
        # the reviewer has `git`/`gh`/etc. in scope; an unmapped repo with no
        # worktree is still rejected — there's nowhere to `cd` to.
        cwd = worktree_path || review_cwd(task, opts)

        case cwd do
          nil ->
            {:error, :missing_worktree}

          path when is_binary(path) ->
            # Inject the per-spawn MCP config (.mcp.json) into the *isolated*
            # worktree so the agent can read its task / mailbox and write
            # completion notes as typed tool calls. Best-effort: never blocks
            # the spawn.
            #
            # Pass `worktree_path`, NOT `path` (bd-dlv3no): a review dispatch has
            # no worktree, so `path` falls back to the repo's shared checkout
            # (`review_cwd/2`). Writing the token-bearing `.mcp.json` there leaks
            # it into the canonical checkout the live server + operator share —
            # the exact "worker leaks into the main worktree" class this fixes.
            # With a nil worktree the helper is a no-op, so reviews never touch
            # the repo's working tree.
            _ = maybe_write_mcp_config(task, worktree_path, opts)

            # Resolve the layered effective skill set and materialize ONLY it
            # into the isolated worktree (bd-d5hy7y). Threaded onto opts so the
            # work prompt can auto-invoke always-on skills and advertise
            # situational ones (DECISION C). No-op without a worktree (review /
            # task-type dispatch) — skills only ever land in an isolated tree.
            resolved_skills = resolve_skills(task, worktree_path, opts)
            _ = Arbiter.Skills.Materializer.materialize(worktree_path, resolved_skills)
            opts = Keyword.put(opts, :resolved_skills, resolved_skills)

            with {:ok, session_opts} <-
                   build_agent_session_opts(task, worker_pid, path, opts),
                 {:ok, port} <- ClaudeSession.start(session_opts) do
              # Move the worker out of :idle so UI/CLI report a meaningful
              # status while Claude works. In claude_driven mode the Driver
              # never ticks the Machine, so without this nudge the worker
              # would remain :idle until "arb done" flipped it to :completed.
              _ = Worker.advance(worker_pid, :claude)
              {:ok, port}
            else
              {:error, reason} -> {:error, {:claude_start_failed, reason}}
            end
        end
    end
  end

  # Resolve a sensible cwd for sessions that skip worktree provisioning:
  #   - review dispatches (`review: true`) — read-only code review, no branch
  #   - task-type issues — deliverable is notes, not a PR; safe on main checkout
  # Regular feature/bug/chore dispatches without a worktree still surface
  # `:missing_worktree` rather than silently running from the main checkout.
  defp review_cwd(%Issue{issue_type: :task} = task, opts) do
    resolve_repo_path(task, Keyword.get(opts, :repo))
  end

  defp review_cwd(%Issue{} = task, opts) do
    case Keyword.get(opts, :review, false) do
      true -> resolve_repo_path(task, Keyword.get(opts, :repo))
      _ -> nil
    end
  end

  # Resolve the agent for this task through the `Arbiter.Agents` dispatcher
  # and the configured `Arbiter.Agents.Routing` policy, then assemble the
  # `ClaudeSession.start/1` options. This is the seam where model-tiering
  # and key-rotation enter the spawn — both default off, so a workspace
  # that hasn't opted in sees today's argv + env unchanged.
  #
  # The `:claude_command` opt (used by tests to spawn an echo script
  # instead of the real Claude CLI) bypasses the adapter entirely — it's a
  # raw argv override and the routing policy has nothing to add.
  defp build_agent_session_opts(%Issue{} = task, worker_pid, worktree_path, opts) do
    base = [owner: worker_pid, worktree_path: worktree_path]

    case Keyword.get(opts, :claude_command) do
      cmd when is_list(cmd) ->
        {:ok, base ++ [command: cmd]}

      _ ->
        workspace = load_workspace(task)
        :ok = Agents.prepare(workspace, :agent)

        # Order matters: apply the provider (agent_type) override *first* so it
        # can strip the routed, provider-specific model, then let an explicit
        # `--model` override win on top of the resolved provider.
        choice =
          task
          |> Routing.choose(workspace, %{})
          |> apply_agent_type_override(Keyword.get(opts, :agent_type))
          |> apply_model_override(Keyword.get(opts, :model))

        adapter = Agents.for_type(choice.type)

        # Resolve the spawn's security posture from the workspace (per-domain),
        # with an optional per-dispatch override from dispatch opts and the
        # resolved repo name so a multi-repo workspace can scope a different
        # posture to this repo (bd-3gc18m). Threaded into the adapter so it
        # bakes the right permission-mode + deny/allow into the argv — no
        # inheritance of the operator's ~/.claude (bd-9u10op).
        policy =
          SecurityPolicy.resolve(workspace, security_override(opts), Keyword.get(opts, :repo))

        agent_opts =
          agent_opts_from_choice(choice) ++
            [security: policy] ++ anthropic_proxy_opts(adapter, workspace)

        tracker_context = fetch_tracker_context(task, workspace)

        prompt =
          opts
          |> Keyword.put(:worktree_path, worktree_path)
          |> Keyword.put(:tracker_context, tracker_context)
          |> then(&prompt_for_task(task, &1))

        provider = Atom.to_string(choice.type)

        # Concrete model the adapter will dispatch with, if it can name one ahead
        # of the stream (Gemini, whose CLI emits no `init` event). nil for Claude,
        # which learns the exact model from its stream-json `init` — we must NOT
        # thread the routed tier alias ("sonnet") onto a Claude session, or the
        # ledger would record the alias when the stream is the source of truth.
        session_model = resolved_model_for(adapter, agent_opts)

        routing_config = %{
          provider: provider,
          # For live display the routed model is a fine pre-stream stand-in.
          model: session_model || Keyword.get(agent_opts, :model),
          model_tier: Keyword.get(agent_opts, :model_tier),
          thinking: Keyword.get(agent_opts, :thinking)
        }

        Worker.report(worker_pid, :routing_config, routing_config)

        # Stamp the resolved model onto the worker's meta at dispatch time so
        # worker_list can show the model before any session output lands.
        if model = Map.get(routing_config, :model) do
          Worker.report(worker_pid, :model, model)
        end

        case adapter.default_argv(prompt, agent_opts) do
          {:ok, argv} ->
            # Skill guard (bd-d5hy7y, spike findings): a worker carrying
            # materialized skills must not be spawned with `--bare` (skips skill
            # discovery) or `--disable-slash-commands` (blocks `/name`
            # invocation), or the skills silently do nothing. We never add these
            # flags — this catches a future regression loudly rather than
            # shipping dead skills.
            _ = guard_skill_flags(argv, Keyword.get(opts, :resolved_skills, []))

            env = safe_spawn_env(adapter, agent_opts)
            # Thread provider (+ pre-resolved model, when the adapter has one)
            # onto the session so the usage ledger and dashboards attribute the
            # run correctly even when the CLI stream carries no model/provider
            # (bd-guegdl).
            session_meta = [provider: provider, model: session_model]
            {:ok, base ++ [command: argv, env: env] ++ session_meta}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Translate a Routing.Policy.choice() config map (JSON string-keyed) into
  # the keyword opts the Agent behaviour expects (`:model`, `:model_tier`,
  # `:thinking`, ...). Unknown keys are passed through under `:config` so
  # future adapters can read adapter-specific keys without growing this
  # function.
  defp agent_opts_from_choice(%{config: config}) when is_map(config) do
    [
      model: Map.get(config, "model"),
      model_tier: Map.get(config, "model_tier"),
      thinking: Map.get(config, "thinking"),
      config: config
    ]
  end

  # A `:model` opt on `Dispatch.dispatch/2` is a one-shot, per-dispatch override —
  # the task might be P2 (routing → sonnet) but the caller wants to try it
  # on Opus once. We splat the override on top of the routed config so it
  # wins over both the workspace default and any routing rule. A `nil` /
  # empty override is a no-op (the routed choice stands).
  defp apply_model_override(choice, override) when is_binary(override) and override != "" do
    %{choice | config: Map.put(choice.config || %{}, "model", override)}
  end

  defp apply_model_override(choice, _), do: choice

  # A `:agent_type` opt on `Dispatch.dispatch/2` is an explicit per-dispatch provider
  # override — the workspace may default to :claude but the caller wants :gemini
  # (or vice versa). Splatting the type onto the routed choice lets it win over
  # both the workspace default and any routing rule.
  #
  # When the override switches to a *different* provider than the one the
  # routing policy chose, the routed `"model"` is provider-specific (e.g. a
  # Claude `"sonnet"`) and meaningless to the new adapter, so we drop it — the
  # new adapter resolves its own default. The abstract `model_tier` / `thinking`
  # knobs are provider-agnostic and stay. An explicit `--model` override is
  # re-applied after this step (see build_agent_session_opts) and still wins.
  defp apply_agent_type_override(%{type: type} = choice, type), do: choice

  defp apply_agent_type_override(choice, type) when is_atom(type) and not is_nil(type) do
    config = Map.drop(choice.config || %{}, ["model"])
    %{choice | type: type, config: config}
  end

  defp apply_agent_type_override(choice, _), do: choice

  # Optional per-dispatch (per-task) security override. Accepts a raw map under
  # the `:security` dispatch opt (same shape as `workspace.config["agent"]["security"]`)
  # or the `:security_mode` shorthand for the common "just change the mode" case.
  # Returns `%{}` (no override) when neither is set.
  defp security_override(opts) do
    base =
      case Keyword.get(opts, :security) do
        %{} = map -> map
        _ -> %{}
      end

    case Keyword.get(opts, :security_mode) do
      mode when is_binary(mode) or (is_atom(mode) and not is_nil(mode)) ->
        Map.update(base, "permissions", %{"mode" => mode}, fn perms ->
          Map.put(perms, "mode", mode)
        end)

      _ ->
        base
    end
  end

  defp safe_spawn_env(adapter, agent_opts) do
    if function_exported?(adapter, :spawn_env, 1) do
      adapter.spawn_env(agent_opts)
    else
      []
    end
  end

  # Route Claude CLI traffic through the local quota-capturing proxy (bd-5boun6)
  # by exporting ANTHROPIC_BASE_URL with the workspace id baked into the path, so
  # captured rate-limit headers are attributed to this workspace. Claude-only —
  # Gemini ignores it — and a no-op when the proxy is disabled (e.g. test env).
  defp anthropic_proxy_opts(Arbiter.Agents.Claude, workspace) do
    if Arbiter.Quota.proxy_enabled?() do
      ws_id = workspace && workspace.id
      [anthropic_base_url: Arbiter.Quota.worker_base_url(ws_id)]
    else
      []
    end
  end

  defp anthropic_proxy_opts(_adapter, _workspace), do: []

  # The concrete model the adapter will dispatch with, if it can name one ahead
  # of the stream (optional `resolved_model/1` callback). Returns nil for
  # adapters that don't implement it (e.g. Claude, whose model arrives in the
  # stream-json `init` event) — the caller then falls back to the routed model.
  defp resolved_model_for(adapter, agent_opts) do
    if function_exported?(adapter, :resolved_model, 1) do
      adapter.resolved_model(agent_opts)
    end
  end

  # Write the per-spawn Arbiter.MCP config into the worktree (bd-dem49g). Mints a
  # narrow `:worker`-tier scope token bound to this task/repo/workspace and hands
  # it to the agent-specific config adapter (Phase 1: Claude `.mcp.json`). The
  # token *is* the worker's capability — it can only read/progress its own task.
  #
  # Gated by `Arbiter.MCP.inject_config?/0` (off in test by default) and fully
  # best-effort: a missing signing secret or write failure is logged and swallowed
  # so MCP config never blocks a dispatch.
  # No isolated worktree (e.g. a review dispatch running in the repo's shared
  # checkout) → never write the token-bearing `.mcp.json`. Injecting it into the
  # canonical checkout would leak the scope token into the working tree the live
  # server and operator share (bd-dlv3no).
  defp maybe_write_mcp_config(_task, nil, _opts), do: :ok

  defp maybe_write_mcp_config(%Issue{} = task, worktree_path, opts)
       when is_binary(worktree_path) do
    if Arbiter.MCP.inject_config?() do
      # `:depth` carries the dispatch-recursion depth (Phase 2 guardrail): a worker
      # slung *by a coordinator* via `worker_dispatch` is minted one level deeper, so
      # a chain of dispatches is tracked. Defaults to 0 for a plain operator dispatch.
      token =
        Arbiter.MCP.Scope.mint_worker(task, Keyword.get(opts, :repo),
          depth: Keyword.get(opts, :depth, 0)
        )

      provider = resolve_mcp_provider(task, opts)

      write_opts = [
        mcp_url: Arbiter.MCP.server_url(),
        scope_token: token,
        server_name: Arbiter.MCP.server_name()
      ]

      result = Arbiter.MCP.AgentConfig.write(provider, worktree_path, write_opts)
      _ = maybe_verify_codex_mcp_connection(task, provider, result, write_opts)
      result
    else
      :ok
    end
  rescue
    e ->
      require Logger
      Logger.warning("Arbiter.Worker.Dispatch: MCP config injection failed: #{inspect(e)}")
      :ok
  end

  # Codex MCP support has reports of *silent* connect failures (its own
  # moduledoc: `Arbiter.MCP.AgentConfig.Codex`) — the process starts, the config
  # file is on disk, but the session never actually reaches Arbiter's MCP
  # server, e.g. because the wrong bearer token landed in `.codex/config.toml`.
  # Fire the module's own `verify_connection/1` off the dispatch path right
  # after a successful write so that failure surfaces as a loud log line
  # immediately, instead of only showing up later as a credential-watchdog
  # false positive that requires live debugging to explain (bd-bi5t54).
  defp maybe_verify_codex_mcp_connection(%Issue{id: task_id}, :codex, :ok, write_opts) do
    Task.Supervisor.start_child(Arbiter.Worker.MCPVerifySupervisor, fn ->
      require Logger

      case Arbiter.MCP.AgentConfig.Codex.verify_connection(write_opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Arbiter.Worker.Dispatch: Codex MCP connect check failed for task=#{task_id}: " <>
              inspect(reason) <>
              " — .codex/config.toml was written but the session may never reach Arbiter's MCP server"
          )
      end
    end)

    :ok
  end

  defp maybe_verify_codex_mcp_connection(_task, _provider, _write_result, _write_opts), do: :ok

  # Resolve the layered effective skill set for this dispatch (workspace → repo
  # → per-task, with opt-out and code-awareness — see `Arbiter.Skills.Selection`).
  # Only meaningful when an isolated worktree exists: skills materialize into
  # `.claude/skills/` in the worktree, so a nil worktree (review / task-type
  # dispatch) resolves to the empty set. Best-effort — a resolver error must
  # never block a dispatch, so we log and fall back to no skills.
  defp resolve_skills(_task, nil, _opts), do: []

  defp resolve_skills(%Issue{} = task, worktree_path, opts) when is_binary(worktree_path) do
    Arbiter.Skills.Selection.resolve(
      task: task,
      workspace: load_workspace(task),
      repo: Keyword.get(opts, :repo)
    )
  rescue
    e ->
      require Logger
      Logger.warning("Arbiter.Worker.Dispatch: skill resolution failed: #{inspect(e)}")
      []
  end

  @skill_blocking_flags ~w(--bare --disable-slash-commands)

  # Warn loudly if a skill-bearing spawn's argv carries a flag that would make
  # the materialized skills inert (`--bare` skips skill discovery;
  # `--disable-slash-commands` blocks `/name` invocation — spike findings). We
  # never add these flags; this catches a future regression rather than blocking
  # the dispatch, since a warning beats a wedged worker.
  defp guard_skill_flags(_argv, []), do: :ok

  defp guard_skill_flags(argv, _resolved) when is_list(argv) do
    case Enum.filter(@skill_blocking_flags, &(&1 in argv)) do
      [] ->
        :ok

      offending ->
        require Logger

        Logger.warning(
          "Arbiter.Worker.Dispatch: dispatching a skill-bearing worker with " <>
            "#{Enum.join(offending, ", ")} — materialized skills will not be " <>
            "discovered/invocable. This should never happen; check argv assembly."
        )
    end
  end

  defp guard_skill_flags(_argv, _resolved), do: :ok

  # Resolve which agent-config adapter to inject (.mcp.json vs .gemini/settings.json
  # vs .codex/config.toml). Resolution mirrors `preflight_adapter/3` so a dispatch that
  # forces a provider (`--provider gemini` / `agent_type: :gemini`) writes *that*
  # provider's config rather than the workspace default:
  #   1. `:agent_adapter` test override.
  #   2. `:agent_type` explicit provider override.
  #   3. Workspace default via `Agents.for_workspace`.
  # Falls back to :claude on any error so a misconfigured workspace never blocks a
  # dispatch — but logs the real exception first (bd-bi5t54): a bare `rescue _ ->
  # :claude` here previously swallowed whatever actually raised, so an explicit
  # `agent_type: :codex` dispatch that hit this clause would silently write
  # Claude's `.mcp.json` into the worktree with zero signal as to why, and Codex
  # would then 401 on its MCP handshake with nothing pointing back here.
  defp resolve_mcp_provider(%Issue{} = task, opts) do
    adapter =
      case Keyword.get(opts, :agent_adapter) do
        mod when is_atom(mod) and not is_nil(mod) ->
          mod

        _ ->
          case Keyword.get(opts, :agent_type) do
            type when is_atom(type) and not is_nil(type) -> Agents.for_type(type)
            _ -> Agents.for_workspace(load_workspace(task))
          end
      end

    String.to_existing_atom(adapter.provider())
  rescue
    e ->
      require Logger

      Logger.error(
        "Arbiter.Worker.Dispatch: resolve_mcp_provider fell back to :claude for task=#{task.id} " <>
          "(opts agent_type=#{inspect(Keyword.get(opts, :agent_type))}): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      :claude
  end

  defp load_workspace(%Issue{workspace_id: nil}), do: nil

  defp load_workspace(%Issue{workspace_id: ws_id}) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  def prompt_for(%Issue{} = task), do: prompt_for_task(task, [])

  @doc false
  def prompt_for_task(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :review, false) == true -> review_prompt(task, opts)
      task.issue_type == :task -> task_prompt(task)
      true -> work_prompt(task, opts)
    end
  end

  @doc """
  Briefing for a **conflict-resolve** acolyte (#354, Phase 2b).

  The Watchdog (`Arbiter.Worker.Watchdog`) dispatches a short-lived acolyte
  against the task's existing worktree when an *approved* PR is blocked as
  `:conflict` — mergeable in isolation but no longer applying cleanly on top of
  the current base. The acolyte's job is narrow: rebase the branch onto the
  current base, resolve the conflicts **honoring the task's original intent**,
  fix anything the rebase broke, and force-push so the Watchdog's next poll can
  re-attempt the merge.

  The original intent (title / description / acceptance) is embedded so a
  semantic conflict is resolved the way the task *meant*, not guessed. This
  supersedes and hardens the narrower #122 auto-conflict-resolver prompt: it
  adds the intent context and an explicit "run the tests, fix what the rebase
  broke" step the old mechanical-only prompt lacked.
  """
  @spec conflict_resolve_briefing(Issue.t(), String.t(), String.t()) :: String.t()
  def conflict_resolve_briefing(%Issue{} = task, branch, target_branch)
      when is_binary(branch) and is_binary(target_branch) do
    """
    You are a conflict-resolution worker for task #{task.id}.

    Your branch (#{branch}) is APPROVED but CONFLICTS with the current head of
    #{target_branch}: it was mergeable in isolation, but the base has moved and
    it no longer applies cleanly. Your ONLY job is to rebase it onto the current
    base, resolve the conflicts, and force-push — NOT to re-implement the change
    or open a new PR.

    ## Original intent — resolve conflicts so the result still satisfies THIS

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}

    ## Steps

      1. Fetch the latest base: `git fetch origin #{target_branch}`
      2. Rebase your branch onto it: `git rebase origin/#{target_branch}`
      3. Resolve every conflict so the result still honors the intent above.
         Most collisions are parallel edits to non-overlapping sections — keep
         both sides. Where two changes touch the same logic, keep the behaviour
         the acceptance criteria describe, then `git rebase --continue`.
      4. Run the test suite and fix anything the rebase broke — a clean rebase
         that fails tests is NOT done. Re-run until green.
      5. Force-push with lease to update the existing PR in place:
         `git push --force-with-lease origin #{branch}`
      6. Print `arb done` on a line by itself.

    DO NOT:
      * re-implement the change set or open a new PR,
      * touch files unrelated to the conflict,
      * abandon the rebase silently (`git rebase --abort` then exit).

    If a conflict is SEMANTIC — two changes both rewrote the same predicate or
    invariant such that no mechanical merge can honor both — STOP and escalate:

        arb message admiral "Conflict on #{task.id} needs human review: <one-line why>"

    then print `arb done`. A loud escalation beats a silent miscompile in
    #{target_branch}.
    """
  end

  # When resuming (bd-auma3z) the work prompt is prefixed with a git-derived
  # briefing of the prior worker's committed + uncommitted work, so the fresh
  # agent continues from the preserved worktree instead of redoing finished
  # steps. `:resume_context` is built by `Arbiter.Worker.ResumeContext`; it's
  # absent (empty prefix) on a normal fresh dispatch.
  defp work_prompt(%Issue{} = task, opts) do
    resume_prefix = Keyword.get(opts, :resume_context) || ""
    resume_prefix <> base_work_prompt(task, opts)
  end

  # The resolved-skills advertisement block (DECISION C): always-on skills get
  # an imperative `/name` directive, situational skills are listed as available.
  # Empty string when no skills resolved (the common case today).
  defp skills_section(opts) do
    Arbiter.Skills.Materializer.prompt_section(Keyword.get(opts, :resolved_skills, []))
  end

  defp base_work_prompt(%Issue{} = task, opts) do
    worktree_path = Keyword.get(opts, :worktree_path)

    isolation_section =
      if worktree_path do
        """

        FILESYSTEM ISOLATION — Your worktree is at:

            #{worktree_path}

        You MUST only write files inside this directory. Do NOT use absolute
        paths that point outside it — especially not to the main repo checkout
        (e.g. /home/ryan/dev/arbiter/...). Writing to the main repo corrupts
        Phoenix hot-reload and cascades to kill every other running worker.
        Always use relative paths or paths rooted at #{worktree_path}.
        """
      else
        ""
      end

    """
    You are a worker working autonomously on task #{task.id}.

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}
    #{prior_review_findings_section(task)}
    Your current directory is a fresh git worktree on a per-task branch.
    #{isolation_section}#{skills_section(opts)}
    Work the task to completion: load context, design, implement, test,
    commit on this branch, and push it.

    Do NOT open a pull request yourself (no `gh pr create` / `glab mr
    create`). The MergeQueue opens the single canonical PR for this task, on
    the correct base branch, using the body you author in the next step.
    Opening your own PR creates a duplicate on the wrong base.
    #{pr_review_instruction(task)}#{pr_body_step(task)}#{completion_notes_step(task)}
    Coordination: at the start of each step, check your mailbox by running

        arb inbox #{task.id}

    This shows any direction from the Admiral or flags from sibling workers
    (e.g. an upstream API shape changed) and marks them read. To leave a flag
    for another worker, use `arb message <their-task-id> <text>`.

    Between major steps, also check for `.arbiter/INBOX` in your working
    directory using `[ -f .arbiter/INBOX ] && cat .arbiter/INBOX` (this does
    NOT error when the file is absent — the normal case). If it exists, read
    it, act on any Admiral instructions it contains, then delete the file to
    acknowledge receipt. Treat it as a real-time message from the Admiral — it
    takes precedence over your current task if it redirects you.

    CRITICAL — continuation discipline: NEVER end a response with only a plan
    or a statement of the next step (for example, announcing that you will now
    write a test instead of writing it). After ANY check (mailbox /
    `.arbiter/INBOX` / git status), immediately continue with the next
    concrete tool call in the same turn. Your session is non-interactive: a
    turn that contains no tool call ENDS the session. The only correct way to
    finish is to print `arb done` once the work is complete — if you are about
    to stop without having printed `arb done`, keep working.

    *** ASYNC TOOLS: You may run tests, linters, compilers, or any diagnostic
    tool — including in parallel or with background execution modes. However,
    you MUST wait for every background task to complete and read its full
    output before printing `arb done`. Do not signal done while any background
    task is still running — the work is incomplete until every tool you launched
    has finished and you have read its result.

    When you are completely done, print the line:

        arb done

    on a line by itself, exactly. The worker watches your stdout and
    will mark the task complete when it sees that marker.
    """
  end

  # bd-5lc99r: briefing for a `task` issue type — non-reviewable ops/research/
  # spike work. The deliverable is a findings/results summary written to the
  # directive's `notes` field via the `task_update_progress` MCP tool, NOT a code
  # change, commit, or PR. The notes gate (Arbiter.Worker) blocks `arb done`
  # until `notes` is non-blank, so this prompt frames the whole job around
  # producing those findings and deliberately omits the commit/push/PR-body
  # steps the standard work prompt carries.
  defp task_prompt(%Issue{} = task) do
    """
    You are a worker working autonomously on task #{task.id}.

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}

    This is a `task`-type directive: non-reviewable ops / research / spike work.
    It produces NO code change, NO commit, and NO pull request. Your deliverable
    is a findings / results summary written to the directive's `notes` field.

    No worktree is provisioned by default — you are not expected to edit a repo.
    If the work genuinely requires inspecting code you may read files, but do not
    author a branch or open a PR.

    Your job:
      1. Do the investigation / ops work the directive describes.
      2. Write your findings to the directive's `notes` field by calling the
         `task_update_progress` MCP tool with its `notes` argument (Markdown is
         fine). Make it self-contained: what you investigated, what you found,
         and any recommendation or conclusion the Admiral needs — they read it
         via `arb show #{task.id}` and the dashboard.

    A notes gate enforces this: if you print `arb done` while `notes` is still
    blank, you will be reprompted to write your findings before the directive
    can close. Do NOT shell out to the `arb` CLI for the notes — use the
    `task_update_progress` MCP tool.
    #{completion_notes_step(task)}
    Coordination: at the start of each step, check your mailbox by running

        arb inbox #{task.id}

    This shows any direction from the Admiral or flags from sibling workers and
    marks them read. To leave a flag for another worker, use
    `arb message <their-task-id> <text>`.

    Between major steps, also check for `.arbiter/INBOX` in your working
    directory. If it exists, read it, act on any Admiral instructions it
    contains, then delete the file to acknowledge receipt.

    *** ASYNC TOOLS: You may run any diagnostic tool — including in parallel or
    with background execution modes. However, you MUST wait for every background
    task to complete and read its full output before printing `arb done`.

    When you are completely done — findings written to `notes` — print the line:

        arb done

    on a line by itself, exactly. The worker watches your stdout and will mark
    the task complete when it sees that marker.
    """
  end

  # The worker authors the PR/MR body and persists it on the task; the
  # MergeQueue (not the worker) opens the one canonical PR with it (bd-53xrmi).
  # Authoring it *after* implementing is what makes it worker-quality — the
  # Test plan reflects what actually passed, not what the spec hoped for. If
  # the repo ships a PR template we fill it rather than discard it (GitHub
  # injects the bare template only when the body is empty — the empty-body
  # incident #3606). Persisted via the `task_update_progress` MCP tool
  # (`pr_body` field), which the MergeQueue reads back as `pr_body`. We use the
  # MCP tool rather than the `arb` escript so completion never depends on
  # `~/.local/bin/arb` being present (it is transiently deleted by test runs).
  defp pr_body_step(%Issue{id: id}) do
    """

    Author the PR description and persist it on the task — the MergeQueue opens
    the PR with this exact body, so write it as the PR writeup, not a restatement
    of the ticket. Do this AFTER the work is implemented and tested, so it
    reflects what actually changed:

      * **Summary** — what changed and why, in a few sentences.
      * **Test plan** — the checks you ran, with checked boxes for what passed.
      * **References** — the task id (#{id}) and any linked ticket/PRs.

    If the repo has a PR template (`.github/pull_request_template.md`), FILL it
    rather than discard it. Persist the finished body verbatim by calling the
    `task_update_progress` MCP tool with its `pr_body` argument set to the full
    PR body (Markdown). Use the MCP tool, which is available in this session —
    do NOT shell out to the `arb` CLI for this.

    Do this before printing `arb done`.
    """
  end

  # When a prior review_gate pass escalated with REQUEST_CHANGES, the reviewer's
  # findings are stored in task.notes by record_review_gate_outcome/3 in Worker.
  # Surface them here so the re-slunged worker sees them immediately in its
  # prompt without having to call task_show or gh pr view first.
  defp prior_review_findings_section(%Issue{notes: notes})
       when is_binary(notes) and notes != "" do
    """

    Prior review findings (address these before starting new work):
    #{notes}
    """
  end

  defp prior_review_findings_section(_task), do: ""

  # When a PR is already open for this task, the re-slunged worker must read
  # the PR review comments to find what changed. The findings in task.notes
  # (above) are the primary source, but the PR reviews are the canonical record
  # — fetching them explicitly guards against notes being stale or missing.
  defp pr_review_instruction(%Issue{pr_ref: pr_ref})
       when is_binary(pr_ref) and pr_ref != "" do
    """

    This task has an existing PR (##{pr_ref}). Read the PR review comments
    before starting work — the review findings are there:

        gh pr view #{pr_ref} --json reviews,reviewComments

    Address every finding (fix the code or rebut with justification), then
    push commits to the existing branch. Do NOT open a new PR.
    """
  end

  defp pr_review_instruction(_task), do: ""

  # For tracker-backed tasks (an upstream Jira/etc. ticket), completing the
  # work includes producing the gated completion notes the tracker requires
  # before it will transition the ticket forward. We make this an explicit,
  # non-optional step in the worker's prompt and tell it exactly how to
  # persist the notes on the task (the `task_update_progress` MCP tool), so the
  # downstream tracker-sync has the fields to push. We use the MCP tool rather
  # than the `arb` escript so completion never depends on `~/.local/bin/arb`
  # being present (it is transiently deleted by test runs — bd-53xrmi). Untracked
  # tasks get nothing extra.
  defp completion_notes_step(%Issue{tracker_type: :none}), do: ""

  defp completion_notes_step(%Issue{tracker_ref: ref}) when ref in [nil, ""], do: ""

  defp completion_notes_step(%Issue{} = issue) do
    adapter = Trackers.for_task(issue)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :gating_fields, 2) do
      """

      This task is backed by an external tracker ticket. Before you finish, you
      MUST produce its completion notes and persist them on the task — the
      tracker gates the ticket's forward transition until both are filled. Call
      the `task_update_progress` MCP tool (available in this session) with these
      arguments:

        * `qa_notes` — What QA should verify: the user-facing behaviour to
          exercise, edge cases, and how to confirm the fix.
        * `deployment_notes` — Rollout considerations: DB migrations, feature
          flags, config/env changes, ordering, and any backout steps. Write
          'None' only if there genuinely are none.

      Use the MCP tool — do NOT shell out to the `arb` CLI for this. Base the
      notes on the change you actually made. This is part of "done": do it before
      printing `arb done`.
      """
    else
      ""
    end
  end

  defp review_prompt(%Issue{} = task, opts) do
    tracker_line =
      case task.pr_ref do
        pr when is_binary(pr) and pr != "" ->
          "Tracker ref (PR/MR to review): #{task.tracker_type}:#{pr}\n\n"

        _ ->
          case task.tracker_ref do
            ref when is_binary(ref) and ref != "" ->
              "Tracker ref (PR/MR to review): #{task.tracker_type}:#{ref}\n\n"

            _ ->
              ""
          end
      end

    tracker_context_section =
      case Keyword.get(opts, :tracker_context) do
        %{ref: ref, type: type, title: title, description: desc}
        when is_binary(ref) and ref != "" ->
          context_body =
            [title && "Title: #{title}", desc] |> Enum.filter(& &1) |> Enum.join("\n\n")

          """

          --- Tracker context (read-only, #{type}:#{ref}) ---
          #{context_body}
          --- End tracker context ---

          """

        _ ->
          ""
      end

    """
    You are a reviewer worker. Review the pull/merge request linked to task
    #{task.id} and post a verdict. You are not the author; do not modify the
    branch.

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}
    #{tracker_context_section}
    #{tracker_line}Your current directory is the repo's local checkout. There is
    no per-task branch and no worktree was provisioned — this is a review-only
    directive.

    Steps:
      1. Read the PR/MR diff via the configured tracker's CLI (`gh pr diff
         <ref>` for GitHub, `glab mr diff <ref>` for GitLab, `git diff` for
         the Direct local strategy). Do not check out the branch.
      2. Identify real correctness, security, or contract issues against the
         task's intent. Skip style nits.
      3. Post inline comments for each finding through the same tracker CLI.
      4. Post a single review-level verdict — `approve` or `request_changes`
         — with a one-paragraph summary.

    Forbidden:
      * Do NOT push code.
      * Do NOT merge or close the PR/MR.
      * Do NOT modify any branch, including the PR's head.

    *** ASYNC TOOLS: You may run tests, linters, or any diagnostic tool —
    including in parallel or with background execution modes. However, you
    MUST wait for every background task to complete and read its full output
    before printing `arb done`. Do not signal done while any background task
    is still running.

    After you post the review to the tracker, print your conclusion on its
    own line, EXACTLY one of:

        VERDICT: APPROVE
        VERDICT: REQUEST_CHANGES

    Then print, on a line by itself:

        arb done
    """
  end

  # Fetch acceptance-criteria context from a tracker issue referenced by
  # `tracker_context_type` + `tracker_context_ref` on the task. Read-only:
  # no assignment check, no write-back, no claim. Returns a map with
  # `:ref`, `:type`, `:title`, `:description` on success, or `nil` when the
  # task has no context ref or the fetch fails (failures are logged and
  # swallowed — context is best-effort).
  defp fetch_tracker_context(
         %Issue{tracker_context_type: type, tracker_context_ref: ref} = _task,
         workspace
       )
       when type not in [nil, :none] and is_binary(ref) and ref != "" do
    adapter = Trackers.for_type(type)

    Trackers.with_workspace(type, workspace, fn ->
      case adapter.fetch(ref) do
        {:ok, raw} ->
          %{
            ref: ref,
            type: type,
            title: adapter.extract_title(raw),
            description: adapter.extract_description(raw)
          }

        {:error, reason} ->
          require Logger

          Logger.warning(
            "Dispatch: failed to fetch tracker context #{type}:#{ref}: #{inspect(reason)}"
          )

          nil
      end
    end)
  rescue
    e ->
      require Logger
      Logger.warning("Dispatch: error fetching tracker context: #{Exception.message(e)}")
      nil
  end

  defp fetch_tracker_context(_task, _workspace), do: nil

  defp maybe_start_driver(
         %Issue{id: id},
         worker_pid,
         machine_id,
         machine_pid,
         worktree_path,
         opts
       ) do
    case Keyword.get(opts, :start_driver, true) do
      false ->
        {:ok, nil}

      true ->
        # When Claude is in charge of doing the real work, the Driver
        # waits on the worker's completion instead of ticking the
        # bookkeeping Machine to closure. This avoids the race where the
        # no-op workflow's 5 steps finish in ~500ms and close the task
        # before Claude has time to respond.
        claude_driven =
          Keyword.get(opts, :claude_driven, Keyword.get(opts, :start_claude, false))

        driver_opts =
          [
            task_id: id,
            worker_pid: worker_pid,
            machine_id: machine_id,
            machine_pid: machine_pid,
            worktree_path: worktree_path,
            cleanup_worktree: Keyword.get(opts, :cleanup_worktree, true),
            claude_driven: claude_driven
          ]
          |> maybe_put_opt(opts, :interval_ms)
          |> maybe_put_opt(opts, :max_ticks)

        case Driver.start(driver_opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, reason} -> {:error, {:driver_start_failed, reason}}
        end
    end
  end

  defp maybe_put_opt(driver_opts, dispatch_opts, key) do
    case Keyword.fetch(dispatch_opts, key) do
      {:ok, val} -> Keyword.put(driver_opts, key, val)
      :error -> driver_opts
    end
  end
end
