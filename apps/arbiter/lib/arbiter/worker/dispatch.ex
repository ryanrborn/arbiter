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
  alias Arbiter.Mergers.Github.RepoResolver
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
  alias Arbiter.Worker.ReviewVerification
  alias Arbiter.Worker.RunProvenance
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
         :ok <- ensure_migrations_up_to_date(),
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
  # `StopReason` and escalate to the coordinator, mirroring the
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
         # window between that guard and `start_worker/3`, flipping the task to
         # `:closed` AFTER the guard passed but as/just before the new worker is
         # attached — leaving a live worker orphaned on a `:closed` task (the
         # close's own StopWorker found no worker to stop). Re-assert here, now
         # that the worker is live, and realign a raced-closed task.
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
  # StopReason and raise a coordinator escalation, so the caller's error return
  # is never the *only* signal — the task is not left silently stranded.
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
  prepended to the standard work prompt (coordinator sign-off 2026-06-05, approach
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
  `{:error, {:worker_active, status}}`, `{:error, :repo_unknown}`.
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
  `{:error, :no_session}`, `{:error, {:worker_active, status}}`,
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

  @doc """
  Operator-facing explanation for an `{:error, {:worker_active, status}}`
  refusal. Single source of truth for the MCP tool and the HTTP API.

  bd-8lq2g7: the two review-park statuses need their own wording. The generic
  "stop it before resuming" is sound advice for a worker that is genuinely
  mid-run, but destructive for a parked one: `:awaiting_review_gate` means the
  ReviewGate is judging the diff right now, and `:awaiting_review` means the
  MR/PR is open and the Watchdog is polling it. Stopping either discards that
  in-flight outcome, and the re-dispatch re-runs the review gate from round 1.
  A parked worker is nearly always parked *correctly* — the thing that actually
  failed was some other pass running alongside it (see `Arbiter.Worker.subordinate?/1`).
  """
  @spec worker_active_message(atom(), String.t()) :: String.t()
  def worker_active_message(:awaiting_review_gate, task_id) do
    "#{task_id}'s worker is parked at awaiting_review_gate — the review gate is " <>
      "judging its diff right now. It is not stalled and must not be stopped: " <>
      "stopping it discards the review in flight and the next dispatch restarts " <>
      "the gate from round 1. Wait for the verdict, or check `arb worker list` for " <>
      "a subordinate pass (`#{task_id}:fixpass` / `:conflict`) if something else failed."
  end

  def worker_active_message(:awaiting_review, task_id) do
    "#{task_id}'s worker is parked at awaiting_review — its MR/PR is open and the " <>
      "watchdog is polling it to completion. It is not stalled and must not be " <>
      "stopped: stopping it drops the watchdog and the next dispatch re-runs the " <>
      "whole review gate. Check the PR, or check `arb worker list` for a subordinate " <>
      "pass (`#{task_id}:fixpass` / `:conflict`) if something else failed."
  end

  def worker_active_message(status, _task_id),
    do: "a worker is still active for this task (#{status}); stop it before resuming"

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
          status -> {:error, {:worker_active, status}}
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
  # it to exist on disk AND be on a branch. A missing worktree — or a detached one
  # — means there's nothing to resume.
  #
  # The detached check matters because `ResumeContext.build/3` renders whatever it
  # finds there as "the commits the prior worker made … DO NOT start over"
  # (bd-9r1tta). A detached checkout holds no prior work at all: its `<base>..HEAD`
  # diff is the *upstream* commits it was cut from (the local `<base>` ref being
  # the parent repo's, possibly stale, one), which the briefing would then present
  # to a fresh agent as its predecessor's output. Refuse the resume instead,
  # exactly as `arb resume` did before a task-type dispatch had any checkout.
  #
  # Only detached is rejected, not "any branch other than the derived one": a
  # worktree on some other branch still has commits that plausibly *are* the prior
  # worker's, and refusing there would throw away a resumable run.
  defp resume_worktree(%Issue{} = task, repo) do
    case resolve_repo_path(task, repo) do
      repo_path when is_binary(repo_path) ->
        path = Worktree.worktree_path(BranchNamer.derive(task))

        cond do
          not File.dir?(path) -> {:error, :no_outpost}
          Worktree.detached?(path) == {:ok, true} -> {:error, :no_outpost}
          true -> {:ok, path}
        end

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
  # just been attached to `task_id`, guarantee the task is not `:closed`. A close
  # can land asynchronously between `ensure_not_closed/1` (checked once, at the
  # front of `dispatch/2`) and `start_worker/3` — e.g. the MergeQueue's
  # direct-strategy close of an in-flight `{:worker_done}` from the run the
  # operator just stopped. Because that close's `StopWorker` after-action fires
  # when no worker is registered yet (the old one torn down, the new one not
  # started), the freshly-started worker would otherwise be orphaned on a
  # `:closed` task — the 2026-07-08 lt-c9td4r failure.
  #
  # When the task raced to `:closed` and the worker is still alive, atomically
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

  defp ensure_migrations_up_to_date do
    migrations_module = Application.get_env(:arbiter, :migrations_module, Arbiter.Migrations)

    case migrations_module.count_pending() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        {:error, {:pending_migrations, count}}

      {:error, reason} ->
        # Block on migration check failure (unreachable DB, invalid shape, etc).
        # This prevents the same silent failure mode as bd-44gk10, where pending
        # migrations were not detected and workers silently 503'd. Failing closed
        # on unknown is a safer default than failing open.
        {:error, {:migrations_check_failed, reason}}
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
  # The gate is provider-aware (bd-2mpo3f): it consults the quota snapshot of the
  # provider this dispatch will ACTUALLY run on — `AnthropicQuota` for Claude,
  # `CodexQuota` for Codex, `GoogleQuota` for Gemini CLI / Antigravity — so an
  # out-of-quota Codex or Gemini dispatch is held exactly like an out-of-quota
  # Anthropic one instead of being spawned into a rate-limited CLI.
  #
  # Fail-open guards: skipped on the drain re-dispatch (`skip_quota_gate: true`),
  # for a task with no workspace, and — for Claude only — when the Anthropic
  # proxy is disabled, since that proxy is the sole source of `AnthropicQuota`
  # rows (e.g. in test). Codex/Google snapshots come from `Quota.CloudProbe`, not
  # the proxy, so their gating does not depend on that flag. A nil snapshot is
  # handled inside each gate impl.
  defp maybe_quota_gate(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :skip_quota_gate, false) == true -> :ok
      not is_binary(task.workspace_id) -> :ok
      true -> run_quota_gate(task, opts)
    end
  end

  defp run_quota_gate(%Issue{workspace_id: ws_id} = task, opts) do
    workspace = load_workspace(task)
    provider = quota_gate_provider(task, workspace, opts)

    if quota_gate_applies?(provider) do
      apply_quota_gate(task, workspace, provider, ws_id, opts)
    else
      :ok
    end
  rescue
    e ->
      # A bug in the gate must never wedge dispatch — fail open.
      require Logger
      Logger.warning("Dispatch: quota gate crashed for #{task.id}: #{Exception.message(e)}")
      :ok
  end

  # Claude's snapshot only exists when the local Anthropic proxy is capturing
  # headers; every other provider is fed by the periodic CloudProbe.
  defp quota_gate_applies?(:claude), do: Arbiter.Quota.proxy_enabled?()
  defp quota_gate_applies?(_provider), do: true

  # Which provider this dispatch will run on. Mirrors `start_agent/4`'s
  # resolution order so the gate reads the same provider the worker is spawned
  # with: the `:agent_adapter` test seam, then an explicit `:agent_type`
  # override, then the workspace's routing policy. Falls back to :claude — the
  # historical (Anthropic-only) behaviour — if resolution raises.
  defp quota_gate_provider(%Issue{} = task, workspace, opts) do
    case Keyword.get(opts, :agent_adapter) do
      mod when is_atom(mod) and not is_nil(mod) ->
        String.to_existing_atom(mod.provider())

      _ ->
        case Keyword.get(opts, :agent_type) do
          type when is_atom(type) and not is_nil(type) -> type
          _ -> Routing.choose(task, workspace, %{}).type
        end
    end
  rescue
    _ -> :claude
  end

  defp apply_quota_gate(%Issue{} = task, workspace, provider, ws_id, opts) do
    gate = Arbiter.Quota.gate_for_workspace(workspace)
    quota = safe_quota_latest(ws_id, provider)

    case gate.check(task, quota, workspace, opts) do
      :allow ->
        :ok

      {:hold, reason} ->
        case Arbiter.Workflows.DispatchQueue.hold(ws_id, task.id, opts, reason, provider) do
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
  end

  defp safe_quota_latest(ws_id, provider) do
    Arbiter.Quota.latest_for_provider(ws_id, provider)
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

    # bd-dzz6ly: capture difficulty HERE, before the worker ever starts — not
    # read later off `issues.difficulty`, which can be edited after dispatch
    # (bd-7rspia was corrected D1 -> D2) and would then silently relabel this
    # run's provenance to the corrected estimate instead of the one it ran under.
    base = Map.put(base, :difficulty_at_dispatch, task.difficulty)

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
                cond do
                  String.contains?(msg, "already exists") ->
                    case Worktree.attach(repo_path, branch) do
                      {:ok, path} -> {:ok, path}
                      {:error, reason} -> {:error, {:worktree_failed, reason}}
                    end

                  String.contains?(msg, "different branch") ->
                    recover_from_detached_worktree(repo_path, branch, target_branch, msg)

                  true ->
                    {:error, {:worktree_failed, {:git_failed, msg}}}
                end

              {:error, reason} ->
                {:error, {:worktree_failed, reason}}
            end
        end
    end
  end

  # A branch dispatch found a *detached* worktree sitting at the branch leaf.
  # Since bd-9r1tta an inspect checkout uses its own leaf, so this only happens
  # for a task whose inspect tree predates that split — but the failure it caused
  # was permanent (`create/3` refuses, the `already exists` → `attach/2` recovery
  # doesn't match "different branch", and nothing else reclaims the directory), so
  # recover instead of stranding the dispatch. Safe by inspection: a detached tree
  # has no branch and therefore no commits only reachable from it.
  defp recover_from_detached_worktree(repo_path, branch, target_branch, msg) do
    require Logger

    path = Worktree.worktree_path(branch)

    case Worktree.detached?(path) do
      {:ok, true} ->
        Logger.info(
          "Dispatch: reclaiming detached inspect worktree at #{path} so branch " <>
            "#{branch} can be provisioned there"
        )

        _ = Worktree.cleanup(path)

        case Worktree.create(repo_path, branch, target_branch) do
          {:ok, path} -> {:ok, path}
          {:error, reason} -> {:error, {:worktree_failed, reason}}
        end

      _ ->
        {:error, {:worktree_failed, {:git_failed, msg}}}
    end
  end

  defp resolve_repo_path(_task, nil), do: nil

  defp resolve_repo_path(%Issue{workspace_id: ws_id}, repo) when is_binary(repo) do
    workspace_repo_path(ws_id, repo) || application_repo_path(repo) ||
      slug_repo_path(ws_id, repo)
  end

  # Reverse resolution (bd-49ajyt): PRPatrol/ReviewPatrol dispatch a follow-up
  # with the PR's GitHub `owner/repo` slug as the `:repo` opt, but a multi-repo
  # workspace's `repo_paths` map is keyed by *rig name* (e.g.
  # "client"), not by slug — so the direct + normalized key lookups above miss
  # (a rig name never normalizes to an `owner/repo` slug) and dispatch used to
  # fail `{:repo_not_found}`, spinning PRPatrol in a 1/min escalation loop.
  #
  # When the requested repo looks like an `owner/repo` slug that no key
  # matched, resolve it the same way `PRPatrolSupervisor` derives its patrol
  # repos: read each registered rig's `origin` remote and match its derived
  # slug. This only runs on the miss path (both direct lookups returned nil)
  # and only for slug-shaped repos, so a normal rig-name dispatch never pays
  # the git cost. Covers client↔verus-client, server↔verus_server, and the
  # other leotech rigs where rig name ≠ slug.
  defp slug_repo_path(_ws_id, repo) when not is_binary(repo), do: nil

  defp slug_repo_path(ws_id, repo) do
    if String.contains?(repo, "/") do
      target = RepoConfig.normalize_slug(repo)

      ws_id
      |> candidate_repo_paths()
      |> Enum.find_value(fn path ->
        case RepoResolver.from_remote(path) do
          {:ok, {owner, name}} ->
            if RepoConfig.normalize_slug("#{owner}/#{name}") == target, do: path

          _ ->
            nil
        end
      end)
    end
  end

  # All locally-checked-out rig paths registered for this workspace (config
  # `repo_paths`) plus the global Application `:repo_paths`, deduplicated.
  # The values are paths to git checkouts whose `origin` remote
  # `slug_repo_path/2` can resolve.
  defp candidate_repo_paths(ws_id) do
    ws_paths =
      case load_workspace_config(ws_id) do
        %{} = config ->
          config_repo_paths(get_in(config, ["repo_paths"]))

        _ ->
          []
      end

    app_paths =
      :arbiter
      |> Application.get_env(:repo_paths, %{})
      |> config_repo_paths()

    (ws_paths ++ app_paths) |> Enum.uniq()
  end

  defp config_repo_paths(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.map(&repo_path_from_config/1)
    |> Enum.reject(&is_nil/1)
  end

  defp config_repo_paths(_), do: []

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
        find_repo_path(get_in(config, ["repo_paths"]), repo)

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
  defp find_repo_path(map, repo), do: RepoConfig.find_path(map, repo)

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

  @doc """
  Enumerate all repo names this task could be dispatched against — every name
  that has a **resolvable** path, drawn from:

    1. The task's workspace config `repo_paths` map.
    2. The global Application env `:repo_paths` map.

  Both sources are combined, de-duplicated, and sorted. Entries whose
  configured path doesn't resolve (moved or deleted directory) are dropped, so
  a caller offering these as choices can't offer one that would later fail
  with `{:repo_not_found, repo}`.

  Public so the dashboard's dispatch modal can populate its repo select from
  the same list dispatch itself resolves against (bd-2cv4ws).
  """
  @spec all_available_repos(Issue.t()) :: [String.t()]
  def all_available_repos(%Issue{workspace_id: ws_id}) do
    ws_repos =
      case load_workspace_config(ws_id) do
        %{"repo_paths" => rp} when is_map(rp) ->
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
  # coordinator with a re-auth remediation, and abort before any task/worktree state
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
        # Dispatches that provision no branch worktree (task-type audits,
        # reviews) still need a real cwd for the agent port. `resolve_agent_cwd/3`
        # owns that fallback — and, since bd-9r1tta, owns making sure it isn't a
        # stale one.
        case resolve_agent_cwd(task, worktree_path, opts) do
          {:error, reason} ->
            {:error, reason}

          {:ok, path} when is_binary(path) ->
            # Inject the per-spawn MCP config (.mcp.json) into the *isolated*
            # worktree so the agent can read its task / mailbox and write
            # completion notes as typed tool calls. Best-effort: never blocks
            # the spawn.
            #
            # Pass `worktree_path`, NOT `path` (bd-dlv3no): a review dispatch has
            # no worktree, so `path` falls back to the repo's shared checkout
            # (`resolve_agent_cwd/3`). Writing the token-bearing `.mcp.json`
            # there leaks it into the canonical checkout the live server +
            # operator share — the exact "worker leaks into the main worktree"
            # class this fixes. With a nil worktree the helper is a no-op, so
            # reviews never touch the repo's working tree.
            #
            # bd-9r1tta note: a task-type dispatch's `path` is now an *isolated*
            # detached worktree, so injecting there would be safe. Left keyed to
            # `worktree_path` deliberately — enabling MCP tools for audit
            # dispatches is a behavior change beyond that fix's scope.
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

  # Resolve the agent's cwd.
  #
  # A provisioned worktree is already cut from `origin/<target>` by
  # `Worktree.create/3`, so it is current by construction — use it as-is.
  #
  # Without one there are two cases, and before bd-9r1tta both got the repo's
  # *shared* local checkout verbatim:
  #
  #   - task-type issues — ops/research/audit work whose deliverable is notes
  #   - review dispatches (`review: true`) — read-only code review, no branch
  #
  # On a developer host that shared checkout is a human contributor's working
  # directory. Nothing kept it current: the `tonic` checkout that produced this
  # bug was 72 commits and a full month behind `origin/main`, its HEAD predating
  # the very merge the audit was asked about. The audit read that tree, found no
  # encryption, and reported "PHI is stored in plaintext" as a release-gating
  # critical finding with file:line citations. Every word of it was true about a
  # month-old tree and false about the repo.
  #
  # So: a task-type dispatch now gets its own detached checkout at
  # `origin/<target>` (`Worktree.create_detached/3`), and a review dispatch — which
  # genuinely wants the shared checkout, since it diffs local branches — at least
  # gets its remote-tracking refs refreshed first. Neither path writes to the
  # contributor's HEAD, index, or working tree.
  #
  # Regular feature/bug/chore dispatches without a worktree still surface
  # `:missing_worktree` rather than silently running from the main checkout.
  @spec resolve_agent_cwd(Issue.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_agent_cwd(_task, worktree_path, _opts) when is_binary(worktree_path),
    do: {:ok, worktree_path}

  defp resolve_agent_cwd(%Issue{issue_type: :task} = task, _nil_worktree, opts) do
    case resolve_repo_path(task, Keyword.get(opts, :repo)) do
      nil ->
        {:error, :missing_worktree}

      repo_path when is_binary(repo_path) ->
        provision_inspect_worktree(task, repo_path, opts)
    end
  end

  defp resolve_agent_cwd(%Issue{} = task, _nil_worktree, opts) do
    with true <- Keyword.get(opts, :review, false),
         repo_path when is_binary(repo_path) <-
           resolve_repo_path(task, Keyword.get(opts, :repo)) do
      # Best-effort: a review that can't reach `origin` is still a useful review
      # of the local branches, and refreshing remote-tracking refs is the only
      # thing that could have failed — nothing was mutated.
      _ = Worktree.fetch_origin(repo_path, resolve_target_branch(task, opts))
      {:ok, repo_path}
    else
      _ -> {:error, :missing_worktree}
    end
  end

  # An isolated, detached checkout at the tip of `origin/<target>`, at the task's
  # *inspect* leaf (`Worktree.inspect_name/1` — the branch name plus a suffix, so
  # it can never collide with a branch worktree for the same task).
  # `Issue.Changes.CleanupWorktree` reclaims that leaf on close exactly as it does
  # a code worktree.
  #
  # A repo with no `origin` cannot be stale — there is no upstream to be behind —
  # so that one case falls back to the local checkout instead of failing a
  # dispatch that works fine today. Every other failure (fetch failed, the target
  # branch is gone upstream, `git worktree add` failed) is surfaced: handing the
  # agent the shared checkout after a failed refresh is precisely the
  # silently-wrong-answer path this fix closes.
  defp provision_inspect_worktree(%Issue{} = task, repo_path, opts) do
    require Logger

    name = Worktree.inspect_name(BranchNamer.derive(task))
    base_branch = resolve_target_branch(task, opts)

    case Worktree.create_detached(repo_path, name, base_branch) do
      {:ok, path} ->
        {:ok, path}

      {:error, {:missing_origin_remote, _msg}} ->
        Logger.info(
          "Dispatch: #{repo_path} has no origin remote; task #{task.id} runs from the local " <>
            "checkout (nothing upstream to be stale against)"
        )

        {:ok, repo_path}

      {:error, reason} ->
        Logger.warning(
          "Dispatch: could not provision an up-to-date checkout for task #{task.id} from " <>
            "#{repo_path} (#{inspect(reason)}); refusing to run the agent against a possibly " <>
            "stale local tree"
        )

        {:error, {:inspect_worktree_failed, reason}}
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

        # Order matters: apply the provider (agent_type) override first so it
        # can strip the routed, provider-specific model, then the bd-8cn795
        # thrash auto-escalation (a *default*, not an override), then let an
        # explicit `--model` override win on top of everything.
        choice =
          task
          |> Routing.choose(workspace, %{})
          |> apply_agent_type_override(Keyword.get(opts, :agent_type))
          |> maybe_escalate_context_window(task.id)
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

        # bd-dzz6ly: everything that GOVERNED this run — the effective
        # post-layering skill set (already threaded onto opts by
        # maybe_start_claude), the routing policy that produced `choice`, and
        # the workspace's standing_orders digest — backfilled onto the Run
        # row the same way :model's late arrival already is above.
        Worker.report(worker_pid, :run_provenance, %{
          resolved_skills: RunProvenance.skills(Keyword.get(opts, :resolved_skills, [])),
          standing_orders_digest: RunProvenance.standing_orders_digest(workspace),
          routing_policy: RunProvenance.routing_policy_string(workspace),
          model_tier: Keyword.get(agent_opts, :model_tier),
          thinking: Keyword.get(agent_opts, :thinking)
        })

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
            # bd-9rdwe4: `prompt:` alongside `command:` plays no role in argv
            # resolution (that's `command:`'s job) — it's carried purely so
            # `Arbiter.Worker` can persist what this worker was actually told.
            {:ok, base ++ [command: argv, prompt: prompt, env: env] ++ session_meta}

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

  # bd-8cn795: a task whose most recent run died with `:context_thrash` (the
  # Claude CLI's "Autocompact is thrashing" loop detector) will die identically
  # on a plain retry — the working set that overflowed the window hasn't
  # changed. Auto-escalate the redispatch to a 1M-context model so the
  # coordinator doesn't have to remember to pass a manual `model:`
  # override every time. This is a *default*, not an override: it's applied
  # before `apply_model_override/2`, so an explicit `opts[:model]` still wins.
  @context_window_escalation_model "claude-sonnet-5[1m]"

  defp maybe_escalate_context_window(choice, task_id) do
    if thrashed_last_run?(task_id) do
      %{choice | config: Map.put(choice.config || %{}, "model", @context_window_escalation_model)}
    else
      choice
    end
  end

  # The dispatch call that's asking has already created ITS OWN `:running` Run
  # row for this attempt (the worker creates it on init, before
  # `build_agent_session_opts` ever runs) — so "the last run" as of this check
  # is always the in-flight one, never the prior failure we're trying to
  # detect. Look at the most recent *:failed* run instead.
  defp thrashed_last_run?(task_id) do
    case latest_failed_run(task_id) do
      %Run{} = run ->
        StopReason.classify(run.exit_code, run.output_lines || []).category == :context_thrash

      nil ->
        false
    end
  end

  defp latest_failed_run(task_id) when is_binary(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id and status == :failed)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  defp latest_failed_run(_), do: nil

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
      task.issue_type == :task -> task_prompt(task, opts)
      true -> work_prompt(task, opts)
    end
  end

  @doc """
  Briefing for a **conflict-resolve** worker (#354, Phase 2b).

  The Watchdog (`Arbiter.Worker.Watchdog`) dispatches a short-lived worker
  against the task's existing worktree when an *approved* PR is blocked as
  `:conflict` — mergeable in isolation but no longer applying cleanly on top of
  the current base. The worker's job is narrow: rebase the branch onto the
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

        arb message coordinator "Conflict on #{task.id} needs human review: <one-line why>"

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

  # bd-8cn795: whole-file reads of large modules (or a large PR body / API
  # dump piped straight into context) refill the window faster than
  # autocompact can shed it, tripping the CLI's own thrash detector
  # ("Autocompact is thrashing...") and aborting the session before any real
  # work happens. This is deterministic for a given file set, so the fix has
  # to be read discipline, not a retry. Shared between the work and review
  # prompts since both failure instances (bd-3cpcw2, lt-5jhqs8) were reads,
  # not writes.
  # Shared between `base_work_prompt/2` and `task_prompt/2` (bd-6v2my2): any
  # dispatch that provisions a worktree needs the same "don't write outside it"
  # warning, regardless of whether the directive is reviewable code or a
  # `:task`-type follow-up that also happens to get a checkout.
  defp isolation_section(worktree_path) when is_binary(worktree_path) do
    """

    FILESYSTEM ISOLATION — Your worktree is at:

        #{worktree_path}

    You MUST only write files inside this directory. Do NOT use absolute
    paths that point outside it — especially not to the main repo checkout
    (e.g. /home/ryan/dev/arbiter/...). Writing to the main repo corrupts
    Phoenix hot-reload and cascades to kill every other running worker.
    Always use relative paths or paths rooted at #{worktree_path}.
    """
  end

  defp isolation_section(_), do: ""

  defp read_discipline_section do
    """
    READ DISCIPLINE — avoid whole-file reads of large modules: they refill
    the context window faster than autocompact can shed it and can abort your
    session mid-task ("Autocompact is thrashing"). Prefer grep/symbol search
    to locate the relevant span first, then read a bounded offset+limit range
    rather than the entire file. For a large `gh`/API command's output, pipe
    it to a file and read bounded slices rather than dumping it whole into
    context.
    """
  end

  defp base_work_prompt(%Issue{} = task, opts) do
    worktree_path = Keyword.get(opts, :worktree_path)
    isolation_section = isolation_section(worktree_path)

    """
    You are a worker working autonomously on task #{task.id}.

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}
    #{prior_review_findings_section(task)}
    Your current directory is a fresh git worktree on a per-task branch.
    #{isolation_section}
    #{read_discipline_section()}#{skills_section(opts)}
    Work the task to completion: load context, design, implement, test,
    commit on this branch, and push it.

    Do NOT open a pull request yourself (no `gh pr create` / `glab mr
    create`). The MergeQueue opens the single canonical PR for this task, on
    the correct base branch, using the body you author in the next step.
    Opening your own PR creates a duplicate on the wrong base.
    #{pr_review_instruction(task)}#{pr_body_step(task)}#{completion_notes_step(task)}
    Coordination: at the start of each step, check your mailbox by running

        arb inbox #{task.id}

    This shows any direction from the coordinator or flags from sibling workers
    (e.g. an upstream API shape changed) and marks them read. To leave a flag
    for another worker, use `arb message <their-task-id> <text>`.

    Between major steps, also check for `.arbiter/INBOX` in your working
    directory using `[ -f .arbiter/INBOX ] && cat .arbiter/INBOX` (this does
    NOT error when the file is absent — the normal case). If it exists, read
    it, act on any coordinator instructions it contains, then delete the file to
    acknowledge receipt. Treat it as a real-time message from the coordinator — it
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
  #
  # bd-6v2my2: a PRPatrol follow-up (`source_pr` set) is also dispatched as a
  # `:task` — it has no branch/PR of its own either — but unlike a pure
  # research/ops task it MAY legitimately need to push a code fix. That fix
  # belongs on the ORIGINAL PR's branch, never a fresh one, so `pr_follow_up_note/1`
  # swaps in that guidance (and the worktree it runs from, when one was
  # provisioned) in place of the generic "you are not expected to edit a repo"
  # line.
  defp task_prompt(%Issue{} = task, opts) do
    """
    You are a worker working autonomously on task #{task.id}.

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}

    This is a `task`-type directive: it has NO branch or pull request of its
    own, and none will be opened for it.
    #{pr_follow_up_note(task)}#{isolation_section(Keyword.get(opts, :worktree_path))}
    #{read_discipline_section()}
    Your job:
      1. Do the investigation / ops work the directive describes.
      2. Write your findings to the directive's `notes` field by calling the
         `task_update_progress` MCP tool with its `notes` argument (Markdown is
         fine). Make it self-contained: what you investigated, what you found,
         and any recommendation or conclusion the coordinator needs — they read it
         via `arb show #{task.id}` and the dashboard.

    A notes gate enforces this: if you print `arb done` while `notes` is still
    blank, you will be reprompted to write your findings before the directive
    can close. Do NOT shell out to the `arb` CLI for the notes — use the
    `task_update_progress` MCP tool.
    #{completion_notes_step(task)}
    Coordination: at the start of each step, check your mailbox by running

        arb inbox #{task.id}

    This shows any direction from the coordinator or flags from sibling workers and
    marks them read. To leave a flag for another worker, use
    `arb message <their-task-id> <text>`.

    Between major steps, also check for `.arbiter/INBOX` in your working
    directory. If it exists, read it, act on any coordinator instructions it
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

  # bd-6v2my2: a PRPatrol follow-up carries `source_pr` — the PR it was auto-filed
  # against (unresolved review threads / CHANGES_REQUESTED / a failing required
  # check, see `Arbiter.Workflows.PRPatrol`). Unlike plain research/ops `:task`
  # work, it may need to push a real fix, but that fix must land on the
  # ORIGINAL PR's branch: pushing a new branch from this directive's own
  # (unintegrated) worktree previously became a byte-identical duplicate PR
  # against the original's entire diff (lt-divfvo -> verus_server#3682). Like
  # any `:task`, this directive gets no branch worktree — its current
  # directory (when one is provisioned) is a disposable, detached checkout
  # with no branch of its own, so `gh pr checkout` there is always safe: there
  # is nothing Arbiter-owned to collide with or lose.
  defp pr_follow_up_note(%Issue{id: id, source_pr: source_pr})
       when is_binary(source_pr) and source_pr != "" do
    """

    This directive is a PRPatrol follow-up against EXISTING pull request ##{source_pr}.
    If the reviewer's findings were already addressed — or your job here is only
    to reply / resolve / escalate on the review threads — completing with no
    code change at all is SUCCESS. Do not force a commit just to have one.

    Your current directory is already a checkout of the repository (read-only
    by convention, not a branch of its own) — good enough to inspect the code
    and run `gh`/`git`. If a fix genuinely is needed: check out the ORIGINAL
    PR's branch directly — `gh pr checkout #{source_pr}` — right there, and
    commit + push (`git push`), which updates PR ##{source_pr} in place. Do
    NOT `git push -u origin <new-branch>` or `gh pr create` — that opens a
    duplicate PR against the original's entire diff.

    If the fix is too large or risky to fold in now, do not silently open a new
    PR either — that must never be a side effect of this dispatch. Push back on
    the thread explaining why (see the protocol above), or, only when a
    genuinely separate deliverable is warranted, file it as an explicit,
    recorded decision: `arb create <title> --parent #{id} --type feature` —
    a distinct task that gets its own branch/PR by design.
    """
  end

  defp pr_follow_up_note(_task) do
    """

    No worktree is provisioned by default — you are not expected to edit a repo.
    If the work genuinely requires inspecting code you may read files, but do
    not author a branch or open a PR.
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
  defp pr_body_step(%Issue{id: id, tracker_type: tracker_type, tracker_ref: tracker_ref}) do
    closes_guidance =
      case {tracker_type, is_binary(tracker_ref) && Regex.match?(~r/^\d+$/, tracker_ref)} do
        {:github, true} ->
          "\n\n    For GitHub-tracked tasks, include a closing keyword `Closes ##{tracker_ref}`" <>
            " in the References section — GitHub will auto-close the issue on merge, " <>
            "acting as a backstop independent of Arbiter's own close mechanism."

        _ ->
          ""
      end

    """

    Author the PR description and persist it on the task — the MergeQueue opens
    the PR with this exact body, so write it as the PR writeup, not a restatement
    of the ticket. Do this AFTER the work is implemented and tested, so it
    reflects what actually changed:

      * **Summary** — what changed and why, in a few sentences.
      * **Test plan** — the checks you ran, with checked boxes for what passed.
      * **References** — the task id (#{id}) and any linked ticket/PRs.#{closes_guidance}

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

    #{read_discipline_section()}
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

    #{ReviewVerification.anti_stale_reflag_block()}
    After you post the review to the tracker, print your conclusion on its
    own line, EXACTLY one of:

        VERDICT: APPROVE
        VERDICT: REQUEST_CHANGES

    If you REQUEST_CHANGES you MUST have posted an ENUMERATED list of concrete
    findings through the tracker CLI — each with a severity, a location, and a
    suggested fix. A REQUEST_CHANGES verdict that names no findings is invalid.

    #{ReviewVerification.disclosure_block()}
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
