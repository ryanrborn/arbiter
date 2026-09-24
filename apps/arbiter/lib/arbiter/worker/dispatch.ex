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
    review_checkout: map() | nil,     # reviewer's throwaway checkout, if any
    claude_port: port() | nil    # nil unless start_claude: true
  }}
  ```

  A review dispatch's `:review_checkout` is normally reclaimed by the Driver
  when the run ends. With `start_driver: false` there is no Driver, so the
  caller owns it and must `Arbiter.Reviews.Checkout.teardown/1` its `:path`.

  Or `{:error, reason}` for any step that fails. On error, partial work is
  best-effort-rolled-back (started worker is stopped; task status revert is
  NOT attempted because the user may want to inspect what happened).
  """

  alias Arbiter.Agents
  alias Arbiter.Agents.Gemini.Config, as: GeminiConfig
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Drain
  alias Arbiter.CircuitBreaker
  alias Arbiter.MCP.AgentConfig.Codex
  alias Arbiter.MCP.AgentConfig.Gemini, as: GeminiMCP
  alias Arbiter.Mergers.Github.RepoResolver
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Reviews.Checkout
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.IssueRepo
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers
  alias Arbiter.Usage.Event
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.Driver
  alias Arbiter.Worker.PromptBuilder
  alias Arbiter.Worker.ResumeContext
  alias Arbiter.Worker.ResumeSlot
  alias Arbiter.Worker.RunProvenance
  alias Arbiter.Worker.StopReason
  alias Arbiter.Worker.TargetBranch
  alias Arbiter.Worker.Watchdog
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
          agent_adapter: module() | nil,
          depth: non_neg_integer(),
          # bd-92mx1m, resume/2 and resume_session/2 only — see ResumeSlot.
          resume_origin: :human | :automatic,
          force_slot: boolean(),
          slot_override_actor: String.t() | nil,
          slot_admitted: boolean(),
          defer_resume: (String.t(), :resume | :resume_session, keyword() -> :ok | term())
        ]

  @typedoc """
  What `resume/2` / `resume_session/2` return in place of a dispatch result
  when an automatic resume was deferred until a slot frees (bd-92mx1m).
  """
  @type deferred_result :: %{
          deferred: true,
          task_id: String.t(),
          cap: non_neg_integer(),
          holders: [String.t()]
        }

  @type dispatch_result :: %{
          task: Issue.t(),
          worker_pid: pid(),
          machine_id: String.t(),
          machine_pid: pid(),
          driver_pid: pid() | nil,
          worktree_path: String.t() | nil,
          # The reviewer's throwaway checkout, if one was provisioned
          # (bd-199giy). Owned by the Driver, which tears it down when the run
          # ends — EXCEPT under `start_driver: false`, where no Driver exists
          # and teardown is the caller's job: `Checkout.teardown(result.review_checkout.path)`.
          review_checkout: Checkout.branch_checkout() | nil,
          claude_port: port() | nil
        }

  @spec dispatch(String.t(), dispatch_opts()) :: {:ok, dispatch_result()} | {:error, term()}
  def dispatch(task_id, opts \\ []) when is_binary(task_id) do
    # bd-9fgg04: until `Worker.start/1` registers, a dispatch in progress is
    # invisible to the worker supervisor — track it so a drain report sees it.
    # This covers every caller: `arb dispatch`, the Conductor's DispatchQueue,
    # Watchdog auto-resume and the autopilot's promotion task.
    Drain.track(:dispatch_pending, %{task_id: task_id}, fn -> do_dispatch(task_id, opts) end)
  end

  defp do_dispatch(task_id, opts) do
    opts = normalize_opts(opts)

    with {:ok, task} <- load_task(task_id),
         opts = apply_issue_repo_default(task, opts),
         :ok <- ensure_not_closed(task),
         :ok <- ensure_not_awaiting_review(task_id),
         :ok <- ensure_no_live_agent_session(task_id, opts),
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
    # `maybe_start_claude/4` hands back the opts it resolved the agent's cwd
    # with — the seam where a review dispatch's throwaway checkout (bd-199giy)
    # is provisioned and recorded, so the Driver can tear it down and the
    # caller can see it.
    #
    # An outer `case` around the inner `with` chain rather than one flat
    # chain, deliberately: a `with`-clause binding does NOT leak into that
    # `with`'s own `else`. With a single chain the error branch would read the
    # *outer* `opts` — the function parameter, which never carries
    # `:review_checkout` (it is added inside `resolve_agent_cwd/3`) — so its
    # teardown was a guaranteed no-op and the throwaway worktree leaked on
    # every post-spawn failure. Splitting the first step out puts the rebound
    # `opts` in scope for the inner `else`, which is the branch that actually
    # needs it.
    case maybe_start_claude(task, worker_pid, worktree_path, opts) do
      {:ok, claude_port, opts} ->
        with {:ok, machine_id, machine_pid} <-
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
             review_checkout: Keyword.get(opts, :review_checkout),
             claude_port: claude_port
           }}
        else
          {:error, reason} = err ->
            # A checkout provisioned moments ago has no Driver to reclaim it once
            # the spawn fails, so tear it down here rather than leak it.
            Checkout.teardown(review_checkout_path(opts))
            fail_spawned_worker(worker_pid, reason)
            err
        end

      # `maybe_start_claude/4` is the frame that provisioned the checkout and
      # tears it down on its own failure path, so there is nothing left to
      # reclaim here — and nothing reachable to reclaim it with.
      {:error, reason} = err ->
        fail_spawned_worker(worker_pid, reason)
        err
    end
  end

  defp review_checkout_path(opts) do
    case Keyword.get(opts, :review_checkout) do
      %{path: path} when is_binary(path) and path != "" -> path
      _ -> nil
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

  This is the explicit `arb resume <task>` path. It carries no Claude/Gemini
  session-resume id; the continuity comes from the preserved worktree state
  plus a `Arbiter.Worker.ResumeContext` briefing prepended to the standard
  work prompt (coordinator sign-off 2026-06-05, approach (b)). It is NOT
  provider-agnostic, though: unless the caller passes an explicit
  `:agent_type`, the fresh agent defaults to whichever provider the task's
  most recent usage-ledger row ran on (bd-b7e33c AC5), so resuming an agy run
  doesn't silently switch to Claude and spend quota the operator dispatched
  to agy specifically to conserve.

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
  @spec resume(String.t(), dispatch_opts()) ::
          {:ok, dispatch_result() | deferred_result()} | {:error, term()}
  def resume(task_id, opts \\ []) when is_binary(task_id) do
    # bd-9fgg04: until `Worker.start/1` registers, a dispatch in progress is
    # invisible to the worker supervisor — track it so a drain report sees it.
    Drain.track(:dispatch_pending, %{task_id: task_id}, fn -> do_resume(task_id, opts) end)
  end

  defp do_resume(task_id, opts) do
    with {:ok, task} <- load_task(task_id),
         :ok <- ensure_not_closed(task),
         :ok <- ensure_not_active(task_id),
         {:ok, repo} <- resolve_resume_repo(task, opts),
         {:ok, worktree_path} <- resume_worktree(task, repo),
         target_branch <- resolve_target_branch(task, Keyword.put(opts, :repo, repo)),
         {:ok, context} <- ResumeContext.build(task, worktree_path, target_branch),
         {:ok, opts} <- resume_slot(task, :resume, opts) do
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

      {provider, fallback_reason} = resolve_resume_provider(task, opts)

      resume_opts =
        opts
        |> Keyword.put(:agent_type, provider)
        |> put_opt_if_present(:provider_fallback, fallback_reason)
        |> Keyword.put(:repo, repo)
        |> Keyword.put(:start_claude, true)
        |> Keyword.put(:resume, true)
        |> Keyword.put(:resume_context, context)
        |> Keyword.put(:resumed_from_run_id, prior_run_id)
        |> Keyword.put(:existing_pr_ref, task.pr_ref)

      # Already inside this resume's Drain.track — skip dispatch/2's own.
      do_dispatch(task_id, resume_opts)
    else
      {:deferred, result} -> {:ok, result}
      other -> other
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
     If the resolved provider doesn't match the provider that captured the
     session id (bd-b7e33c AC5 — e.g. an explicit `--agent` override that
     lands on a different CLI than the one owning the conversation), the
     foreign session id is dropped and `dispatch/2` gets a git-derived
     `ResumeContext.build/3` briefing instead, the same one `resume/2` uses —
     never a silent fresh start with no continuity at all.

  Returns the same `{:ok, dispatch_result()}` / `{:error, reason}` shape as
  `dispatch/2`. Session-resume-specific errors: `{:error, :no_outpost}`,
  `{:error, :no_session}`, `{:error, {:worker_active, status}}`,
  `{:error, :repo_unknown}`.
  """
  @spec resume_session(String.t(), dispatch_opts()) ::
          {:ok, dispatch_result() | deferred_result()} | {:error, term()}
  def resume_session(task_id, opts \\ []) when is_binary(task_id) do
    # bd-9fgg04: until `Worker.start/1` registers, a dispatch in progress is
    # invisible to the worker supervisor — track it so a drain report sees it.
    Drain.track(:dispatch_pending, %{task_id: task_id}, fn -> do_resume_session(task_id, opts) end)
  end

  defp do_resume_session(task_id, opts) do
    with {:ok, task} <- load_task(task_id),
         :ok <- ensure_not_closed(task),
         :ok <- ensure_not_active(task_id),
         {:ok, repo} <- resolve_resume_repo(task, opts),
         {:ok, worktree_path} <- resume_worktree(task, repo),
         {:ok, session_id, session_provider} <- latest_session_id(task_id),
         {:ok, opts} <- resume_slot(task, :resume_session, opts) do
      prior_run_id = latest_run_id(task_id)

      # Free the registry slot the same way resume/2 does: a stopped worker
      # lingers in :failed, still registered under task_id, and would make
      # dispatch/2 attach to the dead one instead of starting a fresh run.
      # Stopping it never touches the worktree, so it stays preserved.
      _ = stop_prior_worker(task_id)

      {provider, fallback_reason} = resolve_session_resume_provider(task, opts, session_provider)

      base_opts =
        opts
        |> Keyword.put(:agent_type, provider)
        |> put_opt_if_present(:provider_fallback, fallback_reason)
        |> Keyword.put(:repo, repo)
        |> Keyword.put(:start_claude, true)
        |> Keyword.put(:resume, true)

      # bd-b7e33c finding 2 (round 1 re-review) / finding 1 (round 2): only
      # carry resume_session_id when the resolved provider still matches the
      # one that captured it — otherwise it's a bogus invocation, e.g.
      # `claude --resume <agy-conversation-uuid>`. Degrade to resume/2's real
      # git-derived briefing instead of silently dropping both (round-2 fix:
      # the old fallback dropped resume_session_id but never built the
      # briefing it claimed to fall back to).
      resume_opts =
        if provider == session_provider do
          Keyword.put(base_opts, :resume_session_id, session_id)
        else
          require Logger

          target_branch = resolve_target_branch(task, Keyword.put(opts, :repo, repo))

          case ResumeContext.build(task, worktree_path, target_branch) do
            {:ok, context} ->
              Logger.info(
                "Dispatch.resume_session: dropping session_id for #{task.id} — session " <>
                  "provider #{inspect(session_provider)} does not match resolved provider " <>
                  "#{inspect(provider)}; degrading to a git-derived resume briefing instead"
              )

              Keyword.put(base_opts, :resume_context, context)

            {:error, reason} ->
              Logger.warning(
                "Dispatch.resume_session: dropping session_id for #{task.id} — session " <>
                  "provider #{inspect(session_provider)} does not match resolved provider " <>
                  "#{inspect(provider)}; failed to build a git-derived resume briefing " <>
                  "(#{inspect(reason)}), proceeding with no briefing"
              )

              base_opts
          end
        end

      resume_opts =
        resume_opts
        |> Keyword.put(:resumed_from_run_id, prior_run_id)
        |> Keyword.put(:existing_pr_ref, task.pr_ref)

      # Already inside this resume's Drain.track — skip dispatch/2's own.
      do_dispatch(task_id, resume_opts)
    else
      {:deferred, result} -> {:ok, result}
      other -> other
    end
  end

  # bd-92mx1m: may this resume re-enter the task at all, given the cap? Asked
  # after every check that could refuse the resume on its own merits (a missing
  # worktree is a better answer than a full cap) and before the prior worker is
  # stopped, so a refusal or a deferral leaves the task exactly as it was. See
  # `Arbiter.Worker.ResumeSlot` for the rule.
  defp resume_slot(%Issue{} = task, kind, opts) do
    admit_opts = [
      origin: Keyword.get(opts, :resume_origin, :human),
      force: Keyword.get(opts, :force_slot) == true,
      actor: Keyword.get(opts, :slot_override_actor),
      slot_admitted: Keyword.get(opts, :slot_admitted) == true
    ]

    case ResumeSlot.admit(task, admit_opts) do
      {:ok, :forced} -> {:ok, Keyword.put(opts, :slot_cap_override, true)}
      {:ok, _admitted} -> {:ok, opts}
      {:defer, info} -> defer_resume(task, kind, opts, info)
      {:error, _} = error -> error
    end
  end

  # `:arbiter, :resume_deferrer` — a module with `defer_resume/3`. The board
  # autopilot everywhere but the test env, which records instead (see
  # config/test.exs).
  defp configured_deferrer do
    module = Application.get_env(:arbiter, :resume_deferrer, Autopilot)
    &module.defer_resume/3
  end

  # An automatic resume at a full cap waits for a slot rather than failing or
  # going over: the board autopilot replays it with the caller's own options
  # the moment one frees, ahead of any new Ready dispatch. A scheduler that
  # cannot take it is a refusal — never a bypass.
  defp defer_resume(%Issue{id: task_id}, kind, opts, info) do
    require Logger

    defer = Keyword.get_lazy(opts, :defer_resume, &configured_deferrer/0)

    case defer.(task_id, kind, Keyword.delete(opts, :defer_resume)) do
      :ok ->
        Logger.info(
          "Dispatch: deferred #{kind} of #{task_id} until a worker slot frees " <>
            "(cap #{info.cap}, held by #{inspect(info.holders)})"
        )

        {:deferred, Map.put(info, :deferred, true)}

      other ->
        Logger.warning(
          "Dispatch: could not defer #{kind} of #{task_id} (#{inspect(other)}); refusing it " <>
            "at the full cap instead"
        )

        {:error, {:slot_cap_full, info}}
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
  def worker_active_message(status, task_id),
    do: worker_active_message(status, task_id, Watchdog.alive?(task_id))

  @doc """
  `worker_active_message/2` with the Watchdog-liveness answer supplied rather
  than looked up.

  bd-8jixav: the `:awaiting_review` wording used to assert "the watchdog is
  polling it to completion" from nothing but the worker's static status. A
  Watchdog is a `:temporary` child — when it crashes it is gone silently — so
  for the abandoned task that motivated this ticket the sentence an operator
  read was the precise opposite of the truth, for hours. Only
  `:awaiting_review` consults the flag; every other status is unaffected.
  """
  @spec worker_active_message(atom(), String.t(), boolean()) :: String.t()
  def worker_active_message(:awaiting_review_gate, task_id, _watchdog_alive?) do
    "#{task_id}'s worker is parked at awaiting_review_gate — the review gate is " <>
      "judging its diff right now. It is not stalled and must not be stopped: " <>
      "stopping it discards the review in flight and the next dispatch restarts " <>
      "the gate from round 1. Wait for the verdict, or check `arb worker list` for " <>
      "a subordinate pass (`#{task_id}:fixpass` / `:conflict`) if something else failed."
  end

  def worker_active_message(:awaiting_review, task_id, false) do
    "#{task_id}'s worker is parked at awaiting_review with its MR/PR open, but " <>
      "no watchdog is running for it — nothing is polling that MR, and nothing " <>
      "will move this task on its own. Re-attach one with " <>
      "`arb queue restart-watchdog #{task_id}` (cheap: it watches the existing " <>
      "MR and does not re-run the review gate). Resuming instead would stop the " <>
      "worker and restart the whole gate from round 1."
  end

  def worker_active_message(:awaiting_review, task_id, _watchdog_alive?) do
    "#{task_id}'s worker is parked at awaiting_review — its MR/PR is open and the " <>
      "watchdog is polling it to completion. It is not stalled and must not be " <>
      "stopped: stopping it drops the watchdog and the next dispatch re-runs the " <>
      "whole review gate. Check the PR, or check `arb worker list` for a subordinate " <>
      "pass (`#{task_id}:fixpass` / `:conflict`) if something else failed."
  end

  def worker_active_message(status, _task_id, _watchdog_alive?),
    do: "a worker is still active for this task (#{status}); stop it before resuming"

  @doc """
  Check if a task can be safely resumed. Returns a tuple of {resumable, blocked_reason}.
  resumable is true if the worker can be resumed (no live worker, or worker in terminal state).
  blocked_reason is a human-readable string if resumable is false, nil otherwise.
  """
  def resumable_status(task_id) do
    case Worker.whereis(task_id) do
      nil ->
        {true, nil}

      pid ->
        case safe_worker_status(pid) do
          status ->
            if resumable_pid_status?(status) do
              {true, nil}
            else
              reason = worker_active_message(status, task_id)
              {false, reason}
            end
        end
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
          status ->
            if resumable_pid_status?(status), do: :ok, else: {:error, {:worker_active, status}}
        end
    end
  end

  defp resumable_pid_status?(status), do: status in [:failed, :completed, nil]

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

  # The most-recent captured upstream session id for the task, newest first,
  # PLUS the provider recorded on that SAME row. Drawn from the usage ledger
  # (`Arbiter.Usage.Event`), where the worker persists each session's
  # `session_id` on its terminal `result` event. The task_id filter is exact,
  # so ReviewGate reviewer rows (which carry a `#review` suffix) are excluded
  # — we resume the author's session, not a reviewer's. `{:error, :no_session}`
  # when none was ever captured: the task was never worked by a
  # session-capable agent, so there is nothing to resume at the session level
  # (the caller must dispatch fresh).
  #
  # bd-b7e33c post-merge finding (2026-09-19): this used to return only the
  # session_id, and callers paired it with a SEPARATE `latest_provider/1`
  # query. The two queries can pick different rows — e.g. a newer row from a
  # failed attempt on a different provider that never got far enough to
  # capture a session_id — pinning `:agent_type` to a provider that doesn't
  # own the conversation id being resumed. Returning the provider off the
  # exact row the session_id came from makes that mismatch impossible.
  defp latest_session_id(task_id) when is_binary(task_id) do
    Event
    |> Ash.Query.filter(task_id == ^task_id and not is_nil(session_id))
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
    |> case do
      %Event{session_id: sid, provider: p} when is_binary(sid) and sid != "" ->
        {:ok, sid, safe_provider_atom(p)}

      _ ->
        {:error, :no_session}
    end
  rescue
    _ -> {:error, :no_session}
  end

  defp safe_provider_atom(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> nil
  end

  defp safe_provider_atom(_), do: nil

  # bd-2exkl0: resume passes inherit the provider of the authoring run being
  # resumed via Agents.resolve_revision_provider/2, with escalation to the
  # coordinator if an unexpected provider fallback occurs.
  defp resolve_resume_provider(%Issue{} = task, opts) do
    case Keyword.get(opts, :agent_type) do
      p when is_atom(p) and not is_nil(p) ->
        {p, nil}

      _ ->
        workspace = load_workspace(task)
        {provider, fallback_reason} = Agents.resolve_revision_provider(task.id, workspace)

        if fallback_reason do
          orig = Run.latest_authoring_provider(task.id)

          CoordinatorNotifier.provider_fallback(
            %{workspace_id: task.workspace_id, task_id: task.id},
            orig,
            provider,
            fallback_reason
          )
        end

        {provider, fallback_reason}
    end
  end

  # bd-b7e33c AC5 post-merge finding: `resolve_resume_provider/2` picks the
  # provider off the most recent AUTHORING run, which is a separate query from
  # `latest_session_id/1`'s "most recent row with a session_id" — a newer row
  # on a different provider (e.g. a failed fallback attempt that never
  # captured a session) would win there and pin `:agent_type` to a provider
  # that doesn't own the `--resume`/`--conversation` id being threaded through
  # resume_session/2. Prefer the provider carried on the SAME row the
  # session_id came from when it's still available; only fall through to the
  # general authoring-provider/fallback resolution (with its escalation) when
  # the caller forced a provider, or the session's own provider is unknown or
  # no longer usable.
  defp resolve_session_resume_provider(%Issue{} = task, opts, session_provider) do
    case Keyword.get(opts, :agent_type) do
      p when is_atom(p) and not is_nil(p) ->
        {p, nil}

      _ ->
        if not is_nil(session_provider) and Agents.provider_available?(session_provider) do
          {session_provider, nil}
        else
          resolve_resume_provider(task, opts)
        end
    end
  end

  defp put_opt_if_present(opts, _key, nil), do: opts
  defp put_opt_if_present(opts, _key, ""), do: opts
  defp put_opt_if_present(opts, key, value), do: Keyword.put(opts, key, value)

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

          with {:ok, reopened} <- reopen_task(task) do
            transition_to_in_progress(reopened, [])
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

  # bd-2aslx6 (#1428): refuse to open a SECOND paid agent session on a task
  # whose worker is already running one.
  #
  # `start_worker/3` deliberately hands back a live worker's pid on
  # `{:already_started, pid}` — attaching to a running worker is the correct
  # behaviour for a no-agent dispatch. But `maybe_start_claude/4` then spawns a
  # whole new CLI subprocess into that same worker: same `worker_run_id`, a
  # second `usage_events` row, and (when the two dispatches named different
  # providers) two providers billed against one run. That is how bd-f7j7eh
  # ended up with an `agy` session and a `claude-haiku` session racing inside
  # run d71ea5d5; the Claude one was killed unfinished at worker teardown after
  # ~127k tokens, its `worker_runs.model` overwriting the agy run's.
  #
  # Scoped to agent-spawning dispatches: a `start_claude: false` dispatch (the
  # hand-off / park path) spends nothing and keeps today's attach semantics.
  #
  # A worker that has already reached a terminal status is exempt: `start_worker/3`
  # evicts it (bd-d70whv) and `Worker.stop/2` kills every still-open session port
  # on the way out (`terminate/2`, bd-bmmj4w), so the re-dispatch cannot inherit a
  # live agent. Guarding it here would do the opposite of this task's intent — a
  # terminal worker that still holds a session (`complete_now/2` and
  # `fail_missing_worktree/1` mark the run terminal WITHOUT calling
  # `terminate_live_sessions/1`, unlike `fail_now/2`) would refuse re-dispatch
  # forever and leave the stray, spending session alive with nothing able to reap
  # it short of a manual `worker_stop`.
  defp ensure_no_live_agent_session(task_id, opts) do
    cond do
      not Keyword.get(opts, :start_claude, false) -> :ok
      terminal_worker?(task_id) -> :ok
      Worker.agent_session_live?(task_id) -> {:error, {:agent_session_active, task_id}}
      true -> :ok
    end
  end

  defp terminal_worker?(task_id) do
    case Worker.whereis(task_id) do
      nil -> false
      pid -> safe_worker_status(pid) in [:failed, :completed]
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
  # Fail-open guards: skipped on the drain re-dispatch (`skip_quota_gate: true`)
  # and for a task with no workspace. A nil snapshot (e.g., in test where polling
  # has not run yet) is handled uniformly inside each gate impl.
  defp maybe_quota_gate(%Issue{workspace_id: ws_id} = task, opts) do
    cond do
      Keyword.get(opts, :skip_quota_gate, false) == true ->
        require Logger

        Logger.warning(
          "quota gate bypassed for task=#{task.id} — quota_gate was skipped via explicit override"
        )

        # Record the quota gate bypass in the audit log
        record_quota_gate_bypass(task, opts)

        :ok

      not is_binary(ws_id) ->
        :ok

      true ->
        run_quota_gate(task, opts)
    end
  end

  defp record_quota_gate_bypass(%Issue{id: task_id, workspace_id: ws_id} = task, opts) do
    workspace = load_workspace(task)
    provider = quota_gate_provider(task, workspace, opts)
    quota = safe_quota_latest(safe_gate_account(ws_id, provider), provider)

    payload = %{
      "task_id" => task_id,
      "actor" => Keyword.get(opts, :quota_bypass_actor),
      "reason" => Keyword.get(opts, :quota_bypass_reason),
      "quota_state" => %{
        "provider" => provider,
        "quota" => format_quota_state(quota)
      }
    }

    Arbiter.Events.broadcast(ws_id, "quota_gate_bypass", payload)
  rescue
    e ->
      require Logger

      Logger.error(
        "Failed to record quota gate bypass audit event for task #{task_id}: #{Exception.message(e)}"
      )
  end

  defp format_quota_state(nil), do: nil

  defp format_quota_state(quota) do
    %{
      "available_spending_usd" => quota.available_spending_usd,
      "snapshot_at" => DateTime.to_iso8601(quota.snapshot_at)
    }
  rescue
    _ -> nil
  end

  defp run_quota_gate(%Issue{workspace_id: ws_id} = task, opts) do
    workspace = load_workspace(task)
    provider = quota_gate_provider(task, workspace, opts)

    apply_quota_gate(task, workspace, provider, ws_id, opts)
  rescue
    e ->
      # A bug in the gate must never wedge dispatch — fail open.
      require Logger
      Logger.warning("Dispatch: quota gate crashed for #{task.id}: #{Exception.message(e)}")
      :ok
  end

  # Antigravity's dispatch gate reads one of four sub-buckets keyed by model
  # family (bd-7qj58o AC4) — "Claude and GPT models" vs "Gemini Models" — but
  # the gate runs before `start_agent/4`'s own model tiering, so it doesn't
  # otherwise know the model. Best-effort hint: an explicit `opts[:model]`
  # override wins as-is; otherwise resolve the same routing choice the real
  # dispatch will use and mirror `Gemini.resolve_model/2`'s own precedence —
  # an explicit `config["model"]` pin wins over `model_tier` (routing
  # policies such as `ByPriority`/`ByBudget` routinely set `"model"`
  # directly). An unresolvable hint leaves `opts` untouched — the gate then
  # falls back to its conservative worst-of-both-groups reading rather than
  # holding on the wrong bucket.
  defp maybe_add_gemini_model_hint(:gemini, task, workspace, opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" ->
        opts

      _ ->
        case gemini_model_tier_hint(task, workspace) do
          model when is_binary(model) and model != "" -> Keyword.put(opts, :model, model)
          _ -> opts
        end
    end
  end

  defp maybe_add_gemini_model_hint(_provider, _task, _workspace, opts), do: opts

  defp gemini_model_tier_hint(task, workspace) do
    config = Routing.choose(task, workspace, %{}).config

    case config["model"] do
      model when is_binary(model) and model != "" ->
        model

      _ ->
        overrides =
          ((workspace && workspace.config["agent"]["config"]) || %{})
          |> Arbiter.Agents.ProviderConfig.apply_overrides("gemini")
          |> Map.get("tier_models", %{})

        base = GeminiConfig.default_tier_models(:agy)
        Map.get(overrides, config["model_tier"]) || Map.get(base, config["model_tier"])
    end
  rescue
    _ -> nil
  end

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

  # The provider account this dispatch is metered under (P7,
  # `docs/provider-account-design.md` §4.2 / §5 rows 4, 9). It is both the key
  # the snapshot is read by and the account half of the gate's threshold
  # policy, so it is resolved once. `nil` when the workspace has no link —
  # the gate then reads no snapshot and fails open, exactly as it did before.
  defp safe_gate_account(ws_id, provider) do
    Arbiter.Accounts.Resolver.get(Arbiter.Quota.account_id(ws_id, provider))
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp apply_quota_gate(%Issue{} = task, workspace, provider, ws_id, opts) do
    gate = Arbiter.Quota.gate_for_workspace(workspace)
    account = safe_gate_account(ws_id, provider)
    quota = safe_quota_latest(account, provider)
    # The model hint (bd-7qj58o AC4) is scoped to this `gate.check/4` call
    # only — `opts` itself (used below for `DispatchQueue.hold/5`, replayed
    # verbatim on drain) must stay exactly what the caller passed, or a
    # best-effort Antigravity bucket guess would silently override the real
    # dispatch's model resolution later.
    gate_opts =
      provider
      |> maybe_add_gemini_model_hint(task, workspace, opts)
      |> Keyword.put(:account, account)

    case gate.check(task, quota, workspace, gate_opts) do
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

  defp safe_quota_latest(nil, _provider), do: nil

  defp safe_quota_latest(%{id: account_id}, provider) do
    Arbiter.Quota.latest_for_provider(account_id, provider)
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

    base =
      base
      |> put_if_present(
        :provider,
        Keyword.get(opts, :agent_type) && to_string(Keyword.get(opts, :agent_type))
      )
      |> put_if_present(:provider_fallback, Keyword.get(opts, :provider_fallback))
      # bd-9fgg04: who asked for this dispatch (the board autopilot stamps
      # "autopilot"), so a drain report can name a board dispatch as one.
      |> put_if_present(:dispatched_by, Keyword.get(opts, :dispatched_by))

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
        # bd-8eheb6: how many times the Watchdog has auto-resumed this task out
        # of an `{:awaiting_review_timeout, _}`. Each auto-resume mints a fresh
        # worker AND a fresh Watchdog, so the counter has to ride the worker's
        # meta to survive the handoff — otherwise the next Watchdog starts from
        # 0 and the retry cap never binds. Absent on every other resume path.
        |> put_if_present(
          :awaiting_review_resume_attempts,
          Keyword.get(opts, :awaiting_review_resume_attempts)
        )
        # bd-a9zb7w: the same trick for the ReviewGate fix-round budget. A
        # `request_changes` verdict auto-dispatches an implementer fix round, and
        # each round mints a fresh worker — so both the attempt counter and the
        # digest of the findings that round was dispatched against have to ride
        # the worker's meta, or neither the cap nor the convergence check can
        # bind. Absent on every other resume path.
        |> put_if_present(
          :review_gate_fix_round_attempts,
          Keyword.get(opts, :review_gate_fix_round_attempts)
        )
        |> put_if_present(
          :review_gate_findings_digest,
          Keyword.get(opts, :review_gate_findings_digest)
        )
        # bd-92mx1m: this resume went over a full concurrency cap by an
        # explicit `force` (also written to the audit log as a
        # `slot_cap_override` event by `ResumeSlot`).
        |> put_if_present(:slot_cap_override, Keyword.get(opts, :slot_cap_override))

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
  #
  # `resume/2` and `resume_session/2` both always set `:resume` to `true`
  # before delegating to `dispatch/2` (`resume_session_id` is only set on top
  # of that, never on its own) — so `:resume` alone is a reliable signal that
  # this dispatch is re-attaching to a preserved worktree rather than cutting
  # a fresh one.
  defp resuming?(opts), do: Keyword.get(opts, :resume) == true

  # Pre-existing complexity 15 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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

            # bd-8ssxap: a redispatch can find its OLD per-task branch still on
            # disk with commits that are already merged upstream (a prior round
            # verified-failed post-merge, or was simply reopened after merge).
            # `create/3` alone would reuse that branch as-is — the worker gets
            # nothing new to add and can submit an empty PR. Reset it to current
            # upstream first; a branch with genuine unmerged work is left alone.
            #
            # `force: true` when the task's last transition was a failed
            # verification: this repo's default GitHub merge method is squash
            # (`lib/arbiter/mergers/github/config.ex`), which produces a brand
            # new commit on the base branch that the old per-task branch tip is
            # NEVER an ancestor of — plain merge-base ancestry (still used for
            # every other redispatch) would never catch that case, which is
            # exactly the bd-96mn8i incident this exists to prevent.
            #
            # A resume (`opts[:resume]`) skips this reset entirely rather than
            # passing `force: true` through: `Dispatch.resume/2` exists to
            # preserve a stopped worker's committed *and* uncommitted worktree
            # state, and this branch's whole point on a resume is continuity,
            # not a clean slate.
            reset_result =
              if resuming?(opts) do
                {:ok, :kept}
              else
                Worktree.reset_if_merged(repo_path, branch, target_branch,
                  force: task.verification_outcome == :failed
                )
              end

            case reset_result do
              {:ok, _} ->
                case Worktree.create(repo_path, branch, target_branch) do
                  {:ok, path} ->
                    {:ok, path}

                  {:error, {:git_failed, msg}} when is_binary(msg) ->
                    cond do
                      String.contains?(msg, "already exists") ->
                        # Pre-existing nesting 5 — baselined when bd-4x2yhq first
                        # wired Credo up. Thresholds stay at the tool's own default so new
                        # code is held to it; see the note in .credo.exs.
                        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
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
  # workspace's `repo_paths` map is keyed by *repo name* (e.g.
  # "client"), not by slug — so the direct + normalized key lookups above miss
  # (a repo name never normalizes to an `owner/repo` slug) and dispatch used to
  # fail `{:repo_not_found}`, spinning PRPatrol in a 1/min escalation loop.
  #
  # When the requested repo looks like an `owner/repo` slug that no key
  # matched, resolve it the same way `PRPatrolSupervisor` derives its patrol
  # repos: read each registered repo's `origin` remote and match its derived
  # slug. This only runs on the miss path (both direct lookups returned nil)
  # and only for slug-shaped repos, so a normal repo-name dispatch never pays
  # the git cost. Covers client↔apex-client, server↔apex_server, and the
  # other acme repos where repo name ≠ slug.
  defp slug_repo_path(_ws_id, repo) when not is_binary(repo), do: nil

  defp slug_repo_path(ws_id, repo) do
    if String.contains?(repo, "/") do
      target = RepoConfig.normalize_slug(repo)

      ws_id
      |> candidate_repo_paths()
      |> Enum.find_value(fn path ->
        case RepoResolver.from_remote(path) do
          {:ok, {owner, name}} ->
            # Pre-existing nesting 4 — baselined when bd-4x2yhq first
            # wired Credo up. Thresholds stay at the tool's own default so new
            # code is held to it; see the note in .credo.exs.
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            if RepoConfig.normalize_slug("#{owner}/#{name}") == target, do: path

          _ ->
            nil
        end
      end)
    end
  end

  # All locally-checked-out repo paths registered for this workspace (config
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
  # "owner/apex_server") must still resolve against a `repo_paths` entry
  # registered under a differently-separated key (e.g. "owner/apex-server").
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

  # An issue that declares its own repo (bd-2jum8j) supplies the default for
  # EVERY dispatch of it, not just `start_claude: true` ones — a dry dispatch
  # of an assigned task should provision a worktree from that repo rather than
  # park with none. A caller's explicit `repo:` opt is left untouched.
  defp apply_issue_repo_default(%Issue{repo: repo}, opts)
       when is_binary(repo) and repo != "" do
    case Keyword.get(opts, :repo) do
      given when is_binary(given) and given != "" -> opts
      _ -> Keyword.put(opts, :repo, repo)
    end
  end

  defp apply_issue_repo_default(_task, opts), do: opts

  # Real-work repo resolution (bd-1ziw04): when start_claude: true the dispatch
  # MUST bind a repo — a no-repo idle stub does nothing and looks dispatched.
  #
  # Contract (approach b):
  #   * Explicit repo that resolves in :repo_paths → proceed.
  #   * Explicit repo that does NOT resolve     → {:error, {:repo_not_found, repo}}.
  #   * No repo, exactly one repo in :repo_paths  → auto-select, update opts.
  #   * No repo, zero repos in :repo_paths        → {:error, :no_repo_configured}.
  #   * No repo, multiple repos, workspace config
  #     `default_repo` set to one of them (bd-5pctey) → auto-select it.
  #   * No repo, multiple repos, no usable default → {:error, {:ambiguous_repo, repos}}.
  #
  # The check fires only for `start_claude: true` dispatches; a dry/manual dispatch
  # (no agent) is allowed to park without a repo.
  defp maybe_resolve_repo_for_real_work(%Issue{} = task, opts) do
    case Keyword.get(opts, :start_claude, false) do
      false -> {:ok, opts}
      true -> resolve_repo_for_dispatch(task, opts)
    end
  end

  # `opts[:repo]` here has already absorbed the issue's own `repo` assignment
  # (see `apply_issue_repo_default/2`), so the precedence this enforces is:
  # explicit per-dispatch override > the issue's stored repo > sole-configured
  # repo auto-select > `{:ambiguous_repo, _}`. A named repo that doesn't
  # resolve is an error either way — a stale assignment must not silently
  # dispatch the work into some other checkout.
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
          repos -> resolve_via_default_repo(task, opts, repos)
        end
    end
  end

  # bd-5pctey: a multi-repo workspace can declare a `default_repo` in its
  # `config` (same precedent as `agent`/`merge`/`tracker`) so an otherwise
  # ambiguous dispatch — e.g. Autopilot auto-dispatching a standalone task
  # with no explicit repo — has a fallback instead of always erroring. Only
  # used if the configured value actually resolves in :repo_paths; an unset
  # or dangling default_repo falls through to the pre-existing ambiguous
  # error rather than silently picking something else.
  defp resolve_via_default_repo(%Issue{workspace_id: ws_id}, opts, repos) do
    with %{"default_repo" => default_repo} when is_binary(default_repo) and default_repo != "" <-
           load_workspace_config(ws_id) || %{},
         true <- default_repo in repos do
      {:ok, Keyword.put(opts, :repo, default_repo)}
    else
      _ -> {:error, {:ambiguous_repo, repos}}
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
  the same list dispatch itself resolves against (bd-2cv4ws). Also accepts a
  bare workspace id, for the create form (bd-2jum8j) — which has to offer repo
  choices before any `Issue` exists to ask.
  """
  @spec all_available_repos(Issue.t() | String.t() | nil) :: [String.t()]
  def all_available_repos(%Issue{workspace_id: ws_id}), do: all_available_repos(ws_id)

  # bd-9dwbvt: one enumeration, shared with the create-time resolver
  # (`Arbiter.Tasks.IssueRepo`) — the set of repos an issue may be created
  # against and the set dispatch resolves against must not be able to drift.
  def all_available_repos(ws_id) when is_binary(ws_id) or is_nil(ws_id) do
    IssueRepo.configured_repos(ws_id)
  end

  # Pre-flight auth guard (bd-awi4nw, retired to a guard-only check by bd-2jgs2h):
  # before transitioning the task and dispatching a (paid, autonomous) worker,
  # refuse immediately if `CredentialWatchdog` already knows this adapter's
  # credentials are expired.
  #
  # THIS NO LONGER RUNS A LIVE PROBE. Measured 2026-09-18: 10 auth-failed worker
  # runs in 90 days (half of them mid-run, where no pre-flight probe could have
  # helped anyway) against ~760 billed probes/day (~$23/week for Claude alone)
  # spent asking "are you logged in?" before every single dispatch and resume.
  # A rejected spawn bills nothing at the provider and the CLI exits in 3-5s, so
  # the cheaper policy is: dispatch, and let a dead credential fail fast. What
  # still has to be bounded is a *wave* of those fast failures against the same
  # dead credential — that is what this guard does, for free, off state
  # `Arbiter.Worker.fail_stopped/2` already writes: each `:auth_expired` death
  # feeds `Arbiter.Agents.AuthHold`, which opens (and marks the
  # CredentialWatchdog) after N consecutive deaths (bd-21bmdh). See both
  # moduledocs for the full posture, including how an open hold and an expired
  # mark clear without a live probe.
  #
  # Only runs on the real-agent path: skipped unless `start_claude: true`.
  # Opt out entirely with `preflight: false`.
  defp maybe_preflight(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :preflight, true) == false ->
        :ok

      not Keyword.get(opts, :start_claude, false) ->
        :ok

      true ->
        guard_known_expired(task, opts)
    end
  end

  defp guard_known_expired(%Issue{} = task, opts) do
    workspace = load_workspace(task)
    adapter = preflight_adapter(task, workspace, opts)

    # bd-21bmdh: an open `AuthHold` (N consecutive auth deaths on this
    # provider) refuses first. Its read is fail-closed — an unreadable hold
    # refuses too — and it is pure bookkeeping, so it never blocks.
    #
    # bd-5wchp1: if the CredentialWatchdog already knows this adapter's creds are
    # expired, refuse immediately — a plain state lookup, no process spawn. The
    # guard is skipped when the watchdog isn't running (returns false by default).
    cond do
      Arbiter.Agents.AuthHold.open?(adapter) ->
        refuse_known_expired(task, opts, auth_hold_stop_reason(adapter))

      Arbiter.Agents.CredentialWatchdog.expired?(adapter) ->
        refuse_known_expired(task, opts, known_expired_stop_reason())

      true ->
        :ok
    end
  end

  defp refuse_known_expired(task, opts, %StopReason{} = reason) do
    escalate_preflight_failure(preflight_snapshot(task, opts), reason)
    {:error, {:auth_check_failed, reason}}
  end

  defp auth_hold_stop_reason(adapter) do
    provider = adapter |> Module.split() |> List.last()

    %StopReason{
      category: :auth_expired,
      summary: "#{provider} dispatch is held: consecutive workers died on auth (AuthHold open)",
      remediation:
        "Re-authenticate the #{provider} CLI. The hold clears when the free credential " <>
          "check or the CredentialWatchdog probe next passes; to clear it by hand, " <>
          "`arb breaker reset --auth-hold <provider>`. Reopened tasks then dispatch again.",
      exit_status: nil,
      signal: nil
    }
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

  @doc """
  Page the coordinator about a refused pre-flight auth guard, behind the shared
  circuit breaker (bd-5jr49o).

  `guard_known_expired/2`'s refusal — the CredentialWatchdog's known-expired
  short circuit — funnels through here, which is the choke point bd-8lnnnt's
  own fix picked for the same reason: the breaker must be independent of
  *which* caller retried. `Arbiter.Workflows.DispatchQueue`'s held-intent
  drain would otherwise re-run this same refusal on `CloudProbe`'s ~5-minute
  cadence, so one task stuck behind a known-expired credential produced 14
  identical pages in 75 minutes.

  The breaker is keyed on task + refusal category, NOT on the reason summary,
  which carries the elapsed time and attempt number. Returns `:ok` when the
  page was attempted and `:suppressed` when the breaker is open.

  Public only so the adoption test can drive the exact code the call sites run.
  """
  @spec escalate_preflight_failure(map(), StopReason.t()) :: :ok | :suppressed
  def escalate_preflight_failure(snapshot, %StopReason{} = reason) do
    result =
      CircuitBreaker.guard(
        :preflight_auth_failed,
        [Map.get(snapshot, :task_id), reason.category],
        [
          workspace_id: Map.get(snapshot, :workspace_id),
          task_ref: Map.get(snapshot, :task_id),
          detail:
            "The CredentialWatchdog's known-expired guard kept refusing dispatch for " <>
              "this task. Only an operator can clear it — re-authenticate the agent " <>
              "CLI, then re-dispatch."
        ],
        fn -> CoordinatorNotifier.preflight_failed(snapshot, reason) end
      )

    case result do
      {:ok, _} -> :ok
      {:suppressed, _info} -> :suppressed
    end
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
    {:ok, nil, []}
  end

  defp maybe_start_claude(%Issue{} = task, worker_pid, worktree_path, opts) do
    case Keyword.get(opts, :start_claude, false) do
      false ->
        {:ok, nil, opts}

      true ->
        # Dispatches that provision no branch worktree (task-type audits,
        # reviews) still need a real cwd for the agent port. `resolve_agent_cwd/3`
        # owns that fallback — and, since bd-9r1tta, owns making sure it isn't a
        # stale one.
        case resolve_agent_cwd(task, worktree_path, opts) do
          {:error, reason} ->
            {:error, reason}

          {:ok, path, opts} when is_binary(path) ->
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
              {:ok, port, opts}
            else
              {:error, reason} ->
                Checkout.teardown(review_checkout_path(opts))
                {:error, {:claude_start_failed, reason}}
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
  # `origin/<target>` (`Worktree.create_detached/3`), and a review dispatch — since
  # bd-199giy — gets its OWN throwaway detached checkout at the reviewed branch's
  # current `origin` head, falling back to the (refreshed) shared checkout when
  # that can't be provisioned. Neither path writes to the contributor's HEAD,
  # index, or working tree.
  #
  # Regular feature/bug/chore dispatches without a worktree still surface
  # `:missing_worktree` rather than silently running from the main checkout.
  #
  # Returns the resolved cwd AND the opts it was resolved with: a review
  # checkout is recorded on them (`:review_checkout`) so the prompt can describe
  # it, `build_agent_session_opts/4` can harden the spawn's tool access, and the
  # Driver can tear it down.
  @spec resolve_agent_cwd(Issue.t(), String.t() | nil, keyword()) ::
          {:ok, String.t(), keyword()} | {:error, term()}
  defp resolve_agent_cwd(_task, worktree_path, opts) when is_binary(worktree_path),
    do: {:ok, worktree_path, opts}

  defp resolve_agent_cwd(%Issue{issue_type: :task} = task, _nil_worktree, opts) do
    case resolve_repo_path(task, Keyword.get(opts, :repo)) do
      nil ->
        {:error, :missing_worktree}

      repo_path when is_binary(repo_path) ->
        with {:ok, path} <- provision_inspect_worktree(task, repo_path, opts) do
          {:ok, path, opts}
        end
    end
  end

  defp resolve_agent_cwd(%Issue{} = task, _nil_worktree, opts) do
    with true <- Keyword.get(opts, :review, false),
         repo_path when is_binary(repo_path) <-
           resolve_repo_path(task, Keyword.get(opts, :repo)) do
      target = resolve_target_branch(task, opts)

      # Best-effort: a review that can't reach `origin` is still a useful review
      # of the local branches, and refreshing remote-tracking refs is the only
      # thing that could have failed — nothing was mutated. It also gives the
      # provisioned checkout below a current `origin/<target>` to diff against.
      _ = Worktree.fetch_origin(repo_path, target)

      case provision_review_checkout(task, repo_path, target) do
        %{path: path} = checkout ->
          {:ok, path, Keyword.put(opts, :review_checkout, checkout)}

        nil ->
          {:ok, repo_path, opts}
      end
    else
      _ -> {:error, :missing_worktree}
    end
  end

  # bd-199giy: give the internal reviewer the same fidelity the external Tier-2
  # reviewer has had since bd-6onexk — a real, disposable checkout at the exact
  # commit under review, instead of the repo's *shared* local checkout plus a
  # `gh pr diff`.
  #
  # Diff-only review is a strictly weaker review: it cannot open a caller the
  # diff doesn't show, grep for other uses of a changed function, or run the
  # test suite against the tree as the branch actually left it. And the shared
  # checkout it ran from is a human contributor's working directory, sitting on
  # whatever branch they last touched — so even the file reads it *could* do
  # were against the wrong tree.
  #
  # Best-effort, and deliberately so: this returns `nil` on every failure (no
  # derivable branch, branch never pushed, no `origin`, git error) and the
  # caller falls straight back to today's diff-only path. A review that can't
  # get a worktree is still worth running.
  defp provision_review_checkout(%Issue{} = task, repo_path, target) do
    require Logger

    case review_branch(task) do
      nil ->
        nil

      branch ->
        case Checkout.provision_branch(repo_path, branch, prefix: "review") do
          {:ok, %{path: path, head_sha: sha}} ->
            %{path: path, branch: branch, head_sha: sha, base_branch: target}

          {:error, reason} ->
            Logger.info(
              "Dispatch: no review checkout for task #{task.id} (branch #{branch}): " <>
                "#{inspect(reason)}; reviewing from #{repo_path} diff-only"
            )

            nil
        end
    end
  end

  # `BranchNamer.derive/1` raises for an issue with no recognisable type or ref
  # (a review-only issue minted for an arbitrary PR can be either) — that is a
  # "no checkout" answer, not a dispatch failure.
  defp review_branch(%Issue{} = task) do
    BranchNamer.derive(task)
  rescue
    _ -> nil
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

  @doc """
  Harden a review dispatch's security policy once the reviewer has a real
  checkout to stand in (bd-199giy).

  A diff-only reviewer had nothing to write to, so nothing to deny. A
  worktree-backed one does: it is holding the branch's actual files, and
  nothing about reviewing needs `Edit`/`Write`/`NotebookEdit`. Denying them
  makes "you are not the author; do not modify the branch" a property of the
  spawn rather than a line in a prompt.

  Network stays ON, unlike the external Tier-2 reviewer (`CodeReview.Checks`):
  this reviewer posts its own inline comments and verdict through `gh`/`glab`,
  so cutting the network would cut the review's whole output path.

  Public so the posture is assertable without reaching into a spawned
  session's argv.
  """
  @spec review_security_policy(SecurityPolicy.t(), keyword()) :: SecurityPolicy.t()
  def review_security_policy(%SecurityPolicy{} = policy, opts) do
    case review_checkout_path(opts) do
      nil ->
        policy

      _path ->
        SecurityPolicy.merge(policy, %{
          "permissions" => %{"deny" => ["Edit", "Write", "NotebookEdit"]}
        })
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
        agent_type = resolve_session_agent_type(opts, task, workspace)

        choice =
          task
          |> Routing.choose(workspace, %{})
          |> apply_agent_type_override(agent_type)
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
          workspace
          |> SecurityPolicy.resolve(security_override(opts), Keyword.get(opts, :repo))
          |> review_security_policy(opts)

        # `workspace:` is carried for the adapter's `spawn_env/1` — it resolves
        # the worker OAuth token from this workspace's `worker_env` before
        # falling back to the server env (bd-bw3466).
        #
        # `worktree_path:` is carried for the same reason on the agy side: it
        # keys the per-spawn isolated `$HOME`
        # (`Arbiter.Agents.Gemini.ConfigDir`, bd-7s29yq). It must be the SAME
        # value `maybe_write_mcp_config/3` above was given, or the spawn would
        # read a different HOME than the one the MCP config was written into.
        agent_opts =
          agent_opts_from_choice(choice) ++
            [security: policy, workspace: workspace, worktree_path: worktree_path]

        tracker_context = fetch_tracker_context(task, workspace)

        prompt =
          opts
          |> Keyword.put(:worktree_path, worktree_path)
          |> Keyword.put(:tracker_context, tracker_context)
          |> Keyword.put(:adapter, adapter)
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

  defp resolve_session_agent_type(opts, %Issue{id: id}, workspace) do
    Keyword.get(opts, :agent_type) || revision_or_resume_provider(opts, id, workspace)
  end

  defp revision_or_resume_provider(opts, id, workspace) do
    if Keyword.get(opts, :resume) || Arbiter.Worker.ReviewGate.base_task_id(id) != id do
      elem(Agents.resolve_revision_provider(id, workspace), 0)
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
      %Run{} = run -> thrashed?(run)
      nil -> false
    end
  end

  # bd-apwfmy: the run already classified itself the moment it died and stored
  # the answer in `stop_category`. Prefer it. Re-deriving from `output_lines`
  # is not merely redundant — those lines are capped, so on a long run the
  # thrash banner has scrolled out of the window and the re-derivation quietly
  # returns "not thrash", losing the escalation. The scan stays only as the
  # fallback for runs that predate the column.
  defp thrashed?(%Run{stop_category: "context_thrash"}), do: true
  defp thrashed?(%Run{stop_category: category}) when is_binary(category), do: false

  defp thrashed?(%Run{} = run),
    do: StopReason.classify(run.exit_code, run.output_lines || []).category == :context_thrash

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
      _ = surface_unsupported_mcp_config(task, provider, result)
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

  # bd-m8geh4: some provider CLIs have no worktree-local MCP config file at all
  # — the `agy` (Antigravity) fork reads MCP servers only from `$HOME`, so a
  # per-spawn scope token has nowhere to live. Its adapter refuses with
  # `{:error, :unsupported}` rather than writing a `.gemini/settings.json` only
  # the *upstream* `gemini` CLI would read. Surface that at dispatch time: a
  # silent no-op is what let agy workers run for weeks with no Arbiter MCP tools
  # and nobody noticing, because the fallback (`arb` CLI) works well enough to
  # hide it.
  #
  # Deliberately NOT fatal: an agy worker without MCP still completes its task
  # through the `arb` CLI. The refusal is a loud capability downgrade, not a
  # dispatch failure.
  defp surface_unsupported_mcp_config(%Issue{id: task_id}, provider, {:error, :unsupported}) do
    require Logger

    Logger.error(
      "Arbiter.Worker.Dispatch: MCP config injection is UNSUPPORTED for provider=#{inspect(provider)} " <>
        "task=#{task_id} (cli=#{inspect(mcp_cli_flavour(provider))}) — this agent's CLI reads MCP " <>
        "config only from $HOME, so no per-spawn scope token can be injected into the worktree. " <>
        "The worker will fall back to the `arb` CLI and will have NO typed Arbiter MCP tools. " <>
        "See Arbiter.MCP.AgentConfig.Gemini's moduledoc."
    )

    :ok
  end

  defp surface_unsupported_mcp_config(_task, _provider, _result), do: :ok

  # Best-effort detail for the log line above: which concrete binary the
  # provider resolved to, when the adapter can tell us.
  defp mcp_cli_flavour(:gemini), do: GeminiMCP.cli_flavour()
  defp mcp_cli_flavour(provider), do: provider

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

      case Codex.verify_connection(write_opts) do
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
  def prompt_for(%Issue{} = task), do: PromptBuilder.prompt_for(task)

  @doc false
  def prompt_for_task(%Issue{} = task, opts), do: PromptBuilder.prompt_for_task(task, opts)

  @doc """
  Briefing for a **conflict-resolve** worker (#354, Phase 2b). See
  `Arbiter.Worker.PromptBuilder.conflict_resolve_briefing/3`.
  """
  @spec conflict_resolve_briefing(Issue.t(), String.t(), String.t()) :: String.t()
  def conflict_resolve_briefing(%Issue{} = task, branch, target_branch)
      when is_binary(branch) and is_binary(target_branch) do
    PromptBuilder.conflict_resolve_briefing(task, branch, target_branch)
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
            # bd-199giy: the reviewer's throwaway checkout, if one was
            # provisioned. The Driver owns its teardown because it is the
            # component that outlives the agent session.
            review_checkout_path: review_checkout_path(opts),
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
