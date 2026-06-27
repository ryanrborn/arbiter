defmodule Arbiter.Worker do
  @moduledoc """
  A `Worker` is the unit of agent work in Gas Town: a supervised GenServer
  driving a single task through a workflow (load → design → implement → verify
  → submit).

  This module is the Phase 2 skeleton — it provides the lifecycle, registry,
  and status FSM. The actual workflow logic ships separately as the
  `Arbiter.Worker.Workflow` behaviour (gte-014) and the driver that walks
  steps lives in a later phase.

  ## Status FSM

      :idle              → :running           (advance/2 from :idle)
      :idle              → :failed            (fail/2 — "stillborn" worker, e.g.
                                              machine died before any step ran)
      :failed            → :running           (advance/2 — defense-in-depth: a re-slung
                                              failed worker is normally replaced by a
                                              fresh one (dispatch.ex bd-d70whv), but if for
                                              any reason the stale worker is reused,
                                              advance resets it to :running so arb-done
                                              is processed instead of silently ignored)
      :running           → :awaiting          (await/2 — parked, generic external wait)
      :awaiting          → :running           (resume/1)
      :running           → :awaiting_review_gate (arb-done when review is required)
      :awaiting_review_gate → :awaiting_review   (review_gate_verdict/2 :approve → merge)
      :awaiting_review_gate → :failed            (review_gate_verdict/2 reject → parked)
      :running           → :awaiting_review   (open_mr/5 — MR opened, parked for review)
      :awaiting_review   → :completed         (complete/2 — MR merged)
      :awaiting_review   → :failed            (fail/2 — MR closed/rejected)
      :running           → :completed         (complete/2 — normal exit)
      :running           → :failed            (fail/2)
      :awaiting          → :failed            (fail/2)

  Illegal transitions return `{:error, {:invalid_transition, from, to}}`.

  ## Review gate (`:awaiting_review_gate`)

  A standing order: an worker must not merge its own work. When the worker's
  `arb done` fires and the workspace requires review
  (`Workspace.review_required?/1`), the worker parks at `:awaiting_review_gate` and
  spawns an `Arbiter.Worker.ReviewGate` — which runs a **distinct** reviewer
  worker over the diff — *instead of* calling the merger. The ReviewGate reports a
  verdict back via `review_gate_verdict/2`: APPROVE proceeds to `do_open_mr` (the
  same merge path), REQUEST_CHANGES (or an inconclusive review) parks the task
  with the findings and escalates to the Admiral without merging. When review is
  not required (the default) completion routes straight to the merger as before.

  ## Merge-request review (`:awaiting_review`)

  When an worker finishes its work the worker opens a merge request via
  `open_mr/5` instead of completing immediately. That call resolves the
  workspace's merger adapter (`Arbiter.Mergers.for_workspace/1`), opens the
  MR, stores the `mr_ref` + clickable `merger_url` on the worker, transitions
  to `:awaiting_review`, and spawns an `Arbiter.Worker.Watchdog` to poll for
  approval. The Watchdog — not the worker's `arb done` — owns the terminal
  transition: it completes the worker when the MR merges, or fails it when the
  MR is closed. See `Arbiter.Worker.Watchdog`.

  This is also the path the `arb done` marker takes in claude-driven mode: when
  the worker knows its branch (a worktree was provisioned at dispatch time) the
  marker triggers the same `open_mr` flow rather than closing the task
  directly. For the default `Direct` strategy the merge (`git merge --no-ff`)
  runs immediately, so the branch reaches the target line before the task
  closes. A merge failure fails the worker instead of silently completing it.
  Only an ad-hoc run with no branch completes straight from `arb done`.

  ## API choice: explicit `await/2` etc. vs sentinel atoms

  The spec gave us a choice between an `advance(pid, :__awaiting__)` sentinel
  and a split API (`advance/2`, `await/2`, `resume/1`, `complete/2`,
  `fail/2`). We picked the split API: each verb has a single meaning, the
  status FSM lives in dispatch heads rather than in a dictionary of sentinels,
  and the type signature is honest about what `advance/2` does (change the
  workflow step, not change the lifecycle state).

  ## Registry

  Each worker registers under `Arbiter.Worker.Registry` keyed by `task_id`.
  Use `whereis/1` to look up by task_id; most API functions accept either a
  pid or a task_id string.

  ## Supervision

  Workers are started under `Arbiter.Worker.Supervisor`
  (a `DynamicSupervisor`) with `restart: :temporary`. A crashed worker is
  not restarted — workflow runners that crash have lost their state, so
  resurrecting the GenServer would just confuse the orchestrator.
  """

  use GenServer

  require Logger

  alias Arbiter.Worker.PRTemplate
  alias Arbiter.Worker.Registry, as: PRegistry

  @typedoc "Lifecycle status — distinct from `Issue.status`."
  @type status ::
          :idle
          | :resuming
          | :running
          | :awaiting
          | :awaiting_review_gate
          | :awaiting_review
          | :completed
          | :failed

  @typedoc "Current workflow step. Free-form atom; `:idle` until first advance."
  @type step :: atom()

  @typedoc "Accepted by most API functions in lieu of a bare pid."
  @type ref :: pid() | String.t()

  @typedoc "Snapshot returned by `state/1`."
  @type snapshot :: %{
          task_id: String.t(),
          workspace_id: String.t() | nil,
          repo: String.t(),
          current_step: step(),
          status: status(),
          started_at: DateTime.t(),
          step_started_at: DateTime.t() | nil,
          mr_ref: String.t() | nil,
          merger_url: String.t() | nil,
          meta: map()
        }

  defmodule State do
    @moduledoc false
    defstruct [
      :task_id,
      # Registry name this worker is registered under. Defaults to task_id
      # but can be overridden via the `:registry_key` start opt so multiple
      # workers can coexist for the same task (e.g. the merge queue's short-lived
      # conflict-resolver runs alongside the original work worker under a
      # `task_id <> ":conflict"` key). `terminate/2` uses this when
      # unregistering so we don't accidentally wipe the task's primary slot.
      :registry_key,
      :workspace_id,
      :repo,
      :current_step,
      :status,
      :started_at,
      :step_started_at,
      :meta,
      # Opaque merge-request ref minted by the merger adapter on open_mr/5
      # (e.g. "!42" for GitLab, "direct:<branch>" for Direct). nil until an MR
      # is opened.
      :mr_ref,
      # Human-clickable URL for mr_ref, computed once at open_mr time via the
      # adapter's link_for/1 (some adapters resolve the URL from per-process
      # config we only have at open time). nil when there's no MR or no web UI.
      :merger_url,
      # The resolved merger adapter module (Arbiter.Mergers.Direct / .Gitlab),
      # captured at open_mr time. Internal — used to mint the Watchdog.
      :merger_adapter,
      # uuid of the persisted Arbiter.Workers.Run row, or nil if the create
      # write failed (best-effort — see record_run_started/1). Subsequent
      # status updates skip the DB write when this is nil.
      :run_id,
      # Map of port -> session config + accumulator. Internal — never exposed
      # via snapshot/1; relevant fields (output_lines, exit_status) are
      # mirrored into meta for snapshot consumers.
      claude_sessions: %{}
    ]
  end

  # Captured stdout is mirrored verbatim into the persisted Run.output_lines
  # column on terminal transitions. Cap at 500 lines so a runaway subprocess
  # doesn't bloat the row to many MB.
  @max_output_lines 500

  # Statuses in which a subprocess exit means "the worker stopped without
  # completing" — i.e. a stall to detect + escalate (bd-awi4nw). The review-gate
  # states (:awaiting_review_gate/:awaiting_review) and terminal states
  # (:completed/:failed) are excluded: there the subprocess SHOULD exit and the
  # next stage (ReviewGate/Watchdog) owns the outcome, not the dead port.
  # `:resuming` is the initial status of a worker re-attached to a preserved
  # worktree via `arb resume` (bd-auma3z). It's live — a subprocess that exits
  # before the resumed agent gets going is still a stop worth detecting — and it
  # advances to `:running` on the first step, exactly like `:idle`.
  @live_statuses [:idle, :resuming, :running, :awaiting]

  # Grace after a subprocess exit before we classify+escalate a stop. This drains
  # any in-flight `arb done` message that the port's exit_status raced ahead of
  # (the done marker is enqueued while processing the data line; the exit_status
  # message can be processed first). A normal completion flips the worker to a
  # terminal/review state within this window, so the deferred check no-ops.
  # Overridable for tests via `config :arbiter, :worker_exit_grace_ms`.
  @exit_grace_ms 500

  # ---- public API ---------------------------------------------------------

  @doc """
  Start a worker under the dynamic supervisor.

  Required opts:
    * `:task_id` — string, used as the default registry key.
    * `:repo`   — string, the repo/project key the worker operates on.

  Optional opts:
    * `:workspace_id`   — string.
    * `:meta`           — initial map of workflow-specific state.
    * `:registry_key`   — string. Overrides the registry key (defaults to
      `:task_id`). Lets multiple workers coexist for the same task — the
      merge queue's conflict-resolver worker uses `task_id <> ":conflict"` so
      it doesn't collide with the completed-but-still-resident original
      work worker (whose lifecycle is tied to task `:close`).
  """
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(Arbiter.Worker.Supervisor, {__MODULE__, opts})
  end

  @doc """
  `GenServer.start_link/3`-style entry point. Prefer `start/1` for normal use.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.fetch(opts, :task_id) do
      {:ok, task_id} when is_binary(task_id) and task_id != "" ->
        case Keyword.fetch(opts, :repo) do
          {:ok, repo} when is_binary(repo) and repo != "" ->
            registry_key = resolve_registry_key(opts, task_id)
            GenServer.start_link(__MODULE__, opts, name: PRegistry.via_tuple(registry_key))

          _ ->
            {:error, :missing_repo}
        end

      _ ->
        {:error, :missing_task_id}
    end
  end

  defp resolve_registry_key(opts, task_id) do
    case Keyword.get(opts, :registry_key) do
      key when is_binary(key) and key != "" -> key
      _ -> task_id
    end
  end

  @doc """
  Return the pid of the worker registered for `task_id`, or `nil`.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(task_id) when is_binary(task_id), do: PRegistry.whereis(task_id)

  @doc """
  Return a list of active worker snapshots — one entry per child under
  `Arbiter.Worker.Supervisor`. Crashed / stopped workers are omitted.

  Each entry is the same snapshot map `state/1` returns (task_id,
  workspace_id, repo, current_step, status, started_at, step_started_at,
  meta), plus `:pid`.
  """
  @spec list_children() :: [map()]
  def list_children do
    Arbiter.Worker.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      # Only actual workers answer :snapshot. Other children of this supervisor
      # — notably an Arbiter.Worker.ReviewGate review gate — must NOT be probed:
      # calling :snapshot on them crashes them and strands the author. Match
      # strictly on the Worker module. See bd-2y0gd5.
      {_id, pid, :worker, [__MODULE__]} when is_pid(pid) ->
        case Process.alive?(pid) && safe_snapshot(pid) do
          %{} = snap -> [Map.put(snap, :pid, pid)]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp safe_snapshot(pid) do
    GenServer.call(pid, :snapshot, 500)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc """
  Return a snapshot of the worker's state, or `nil` if no worker is
  registered for the given task_id.
  """
  @spec state(ref()) :: snapshot() | nil
  def state(pid) when is_pid(pid), do: GenServer.call(pid, :snapshot)

  def state(task_id) when is_binary(task_id) do
    case whereis(task_id) do
      nil -> nil
      pid -> state(pid)
    end
  end

  @doc """
  Advance the workflow step. Permitted when status is `:idle` (transitions to
  `:running`) or `:running` (stays `:running`).
  """
  @spec advance(ref(), step()) :: :ok | {:error, term()}
  def advance(ref, step) when is_atom(step), do: call(ref, {:advance, step})

  @doc """
  Park the worker — status becomes `:awaiting`. Only valid from `:running`.
  """
  @spec await(ref(), term()) :: :ok | {:error, term()}
  def await(ref, reason \\ nil), do: call(ref, {:await, reason})

  @doc """
  Resume a parked worker. Only valid from `:awaiting`.
  """
  @spec resume(ref()) :: :ok | {:error, term()}
  def resume(ref), do: call(ref, :resume)

  @doc """
  Open a merge request for `branch` and park the worker at
  `:awaiting_review`.

  Resolves the workspace's merger adapter, calls `open/4`, stores the resulting
  `mr_ref` + clickable `merger_url`, transitions `:running -> :awaiting_review`,
  and spawns an `Arbiter.Worker.Watchdog` to poll for approval. Only valid from
  `:running`.

  `opts` is a map forwarded to the adapter's `open/4` (`:target_branch`,
  `:reviewer_ids`, `:labels`, and — for `Direct` — `:repo_path`, which defaults
  to the worker's `meta[:worktree_path]`). It may also carry overrides
  primarily for testing and advanced callers:

    * `:adapter` — a merger module to use directly, bypassing workspace
      resolution.
    * `:workspace` — the `Workspace` struct (used to seed adapter config and
      read the auto-merge flag) when `:adapter` is supplied.
    * `:auto_merge`, `:interval_ms`, `:initial_delay_ms` — Watchdog overrides.

  Returns `{:ok, mr_ref}` on success, or `{:error, reason}` (the worker stays
  `:running`) if the adapter can't be resolved or `open/4` fails.
  """
  @spec open_mr(ref(), String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def open_mr(ref, branch, title, description \\ "", opts \\ %{})
      when is_binary(branch) and is_binary(title) and is_binary(description) and is_map(opts) do
    call(ref, {:open_mr, branch, title, description, opts})
  end

  @doc """
  Record the latest `Arbiter.Mergers.get/1` result on the worker's `:meta`
  (as `:last_merger_status`) along with a `:last_checked_at` timestamp.

  Called by the `Arbiter.Worker.Watchdog` on every poll so the dashboard and
  detail view can surface approval status and freshness without holding the
  Watchdog's state.
  """
  @spec record_merger_status(ref(), map()) :: :ok | {:error, term()}
  def record_merger_status(ref, status) when is_map(status),
    do: call(ref, {:record_merger_status, status})

  @doc """
  Mark the workflow completed. Only valid from `:running`. The worker keeps
  running (so callers can read the final state) but rejects further
  transitions.
  """
  @spec complete(ref(), term()) :: :ok | {:error, term()}
  def complete(ref, result \\ nil), do: call(ref, {:complete, result})

  @doc """
  Mark the workflow failed. Valid from `:running` or `:awaiting`.
  """
  @spec fail(ref(), term()) :: :ok | {:error, term()}
  def fail(ref, reason \\ nil), do: call(ref, {:fail, reason})

  @doc """
  Deliver a ReviewGate (review-gate) verdict. Only valid from `:awaiting_review_gate`
  — the state the worker parks at after the worker's `arb done` when review is
  required. Called by `Arbiter.Worker.ReviewGate` once the reviewer worker
  reaches its verdict.

    * `{:approve, findings}` → records the approval and proceeds to the merger
      (`do_open_mr`); the worker transitions to `:awaiting_review`.
    * `{:request_changes, findings}` → records the findings, escalates to the
      Admiral, and parks the worker at `:failed` **without** merging. The task
      stays `:in_progress` (the Driver leaves a `:failed` worker's task open for
      inspection / re-dispatch).
    * `{:no_verdict, reason}` → an inconclusive review; treated like a rejection
      (escalate, do not merge) since the safe default is never to merge unreviewed
      work.
  """
  @spec review_gate_verdict(
          ref(),
          Arbiter.Worker.ReviewGate.verdict() | {:no_verdict, String.t()}
        ) ::
          :ok | {:error, term()}
  def review_gate_verdict(ref, verdict), do: call(ref, {:review_gate_verdict, verdict})

  @doc """
  Record an arbitrary key/value pair in the worker's `:meta` map.
  """
  @spec report(ref(), atom() | String.t(), term()) :: :ok | {:error, term()}
  def report(ref, key, value), do: call(ref, {:report, key, value})

  @doc """
  Stop the worker cleanly.
  """
  @spec stop(ref(), term()) :: :ok | {:error, :not_found}
  def stop(ref, reason \\ :normal)
  def stop(pid, reason) when is_pid(pid), do: GenServer.stop(pid, reason)

  def stop(task_id, reason) when is_binary(task_id) do
    case whereis(task_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.stop(pid, reason)
    end
  end

  # ---- GenServer callbacks -----------------------------------------------

  @impl true
  def init(opts) do
    now = DateTime.utc_now()
    task_id = Keyword.fetch!(opts, :task_id)
    meta = Keyword.get(opts, :meta, %{})

    state = %State{
      task_id: task_id,
      registry_key: resolve_registry_key(opts, task_id),
      workspace_id: Keyword.get(opts, :workspace_id),
      repo: Keyword.fetch!(opts, :repo),
      current_step: :idle,
      status: initial_status(meta),
      started_at: now,
      step_started_at: nil,
      meta: meta,
      run_id: nil
    }

    state = record_run_started(state)

    broadcast_lifecycle(:started, state)

    {:ok, state}
  end

  # A worker re-attached to a preserved worktree via `arb resume` (bd-auma3z)
  # boots into `:resuming` rather than `:idle`, so the dashboard/CLI can tell a
  # resumed run apart from a fresh dispatch. It advances to `:running` on the
  # first step exactly like `:idle` does.
  defp initial_status(%{resume: true}), do: :resuming
  defp initial_status(%{"resume" => true}), do: :resuming
  defp initial_status(_), do: :idle

  @doc """
  Broadcast a `{:worker_lifecycle, event, snapshot}` message on the `"workers"`
  topic. `event` is one of:

    * `:started` — the worker just booted (`init/1`).
    * `:stopped` — the worker is terminating (`terminate/2`).
    * `:updated` — a mid-life state change worth pushing to live views, namely
      parking at `:awaiting_review` (MR opened) and each Watchdog poll that
      records a fresh merger status. Lets the dashboard's merge-queue view
      track in-flight merges without polling.

  Best-effort: a PubSub failure is logged at debug and swallowed.
  """
  def broadcast_lifecycle(event, %State{} = state) when event in [:started, :stopped, :updated] do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      "workers",
      {:worker_lifecycle, event, snapshot(state)}
    )

    :ok
  rescue
    # Silent-on-failure (PubSub registry may be down in tests), but leave
    # breadcrumbs so a programming error in the payload isn't invisible.
    e ->
      Logger.debug("Worker.broadcast_lifecycle/2 swallowed: #{Exception.message(e)}")
      :ok
  end

  # Broadcast {:worker_done, task_id} to "worker:done:<workspace_id>" so the
  # workspace's MergeQueue (the merge queue) can pick the task up and drive it through
  # the merge queue. A worker without a workspace_id (e.g. ad-hoc local runs)
  # has no MergeQueue listening and so the broadcast is skipped.
  #
  # Review-only workers (`meta[:review_only] == true`) skip the merge queue
  # broadcast — they don't author code, so there's nothing for the merge queue
  # to do, and the task they're reviewing may not even belong to the fleet.
  # The Admiral notification still fires so the dashboard / inbox feed picks
  # up the completion.
  defp broadcast_done(%State{workspace_id: nil}), do: :ok

  defp broadcast_done(%State{workspace_id: ws_id, task_id: task_id, meta: meta} = state) do
    unless review_only?(meta) do
      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        "worker:done:" <> ws_id,
        {:worker_done, task_id}
      )

      Arbiter.Events.broadcast(ws_id, "worker_done", %{task_id: task_id})
    end

    # The message queue is the single source of truth for the notification
    # feed: record a durable :notification alongside the transient broadcast.
    # This in turn broadcasts {:new_message, _} on "messages:<ws>" via the
    # resource's after_action hook, which the dashboard feed subscribes to.
    Arbiter.Messages.AdmiralNotifier.completed(snapshot(state))

    :ok
  rescue
    # Same contract as broadcast_lifecycle/2: don't fail the caller on a
    # PubSub hiccup, but log so a payload-construction bug isn't silent.
    e ->
      Logger.debug("Worker.broadcast_done/1 swallowed: #{Exception.message(e)}")
      :ok
  end

  defp broadcast_worker_failed(%State{workspace_id: nil}), do: :ok

  defp broadcast_worker_failed(%State{workspace_id: ws_id, task_id: task_id, meta: meta}) do
    unless review_only?(meta) do
      Arbiter.Events.broadcast(ws_id, "worker_failed", %{task_id: task_id})
    end

    :ok
  end

  defp review_only?(%{review_only: true}), do: true
  defp review_only?(%{"review_only" => true}), do: true
  defp review_only?(_), do: false

  # bd-5lc99r: a `task` issue type is non-reviewable work — its deliverable is a
  # findings summary written to `notes`, not a code change. Dispatch stamps the
  # task's `:issue_type` into the worker meta; the completion path reads it here
  # to route through the notes gate instead of the commit/review gates.
  defp task_type?(%{issue_type: :task}), do: true
  defp task_type?(%{issue_type: "task"}), do: true
  defp task_type?(_), do: false

  # ---- Run history (Arbiter.Workers.Run) -------------------------------

  # Best-effort: create the persistent Run row for this worker. Returns the
  # state, with :run_id populated on success. On failure (DB down, validation
  # error, no sandbox checkout in a test) we log a warning and leave run_id
  # nil — subsequent terminal updates will no-op cleanly.
  defp record_run_started(%State{} = state) do
    attrs = %{
      task_id: state.task_id,
      task_title: lookup_task_title(state.task_id),
      repo: state.repo,
      workspace_id: state.workspace_id,
      worker_type: worker_type_from_meta(state.meta),
      status: :running,
      started_at: state.started_at,
      output_lines: [],
      # bd-auma3z: when this worker was resumed (re-attached to a preserved
      # worktree), link the new run to the prior one so the stopped→resumed
      # lineage is traceable and metrics don't read it as two unrelated runs.
      resumed_from_run_id: resumed_from_run_id(state.meta)
    }

    case Ash.create(Arbiter.Workers.Run, attrs) do
      {:ok, run} ->
        %State{state | run_id: run.id}

      {:error, reason} ->
        log_run_warning("create", state.task_id, reason)
        state
    end
  rescue
    e ->
      log_run_warning("create", state.task_id, e)
      state
  end

  defp resumed_from_run_id(meta) when is_map(meta),
    do: Map.get(meta, :resumed_from_run_id) || Map.get(meta, "resumed_from_run_id")

  defp resumed_from_run_id(_), do: nil

  # Classify the worker that owns this run from its meta, mirroring the role
  # tags the ReviewGate and Dispatch stamp:
  #   * role == :reviewer  → :review  (review-gate reviewer)
  #   * role == :implementer → :impl  (review-gate revise-round implementer)
  #   * review_only == true → :review (coordinator-dispatched review-only worker)
  #   * otherwise           → :main   (the authoring worker)
  defp worker_type_from_meta(meta) when is_map(meta) do
    cond do
      Map.get(meta, :role) == :reviewer -> :review
      Map.get(meta, :role) == :implementer -> :impl
      review_only?(meta) -> :review
      true -> :main
    end
  end

  defp worker_type_from_meta(_), do: :main

  # Best-effort: stamp the terminal status / output / exit fields onto the
  # Run row created at init. No-op (with a debug breadcrumb) when run_id is
  # nil — the original create failed, so there's nothing to update and the
  # warning was already logged at that time.
  defp record_run_finished(%State{run_id: nil} = state) do
    Logger.debug("Worker.record_run_finished/1 skipped (no run_id) for task=#{state.task_id}")

    :ok
  end

  defp record_run_finished(%State{run_id: run_id} = state) do
    # Extract the model from meta, checking both potential sources
    meta = state.meta || %{}
    model = Map.get(meta, :model)

    attrs = %{
      status: state.status,
      completed_at: DateTime.utc_now(),
      exit_code: Map.get(meta, :exit_status),
      output_lines: capture_output_lines(state),
      failure_reason: stringify_failure(Map.get(meta, :failure_reason))
    }

    # Only include model in the update if it's non-nil (to preserve NULL if not set)
    attrs = if model, do: Map.put(attrs, :model, model), else: attrs

    with {:ok, run} <- Ash.get(Arbiter.Workers.Run, run_id),
         {:ok, _updated} <- Ash.update(run, attrs, action: :update) do
      :ok
    else
      {:error, reason} -> log_run_warning("update", state.task_id, reason)
    end
  rescue
    e -> log_run_warning("update", state.task_id, e)
  end

  defp capture_output_lines(%State{} = state) do
    (state.meta || %{})
    |> Map.get(:output_lines)
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.take(-@max_output_lines)
  end

  # Open the durable, uncapped per-run transcript for this session. Keyed on
  # run_id: a worker whose Run row never persisted (run_id nil) gets no
  # durable log, since there's no row to anchor audit retrieval to. A disk
  # error logs a warning and degrades to nil — the live capped path (PubSub +
  # bounded output_lines) is unaffected either way. See Arbiter.Worker.OutputLog.
  defp open_output_log(%State{run_id: nil}), do: nil

  defp open_output_log(%State{run_id: run_id} = state) do
    case Arbiter.Worker.OutputLog.open(run_id) do
      {:ok, handle} ->
        handle

      {:error, reason} ->
        log_run_warning("output_log_open", state.task_id, reason)
        nil
    end
  end

  defp stringify_failure(nil), do: nil
  defp stringify_failure(s) when is_binary(s), do: s
  defp stringify_failure(other), do: inspect(other)

  defp lookup_task_title(task_id) do
    case Ash.get(Arbiter.Tasks.Issue, task_id) do
      {:ok, %{title: title}} -> title
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp log_run_warning(op, task_id, reason) do
    Logger.warning("Worker.record_run_#{op}/1 swallowed for task=#{task_id}: #{inspect(reason)}")

    :error
  end

  # ---- Usage ledger (Arbiter.Usage.Event) -------------------------------

  # Best-effort: persist a row in the structured usage ledger when a Claude
  # session exits. The session carries everything we need (model, tokens,
  # cost, duration) in its `:usage` map; we shovel it into `Arbiter.Usage.Event`
  # alongside the worker's identifying fields. A reviewer worker (spawned by
  # the ReviewGate, meta.role == :reviewer) writes a `:review` step row;
  # everything else writes `:work`. Missing fields are fine — we record what
  # we have rather than dropping the row.
  defp record_usage_event(%State{} = state, %{} = session, exit_status) do
    usage = Arbiter.Worker.ClaudeSession.usage_summary(session)
    role = Map.get(state.meta || %{}, :role)

    step =
      cond do
        role == :reviewer -> :review
        true -> :work
      end

    # Model: prefer the value the CLI stream reported (Claude's `init` event)
    # over the model threaded onto the session at spawn time — the latter is the
    # pre-resolved id we stamp for adapters (Gemini/agy) whose stream carries no
    # model. Either way a non-Claude run lands a concrete model id.
    model = Map.get(usage, :model) || Map.get(session, :model)

    # Provider: prefer the explicitly-set provider (passed in session opts for
    # non-Claude adapters like Gemini/agy, which have no stream-json init event
    # to carry model/provider) over the model-name inference used for Claude.
    provider =
      Map.get(session, :provider) || provider_for(model)

    # Duration: prefer the value from the CLI's result event (millisecond-precise)
    # but fall back to wall-clock elapsed for adapters that don't emit one (e.g.
    # Gemini/agy), so the row is still usable for latency analysis.
    duration_ms =
      Map.get(usage, :duration_ms) ||
        wall_clock_duration_ms(Map.get(session, :started_at), Map.get(session, :exited_at))

    attrs = %{
      task_id: state.task_id,
      workspace_id: state.workspace_id,
      repo: state.repo,
      step: step,
      model: model,
      provider: provider,
      tokens_in: Map.get(usage, :tokens_in),
      tokens_out: Map.get(usage, :tokens_out),
      cache_creation_tokens: Map.get(usage, :cache_creation_tokens),
      cache_read_tokens: Map.get(usage, :cache_read_tokens),
      cost_usd: Map.get(usage, :cost_usd),
      duration_ms: duration_ms,
      exit_status: exit_status,
      worker_run_id: state.run_id,
      session_id: Map.get(usage, :session_id),
      occurred_at: DateTime.utc_now(),
      raw: Map.get(usage, :raw)
    }

    case Ash.create(Arbiter.Usage.Event, attrs) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Worker.record_usage_event/3 swallowed for task=#{state.task_id}: #{inspect(reason)}"
        )

        :error
    end
  rescue
    e ->
      Logger.warning(
        "Worker.record_usage_event/3 raised for task=#{state.task_id}: #{Exception.message(e)}"
      )

      :error
  end

  # Map a model name to a provider key. Currently every model we see is
  # Claude — but the column is here for the day we route to other agents and
  # the ledger needs to roll up cross-provider.
  defp provider_for(nil), do: nil

  defp provider_for(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "claude") -> "claude"
      String.starts_with?(model, "gemini") -> "gemini"
      String.contains?(model, "gpt") -> "openai"
      true -> "other"
    end
  end

  defp provider_for(_), do: nil

  defp wall_clock_duration_ms(%DateTime{} = started_at, %DateTime{} = exited_at) do
    DateTime.diff(exited_at, started_at, :millisecond)
  end

  defp wall_clock_duration_ms(_started_at, _exited_at), do: nil

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:advance, step}, _from, %State{status: status} = state)
      when status in [:idle, :resuming, :failed] do
    new_state = %State{
      state
      | current_step: step,
        status: :running,
        step_started_at: DateTime.utc_now()
    }

    {:reply, :ok, new_state}
  end

  def handle_call({:advance, step}, _from, %State{status: :running} = state) do
    new_state = %State{state | current_step: step, step_started_at: DateTime.utc_now()}
    {:reply, :ok, new_state}
  end

  def handle_call({:advance, step}, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, {:advance, step}}}, state}
  end

  def handle_call({:await, reason}, _from, %State{status: :running} = state) do
    meta =
      case reason do
        nil -> state.meta
        r -> Map.put(state.meta, :await_reason, r)
      end

    new_state = %State{state | status: :awaiting, meta: meta}
    Arbiter.Messages.AdmiralNotifier.awaiting_review(snapshot(new_state))
    {:reply, :ok, new_state}
  end

  def handle_call({:await, _reason}, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, :awaiting}}, state}
  end

  def handle_call(:resume, _from, %State{status: :awaiting} = state) do
    {:reply, :ok, %State{state | status: :running, meta: Map.delete(state.meta, :await_reason)}}
  end

  def handle_call(:resume, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, :running}}, state}
  end

  def handle_call(
        {:open_mr, branch, title, description, opts},
        _from,
        %State{status: :running} = state
      ) do
    case do_open_mr(state, branch, title, description, opts) do
      {:ok, mr_ref, new_state} ->
        # The worker just parked at :awaiting_review with an MR open and a
        # Watchdog watching. Push an :updated lifecycle event so the dashboard's
        # merge-queue view picks the in-flight merge up live (the topic
        # otherwise only fires on :started/:stopped).
        broadcast_lifecycle(:updated, new_state)
        {:reply, {:ok, mr_ref}, new_state}

      {:error, reason, kept_state} ->
        {:reply, {:error, reason}, kept_state}
    end
  end

  def handle_call(
        {:open_mr, _branch, _title, _description, _opts},
        _from,
        %State{status: status} = state
      ) do
    {:reply, {:error, {:invalid_transition, status, :awaiting_review}}, state}
  end

  def handle_call({:record_merger_status, status_map}, _from, %State{} = state) do
    meta =
      state.meta
      |> Map.put(:last_merger_status, status_map)
      |> Map.put(:last_checked_at, DateTime.utc_now())

    new_state = %State{state | meta: meta}

    # Each Watchdog poll lands here. Push an :updated lifecycle event so the
    # merge-queue view's approval status + last-checked freshness stay live.
    broadcast_lifecycle(:updated, new_state)

    {:reply, :ok, new_state}
  end

  def handle_call({:complete, result}, _from, %State{status: status} = state)
      when status in [:running, :awaiting_review] do
    {:reply, :ok, complete_now(state, result)}
  end

  def handle_call({:complete, _result}, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, :completed}}, state}
  end

  def handle_call({:fail, reason}, _from, %State{status: status} = state)
      when status in [:idle, :running, :awaiting, :awaiting_review] do
    {:reply, :ok, fail_now(state, reason)}
  end

  def handle_call({:fail, _reason}, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, :failed}}, state}
  end

  def handle_call(
        {:review_gate_verdict, verdict},
        _from,
        %State{status: :awaiting_review_gate} = state
      ) do
    {:reply, :ok, apply_review_gate_verdict(state, verdict)}
  end

  def handle_call({:review_gate_verdict, _verdict}, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, :review_gate_verdict}}, state}
  end

  def handle_call({:report, key, value}, _from, %State{} = state) do
    state = %State{state | meta: Map.put(state.meta, key, value)}

    if key == :model and not is_nil(state.run_id) do
      backfill_run_model(state.run_id, value, state.task_id)
    end

    {:reply, :ok, state}
  end

  # Open a Claude session port. Called by Arbiter.Worker.ClaudeSession.start/1
  # so this process (the worker) owns the port. We stash session config keyed
  # by the port itself so multiple concurrent sessions (future) wouldn't
  # collide.
  def handle_call({:__claude_session_open__, port_args, session_config}, _from, %State{} = state) do
    try do
      # bd-1z7624: a session-level resume (`arb worker resume`) seeds the worker
      # with :resume_session_id. Inject `--resume <id>` (+ the terse continue
      # prompt) into THIS spawn so it continues the prior Claude session, but
      # stash the PRISTINE argv as :claude_spawn — the bd-t9uq25 auto-resume
      # rebuilds each `--resume` from pristine args + the latest session id, so a
      # polluted spawn would stack duplicate flags. One-shot: consumed below.
      {spawn_args, pristine_args} = resume_spawn_args(state, port_args)
      port = Arbiter.Worker.ClaudeSession.open_port(spawn_args)
      now = DateTime.utc_now()

      session =
        session_config
        |> Map.put(:port, port)
        |> Map.put(:output_lines, [])
        |> Map.put(:line_buf, "")
        |> Map.put(:exit_status, nil)
        |> Map.put(:exited_at, nil)
        |> Map.put(:started_at, now)
        |> Map.put(:activity, "starting")
        |> Map.put(:activity_at, now)
        |> Map.put(:output_log, open_output_log(state))

      sessions = Map.put(state.claude_sessions, port, session)

      # Mark the worker claude-driven so views can show the live activity
      # signal (mirrored below) instead of a frozen workflow step — the
      # claude-driven Driver never ticks the Machine. See bd-c919xj.
      #
      # Also stash the spawn args so the commit-gate (bd-ofql8k) can re-launch
      # the worker with a nudge prompt when arb-done arrives with uncommitted
      # work, without round-tripping through the workspace-aware Dispatch builder
      # that does not know how to swap the prompt mid-session.
      meta =
        (state.meta || %{})
        |> Map.put(:claude_session, true)
        |> Map.put(:claude_spawn, pristine_args)
        |> Map.delete(:resume_session_id)

      new_state = %State{state | claude_sessions: sessions, meta: meta}
      new_state = sync_session_meta(new_state, port)

      {:reply, {:ok, port}, new_state}
    rescue
      e -> {:reply, {:error, {:port_open_failed, Exception.message(e)}}, state}
    end
  end

  # bd-1z7624: build the spawn argv for the first session, injecting
  # `--resume <session_id>` when this worker was started for a session-level
  # resume. Returns `{spawn_args, pristine_args}`: `spawn_args` carries the
  # `--resume` flag (+ the terse continue prompt) for THIS launch, `pristine_args`
  # is the untouched argv to stash as :claude_spawn so later auto-resumes rebuild
  # cleanly. With no resume marker — or a custom/fixture argv lacking a `--print`
  # slot — both are the original args (no injection).
  defp resume_spawn_args(%State{meta: meta} = state, port_args) do
    case meta && Map.get(meta, :resume_session_id) do
      sid when is_binary(sid) and sid != "" ->
        case inject_resume_argv(port_args, sid, continue_prompt(state)) do
          {:ok, resumed_args} ->
            Logger.info(
              "Worker: bd-1z7624 session-resume task=#{state.task_id} session=#{sid}"
            )

            {resumed_args, port_args}

          _ ->
            {port_args, port_args}
        end

      _ ->
        {port_args, port_args}
    end
  end

  # ---- Port message routing (Claude session I/O) -------------------------

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %State{} = state) when is_port(port) do
    {:noreply, on_port_data(state, port, line, true)}
  end

  def handle_info({port, {:data, {:noeol, partial}}}, %State{} = state) when is_port(port) do
    {:noreply, on_port_data(state, port, partial, false)}
  end

  def handle_info({port, {:exit_status, status}}, %State{} = state) when is_port(port) do
    case Map.fetch(state.claude_sessions, port) do
      {:ok, session} ->
        updated = Arbiter.Worker.ClaudeSession.handle_exit(session, status)
        sessions = Map.put(state.claude_sessions, port, updated)
        new_state = %State{state | claude_sessions: sessions}
        record_usage_event(new_state, updated, status)
        new_state = sync_session_meta(new_state, port)

        # bd-awi4nw: the port closing is the PRIMARY stop signal. If the worker
        # is still in a live state, the worker died/stopped without completing
        # (token exhaustion, crash, kill, flag-rejection). Don't strand the task
        # at a silent in_progress — schedule a classify+escalate after a short
        # grace so an in-flight `arb done` (which the exit_status message can
        # race ahead of) still wins and the check no-ops on a normal completion.
        if new_state.status in @live_statuses do
          Process.send_after(self(), {:__acolyte_stopped__, port}, exit_grace_ms())
        end

        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  # Deferred stop check (scheduled by the exit_status handler). By now an
  # in-flight `arb done` has been processed: if the worker moved to a
  # terminal/review state, the exit was the expected end of a normal completion
  # — nothing to do. Otherwise the subprocess is genuinely gone with the task
  # unfinished: classify the cause from exit status + captured output and fail +
  # escalate to the Admiral (bd-awi4nw).
  #
  # bd-1pdyov: a stop check must consider the WHOLE run, not just the one port
  # that closed. A single task run can span multiple ClaudeSession ports — the
  # commit-gate nudge (respawn_with_commit_nudge/2) opens a continuation session
  # in the same worktree, and `arb resume` re-attaches a fresh one. When the
  # primary session's port exits while a continuation is still mid-run, this
  # check fires after the short grace and would falsely fail work the live
  # continuation is about to finish. Two guards before failing:
  #
  #   1. another session is still live (its port hasn't exited) → the run isn't
  #      over; no-op and let the live session drive the outcome.
  #   2. the run already signalled `arb done` somewhere (primary OR continuation)
  #      → prefer completion. Re-enter on_claude_done so the commit gate decides:
  #      committed work routes to the ReviewGate, uncommitted work still diverts.
  def handle_info({:__acolyte_stopped__, port}, %State{status: status} = state)
      when status in @live_statuses do
    case Map.fetch(state.claude_sessions, port) do
      {:ok, session} ->
        cond do
          other_session_live?(state, port) ->
            {:noreply, state}

          run_signalled_done?(state) ->
            {:noreply, on_claude_done(state)}

          # bd-2da6ay: a non-reviewable `task`-type worker whose subprocess
          # exited cleanly (status 0) at wrap-up without ever printing `arb
          # done`. Its deliverable is a findings summary in `notes`, NOT a
          # worktree change — so a clean exit means the agent reached the end of
          # its work and quit; it just never emitted the sentinel. Resuming
          # (bd-t9uq25) only replays the identical clean exit, burning Opus on a
          # loop that can never converge (observed: 3× on bd-8ggqep, ~$6.28).
          # Finalize deterministically through the same notes gate `arb done`
          # uses instead: populated notes complete the task; blank notes nudge
          # up to the cap then escalate with a concrete cause. Infra failures
          # (auth/credit/rate/killed/crashed) are NOT clean exits, so they fall
          # through to the resume/fail_stopped path and keep their specific
          # escalations (e.g. the credential watchdog).
          task_type?(state.meta) and not review_only?(state.meta) and
              clean_exit_without_done?(session) ->
            {:noreply, finalize_task_type_stop(state)}

          true ->
            # bd-t9uq25: exited without `arb done` — try to resume the session
            # in place (bounded) before failing + discarding the worktree.
            {:noreply, maybe_resume_continuation(state, session)}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:__acolyte_stopped__, _port}, %State{} = state) do
    # The worker completed (arb done won the race) or already failed — the
    # subprocess exit was expected. No escalation.
    {:noreply, state}
  end

  def handle_info({:__claude_session_done__, _line}, %State{status: status} = state)
      when status not in [:completed, :failed, :awaiting_review_gate, :awaiting_review] do
    # "arb done" detected. The guard accepts most non-terminal statuses
    # (:idle, :running, :awaiting). In claude_driven mode the worker may sit at
    # :idle (the Machine is not ticked, so Worker.advance is never called), so
    # accepting :idle here is intentional and critical for this signal to fire.
    #
    # :awaiting_review_gate and :awaiting_review are deliberately excluded: once the
    # worker has signalled done, the review gate (ReviewGate) and then the merger
    # / Watchdog decide completion — not a repeated "arb done" on the author's
    # stdout. A late marker is ignored (handled by the catch-all clause below).
    #
    # bd-1pdyov: stamp :done_seen so a later whole-run stop check (e.g. a primary
    # port that exits after the commit gate diverted to a continuation) can tell
    # the run signalled done and prefer completion over a false stop failure.
    {:noreply, on_claude_done(mark_done_seen(state))}
  end

  def handle_info({:__claude_session_done__, _line}, %State{} = state) do
    # Already :completed / :failed / awaiting a downstream gate — ignore the
    # duplicate signal for transition purposes, but still record that the marker
    # was seen (bd-1pdyov) so the whole-run check has a complete picture.
    {:noreply, mark_done_seen(state)}
  end

  # The ReviewGate (review gate) exited before delivering a verdict. Do NOT strand
  # the author at :awaiting_review_gate — treat it as an inconclusive review and
  # escalate (no merge). Matched by the monitor ref stashed in meta. bd-2y0gd5.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{status: :awaiting_review_gate, meta: %{review_gate_ref: ref}} = state
      ) do
    Logger.warning(
      "Worker: ReviewGate for task=#{state.task_id} exited before a verdict " <>
        "(#{inspect(reason)}); escalating as no_verdict"
    )

    {:noreply,
     apply_review_gate_verdict(
       state,
       {:no_verdict,
        "ReviewGate process exited before delivering a verdict (#{inspect(reason)})."}
     )}
  end

  # Any other monitor DOWN (the ReviewGate's expected exit AFTER a verdict, or an
  # unrelated monitor) — nothing to do.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # ---- helpers -----------------------------------------------------------

  defp on_port_data(%State{} = state, port, fragment, eol?) do
    case Map.fetch(state.claude_sessions, port) do
      {:ok, session} ->
        updated = Arbiter.Worker.ClaudeSession.handle_data(session, fragment, eol?)
        sessions = Map.put(state.claude_sessions, port, updated)
        new_state = %State{state | claude_sessions: sessions}
        sync_session_meta(new_state, port)

      :error ->
        state
    end
  end

  # Mirror the most useful session fields (output_lines, exit_status) into the
  # top-level meta so callers reading `Worker.state(pid).meta` see them
  # without having to know about the internal :claude_sessions map.
  # When there are multiple concurrent sessions this surfaces the most recent
  # one; for now there's only ever one.
  defp sync_session_meta(%State{claude_sessions: sessions, meta: meta} = state, port) do
    case Map.get(sessions, port) do
      %{} = session ->
        new_activity = Map.get(session, :activity)
        old_activity = Map.get(meta, :activity)

        # Extract model from multiple possible sources, in order of preference
        session_model =
          case Map.get(session, :usage) do
            %{} = usage -> Map.get(usage, :model)
            _ -> nil
          end

        model = session_model || Map.get(session, :model)
        had_model? = not is_nil(Map.get(meta, :model))

        meta =
          meta
          |> Map.put(:output_lines, Enum.reverse(session.output_lines))
          |> Map.put(:exit_status, session.exit_status)
          |> maybe_put(:activity, new_activity)
          |> maybe_put(:activity_at, Map.get(session, :activity_at))
          |> maybe_put(:exited_at, session.exited_at)
          |> maybe_put(:model, model)
          |> maybe_put(:provider, Map.get(session, :provider))

        new_state = %State{state | meta: meta}

        if new_activity != old_activity do
          broadcast_lifecycle(:updated, new_state)
        end

        # Race-condition patch: if the worker already terminated (fail_now/complete_now
        # fired) but model arrived late via a subsequent session event, write just the
        # model column to the existing worker_runs row so it is never left NULL.
        if not had_model? and not is_nil(model) and
             new_state.status in [:completed, :failed] and
             not is_nil(new_state.run_id) do
          backfill_run_model(new_state.run_id, model, new_state.task_id)
        end

        new_state

      _ ->
        state
    end
  end

  defp backfill_run_model(run_id, model, task_id) do
    with {:ok, run} <- Ash.get(Arbiter.Workers.Run, run_id),
         {:ok, _updated} <- Ash.update(run, %{model: model}, action: :update) do
      :ok
    else
      {:error, reason} -> log_run_warning("backfill_model", task_id, reason)
    end
  rescue
    e -> log_run_warning("backfill_model", task_id, e)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---- terminal transitions ----------------------------------------------
  #
  # complete_now/2 and fail_now/2 hold the terminal side effects (DB write +
  # broadcast/notify) in one place, shared by the public complete/2 + fail/2
  # calls and the worker-completion (arb-done) path.

  defp complete_now(%State{} = state, result) do
    meta = if is_nil(result), do: state.meta, else: Map.put(state.meta, :result, result)
    new_state = %State{state | status: :completed, meta: meta}
    record_run_finished(new_state)
    broadcast_done(new_state)
    new_state
  end

  defp fail_now(%State{} = state, reason) do
    meta = if is_nil(reason), do: state.meta, else: Map.put(state.meta, :failure_reason, reason)
    new_state = %State{state | status: :failed, meta: meta}
    record_run_finished(new_state)
    Arbiter.Messages.AdmiralNotifier.failed(snapshot(new_state))
    broadcast_worker_failed(new_state)
    new_state
  end

  # bd-awi4nw: a stopped/dead worker detected via the closed port. Classify the
  # stop from the exit status + captured output, fail the worker into an
  # obviously-stalled state (not silent in_progress), and raise an addressed
  # Admiral escalation naming the task + cause + remediation. Distinct from
  # fail_now/2's generic "exit code N" notification: the StopReason carries the
  # actionable classification (auth expiry, credit exhaustion, kill, …).
  #
  # bd-5wchp1: when the stop category is :auth_expired, also notify the
  # CredentialWatchdog so it records the expiry and blocks future dispatches
  # immediately, without waiting for the next periodic probe.
  defp fail_stopped(%State{} = state, session) do
    exit_status = Map.get(session, :exit_status)
    output_lines = Enum.reverse(Map.get(session, :output_lines, []))
    reason = Arbiter.Worker.StopReason.classify(exit_status, output_lines)

    Logger.warning(
      "Worker: worker for task=#{state.task_id} stopped — #{Arbiter.Worker.StopReason.label(reason)}"
    )

    if reason.category == :auth_expired do
      notify_credential_watchdog(state, reason)
    end

    meta =
      state.meta
      |> Map.put(:failure_reason, reason.summary)
      |> Map.put(:stop_reason, Arbiter.Worker.StopReason.to_map(reason))

    new_state = %State{state | status: :failed, meta: meta}
    record_run_finished(new_state)
    Arbiter.Messages.AdmiralNotifier.acolyte_stopped(snapshot(new_state), reason)
    broadcast_lifecycle(:updated, new_state)
    broadcast_worker_failed(new_state)
    new_state
  end

  # Resolve the agent adapter from the worker's routing config (set by Dispatch
  # via Worker.report/3) and notify the CredentialWatchdog. Best-effort —
  # missing routing info or an unknown provider just skips the notification.
  defp notify_credential_watchdog(%State{meta: meta}, reason) do
    provider = meta && (Map.get(meta, :routing_config) || %{}) |> Map.get(:provider)

    adapter =
      if is_binary(provider) do
        try do
          Arbiter.Agents.adapters()[String.to_existing_atom(provider)]
        rescue
          _ -> nil
        end
      end

    if is_atom(adapter) and not is_nil(adapter) do
      Arbiter.Agents.CredentialWatchdog.mark_expired(adapter, reason)
    end
  end

  defp exit_grace_ms do
    Application.get_env(:arbiter, :worker_exit_grace_ms, @exit_grace_ms)
  end

  # bd-1pdyov: is a Claude session OTHER than the one that just exited still
  # running? Its port has not yet reported an exit_status. A continuation /
  # resume session opened by the commit-gate nudge (respawn_with_commit_nudge/2)
  # is exactly this — the primary port exits while the continuation is mid-run.
  # While one is live the task run is not over, so a per-port stop check must
  # not fail it.
  defp other_session_live?(%State{claude_sessions: sessions}, exited_port) do
    Enum.any?(sessions, fn {port, session} ->
      port != exited_port and is_nil(Map.get(session, :exit_status))
    end)
  end

  # bd-1pdyov: did any session in this run (primary or continuation/resume)
  # signal `arb done`? Keys off the :done_seen flag stamped in the
  # __claude_session_done__ handler, which fires ONLY for the assistant-scoped,
  # word-bounded marker (claude_session.ex emits the done message exclusively for
  # assistant text / the raw-line fallback, never for tool calls or tool
  # results). Scanning the raw output buffer instead would re-admit the mid-task
  # false positive the live detector guards against (an worker that cats/echoes
  # "arb done"), so we deliberately rely on the already-scoped signal.
  defp run_signalled_done?(%State{meta: meta}), do: Map.get(meta || %{}, :done_seen, false)

  defp mark_done_seen(%State{meta: meta} = state),
    do: %State{state | meta: Map.put(meta || %{}, :done_seen, true)}

  # Handle the worker's "arb done" marker. Before bd-7qq81g this closed the task
  # directly, bypassing the merger entirely — branches never reached the target
  # line. Completion now routes through the configured merger:
  #
  #   * When the worker knows its branch (a worktree was provisioned) we open
  #     the MR / run the merge via the same path open_mr/5 uses. For the default
  #     Direct strategy this merges --no-ff into the target branch synchronously,
  #     parks at :awaiting_review, and the Watchdog completes the worker on its
  #     first poll. A merge failure surfaces as a :failure_reason rather than
  #     silently closing the task as done.
  #   * With no branch (ad-hoc runs / unconfigured repo / no worktree) there is
  #     nothing to integrate. For review_only workers this is the expected path
  #     (coordinator-dispatched reviewers have no worktree). When the reviewer
  #     produced an APPROVE verdict, trigger the Watchdog on the task's pr_ref so
  #     the PR is merged automatically (bd-4ji58d). For REQUEST_CHANGES or no
  #     parseable verdict, fail the worker so the task stays :in_progress for a
  #     fix-pass rather than silently closing with the PR unreviewed. Non-review
  #     workers with no branch complete directly as before.
  defp on_claude_done(%State{meta: meta} = state) do
    cond do
      # bd-5lc99r: a `task` issue type is non-reviewable ops/research/spike work.
      # It produces a findings summary in `notes`, NOT a code change — so there
      # is no commit gate, no review gate, no PR, and no merge. The only gate is
      # the notes gate: refuse to let `arb done` close the directive until the
      # acolyte has written its findings to `notes`. Then complete directly,
      # regardless of whether a worktree/branch exists (the worktree is optional
      # for a task and is never integrated).
      task_type?(meta) and not review_only?(meta) ->
        case notes_gate(state) do
          :ok -> complete_now(state, :claude_done)
          {:gate, :blank} -> handle_notes_gate(state)
        end

      true ->
        on_claude_done_reviewable(state, meta)
    end
  end

  defp on_claude_done_reviewable(%State{} = state, meta) do
    case mergeable_branch(meta) do
      nil ->
        if review_only?(meta) do
          route_reviewer_completion(state)
        else
          complete_now(state, :claude_done)
        end

      branch ->
        # Skip commit gate for review-only workers (reviewers make no commits
        # by design) — reviewers operate on a pre-existing branch and analyze
        # diffs without authoring code.
        if review_only?(meta) do
          route_completion(state, branch)
        else
          # bd-ofql8k: before routing to the ReviewGate (which diffs the per-task
          # branch's COMMITTED history) or the merger, check that the worktree is
          # actually in a reviewable state — clean tree AND ≥1 commit ahead of the
          # target. The repeated failure mode this guards against: the worker
          # edits files correctly but never `git commit`s them; HEAD stays at the
          # base branch with the work sitting uncommitted in the worktree; the
          # reviewer diffs `base..HEAD`, sees empty, and concludes "no code
          # exists" — sitting on the uncommitted changes and ignoring them.
          case commit_gate(state) do
            :ok ->
              route_completion(state, branch)

            {:gate, reason} ->
              handle_commit_gate(state, branch, reason)
          end
        end
    end
  end

  defp route_completion(%State{meta: meta} = state, branch) do
    if review_required?(state) do
      # Standing order: don't merge unreviewed work. Park at :awaiting_review_gate
      # and let a distinct reviewer worker judge the diff first. The merge
      # fires only on review_gate_verdict/2 :approve.
      enter_review_gate(state, branch)
    else
      merge_branch(state, branch, merge_opts_from_meta(meta, %{}))
    end
  end

  # ---- coordinator-dispatched reviewer completion (bd-4ji58d) ---------------

  # For review_only workers with no branch (the coordinator-dispatch path via
  # `worker_review` / `arb worker review`): parse the APPROVE / REQUEST_CHANGES
  # verdict from the reviewer's captured output and act on it.
  #
  # APPROVE → complete the worker so the Driver closes the task. The review has
  # already been posted to the forge by the reviewer; a coordinator-dispatched
  # reviewer must NEVER merge the PR (bd-ddtbhb). The full ReviewGate merge
  # path (fleet-authored work) is a separate path and is unaffected.
  #
  # REQUEST_CHANGES / :no_verdict → fail the worker (not complete it) so the
  # Driver does NOT close the task. The task stays :in_progress for the
  # coordinator to dispatch a fix-pass. Mirrors park_rejected/3 from the full
  # review_gate path.
  #
  # bd-btcyn6: when no VERDICT sentinel is found in stdout (e.g. the reviewer
  # submitted via the adapter/CLI without printing the required sentinel), fall
  # back to querying the merger adapter for the PR's submitted review state. This
  # treats the adapter submission as the source of truth and avoids landing
  # INCONCLUSIVE when the review genuinely went out.
  defp route_reviewer_completion(%State{} = state) do
    output_lines = Map.get(state.meta || %{}, :output_lines, [])

    case Arbiter.Worker.ReviewGate.parse_verdict(output_lines) do
      {:approve, _findings} ->
        trigger_watchdog_on_approval(state)

      {:request_changes, findings} ->
        park_rejected(state, :request_changes, findings)

      :no_verdict ->
        case derive_verdict_from_adapter(state) do
          {:approve, _} ->
            Logger.info(
              "Worker: review_only task=#{state.task_id}: no VERDICT sentinel in stdout; " <>
                "derived APPROVE from adapter-submitted review"
            )

            trigger_watchdog_on_approval(state)

          {:request_changes, findings} ->
            Logger.info(
              "Worker: review_only task=#{state.task_id}: no VERDICT sentinel in stdout; " <>
                "derived REQUEST_CHANGES from adapter-submitted review"
            )

            park_rejected(state, :request_changes, findings)

          :no_verdict ->
            park_rejected(state, :no_verdict, "Reviewer produced no parseable VERDICT line.")
        end
    end
  end

  # bd-btcyn6: attempt to derive the review verdict from the adapter's PR review
  # state when the reviewer's stdout lacks the VERDICT sentinel. Queries the
  # merger adapter for the task's pr_ref reviews; maps the forge state to the
  # internal verdict type. Returns :no_verdict on any error or when no review
  # is found so the caller can fall through to INCONCLUSIVE.
  defp derive_verdict_from_adapter(%State{task_id: task_id} = state) do
    with {:ok, pr_ref} <- fetch_task_pr_ref(task_id),
         {:ok, adapter, _workspace} <-
           resolve_merger(state, merge_opts_from_meta(state.meta, %{})),
         {:ok, feedback} <- safe_list_review_feedback(adapter, pr_ref) do
      reviews = Enum.filter(Map.get(feedback, :feedback, []), &(&1[:kind] == :review))

      cond do
        Enum.any?(reviews, &(&1[:state] == "APPROVED")) ->
          {:approve, ""}

        Map.get(feedback, :changes_requested) ->
          body =
            reviews
            |> Enum.filter(&(&1[:state] == "CHANGES_REQUESTED"))
            |> Enum.map_join("\n", &Map.get(&1, :body, ""))

          {:request_changes, body}

        true ->
          :no_verdict
      end
    else
      _ -> :no_verdict
    end
  end

  defp safe_list_review_feedback(adapter, pr_ref) do
    adapter.list_review_feedback(pr_ref)
  rescue
    _ -> {:error, :exception}
  catch
    :exit, _ -> {:error, :exit}
  end

  # APPROVE path for a coordinator-dispatched review_only worker. The reviewer
  # has already posted the forge-level review approval. Complete the worker so
  # the Driver closes the task, and also signal MergeQueue to adopt and merge
  # the PR according to the workspace's auto-merge policy. (bd-ddtbhb, bd-bs3z04)
  defp trigger_watchdog_on_approval(%State{} = state) do
    new_state = complete_now(state, :claude_done)
    maybe_enqueue_approved_pr(new_state)
    new_state
  end

  # Broadcast {:worker_done, task_id} to the workspace MergeQueue when the
  # coordinator reviewer approves a task that already has a PR open. This lets
  # the workspace's auto-merge policy drive the merge now that the forge-level
  # approval has been submitted. Skipped when workspace_id is nil or no pr_ref.
  defp maybe_enqueue_approved_pr(%State{workspace_id: ws_id, task_id: task_id})
       when is_binary(ws_id) do
    with {:ok, _pr_ref} <- fetch_task_pr_ref(task_id) do
      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        "worker:done:" <> ws_id,
        {:worker_done, task_id}
      )
    end

    :ok
  end

  defp maybe_enqueue_approved_pr(_), do: :ok

  # Load the pr_ref from the task's current DB record. Returns {:ok, pr_ref}
  # when present, {:error, :no_pr_ref} when nil/blank, and {:error, reason}
  # on any other failure. Best-effort: callers fall back to a plain complete.
  defp fetch_task_pr_ref(task_id) do
    case Ash.get(Arbiter.Tasks.Issue, task_id) do
      {:ok, %{pr_ref: pr_ref}} when is_binary(pr_ref) and pr_ref != "" ->
        {:ok, pr_ref}

      {:ok, _} ->
        {:error, :no_pr_ref}

      {:error, _} = err ->
        err
    end
  rescue
    _ -> {:error, :exception}
  end

  # bd-ofql8k commit gate. Returns `:ok` to proceed, or `{:gate, :uncommitted |
  # :no_commits}` to divert. We only gate when:
  #
  #   * a worktree is configured and exists on disk, AND
  #   * the worktree is actually checked out on the per-task branch.
  #
  # The branch check exists because some test setups (notably ReviewGateTest)
  # reuse the repo itself as the "worktree" with `worktree_path: repo` and a
  # feature branch that was created on the repo but left checked-out elsewhere.
  # In that case the worktree's HEAD is some other branch (usually `main`) and
  # `git rev-list main..HEAD` is meaningless — gating on it would manufacture
  # false `:no_commits` trips. Production worktrees provisioned via
  # `Worktree.create/3` are always checked out on the per-task branch, so the
  # gate fires there as intended.
  #
  # ad-hoc runs without a provisioned worktree (no `:worktree_path` in meta)
  # fall through to the legacy path. git failures fail open: a transient git
  # hiccup must not strand a real completion.
  defp commit_gate(%State{meta: meta}) do
    worktree = meta && Map.get(meta, :worktree_path)
    target = (meta && Map.get(meta, :target_branch)) || "main"
    expected = meta && Map.get(meta, :branch)

    cond do
      is_binary(worktree) and File.dir?(worktree) and
          worktree_on_branch?(worktree, expected) ->
        case Arbiter.Worker.Worktree.completion_state(worktree, target) do
          {:ok, :ready} -> :ok
          {:ok, :uncommitted} -> {:gate, :uncommitted}
          {:ok, :no_commits} -> {:gate, :no_commits}
          {:error, _} -> :ok
        end

      true ->
        :ok
    end
  end

  defp worktree_on_branch?(_path, nil), do: false
  defp worktree_on_branch?(_path, ""), do: false

  defp worktree_on_branch?(path, expected) when is_binary(expected) do
    case Arbiter.Worker.Worktree.current_branch(path) do
      {:ok, ^expected} -> true
      _ -> false
    end
  end

  # The worker signalled done but the worktree isn't in a reviewable state.
  # First try a single bounded "send-back" nudge — relaunch the worker with a
  # short prompt telling it exactly what's missing (commit + push, or "you
  # printed `arb done` without making any commits") so the same mind that did
  # the work can fix the omission. Cap is `meta[:commit_nudge_cap]`, default 1;
  # tests pass 0 to assert the structural gate without the retry layer.
  #
  # If nothing usable is captured to relaunch with, OR the cap is exhausted, we
  # fail_now WITHOUT routing to the ReviewGate: a stale, empty `base..HEAD` diff
  # must not reach a reviewer who will report "no work" while the work is right
  # there in the worktree.
  defp handle_commit_gate(%State{meta: meta} = state, _branch, reason) do
    cap = (meta && Map.get(meta, :commit_nudge_cap)) || 1
    attempts = (meta && Map.get(meta, :commit_nudge_attempts)) || 0

    cond do
      attempts >= cap ->
        park_commit_gate(state, reason, :cap_exhausted)

      true ->
        case respawn_with_commit_nudge(state, reason) do
          {:ok, new_state} ->
            new_state

          {:error, why} ->
            park_commit_gate(state, reason, {:respawn_failed, why})
        end
    end
  end

  # Build a nudge prompt + port_args from the stashed claude_spawn and relaunch
  # a fresh claude session in the same worktree. The mailbox/nudge prompt is
  # short and direct: it names the gate-trip reason and the exact action
  # required, then asks the worker to print `arb done` again only after the
  # commit lands.
  #
  # The stashed argv must be the streaming `claude` invocation built by
  # `Arbiter.Worker.ClaudeSession.default_claude_argv/1` (a `sh -c 'exec "$@"
  # < /dev/null' sh claude --print <prompt> ...`) for the prompt-swap to work.
  # When the argv is a test fixture (`claude_command:` opt) we re-run the same
  # argv so a fixture-based test exercises the gate-retry-then-fail cycle
  # without us second-guessing what the fixture does.
  defp respawn_with_commit_nudge(%State{} = state, reason) do
    respawn_with_nudge(state, commit_nudge_prompt(state, reason),
      attempts_key: :commit_nudge_attempts,
      label: "bd-ofql8k commit gate tripped (#{reason})"
    )
  end

  # Shared relaunch mechanism for the gate nudges (commit gate bd-ofql8k, notes
  # gate bd-5lc99r). Swaps the nudge prompt into the stashed claude argv, opens
  # a fresh port in the same cwd, and bumps the gate-specific attempt counter so
  # the cap in the caller bounds the retry loop.
  defp respawn_with_nudge(%State{meta: meta} = state, nudge, opts) do
    attempts_key = Keyword.fetch!(opts, :attempts_key)
    label = Keyword.get(opts, :label, "gate")
    spawn_args = meta && Map.get(meta, :claude_spawn)

    with %{} = port_args <- spawn_args || :no_spawn_args,
         {:ok, new_args} <- inject_nudge_argv(port_args, nudge),
         {:ok, port} <- safe_open_port(new_args) do
      next_attempts = ((meta && Map.get(meta, attempts_key)) || 0) + 1

      Logger.info(
        "Worker: #{label} for task=#{state.task_id}; " <>
          "relaunching worker with nudge (attempt #{next_attempts})"
      )

      session_config = %{
        task_id: state.task_id,
        topic: "worker:" <> state.task_id,
        line_cap: Arbiter.Worker.ClaudeSession.line_cap(),
        done_regex: Arbiter.Worker.ClaudeSession.done_regex()
      }

      now = DateTime.utc_now()

      session =
        session_config
        |> Map.put(:port, port)
        |> Map.put(:output_lines, [])
        |> Map.put(:line_buf, "")
        |> Map.put(:exit_status, nil)
        |> Map.put(:exited_at, nil)
        |> Map.put(:started_at, now)
        |> Map.put(:activity, "starting")
        |> Map.put(:activity_at, now)
        |> Map.put(:output_log, open_output_log(state))

      new_meta =
        meta
        |> Map.put(attempts_key, next_attempts)
        |> Map.put(:claude_spawn, new_args)

      sessions = Map.put(state.claude_sessions, port, session)

      {:ok,
       %State{
         state
         | claude_sessions: sessions,
           meta: new_meta,
           status: :running,
           step_started_at: DateTime.utc_now()
       }}
    else
      :no_spawn_args -> {:error, :no_spawn_args}
      {:error, _} = err -> err
      other -> {:error, {:unexpected, other}}
    end
  end

  defp commit_nudge_cap(meta), do: (meta && Map.get(meta, :commit_nudge_cap)) || 1

  defp safe_open_port(port_args) do
    {:ok, Arbiter.Worker.ClaudeSession.open_port(port_args)}
  rescue
    e -> {:error, {:port_open_failed, Exception.message(e)}}
  end

  # Swap the prompt in a stashed argv. Real claude argv from
  # `default_claude_argv/1` looks like:
  #
  #   ["sh", "-c", "exec \"$@\" < /dev/null", "sh", <claude>, "--print", <prompt>, ...]
  #
  # We locate `--print` and replace the following element. If no `--print` slot
  # is present (test fixtures, custom commands) we accept the argv unchanged
  # and rely on the fixture to honor a re-run; the cap then bounds how many
  # times we try.
  defp inject_nudge_argv(%{argv: argv} = port_args, nudge) when is_list(argv) do
    new_argv =
      case Enum.find_index(argv, &(&1 == "--print")) do
        nil ->
          argv

        idx when idx + 1 < length(argv) ->
          List.replace_at(argv, idx + 1, nudge)

        _ ->
          argv
      end

    {:ok, %{port_args | argv: new_argv}}
  end

  defp inject_nudge_argv(_port_args, _nudge), do: {:error, :missing_argv}

  defp commit_nudge_prompt(%State{task_id: task_id, meta: meta}, :uncommitted) do
    branch = (meta && Map.get(meta, :branch)) || "(your branch)"

    """
    bd-ofql8k commit gate: you printed `arb done` for task #{task_id}, but the
    worktree on branch `#{branch}` has uncommitted changes (staged, unstaged,
    or untracked). The review gate diffs `base..HEAD` — committed history
    only — so without commits your work is invisible and the reviewer would
    report "no code exists" while sitting on your edits.

    Do EXACTLY this, then print `arb done` again on its own line:

      1. `git status` to see what is uncommitted.
      2. `git add -A`
      3. `git commit -m "<a short message describing the work>"`
      4. (`git push -u origin #{branch}` is OPTIONAL — the arbiter pushes /
         opens the MR for you on merge.)

    Do not redo the work — just commit what is already on disk. If a hunk in
    the diff looks half-finished or wrong, finish it first, then commit.
    """
  end

  defp commit_nudge_prompt(%State{task_id: task_id, meta: meta}, :no_commits) do
    branch = (meta && Map.get(meta, :branch)) || "(your branch)"
    target = (meta && Map.get(meta, :target_branch)) || "main"

    """
    bd-ofql8k commit gate: you printed `arb done` for task #{task_id}, but
    branch `#{branch}` has no commits ahead of `#{target}`. Either no work
    was done, or your edits landed on a different branch. The review gate
    cannot proceed with a zero-commit branch.

    Inspect what happened:

      git status
      git log --oneline #{target}..HEAD
      git diff #{target}..HEAD

    If work IS on disk but uncommitted, commit it on `#{branch}`:

      git add -A
      git commit -m "<a short message>"

    If you skipped the work, do it now and commit. Then print `arb done`
    again on its own line.
    """
  end

  # ---- bd-5lc99r notes gate -------------------------------------------------
  #
  # A `task` issue type is non-reviewable ops/research/spike work whose
  # deliverable is a findings summary in the directive's `notes`, not a code
  # change. The notes gate is the task-type analogue of the commit gate: it
  # refuses to let `arb done` close the directive while `notes` is blank, and
  # reprompts the acolyte to write its findings via the `task_update_progress`
  # MCP tool.
  #
  # Returns `:ok` to proceed, or `{:gate, :blank}` to divert. A DB read failure
  # fails OPEN (mirrors the commit gate's git-failure policy): a transient hiccup
  # must not strand a real completion behind an unreadable directive.
  defp notes_gate(%State{task_id: task_id}) do
    case fetch_task_notes(task_id) do
      {:ok, notes} when is_binary(notes) ->
        if String.trim(notes) == "", do: {:gate, :blank}, else: :ok

      {:ok, _} ->
        {:gate, :blank}

      {:error, reason} ->
        Logger.warning(
          "Worker: bd-5lc99r notes gate could not read notes for task=#{task_id} " <>
            "(#{inspect(reason)}); failing open."
        )

        :ok
    end
  end

  defp fetch_task_notes(task_id) do
    case Ash.get(Arbiter.Tasks.Issue, task_id) do
      {:ok, %{notes: notes}} -> {:ok, notes}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  end

  # The worker signalled done on a task-type directive but `notes` is still
  # blank. Mirror the commit gate's bounded send-back: relaunch the same session
  # with a nudge telling it to write findings to `notes`, capped by
  # `meta[:notes_nudge_cap]` (default 1; tests pass 0 to assert the structural
  # gate without the retry layer). On cap exhaustion or a respawn failure, fail
  # the worker rather than silently close a directive with no deliverable.
  defp handle_notes_gate(%State{meta: meta} = state) do
    cap = notes_nudge_cap(meta)
    attempts = (meta && Map.get(meta, :notes_nudge_attempts)) || 0

    cond do
      attempts >= cap ->
        park_notes_gate(state, :cap_exhausted)

      true ->
        case respawn_with_notes_nudge(state) do
          {:ok, new_state} -> new_state
          {:error, why} -> park_notes_gate(state, {:respawn_failed, why})
        end
    end
  end

  defp respawn_with_notes_nudge(%State{} = state) do
    respawn_with_nudge(state, notes_nudge_prompt(state),
      attempts_key: :notes_nudge_attempts,
      label: "bd-5lc99r notes gate tripped (blank notes)"
    )
  end

  # bd-2da6ay: did the session that just closed exit cleanly (status 0) without
  # signalling `arb done` — i.e. the agent reached the end and quit, as opposed
  # to being killed / crashing / hitting an auth or rate-limit wall? Reuses the
  # exact StopReason classification the resume path keys off, scoped to the one
  # session. Only a clean exit routes a task-type worker through the notes gate;
  # every other category stays on the resume/fail_stopped path so its specific
  # escalation (credential watchdog, host-health) still fires.
  defp clean_exit_without_done?(session) do
    exit_status = Map.get(session, :exit_status)
    output_lines = Enum.reverse(Map.get(session, :output_lines, []))

    Arbiter.Worker.StopReason.classify(exit_status, output_lines).category ==
      :exited_without_done
  end

  # bd-2da6ay: finalize a task-type worker that exited without `arb done` by
  # routing through the same notes gate `arb done` itself uses. on_claude_done/1
  # for a task type either completes (notes populated — the findings exist, the
  # missing sentinel was just a handshake glitch) or diverts to the notes gate
  # (blank notes — nudge up to the cap, then park + escalate with a concrete
  # cause). Either way the task finalizes deterministically rather than silently
  # looping on resume.
  defp finalize_task_type_stop(%State{} = state) do
    Logger.info(
      "Worker: bd-2da6ay task=#{state.task_id} (task type) exited cleanly without " <>
        "`arb done`; finalizing through the notes gate instead of resuming."
    )

    on_claude_done(state)
  end

  defp notes_nudge_cap(meta), do: (meta && Map.get(meta, :notes_nudge_cap)) || 1

  defp notes_nudge_prompt(%State{task_id: task_id}) do
    """
    bd-5lc99r notes gate: you printed `arb done` for task #{task_id}, but this is
    a `task`-type directive whose deliverable is a findings summary written to
    the directive's `notes` field — and `notes` is still blank. A task produces
    no code change and no PR; the notes ARE the deliverable, so completion is
    blocked until they exist.

    Do EXACTLY this, then print `arb done` again on its own line:

      1. Call the `task_update_progress` MCP tool with its `notes` argument set
         to your findings / results summary for this directive (Markdown is fine).
      2. Make it self-contained: what you investigated, what you found, and any
         recommendation or conclusion the Admiral needs — they read it via
         `arb show #{task_id}` and the dashboard.

    Do NOT shell out to the `arb` CLI for the notes — use the MCP tool. Then
    print `arb done`.
    """
  end

  # ---- bd-t9uq25: resume a session that exited mid-task without `arb done` ----
  #
  # The deferred stop check routes here when a worker subprocess exits, no other
  # session is live, and the run never signalled `arb done`. Rather than failing
  # and discarding the (preserved) worktree, re-spawn the SAME Claude session via
  # `claude --print --resume <session_id> "<continue>"` so it picks up where it
  # left off (verified to preserve context headlessly under --print). Bounded two
  # ways so a stuck agent can't loop forever:
  #   * a hard attempt cap (`:resume_cap`, default 3), and
  #   * a no-progress guard: if a resumed session exits having changed nothing in
  #     the worktree (same fingerprint as when it started), stop and fail.
  # `:exited_without_done` and `:gateway_error` are auto-resumed; auth/credit/
  # rate/crash/kill fall straight through to fail_stopped.
  # gateway_error: the local proxy got a transient 502/503 from Anthropic; the
  # session context is intact so a `claude --resume` picks up where it left off
  # (bd-298jz0 investigation — Mode A from issue #512 harness safety net).
  @resumable_stop_categories [:exited_without_done, :gateway_error]

  defp maybe_resume_continuation(%State{meta: meta} = state, session) do
    exit_status = Map.get(session, :exit_status)
    output_lines = Enum.reverse(Map.get(session, :output_lines, []))
    reason = Arbiter.Worker.StopReason.classify(exit_status, output_lines)

    session_id =
      session |> Arbiter.Worker.ClaudeSession.usage_summary() |> Map.get(:session_id)

    cap = resume_cap(meta)
    attempts = (meta && Map.get(meta, :resume_attempts)) || 0
    prev_fp = meta && Map.get(meta, :resume_fingerprint)
    cur_fp = worktree_fingerprint(state)

    case resume_decision(reason.category, session_id, attempts, cap, prev_fp, cur_fp) do
      :resume ->
        case respawn_with_resume(state, session_id, cur_fp) do
          {:ok, new_state} -> new_state
          {:error, _why} -> fail_stopped(state, session)
        end

      {:fail, why} ->
        if why in [:cap_exhausted, :no_progress] do
          Logger.info(
            "Worker: task=#{state.task_id} not resuming (#{why}, attempt " <>
              "#{attempts}/#{cap}) — failing."
          )
        end

        fail_stopped(state, session)
    end
  end

  # Pure resume/fail decision — isolated so the guard logic (hard cap +
  # no-progress) is unit-testable without spawning a session. Returns `:resume`
  # or `{:fail, why}`.
  @doc false
  def resume_decision(category, session_id, attempts, cap, prev_fp, cur_fp) do
    cond do
      category not in @resumable_stop_categories -> {:fail, :not_resumable_category}
      is_nil(session_id) -> {:fail, :no_session_id}
      attempts >= cap -> {:fail, :cap_exhausted}
      attempts > 0 and not is_nil(prev_fp) and cur_fp == prev_fp -> {:fail, :no_progress}
      true -> :resume
    end
  end

  # Re-spawn Claude against the SAME session id with a terse "keep going" prompt,
  # in the same worktree. Mirrors respawn_with_commit_nudge/2 but injects
  # `--resume <session_id>` and does NOT persist the resume argv onto
  # :claude_spawn — each resume rebuilds from the pristine spawn args + the
  # latest session id, so we never stack multiple `--resume` flags.
  defp respawn_with_resume(%State{meta: meta} = state, session_id, fingerprint) do
    spawn_args = meta && Map.get(meta, :claude_spawn)
    prompt = continue_prompt(state)

    with %{} = port_args <- spawn_args || :no_spawn_args,
         {:ok, new_args} <- inject_resume_argv(port_args, session_id, prompt),
         {:ok, port} <- safe_open_port(new_args) do
      next_attempts = ((meta && Map.get(meta, :resume_attempts)) || 0) + 1

      Logger.info(
        "Worker: bd-t9uq25 resuming task=#{state.task_id} session=#{session_id} " <>
          "(attempt #{next_attempts}/#{resume_cap(meta)})"
      )

      now = DateTime.utc_now()

      session =
        %{
          task_id: state.task_id,
          topic: "worker:" <> state.task_id,
          line_cap: Arbiter.Worker.ClaudeSession.line_cap(),
          done_regex: Arbiter.Worker.ClaudeSession.done_regex()
        }
        |> Map.put(:port, port)
        |> Map.put(:output_lines, [])
        |> Map.put(:line_buf, "")
        |> Map.put(:exit_status, nil)
        |> Map.put(:exited_at, nil)
        |> Map.put(:started_at, now)
        |> Map.put(:activity, "resuming")
        |> Map.put(:activity_at, now)
        |> Map.put(:output_log, open_output_log(state))

      new_meta =
        (meta || %{})
        |> Map.put(:resume_attempts, next_attempts)
        |> Map.put(:resume_fingerprint, fingerprint)

      sessions = Map.put(state.claude_sessions, port, session)

      {:ok,
       %State{
         state
         | claude_sessions: sessions,
           meta: new_meta,
           status: :running,
           step_started_at: now
       }}
    else
      :no_spawn_args -> {:error, :no_spawn_args}
      {:error, _} = err -> err
      other -> {:error, {:unexpected, other}}
    end
  end

  defp resume_cap(meta) do
    (meta && Map.get(meta, :resume_cap)) ||
      Application.get_env(:arbiter, :worker_resume_cap, 3)
  end

  # Insert `--resume <session_id>` immediately after `--print` and swap the
  # prompt that follows it (same argv shape as inject_nudge_argv/2). No `--print`
  # slot (test fixtures / custom commands) → can't build a resume invocation, so
  # the caller falls back to failing.
  @doc false
  def inject_resume_argv(%{argv: argv} = port_args, session_id, prompt)
       when is_list(argv) and is_binary(session_id) do
    case Enum.find_index(argv, &(&1 == "--print")) do
      nil ->
        {:error, :no_print_slot}

      idx when idx + 1 < length(argv) ->
        {before, [_old_prompt | after_prompt]} = Enum.split(argv, idx + 1)
        new_argv = before ++ ["--resume", session_id, prompt] ++ after_prompt
        {:ok, %{port_args | argv: new_argv}}

      _ ->
        {:error, :no_print_slot}
    end
  end

  def inject_resume_argv(_port_args, _session_id, _prompt), do: {:error, :missing_argv}

  defp continue_prompt(%State{task_id: task_id}) do
    """
    Your previous session for task #{task_id} ended before you finished — you
    did not print `arb done`. Your work so far is preserved in this worktree.
    Pick up exactly where you left off, complete the remaining work, and when the
    task is fully done print `arb done` on its own line.
    """
  end

  # A content fingerprint of the worktree's work-in-progress: HEAD commit +
  # tracked diff vs HEAD + the set of untracked files. The no-progress guard
  # compares it across a resume — an identical fingerprint means the resumed
  # session changed nothing. nil when there's no worktree on disk (the hard cap
  # still bounds attempts).
  defp worktree_fingerprint(%State{meta: meta}) do
    worktree = meta && Map.get(meta, :worktree_path)

    if is_binary(worktree) and File.dir?(worktree) do
      payload =
        [
          git_out(worktree, ["rev-parse", "HEAD"]),
          git_out(worktree, ["diff", "HEAD"]),
          git_out(worktree, ["ls-files", "--others", "--exclude-standard"])
        ]
        |> Enum.join("\n")

      :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    end
  end

  defp git_out(worktree, args) do
    case System.cmd("git", ["-C", worktree | args], stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> ""
    end
  rescue
    _ -> ""
  end

  # Final park: record on the task, escalate to the Admiral, fail the worker.
  # We deliberately do NOT auto-commit (per bd-ofql8k: "Prefer send-back/retry
  # over a blind auto-commit (so half-work/junk is not committed)") — an
  # uncommitted worktree at gate-cap is escalated for human / dispatcher
  # judgement, not silently buried.
  defp park_commit_gate(%State{} = state, reason, why) do
    {failure_reason, subject} = commit_gate_failure_metadata(reason)
    summary = commit_gate_summary(state, reason, why)

    record_commit_gate_note(state, reason, why, summary)
    escalate_commit_gate(state, subject, summary)

    meta =
      (state.meta || %{})
      |> Map.put(:commit_gate_reason, reason)
      |> Map.put(:commit_gate_detail, why)

    fail_now(%State{state | meta: meta}, failure_reason)
  end

  defp commit_gate_failure_metadata(:uncommitted),
    do: {:uncommitted_at_completion, "Worker signalled done with uncommitted work"}

  defp commit_gate_failure_metadata(:no_commits),
    do: {:no_commits_at_completion, "Worker signalled done with no commits on branch"}

  defp commit_gate_summary(%State{task_id: task_id, meta: meta}, reason, why) do
    branch = (meta && Map.get(meta, :branch)) || "(unknown)"
    target = (meta && Map.get(meta, :target_branch)) || "main"
    worktree = (meta && Map.get(meta, :worktree_path)) || "(unknown)"
    attempts = (meta && Map.get(meta, :commit_nudge_attempts)) || 0
    cap = commit_nudge_cap(meta)
    status = commit_gate_git_status(worktree)

    reason_blurb =
      case reason do
        :uncommitted ->
          "the worktree has uncommitted changes (staged/unstaged/untracked) " <>
            "but no commits made it onto branch `#{branch}`. The review gate " <>
            "would diff `#{target}..HEAD`, see empty, and falsely report 'no work'."

        :no_commits ->
          "branch `#{branch}` has zero commits ahead of `#{target}`. Either " <>
            "the worker did no work, or its edits landed elsewhere."
      end

    detail_blurb =
      case why do
        :cap_exhausted ->
          "Nudge cap reached: tried #{attempts}/#{cap} send-back attempt(s) and " <>
            "the worktree is still in the failed state."

        {:respawn_failed, sub} ->
          "Could not relaunch the worker for a send-back nudge: #{inspect(sub)}."

        other ->
          "Detail: #{inspect(other)}."
      end

    """
    bd-ofql8k commit gate tripped for task #{task_id}: #{reason_blurb}

    #{detail_blurb}

    Worktree: #{worktree}
    Branch: #{branch} → #{target}

    git status (--porcelain):
    #{status}
    """
    |> String.trim()
  end

  defp commit_gate_git_status(path) when is_binary(path) do
    case System.cmd("git", ["-C", path, "status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> "  (clean)"
      {out, 0} -> indent(out)
      {out, _} -> "  (could not run git status: " <> String.trim(out) <> ")"
    end
  rescue
    _ -> "  (git status unavailable)"
  end

  defp commit_gate_git_status(_), do: "  (no worktree path)"

  defp indent(text) do
    text
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.map(&("  " <> &1))
    |> Enum.join("\n")
  end

  defp record_commit_gate_note(%State{task_id: task_id}, _reason, _why, summary) do
    stamp = DateTime.utc_now() |> DateTime.to_iso8601()
    block = "## Commit gate tripped (#{stamp})\n\n#{summary}"

    with {:ok, task} <- Ash.get(Arbiter.Tasks.Issue, task_id) do
      notes =
        [task.notes, block]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")

      case Ash.update(task, %{notes: notes}, action: :update) do
        {:ok, _} -> :ok
        {:error, reason} -> log_commit_gate_warning(task_id, reason)
      end
    end

    :ok
  rescue
    e -> log_commit_gate_warning(task_id, e)
  end

  defp escalate_commit_gate(%State{workspace_id: ws_id, task_id: task_id}, subject, summary)
       when is_binary(ws_id) do
    Arbiter.Messages.Message.send_mail(%{
      kind: :escalation,
      to_ref: "admiral",
      from_ref: task_id,
      workspace_id: ws_id,
      directive_ref: task_id,
      subject: "Commit gate: #{subject} (#{task_id})",
      body: summary
    })

    :ok
  rescue
    e -> log_commit_gate_warning(task_id, e)
  catch
    :exit, _ -> :ok
  end

  defp escalate_commit_gate(_state, _subject, _summary), do: :ok

  defp log_commit_gate_warning(task_id, reason) do
    Logger.warning(
      "Worker: commit-gate escalation swallowed for task=#{task_id}: #{inspect(reason)}"
    )

    :error
  end

  # bd-5lc99r: the notes gate could not be satisfied (nudge cap exhausted or the
  # send-back relaunch failed). Escalate to the Admiral and fail the worker so
  # the directive is not silently closed without its findings deliverable.
  #
  # Unlike the commit gate, we deliberately do NOT write the gate-trip summary
  # into `notes` — that field IS what the gate checks, so polluting it would let
  # a re-dispatched worker satisfy the gate without producing real findings. The
  # escalation mail surfaces the trip to the Admiral instead.
  defp park_notes_gate(%State{} = state, why) do
    summary = notes_gate_summary(state, why)
    escalate_notes_gate(state, summary)

    meta = Map.put(state.meta || %{}, :notes_gate_detail, why)
    fail_now(%State{state | meta: meta}, :blank_notes_at_completion)
  end

  defp notes_gate_summary(%State{task_id: task_id, meta: meta}, why) do
    attempts = (meta && Map.get(meta, :notes_nudge_attempts)) || 0
    cap = notes_nudge_cap(meta)

    detail_blurb =
      case why do
        :cap_exhausted ->
          "Nudge cap reached: tried #{attempts}/#{cap} send-back attempt(s) and " <>
            "`notes` is still blank."

        {:respawn_failed, sub} ->
          "Could not relaunch the worker for a send-back nudge: #{inspect(sub)}."

        other ->
          "Detail: #{inspect(other)}."
      end

    """
    bd-5lc99r notes gate tripped for task #{task_id}: this is a `task`-type
    directive whose deliverable is a findings summary in `notes`, but `notes`
    is blank and `arb done` was signalled.

    #{detail_blurb}

    The directive cannot close without its findings. Re-dispatch it and ensure
    the acolyte writes its results to `notes` via the `task_update_progress` MCP
    tool before completing.
    """
    |> String.trim()
  end

  defp escalate_notes_gate(%State{workspace_id: ws_id, task_id: task_id}, summary)
       when is_binary(ws_id) do
    Arbiter.Messages.Message.send_mail(%{
      kind: :escalation,
      to_ref: "admiral",
      from_ref: task_id,
      workspace_id: ws_id,
      directive_ref: task_id,
      subject: "Notes gate: blank findings on task-type directive (#{task_id})",
      body: summary
    })

    :ok
  rescue
    e -> log_commit_gate_warning(task_id, e)
  catch
    :exit, _ -> :ok
  end

  defp escalate_notes_gate(_state, _summary), do: :ok

  # The shared "integrate this branch" path: open the MR / run the merge, or fail
  # the worker (not silently complete it) if the adapter rejects.
  #
  # `opts` may carry `:via_review_gate` (default `false`). When true the Watchdog is
  # told the gate has already approved this MR, so it merges on its first poll
  # instead of waiting for a hosted-forge approval signal that will never come
  # (bd-66ey1o: the ReviewGate approves in-process, it does NOT post a GitHub
  # review).
  defp merge_branch(%State{meta: meta} = state, branch, opts) when is_map(opts) do
    title = pr_title_for(state.task_id, meta)
    description = build_pr_body(state.task_id, Map.get(meta, :worktree_path))

    case do_open_mr(state, branch, title, description, opts) do
      {:ok, _mr_ref, new_state} -> new_state
      {:error, reason, _state} -> park_merge_failure(state, branch, reason)
    end
  end

  # The PR/MR title to open with. Formats according to the workspace's
  # pr_title_format convention (e.g. conventional commits for leotech), falling
  # back to the internal merge_title stashed in meta when the task can't be
  # loaded (bd-7d5smn: strip the "Merge <id>:" prefix from outbound PRs).
  defp pr_title_for(task_id, meta) do
    case Ash.get(Arbiter.Tasks.Issue, task_id) do
      {:ok, task} when is_binary(task.title) and task.title != "" ->
        case Ash.load(task, [:workspace]) do
          {:ok, task_with_ws} ->
            Arbiter.Mergers.PRTitle.format(task_with_ws, task_with_ws.workspace)

          _ ->
            Arbiter.Mergers.PRTitle.format(task, nil)
        end

      _ ->
        Map.get(meta, :merge_title) || "Merge #{task_id}"
    end
  rescue
    _ -> Map.get(meta, :merge_title) || "Merge #{task_id}"
  end

  # Build the PR/MR body. Precedence (mirrors MergeQueue.pr_description_for/1,
  # bd-53xrmi / bd-7d5smn):
  #
  #   1. Worker-authored pr_body stored on the task — verbatim, highest priority.
  #   2. Repo's pull_request_template.md filled with task metadata.
  #   3. PRTemplate.default_body/1 when no template file exists.
  #
  # Falls back to "" only when the task cannot be loaded at all.
  defp build_pr_body(task_id, worktree_path) do
    case Ash.get(Arbiter.Tasks.Issue, task_id) do
      {:ok, task} ->
        case task.pr_body do
          b when is_binary(b) and b != "" ->
            case String.trim(b) do
              "" ->
                fill_template_body(task, worktree_path)

              _ ->
                b
            end

          _ ->
            fill_template_body(task, worktree_path)
        end

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  defp fill_template_body(task, worktree_path) do
    template = is_binary(worktree_path) && PRTemplate.read(worktree_path)
    if template, do: PRTemplate.fill(template, task), else: PRTemplate.default_body(task)
  end

  # A merge failed. The adapter has already restored the canonical tree (the
  # Direct merger runs `git merge --abort` on conflict — see bd-1rhyla: a
  # half-merged tree took the live server down), so main stays clean and
  # compilable. Here we own the lifecycle side: fail the worker WITHOUT closing
  # the task, and — for a genuine conflict — escalate to the Admiral inbox with
  # the conflicting files so the task can be rebased / re-resolved.
  #
  # failure_reason stays a short term (it shares the Run.failure_reason column);
  # the full conflict detail lives in the escalation message + task notes.
  defp park_merge_failure(%State{} = state, branch, {:merge_conflict, detail}) do
    record_merge_conflict_note(state, branch, detail)
    escalate_merge_conflict(state, branch, detail)
    fail_now(state, :merge_conflict)
  end

  defp park_merge_failure(%State{} = state, _branch, reason) do
    fail_now(state, {:merge_failed, reason})
  end

  # Append the conflict + conflicting files to the task's notes so `arb show`
  # and the UI carry the rebase context. Best-effort: a DB hiccup is logged,
  # never fatal (mirrors record_review_gate_outcome/3).
  defp record_merge_conflict_note(%State{task_id: task_id}, branch, detail) do
    block = format_merge_conflict_note(branch, detail)

    with {:ok, task} <- Ash.get(Arbiter.Tasks.Issue, task_id) do
      notes =
        [task.notes, block]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")

      case Ash.update(task, %{notes: notes}, action: :update) do
        {:ok, _} -> :ok
        {:error, reason} -> log_merge_conflict_warning(task_id, reason)
      end
    end

    :ok
  rescue
    e -> log_merge_conflict_warning(task_id, e)
  end

  defp format_merge_conflict_note(branch, detail) do
    stamp = DateTime.utc_now() |> DateTime.to_iso8601()

    "## Merge conflict — aborted, needs rebase (#{stamp})\n\n#{merge_conflict_body(branch, detail)}"
  end

  # Raise an escalation to the Admiral's mailbox naming the conflicting files.
  # Requires a workspace (messages are workspace-scoped); mirrors
  # escalate_review_gate/3.
  defp escalate_merge_conflict(%State{workspace_id: ws_id, task_id: task_id}, branch, detail)
       when is_binary(ws_id) do
    Arbiter.Messages.Message.send_mail(%{
      kind: :escalation,
      to_ref: "admiral",
      from_ref: task_id,
      workspace_id: ws_id,
      directive_ref: task_id,
      subject: "Merge conflict: #{task_id} aborted, needs rebase",
      body: merge_conflict_body(branch, detail)
    })

    :ok
  rescue
    e -> log_merge_conflict_warning(task_id, e)
  catch
    :exit, _ -> :ok
  end

  defp escalate_merge_conflict(_state, _branch, _detail), do: :ok

  defp log_merge_conflict_warning(task_id, reason) do
    Logger.warning(
      "Worker merge-conflict escalation swallowed for task=#{task_id}: #{inspect(reason)}"
    )

    :error
  end

  defp merge_conflict_body(branch, detail) do
    files = Map.get(detail, :files, [])

    file_list =
      case files do
        [] -> "  (none reported)"
        _ -> Enum.map_join(files, "\n", &("  - " <> &1))
      end

    """
    Auto-merge of branch #{branch} into the target conflicted and was aborted.
    The canonical working tree was restored (git merge --abort) — main is \
    unchanged and compilable; the task was NOT merged or closed. It is parked \
    for rebase / re-resolution.

    Conflicting files:
    #{file_list}
    """
  end

  defp mergeable_branch(meta) do
    case meta && Map.get(meta, :branch) do
      branch when is_binary(branch) and branch != "" -> branch
      _ -> nil
    end
  end

  # Pull merge-adapter overrides out of the worker's meta so the
  # review_gate-approve path can route through a test stub adapter without going
  # through workspace config. Tests set these via `meta:` at worker start;
  # production callers leave them nil and rely on workspace resolution.
  defp merge_opts_from_meta(meta, base) when is_map(base) do
    meta = meta || %{}

    base
    |> maybe_put_meta(:adapter, Map.get(meta, :merger_adapter_override))
    |> maybe_put_meta(:workspace, Map.get(meta, :merger_workspace_override))
    |> maybe_put_meta(:interval_ms, Map.get(meta, :watchdog_interval_ms))
    |> maybe_put_meta(:initial_delay_ms, Map.get(meta, :watchdog_initial_delay_ms))
    |> maybe_put_meta(:max_polls, Map.get(meta, :watchdog_max_polls))
  end

  defp maybe_put_meta(map, _key, nil), do: map
  defp maybe_put_meta(map, key, value), do: Map.put(map, key, value)

  # ---- review gate (ReviewGate) --------------------------------------------

  # Resolve whether this worker's workspace requires a review gate. An explicit
  # meta override (`:review_required`) wins — used by tests and advanced callers;
  # otherwise read the workspace config (default false). A worker with no
  # workspace can't resolve config, so it never gates.
  defp review_required?(%State{meta: meta} = state) do
    case meta && Map.get(meta, :review_required) do
      flag when is_boolean(flag) ->
        flag

      _ ->
        case state.workspace_id && Ash.get(Arbiter.Tasks.Workspace, state.workspace_id) do
          {:ok, ws} -> Arbiter.Tasks.Workspace.review_required?(ws)
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  # Resolve the revise-and-rediscuss round cap for the ReviewGate.
  #
  # Resolution order:
  #   1. An explicit meta `:review_rounds` override (tests / advanced callers).
  #   2. `min(difficulty_default, workspace_cap)` — the difficulty-derived default
  #      (bd-a5k6wb) optionally tightened by `config["review_gate"]["max_rounds"]`.
  #   3. Falls back to `nil` to let the ReviewGate apply its built-in D2 default.
  #
  # The task's difficulty drives the default; the workspace cap can only tighten
  # it (min), never loosen it beyond the difficulty-appropriate ceiling.
  defp resolve_review_rounds(%State{meta: meta} = state) do
    case meta && Map.get(meta, :review_rounds) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        difficulty = task_difficulty(state.task_id)
        difficulty_default = Arbiter.Worker.ReviewGate.rounds_for_difficulty(difficulty)

        case state.workspace_id && Ash.get(Arbiter.Tasks.Workspace, state.workspace_id) do
          {:ok, ws} ->
            case Arbiter.Tasks.Workspace.review_gate_max_rounds(ws) do
              nil -> difficulty_default
              cap -> min(difficulty_default, cap)
            end

          _ ->
            difficulty_default
        end
    end
  rescue
    _ -> nil
  end

  # Load the task's difficulty integer (0..4) from the DB. Returns nil on any
  # error so the ReviewGate falls back to its D2 default rather than crashing.
  defp task_difficulty(task_id) when is_binary(task_id) do
    case Ash.get(Arbiter.Tasks.Issue, task_id) do
      {:ok, %Arbiter.Tasks.Issue{difficulty: d}} -> d
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp task_difficulty(_), do: nil

  # Park at :awaiting_review_gate and spawn the reviewer. The branch + merge title
  # are stashed in meta so review_gate_verdict/2 can fire the same merge path on
  # approval without re-deriving them.
  defp enter_review_gate(%State{} = state, branch) do
    meta = Map.put(state.meta || %{}, :review_gate_branch, branch)

    # bd-129xh4: when a hosted merger is configured (github/gitlab), open the PR
    # BEFORE the reviewer runs so it can review the real PR (`gh pr diff <n>`)
    # rather than a bare branch. The open is idempotent — the merge still runs
    # on APPROVE through the unchanged merge_branch path, which adopts this same
    # PR. A failure (or the local :direct strategy) falls back to branch-diff
    # review rather than blocking it; the reviewer's prompt drops the PR hint.
    meta =
      case maybe_open_pr_for_review(%State{state | meta: meta}, branch) do
        {:ok, pr_ref} -> Map.put(meta, :review_pr_ref, pr_ref)
        _ -> meta
      end

    parked = %State{
      state
      | status: :awaiting_review_gate,
        step_started_at: DateTime.utc_now(),
        meta: meta
    }

    case spawn_review_gate(parked, branch) do
      # Stash the monitor ref so a ReviewGate that dies before reporting can't
      # silently strand us at :awaiting_review_gate (see the :DOWN handler).
      {:ok, ref} ->
        %State{parked | meta: Map.put(parked.meta, :review_gate_ref, ref)}

      # Tests drive review_gate_verdict/2 directly (review_spawn: false).
      :skip ->
        parked

      # The ReviewGate couldn't start — don't park unreviewed work forever; treat
      # it as an inconclusive review and escalate (no merge). bd-2y0gd5.
      :error ->
        apply_review_gate_verdict(
          parked,
          {:no_verdict, "ReviewGate failed to start; merge blocked pending review."}
        )
    end
  end

  # Spawn the ReviewGate (which runs the distinct reviewer worker). The
  # `:review_spawn` meta flag (default true) lets tests park the worker at
  # :awaiting_review_gate and drive review_gate_verdict/2 directly, in isolation from a
  # live reviewer subprocess. `:review_command` is the reviewer argv test escape
  # hatch (forwarded to the ReviewGate → ClaudeSession), mirroring dispatch's
  # `:claude_command`.
  # Spawn the ReviewGate and MONITOR it. Returns {:ok, monitor_ref} so the author
  # can detect a ReviewGate that dies before reporting, :skip when review_spawn is
  # off (tests drive review_gate_verdict/2 directly), or :error when it can't start.
  defp spawn_review_gate(%State{meta: meta} = state, branch) do
    if Map.get(meta, :review_spawn, true) do
      opts =
        [
          author: self(),
          task_id: state.task_id,
          workspace_id: state.workspace_id,
          repo: state.repo,
          worktree_path: Map.get(meta, :worktree_path),
          branch: branch,
          target_branch: Map.get(meta, :target_branch, "main")
        ]
        |> maybe_opt(:command, Map.get(meta, :review_command))
        |> maybe_opt(:revise_command, Map.get(meta, :revise_command))
        |> maybe_opt(:timeout_ms, Map.get(meta, :review_timeout_ms))
        |> maybe_opt(:verdict_retries, Map.get(meta, :review_verdict_retries))
        |> maybe_opt(:rounds, resolve_review_rounds(state))
        |> maybe_opt(:pr_ref, Map.get(meta, :review_pr_ref))

      case Arbiter.Worker.ReviewGate.start(opts) do
        {:ok, pid} ->
          {:ok, Process.monitor(pid)}

        {:error, reason} ->
          Logger.warning(
            "Worker: failed to start ReviewGate for task=#{state.task_id}: #{inspect(reason)}"
          )

          :error
      end
    else
      :skip
    end
  end

  # Apply a ReviewGate verdict from :awaiting_review_gate.
  defp apply_review_gate_verdict(%State{} = state, {:approve, findings}) do
    record_review_gate_outcome(state, :approve, findings)
    branch = Map.get(state.meta, :review_gate_branch) || mergeable_branch(state.meta)
    # Tell the Watchdog the gate approved this MR. Without via_review_gate,
    # hosted-forge adapters (Github) park forever at :awaiting_review waiting
    # for a PR-level approval the ReviewGate never posts (bd-66ey1o). force_merge
    # makes this the explicit merge-regardless-of-lane signal (bd-ddtbhb).
    merge_branch(
      state,
      branch,
      merge_opts_from_meta(state.meta, %{via_review_gate: true, force_merge: true})
    )
  end

  defp apply_review_gate_verdict(%State{} = state, {:request_changes, findings}) do
    park_rejected(state, :request_changes, findings)
  end

  defp apply_review_gate_verdict(%State{} = state, {:no_verdict, findings}) do
    park_rejected(state, :no_verdict, findings)
  end

  defp apply_review_gate_verdict(%State{} = state, :no_verdict) do
    park_rejected(state, :no_verdict, "Reviewer produced no parseable VERDICT line.")
  end

  # Reject path: record findings, escalate to the Admiral, and park the worker
  # at :failed WITHOUT merging. failure_reason stays a short atom; the full
  # findings live in meta + task notes + the escalation message (well under the
  # Run.failure_reason length cap).
  defp park_rejected(%State{} = state, verdict, findings) do
    record_review_gate_outcome(state, verdict, findings)
    escalate_review_gate(state, verdict, findings)

    meta =
      state.meta
      |> Map.put(:review_gate_verdict, verdict)
      |> Map.put(:review_gate_findings, findings)

    fail_now(%State{state | meta: meta}, fail_reason_for(verdict))
  end

  defp fail_reason_for(:no_verdict), do: :review_gate_inconclusive
  defp fail_reason_for(_), do: :review_gate_rejected

  # Append the verdict + findings to the task's notes so it surfaces in
  # `arb show` / the UI. Best-effort: a DB hiccup is logged, never fatal.
  defp record_review_gate_outcome(%State{task_id: task_id, meta: meta}, verdict, findings) do
    rounds = Map.get(meta || %{}, :review_gate_rounds)
    block = format_review_gate_note(verdict, findings, rounds)

    with {:ok, task} <- Ash.get(Arbiter.Tasks.Issue, task_id) do
      notes =
        [task.notes, block]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")

      case Ash.update(task, %{notes: notes}, action: :update) do
        {:ok, _} -> :ok
        {:error, reason} -> log_review_gate_warning(task_id, reason)
      end
    end

    :ok
  rescue
    e -> log_review_gate_warning(task_id, e)
  end

  defp format_review_gate_note(verdict, findings, rounds) do
    header =
      case verdict do
        :approve -> "ReviewGate verdict: APPROVE"
        :request_changes -> "ReviewGate verdict: REQUEST_CHANGES"
        :no_verdict -> "ReviewGate verdict: INCONCLUSIVE (no verdict)"
      end

    stamp = DateTime.utc_now() |> DateTime.to_iso8601()
    rounds_line = if rounds, do: "\nrounds: #{rounds}", else: ""
    "## #{header} (#{stamp})#{rounds_line}\n\n#{findings}"
  end

  # On a non-approve verdict, raise an escalation to the Admiral's mailbox with
  # the reviewer's findings. Requires a workspace (messages are workspace-scoped).
  defp escalate_review_gate(%State{workspace_id: ws_id, task_id: task_id}, verdict, findings)
       when is_binary(ws_id) do
    subject =
      case verdict do
        :no_verdict -> "ReviewGate: review inconclusive for #{task_id}"
        _ -> "ReviewGate: changes requested for #{task_id}"
      end

    Arbiter.Messages.Message.send_mail(%{
      kind: :escalation,
      to_ref: "admiral",
      from_ref: task_id,
      workspace_id: ws_id,
      directive_ref: task_id,
      subject: subject,
      body: findings
    })

    Arbiter.Events.broadcast(ws_id, "review_gate", %{task_id: task_id, message: subject})

    :ok
  rescue
    e -> log_review_gate_warning(task_id, e)
  catch
    :exit, _ -> :ok
  end

  defp escalate_review_gate(_state, _verdict, _findings), do: :ok

  defp log_review_gate_warning(task_id, reason) do
    Logger.warning(
      "Worker.record_review_gate_outcome swallowed for task=#{task_id}: #{inspect(reason)}"
    )

    :error
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    # Finalize the run row before we tear down. This is the normal-path
    # bookkeeping the boot reconciler (bd-6k8519) was silently masking: the
    # real worker-completion path is `arb done` -> task closes -> the task
    # `:close` after-action StopWorker calls `Worker.stop` -> terminate/2
    # from a NON-terminal state (:running/:idle/:awaiting/:awaiting_review).
    # Nothing on that path ever marks the row terminal, so it stayed :running
    # until the next server boot. See finalize_run_on_terminate/1.
    finalize_run_on_terminate(state)

    # Explicitly unregister so callers that ask `whereis/1` immediately after
    # `GenServer.stop/1` see `nil` deterministically. Registry's own
    # monitor-based cleanup runs asynchronously and was the source of a flaky
    # test where `whereis/1` returned the dead pid briefly after stop.
    # Use the registry_key the worker actually registered under — defaults
    # to task_id but the merge queue's conflict-resolver overrides it so its
    # teardown doesn't accidentally unregister the original work worker.
    PRegistry.unregister(state.registry_key || state.task_id)
    broadcast_lifecycle(:stopped, state)
    :ok
  end

  # On termination, guarantee the worker_runs row is closed out.
  #
  #   * :completed / :failed — the row was already stamped by complete_now/2 or
  #     fail_now/2 (the explicit complete/fail paths). Don't double-write.
  #   * any non-terminal status (:idle/:running/:awaiting/:awaiting_review) —
  #     the worker is being torn down without an explicit terminal transition
  #     (the normal `arb done` -> task :close -> StopWorker teardown). Treat
  #     the termination as completion and stamp the row :completed + completed_at
  #     so `arb worker show` reflects the finished run immediately, with no
  #     manual reconcile.
  defp finalize_run_on_terminate(%State{status: status}) when status in [:completed, :failed] do
    :ok
  end

  defp finalize_run_on_terminate(%State{} = state) do
    record_run_finished(%State{state | status: :completed})
  end

  # ---- child_spec --------------------------------------------------------

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  # ---- internals ---------------------------------------------------------

  defp call(pid, msg) when is_pid(pid), do: GenServer.call(pid, msg)

  defp call(task_id, msg) when is_binary(task_id) do
    case whereis(task_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, msg)
    end
  end

  defp snapshot(%State{} = s) do
    %{
      task_id: s.task_id,
      workspace_id: s.workspace_id,
      repo: s.repo,
      current_step: s.current_step,
      status: s.status,
      started_at: s.started_at,
      step_started_at: s.step_started_at,
      mr_ref: s.mr_ref,
      merger_url: s.merger_url,
      meta: s.meta
    }
  end

  # ---- merge-request review internals ------------------------------------

  # Resolve the merger, open the MR / run the merge, park at :awaiting_review,
  # and spawn the Watchdog. Returns `{:ok, mr_ref, new_state}` on success or
  # `{:error, reason, unchanged_state}` on failure.
  #
  # Shared by the explicit open_mr/5 API (handle_call) and the worker
  # completion path (the arb-done handler) so the branch is always integrated
  # through the same code, regardless of how completion was triggered. For the
  # default Direct strategy this performs the local `git merge --no-ff`
  # synchronously; the Watchdog then completes the worker on its first poll.
  defp do_open_mr(%State{} = state, branch, title, description, opts) do
    case resolve_merger(state, opts) do
      {:ok, adapter, workspace} ->
        Arbiter.Mergers.prepare(workspace)
        open_opts = build_open_opts(state, opts)

        case safe_open(adapter, branch, title, description, open_opts) do
          {:ok, mr_ref} ->
            merger_url = safe_link_for(adapter, mr_ref)

            # bd-7b46wd: persist the PR/MR ref onto the task so the workspace
            # MergeQueue ADOPTS this PR (instead of opening a duplicate) when it
            # later receives the {:worker_done, task_id} broadcast. Without
            # this the MergeQueue's existing_mr_ref/1 is always nil, it falls
            # through to open_mr_for/3, fails opening a second PR on the
            # already-merged branch, and the task is never auto-closed.
            record_pr_ref_on_task(state, mr_ref)
            sync_tracker_pr_opened(state, mr_ref, merger_url)

            new_state = %State{
              state
              | status: :awaiting_review,
                mr_ref: mr_ref,
                merger_url: merger_url,
                merger_adapter: adapter,
                step_started_at: DateTime.utc_now(),
                meta:
                  state.meta
                  |> Map.put(:mr_ref, mr_ref)
                  |> Map.put(:merger_url, merger_url)
            }

            # Guard: MR already exists on the forge. Watchdog startup failure must
            # NOT prevent the worker from parking at :awaiting_review — the MR
            # is real and must not be discarded. If the Watchdog can't start for
            # any reason, escalate to the Admiral so the MR is not silently
            # orphaned while the worker parks indefinitely.
            watchdog_ok? =
              try do
                start_watchdog(new_state, workspace, opts) == :ok
              rescue
                e ->
                  Logger.warning(
                    "Worker.open_mr: Watchdog startup raised for task=#{state.task_id}: #{Exception.message(e)}"
                  )

                  false
              catch
                :exit, reason ->
                  Logger.warning(
                    "Worker.open_mr: Watchdog startup exit for task=#{state.task_id}: #{inspect(reason)}"
                  )

                  false
              end

            unless watchdog_ok? do
              escalate_watchdog_failure(new_state)
            end

            {:ok, mr_ref, new_state}

          {:error, reason} ->
            Logger.warning(
              "Worker.open_mr: adapter open failed for task=#{state.task_id}: #{inspect(reason)}"
            )

            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # bd-129xh4: open the PR for `branch` BEFORE the reviewer runs, WITHOUT
  # merging or starting the Watchdog, so the ReviewGate's reviewer reviews a
  # real PR (`gh pr diff <n>`) instead of a bare branch. Only fires for a
  # hosted-forge merger (github/gitlab); the local :direct strategy has no
  # remote PR — its `open` performs the merge — so it is skipped and the
  # reviewer falls back to the branch diff. Returns `{:ok, pr_ref}` when a PR
  # was opened, or `:none` when no hosted merger is configured / the open failed
  # (the caller proceeds with branch-diff review either way). The merge still
  # happens later, on APPROVE, through the unchanged merge_branch path — its
  # adapter.open is idempotent and adopts the PR opened here.
  defp maybe_open_pr_for_review(%State{} = state, branch)
       when is_binary(branch) and branch != "" do
    opts = merge_opts_from_meta(state.meta, %{})

    case resolve_merger(state, opts) do
      {:ok, adapter, workspace} ->
        if hosted_forge_merger?(workspace, opts) do
          open_pr_without_merge(state, adapter, workspace, branch, opts)
        else
          :none
        end

      {:error, _reason} ->
        :none
    end
  rescue
    e ->
      Logger.warning(
        "Worker: pre-review PR open raised for task=#{state.task_id}: #{Exception.message(e)}"
      )

      :none
  end

  defp maybe_open_pr_for_review(_state, _branch), do: :none

  # A hosted forge (github/gitlab) has a real remote PR worth opening ahead of
  # review; the local :direct strategy does not. An explicit `:adapter` override
  # (tests) is treated as hosted so the pre-review open path can be exercised.
  defp hosted_forge_merger?(workspace, opts) do
    cond do
      Map.get(opts, :adapter) ->
        true

      match?(%Arbiter.Tasks.Workspace{}, workspace) ->
        Arbiter.Tasks.Workspace.merger_strategy(workspace) in [:github, :gitlab]

      true ->
        false
    end
  end

  # Open the PR via the adapter and record it on the task, but do NOT park the
  # worker or start the Watchdog — that all happens later on APPROVE. Records
  # pr_ref so the MergeQueue adopts this PR rather than opening a duplicate.
  defp open_pr_without_merge(%State{} = state, adapter, workspace, branch, opts) do
    Arbiter.Mergers.prepare(workspace)
    title = pr_title_for(state.task_id, state.meta)
    description = build_pr_body(state.task_id, Map.get(state.meta, :worktree_path))
    open_opts = build_open_opts(state, opts)

    case safe_open(adapter, branch, title, description, open_opts) do
      {:ok, mr_ref} ->
        merger_url = safe_link_for(adapter, mr_ref)
        record_pr_ref_on_task(state, mr_ref)
        sync_tracker_pr_opened(state, mr_ref, merger_url)
        {:ok, mr_ref}

      {:error, reason} ->
        Logger.warning(
          "Worker: pre-review PR open failed for task=#{state.task_id}: #{inspect(reason)} " <>
            "— falling back to branch-diff review"
        )

        :none
    end
  end

  # Resolve {adapter, workspace} for an open_mr/5 call. An explicit `:adapter`
  # in opts wins (test/advanced override); otherwise resolve from the worker's
  # workspace via Arbiter.Mergers.for_workspace/1.
  defp resolve_merger(%State{} = state, opts) do
    cond do
      adapter = Map.get(opts, :adapter) ->
        {:ok, adapter, Map.get(opts, :workspace)}

      is_binary(state.workspace_id) ->
        case Ash.get(Arbiter.Tasks.Workspace, state.workspace_id) do
          {:ok, ws} -> {:ok, Arbiter.Mergers.for_workspace(ws), ws}
          _ -> {:error, :workspace_not_found}
        end

      true ->
        {:error, :no_workspace}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # Build the opts map handed to the adapter's open/4. Carries the task-domain
  # keys and, when the caller didn't supply them, defaults from the worker's
  # meta:
  #
  #   * :repo_path — the repo path (local checkout where the target branch
  #     lives) the Direct adapter runs `git merge --no-ff` inside. Seeded into
  #     meta at dispatch time; falls back to the worktree path for older callers.
  #   * :target_branch — the base branch the worktree was cut from.
  defp build_open_opts(%State{meta: meta}, opts) do
    meta = meta || %{}

    opts
    |> Map.take([:target_branch, :reviewer_ids, :labels, :repo_path])
    |> maybe_default(:repo_path, Map.get(meta, :repo_path) || Map.get(meta, :worktree_path))
    |> maybe_default(:target_branch, Map.get(meta, :target_branch))
  end

  defp maybe_default(map, _key, nil), do: map
  defp maybe_default(map, key, value), do: Map.put_new(map, key, value)

  defp safe_open(adapter, branch, title, description, open_opts) do
    adapter.open(branch, title, description, open_opts)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # link_for/1 is best-effort: some adapters resolve the URL from per-process
  # config (already seeded via Mergers.prepare/1 above). A failure or empty
  # string just means "no clickable link" — store nil rather than "".
  defp safe_link_for(adapter, mr_ref) do
    case adapter.link_for(mr_ref) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Persist the opened MR/PR ref onto the task's `pr_ref` (bd-7b46wd). This is
  # the single signal the workspace MergeQueue reads (`existing_mr_ref/1`) to
  # ADOPT an already-open PR rather than open a duplicate — without it the
  # Watchdog-merged PR is invisible to the MergeQueue and the task never closes.
  # Mirrors `Arbiter.Workflows.MergeQueue.maybe_record_mr_ref/2`. Best-effort: a
  # DB hiccup logs at debug and never fails the open.
  defp record_pr_ref_on_task(%State{task_id: task_id}, mr_ref)
       when is_binary(mr_ref) and mr_ref != "" do
    with {:ok, task} <- Ash.get(Arbiter.Tasks.Issue, task_id),
         {:ok, _updated} <- Ash.update(task, %{pr_ref: mr_ref}, action: :update) do
      :ok
    else
      {:error, reason} ->
        Logger.debug(
          "Worker.open_mr: failed to record pr_ref=#{mr_ref} for task=#{task_id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.debug(
        "Worker.open_mr: pr_ref record raised for task=#{task_id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp record_pr_ref_on_task(_state, _mr_ref), do: :ok

  # PR-open: drive the task's external tracker forward (e.g. Jira VR ->
  # In Code Review) and attach the PR as a comment + remote link. The original
  # incident (VR-17911) opened a PR but never transitioned the ticket and left
  # 0 comments / no remote-link; this fires that hook. Best-effort and
  # loud-on-failure inside `Arbiter.Trackers.Sync` — a missing/unreadable task
  # here just skips. (bd-c4cfuv)
  defp sync_tracker_pr_opened(%State{task_id: task_id}, mr_ref, merger_url) do
    with {:ok, task} <- Ash.get(Arbiter.Tasks.Issue, task_id) do
      Arbiter.Trackers.Sync.lifecycle(task, :pr_opened,
        pr_url: merger_url,
        pr_title: "PR #{mr_ref} (#{task_id})"
      )
    end

    :ok
  rescue
    e ->
      Logger.debug(
        "Worker.open_mr: PR-open tracker sync raised for task=#{task_id}: #{Exception.message(e)}"
      )

      :ok
  end

  # Spawn the Watchdog that polls for approval. auto_merge + poll interval come
  # from the workspace config (opts may override, primarily for tests).
  #
  # The `:via_review_gate` opt tells the Watchdog the gate has already approved
  # this MR; it short-circuits hosted-forge approval polling (meaning a). It does
  # NOT implicitly force auto_merge — that is opt-in via `:force_merge` (meaning
  # b). The ReviewGate APPROVE merge path passes both (bd-ddtbhb).
  defp start_watchdog(%State{} = state, workspace, opts) do
    # Test escape hatch: :watchdog_start_error in opts simulates a Watchdog startup
    # failure without needing a real error condition, mirroring :review_spawn for
    # the ReviewGate. Production callers never set this key.
    if Map.get(opts, :watchdog_start_error) do
      :error
    else
      do_start_watchdog(state, workspace, opts)
    end
  end

  defp do_start_watchdog(%State{} = state, workspace, opts) do
    via_review_gate = Map.get(opts, :via_review_gate, false)

    auto_merge =
      cond do
        Map.get(opts, :force_merge, false) -> true
        Map.has_key?(opts, :auto_merge) -> Map.fetch!(opts, :auto_merge)
        true -> workspace_auto_merge?(workspace)
      end

    watchdog_opts =
      [
        task_id: state.task_id,
        worker: self(),
        mr_ref: state.mr_ref,
        adapter: state.merger_adapter,
        workspace: workspace,
        auto_merge: auto_merge,
        via_review_gate: via_review_gate
      ]
      |> maybe_opt(:interval_ms, Map.get(opts, :interval_ms))
      |> maybe_opt(:initial_delay_ms, Map.get(opts, :initial_delay_ms))
      |> maybe_opt(
        :max_polls,
        Map.get(opts, :max_polls) || workspace_watchdog_max_polls(workspace)
      )

    case Arbiter.Worker.Watchdog.start(watchdog_opts) do
      {:ok, _pid} ->
        :ok

      # DynamicSupervisor.start_child/2 admits :ignore per its typespec; today
      # Watchdog.init/1 returns :ignore when worker_pid is not a pid (defensive
      # path). Treat as a no-op: the MR is already created and the Watchdog is
      # simply not needed (matches pattern in start_merge_queue.ex).
      :ignore ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Worker.open_mr: failed to start Watchdog for task=#{state.task_id}: #{inspect(reason)}"
        )

        :error
    end
  end

  # An MR was opened but the Watchdog failed to start. The worker stays at
  # :awaiting_review (the MR is real and must not be discarded), but the Admiral
  # is escalated so the orphaned MR can be resolved manually rather than hanging
  # indefinitely with no watcher.
  defp escalate_watchdog_failure(%State{
         workspace_id: ws_id,
         task_id: task_id,
         mr_ref: mr_ref,
         merger_url: merger_url
       })
       when is_binary(ws_id) do
    mr_info =
      case merger_url do
        url when is_binary(url) and url != "" -> "#{mr_ref} (#{url})"
        _ -> to_string(mr_ref)
      end

    Logger.warning(
      "Worker.open_mr: Watchdog failed to start for task=#{task_id} — MR #{mr_ref} orphaned; escalating"
    )

    Arbiter.Messages.Message.send_mail(%{
      kind: :escalation,
      to_ref: "admiral",
      from_ref: task_id,
      workspace_id: ws_id,
      directive_ref: task_id,
      subject: "Watchdog startup failed: #{task_id} MR orphaned",
      body:
        "The Watchdog process failed to start after MR #{mr_info} was opened for task #{task_id}. " <>
          "The MR exists on the forge but has no Watchdog watching it — " <>
          "manual completion or failure is required once the MR resolves.\n\n" <>
          "To complete: Worker.complete(#{inspect(task_id)}, :merged)\n" <>
          "To fail:     Worker.fail(#{inspect(task_id)}, :watchdog_lost)"
    })

    :ok
  rescue
    e ->
      Logger.warning(
        "Worker: Watchdog-failure escalation swallowed for task=#{task_id}: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  defp escalate_watchdog_failure(_state), do: :ok

  defp workspace_auto_merge?(%Arbiter.Tasks.Workspace{} = ws),
    do: Arbiter.Tasks.Workspace.auto_merge?(ws)

  defp workspace_auto_merge?(_), do: false

  defp workspace_watchdog_max_polls(%Arbiter.Tasks.Workspace{} = ws),
    do: Arbiter.Tasks.Workspace.watchdog_max_polls(ws)

  defp workspace_watchdog_max_polls(_), do: nil

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
