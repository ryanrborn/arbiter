defmodule Arbiter.Polecat do
  @moduledoc """
  A `Polecat` is the unit of agent work in Gas Town: a supervised GenServer
  driving a single bead through a workflow (load → design → implement → verify
  → submit).

  This module is the Phase 2 skeleton — it provides the lifecycle, registry,
  and status FSM. The actual workflow logic ships separately as the
  `Arbiter.Polecat.Workflow` behaviour (gte-014) and the driver that walks
  steps lives in a later phase.

  ## Status FSM

      :idle              → :running           (advance/2 from :idle)
      :idle              → :failed            (fail/2 — "stillborn" polecat, e.g.
                                              machine died before any step ran)
      :running           → :awaiting          (await/2 — parked, generic external wait)
      :awaiting          → :running           (resume/1)
      :running           → :awaiting_tribunal (arb-done when review is required)
      :awaiting_tribunal → :awaiting_review   (tribunal_verdict/2 :approve → merge)
      :awaiting_tribunal → :failed            (tribunal_verdict/2 reject → parked)
      :running           → :awaiting_review   (open_mr/5 — MR opened, parked for review)
      :awaiting_review   → :completed         (complete/2 — MR merged)
      :awaiting_review   → :failed            (fail/2 — MR closed/rejected)
      :running           → :completed         (complete/2 — normal exit)
      :running           → :failed            (fail/2)
      :awaiting          → :failed            (fail/2)

  Illegal transitions return `{:error, {:invalid_transition, from, to}}`.

  ## Review gate (`:awaiting_tribunal`)

  A standing order: an acolyte must not merge its own work. When the acolyte's
  `arb done` fires and the workspace requires review
  (`Workspace.review_required?/1`), the polecat parks at `:awaiting_tribunal` and
  spawns an `Arbiter.Polecat.Tribunal` — which runs a **distinct** reviewer
  acolyte over the diff — *instead of* calling the merger. The Tribunal reports a
  verdict back via `tribunal_verdict/2`: APPROVE proceeds to `do_open_mr` (the
  same merge path), REQUEST_CHANGES (or an inconclusive review) parks the bead
  with the findings and escalates to the Admiral without merging. When review is
  not required (the default) completion routes straight to the merger as before.

  ## Merge-request review (`:awaiting_review`)

  When an acolyte finishes its work the polecat opens a merge request via
  `open_mr/5` instead of completing immediately. That call resolves the
  workspace's merger adapter (`Arbiter.Mergers.for_workspace/1`), opens the
  MR, stores the `mr_ref` + clickable `merger_url` on the polecat, transitions
  to `:awaiting_review`, and spawns an `Arbiter.Polecat.Warden` to poll for
  approval. The Warden — not the acolyte's `arb done` — owns the terminal
  transition: it completes the polecat when the MR merges, or fails it when the
  MR is closed. See `Arbiter.Polecat.Warden`.

  This is also the path the `arb done` marker takes in claude-driven mode: when
  the polecat knows its branch (a worktree was provisioned at sling time) the
  marker triggers the same `open_mr` flow rather than closing the bead
  directly. For the default `Direct` strategy the merge (`git merge --no-ff`)
  runs immediately, so the branch reaches the target line before the bead
  closes. A merge failure fails the polecat instead of silently completing it.
  Only an ad-hoc run with no branch completes straight from `arb done`.

  ## API choice: explicit `await/2` etc. vs sentinel atoms

  The spec gave us a choice between an `advance(pid, :__awaiting__)` sentinel
  and a split API (`advance/2`, `await/2`, `resume/1`, `complete/2`,
  `fail/2`). We picked the split API: each verb has a single meaning, the
  status FSM lives in dispatch heads rather than in a dictionary of sentinels,
  and the type signature is honest about what `advance/2` does (change the
  workflow step, not change the lifecycle state).

  ## Registry

  Each polecat registers under `Arbiter.Polecat.Registry` keyed by `bead_id`.
  Use `whereis/1` to look up by bead_id; most API functions accept either a
  pid or a bead_id string.

  ## Supervision

  Polecats are started under `Arbiter.Polecat.Supervisor`
  (a `DynamicSupervisor`) with `restart: :temporary`. A crashed polecat is
  not restarted — workflow runners that crash have lost their state, so
  resurrecting the GenServer would just confuse the orchestrator.
  """

  use GenServer

  require Logger

  alias Arbiter.Polecat.Registry, as: PRegistry

  @typedoc "Lifecycle status — distinct from `Issue.status`."
  @type status ::
          :idle
          | :running
          | :awaiting
          | :awaiting_tribunal
          | :awaiting_review
          | :completed
          | :failed

  @typedoc "Current workflow step. Free-form atom; `:idle` until first advance."
  @type step :: atom()

  @typedoc "Accepted by most API functions in lieu of a bare pid."
  @type ref :: pid() | String.t()

  @typedoc "Snapshot returned by `state/1`."
  @type snapshot :: %{
          bead_id: String.t(),
          workspace_id: String.t() | nil,
          rig: String.t(),
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
      :bead_id,
      :workspace_id,
      :rig,
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
      # captured at open_mr time. Internal — used to mint the Warden.
      :merger_adapter,
      # uuid of the persisted Arbiter.Polecats.Run row, or nil if the create
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

  # ---- public API ---------------------------------------------------------

  @doc """
  Start a polecat under the dynamic supervisor.

  Required opts:
    * `:bead_id` — string, used as the registry key.
    * `:rig`    — string, the repo/project key the polecat operates on.

  Optional opts:
    * `:workspace_id` — string.
    * `:meta`         — initial map of workflow-specific state.
  """
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(Arbiter.Polecat.Supervisor, {__MODULE__, opts})
  end

  @doc """
  `GenServer.start_link/3`-style entry point. Prefer `start/1` for normal use.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.fetch(opts, :bead_id) do
      {:ok, bead_id} when is_binary(bead_id) and bead_id != "" ->
        case Keyword.fetch(opts, :rig) do
          {:ok, rig} when is_binary(rig) and rig != "" ->
            GenServer.start_link(__MODULE__, opts, name: PRegistry.via_tuple(bead_id))

          _ ->
            {:error, :missing_rig}
        end

      _ ->
        {:error, :missing_bead_id}
    end
  end

  @doc """
  Return the pid of the polecat registered for `bead_id`, or `nil`.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(bead_id) when is_binary(bead_id), do: PRegistry.whereis(bead_id)

  @doc """
  Return a list of active polecat snapshots — one entry per child under
  `Arbiter.Polecat.Supervisor`. Crashed / stopped polecats are omitted.

  Each entry is the same snapshot map `state/1` returns (bead_id,
  workspace_id, rig, current_step, status, started_at, step_started_at,
  meta), plus `:pid`.
  """
  @spec list_children() :: [map()]
  def list_children do
    Arbiter.Polecat.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      # Only actual polecats answer :snapshot. Other children of this supervisor
      # — notably an Arbiter.Polecat.Tribunal review gate — must NOT be probed:
      # calling :snapshot on them crashes them and strands the author. Match
      # strictly on the Polecat module. See bd-2y0gd5.
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
  Return a snapshot of the polecat's state, or `nil` if no polecat is
  registered for the given bead_id.
  """
  @spec state(ref()) :: snapshot() | nil
  def state(pid) when is_pid(pid), do: GenServer.call(pid, :snapshot)

  def state(bead_id) when is_binary(bead_id) do
    case whereis(bead_id) do
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
  Park the polecat — status becomes `:awaiting`. Only valid from `:running`.
  """
  @spec await(ref(), term()) :: :ok | {:error, term()}
  def await(ref, reason \\ nil), do: call(ref, {:await, reason})

  @doc """
  Resume a parked polecat. Only valid from `:awaiting`.
  """
  @spec resume(ref()) :: :ok | {:error, term()}
  def resume(ref), do: call(ref, :resume)

  @doc """
  Open a merge request for `branch` and park the polecat at
  `:awaiting_review`.

  Resolves the workspace's merger adapter, calls `open/4`, stores the resulting
  `mr_ref` + clickable `merger_url`, transitions `:running -> :awaiting_review`,
  and spawns an `Arbiter.Polecat.Warden` to poll for approval. Only valid from
  `:running`.

  `opts` is a map forwarded to the adapter's `open/4` (`:target_branch`,
  `:reviewer_ids`, `:labels`, and — for `Direct` — `:repo_path`, which defaults
  to the polecat's `meta[:worktree_path]`). It may also carry overrides
  primarily for testing and advanced callers:

    * `:adapter` — a merger module to use directly, bypassing workspace
      resolution.
    * `:workspace` — the `Workspace` struct (used to seed adapter config and
      read the auto-merge flag) when `:adapter` is supplied.
    * `:auto_merge`, `:interval_ms`, `:initial_delay_ms` — Warden overrides.

  Returns `{:ok, mr_ref}` on success, or `{:error, reason}` (the polecat stays
  `:running`) if the adapter can't be resolved or `open/4` fails.
  """
  @spec open_mr(ref(), String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def open_mr(ref, branch, title, description \\ "", opts \\ %{})
      when is_binary(branch) and is_binary(title) and is_binary(description) and is_map(opts) do
    call(ref, {:open_mr, branch, title, description, opts})
  end

  @doc """
  Record the latest `Arbiter.Mergers.get/1` result on the polecat's `:meta`
  (as `:last_merger_status`) along with a `:last_checked_at` timestamp.

  Called by the `Arbiter.Polecat.Warden` on every poll so the dashboard and
  detail view can surface approval status and freshness without holding the
  Warden's state.
  """
  @spec record_merger_status(ref(), map()) :: :ok | {:error, term()}
  def record_merger_status(ref, status) when is_map(status),
    do: call(ref, {:record_merger_status, status})

  @doc """
  Mark the workflow completed. Only valid from `:running`. The polecat keeps
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
  Deliver a Tribunal (review-gate) verdict. Only valid from `:awaiting_tribunal`
  — the state the polecat parks at after the acolyte's `arb done` when review is
  required. Called by `Arbiter.Polecat.Tribunal` once the reviewer acolyte
  reaches its verdict.

    * `{:approve, findings}` → records the approval and proceeds to the merger
      (`do_open_mr`); the polecat transitions to `:awaiting_review`.
    * `{:request_changes, findings}` → records the findings, escalates to the
      Admiral, and parks the polecat at `:failed` **without** merging. The bead
      stays `:in_progress` (the Driver leaves a `:failed` polecat's bead open for
      inspection / re-dispatch).
    * `{:no_verdict, reason}` → an inconclusive review; treated like a rejection
      (escalate, do not merge) since the safe default is never to merge unreviewed
      work.
  """
  @spec tribunal_verdict(ref(), Arbiter.Polecat.Tribunal.verdict() | {:no_verdict, String.t()}) ::
          :ok | {:error, term()}
  def tribunal_verdict(ref, verdict), do: call(ref, {:tribunal_verdict, verdict})

  @doc """
  Record an arbitrary key/value pair in the polecat's `:meta` map.
  """
  @spec report(ref(), atom() | String.t(), term()) :: :ok | {:error, term()}
  def report(ref, key, value), do: call(ref, {:report, key, value})

  @doc """
  Stop the polecat cleanly.
  """
  @spec stop(ref(), term()) :: :ok | {:error, :not_found}
  def stop(ref, reason \\ :normal)
  def stop(pid, reason) when is_pid(pid), do: GenServer.stop(pid, reason)

  def stop(bead_id, reason) when is_binary(bead_id) do
    case whereis(bead_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.stop(pid, reason)
    end
  end

  # ---- GenServer callbacks -----------------------------------------------

  @impl true
  def init(opts) do
    now = DateTime.utc_now()

    state = %State{
      bead_id: Keyword.fetch!(opts, :bead_id),
      workspace_id: Keyword.get(opts, :workspace_id),
      rig: Keyword.fetch!(opts, :rig),
      current_step: :idle,
      status: :idle,
      started_at: now,
      step_started_at: nil,
      meta: Keyword.get(opts, :meta, %{}),
      run_id: nil
    }

    state = record_run_started(state)

    broadcast_lifecycle(:started, state)

    {:ok, state}
  end

  @doc false
  def broadcast_lifecycle(event, %State{} = state) when event in [:started, :stopped] do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      "polecats",
      {:polecat_lifecycle, event, snapshot(state)}
    )

    :ok
  rescue
    # Silent-on-failure (PubSub registry may be down in tests), but leave
    # breadcrumbs so a programming error in the payload isn't invisible.
    e ->
      Logger.debug("Polecat.broadcast_lifecycle/2 swallowed: #{Exception.message(e)}")
      :ok
  end

  # Broadcast {:polecat_done, bead_id} to "polecat:done:<workspace_id>" so the
  # workspace's Refinery (Crucible) can pick the bead up and drive it through
  # the merge queue. A polecat without a workspace_id (e.g. ad-hoc local runs)
  # has no Refinery listening and so the broadcast is skipped.
  defp broadcast_done(%State{workspace_id: nil}), do: :ok

  defp broadcast_done(%State{workspace_id: ws_id, bead_id: bead_id} = state) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      "polecat:done:" <> ws_id,
      {:polecat_done, bead_id}
    )

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
      Logger.debug("Polecat.broadcast_done/1 swallowed: #{Exception.message(e)}")
      :ok
  end

  # ---- Run history (Arbiter.Polecats.Run) -------------------------------

  # Best-effort: create the persistent Run row for this polecat. Returns the
  # state, with :run_id populated on success. On failure (DB down, validation
  # error, no sandbox checkout in a test) we log a warning and leave run_id
  # nil — subsequent terminal updates will no-op cleanly.
  defp record_run_started(%State{} = state) do
    attrs = %{
      bead_id: state.bead_id,
      bead_title: lookup_bead_title(state.bead_id),
      rig: state.rig,
      workspace_id: state.workspace_id,
      status: :running,
      started_at: state.started_at,
      output_lines: []
    }

    case Ash.create(Arbiter.Polecats.Run, attrs) do
      {:ok, run} ->
        %State{state | run_id: run.id}

      {:error, reason} ->
        log_run_warning("create", state.bead_id, reason)
        state
    end
  rescue
    e ->
      log_run_warning("create", state.bead_id, e)
      state
  end

  # Best-effort: stamp the terminal status / output / exit fields onto the
  # Run row created at init. No-op (with a debug breadcrumb) when run_id is
  # nil — the original create failed, so there's nothing to update and the
  # warning was already logged at that time.
  defp record_run_finished(%State{run_id: nil} = state) do
    Logger.debug("Polecat.record_run_finished/1 skipped (no run_id) for bead=#{state.bead_id}")

    :ok
  end

  defp record_run_finished(%State{run_id: run_id} = state) do
    attrs = %{
      status: state.status,
      completed_at: DateTime.utc_now(),
      exit_code: Map.get(state.meta || %{}, :exit_status),
      output_lines: capture_output_lines(state),
      failure_reason: stringify_failure(Map.get(state.meta || %{}, :failure_reason))
    }

    with {:ok, run} <- Ash.get(Arbiter.Polecats.Run, run_id),
         {:ok, _updated} <- Ash.update(run, attrs, action: :update) do
      :ok
    else
      {:error, reason} -> log_run_warning("update", state.bead_id, reason)
    end
  rescue
    e -> log_run_warning("update", state.bead_id, e)
  end

  defp capture_output_lines(%State{} = state) do
    state.meta
    |> Kernel.||(%{})
    |> Map.get(:output_lines, [])
    |> Enum.take(-@max_output_lines)
  end

  # Open the durable, uncapped per-run transcript for this session. Keyed on
  # run_id: a polecat whose Run row never persisted (run_id nil) gets no
  # durable log, since there's no row to anchor audit retrieval to. A disk
  # error logs a warning and degrades to nil — the live capped path (PubSub +
  # bounded output_lines) is unaffected either way. See Arbiter.Polecat.OutputLog.
  defp open_output_log(%State{run_id: nil}), do: nil

  defp open_output_log(%State{run_id: run_id} = state) do
    case Arbiter.Polecat.OutputLog.open(run_id) do
      {:ok, handle} ->
        handle

      {:error, reason} ->
        log_run_warning("output_log_open", state.bead_id, reason)
        nil
    end
  end

  defp stringify_failure(nil), do: nil
  defp stringify_failure(s) when is_binary(s), do: s
  defp stringify_failure(other), do: inspect(other)

  defp lookup_bead_title(bead_id) do
    case Ash.get(Arbiter.Beads.Issue, bead_id) do
      {:ok, %{title: title}} -> title
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp log_run_warning(op, bead_id, reason) do
    Logger.warning("Polecat.record_run_#{op}/1 swallowed for bead=#{bead_id}: #{inspect(reason)}")

    :error
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:advance, step}, _from, %State{status: :idle} = state) do
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
      {:ok, mr_ref, new_state} -> {:reply, {:ok, mr_ref}, new_state}
      {:error, reason, kept_state} -> {:reply, {:error, reason}, kept_state}
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

    {:reply, :ok, %State{state | meta: meta}}
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

  def handle_call({:tribunal_verdict, verdict}, _from, %State{status: :awaiting_tribunal} = state) do
    {:reply, :ok, apply_tribunal_verdict(state, verdict)}
  end

  def handle_call({:tribunal_verdict, _verdict}, _from, %State{status: status} = state) do
    {:reply, {:error, {:invalid_transition, status, :tribunal_verdict}}, state}
  end

  def handle_call({:report, key, value}, _from, %State{} = state) do
    {:reply, :ok, %State{state | meta: Map.put(state.meta, key, value)}}
  end

  # Open a Claude session port. Called by Arbiter.Polecat.ClaudeSession.start/1
  # so this process (the polecat) owns the port. We stash session config keyed
  # by the port itself so multiple concurrent sessions (future) wouldn't
  # collide.
  def handle_call({:__claude_session_open__, port_args, session_config}, _from, %State{} = state) do
    try do
      port = Arbiter.Polecat.ClaudeSession.open_port(port_args)

      session =
        session_config
        |> Map.put(:port, port)
        |> Map.put(:output_lines, [])
        |> Map.put(:line_buf, "")
        |> Map.put(:exit_status, nil)
        |> Map.put(:exited_at, nil)
        |> Map.put(:output_log, open_output_log(state))

      sessions = Map.put(state.claude_sessions, port, session)
      new_state = %State{state | claude_sessions: sessions}
      new_state = sync_session_meta(new_state, port)

      {:reply, {:ok, port}, new_state}
    rescue
      e -> {:reply, {:error, {:port_open_failed, Exception.message(e)}}, state}
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
        updated = Arbiter.Polecat.ClaudeSession.handle_exit(session, status)
        sessions = Map.put(state.claude_sessions, port, updated)
        new_state = %State{state | claude_sessions: sessions}
        {:noreply, sync_session_meta(new_state, port)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:__claude_session_done__, _line}, %State{status: status} = state)
      when status not in [:completed, :failed, :awaiting_tribunal, :awaiting_review] do
    # "arb done" detected. The guard accepts most non-terminal statuses
    # (:idle, :running, :awaiting). In claude_driven mode the polecat may sit at
    # :idle (the Machine is not ticked, so Polecat.advance is never called), so
    # accepting :idle here is intentional and critical for this signal to fire.
    #
    # :awaiting_tribunal and :awaiting_review are deliberately excluded: once the
    # acolyte has signalled done, the review gate (Tribunal) and then the merger
    # / Warden decide completion — not a repeated "arb done" on the author's
    # stdout. A late marker is ignored (handled by the catch-all clause below).
    {:noreply, on_claude_done(state)}
  end

  def handle_info({:__claude_session_done__, _line}, %State{} = state) do
    # Already :completed or :failed — ignore duplicate signal.
    {:noreply, state}
  end

  # The Tribunal (review gate) exited before delivering a verdict. Do NOT strand
  # the author at :awaiting_tribunal — treat it as an inconclusive review and
  # escalate (no merge). Matched by the monitor ref stashed in meta. bd-2y0gd5.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{status: :awaiting_tribunal, meta: %{tribunal_ref: ref}} = state
      ) do
    Logger.warning(
      "Polecat: Tribunal for bead=#{state.bead_id} exited before a verdict " <>
        "(#{inspect(reason)}); escalating as no_verdict"
    )

    {:noreply,
     apply_tribunal_verdict(
       state,
       {:no_verdict, "Tribunal process exited before delivering a verdict (#{inspect(reason)})."}
     )}
  end

  # Any other monitor DOWN (the Tribunal's expected exit AFTER a verdict, or an
  # unrelated monitor) — nothing to do.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # ---- helpers -----------------------------------------------------------

  defp on_port_data(%State{} = state, port, fragment, eol?) do
    case Map.fetch(state.claude_sessions, port) do
      {:ok, session} ->
        updated = Arbiter.Polecat.ClaudeSession.handle_data(session, fragment, eol?)
        sessions = Map.put(state.claude_sessions, port, updated)
        new_state = %State{state | claude_sessions: sessions}
        sync_session_meta(new_state, port)

      :error ->
        state
    end
  end

  # Mirror the most useful session fields (output_lines, exit_status) into the
  # top-level meta so callers reading `Polecat.state(pid).meta` see them
  # without having to know about the internal :claude_sessions map.
  # When there are multiple concurrent sessions this surfaces the most recent
  # one; for now there's only ever one.
  defp sync_session_meta(%State{claude_sessions: sessions, meta: meta} = state, port) do
    case Map.get(sessions, port) do
      %{} = session ->
        meta =
          meta
          |> Map.put(:output_lines, Enum.reverse(session.output_lines))
          |> Map.put(:exit_status, session.exit_status)
          |> maybe_put(:exited_at, session.exited_at)

        %State{state | meta: meta}

      _ ->
        state
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---- terminal transitions ----------------------------------------------
  #
  # complete_now/2 and fail_now/2 hold the terminal side effects (DB write +
  # broadcast/notify) in one place, shared by the public complete/2 + fail/2
  # calls and the acolyte-completion (arb-done) path.

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
    new_state
  end

  # Handle the acolyte's "arb done" marker. Before bd-7qq81g this closed the bead
  # directly, bypassing the merger entirely — branches never reached the target
  # line. Completion now routes through the configured merger:
  #
  #   * When the polecat knows its branch (a worktree was provisioned) we open
  #     the MR / run the merge via the same path open_mr/5 uses. For the default
  #     Direct strategy this merges --no-ff into the target branch synchronously,
  #     parks at :awaiting_review, and the Warden completes the polecat on its
  #     first poll. A merge failure surfaces as a :failure_reason rather than
  #     silently closing the bead as done.
  #   * With no branch (ad-hoc runs / unconfigured rig / no worktree) there is
  #     nothing to integrate, so we complete directly as before.
  defp on_claude_done(%State{meta: meta} = state) do
    case mergeable_branch(meta) do
      nil ->
        complete_now(state, :claude_done)

      branch ->
        if review_required?(state) do
          # Standing order: don't merge unreviewed work. Park at :awaiting_tribunal
          # and let a distinct reviewer acolyte judge the diff first. The merge
          # fires only on tribunal_verdict/2 :approve.
          enter_tribunal(state, branch)
        else
          merge_branch(state, branch)
        end
    end
  end

  # The shared "integrate this branch" path: open the MR / run the merge, or fail
  # the polecat (not silently complete it) if the adapter rejects.
  defp merge_branch(%State{meta: meta} = state, branch) do
    title = Map.get(meta, :merge_title) || "Merge #{state.bead_id}"

    case do_open_mr(state, branch, title, "", %{}) do
      {:ok, _mr_ref, new_state} -> new_state
      {:error, reason, _state} -> fail_now(state, {:merge_failed, reason})
    end
  end

  defp mergeable_branch(meta) do
    case meta && Map.get(meta, :branch) do
      branch when is_binary(branch) and branch != "" -> branch
      _ -> nil
    end
  end

  # ---- review gate (Tribunal) --------------------------------------------

  # Resolve whether this polecat's workspace requires a review gate. An explicit
  # meta override (`:review_required`) wins — used by tests and advanced callers;
  # otherwise read the workspace config (default false). A polecat with no
  # workspace can't resolve config, so it never gates.
  defp review_required?(%State{meta: meta} = state) do
    case meta && Map.get(meta, :review_required) do
      flag when is_boolean(flag) ->
        flag

      _ ->
        case state.workspace_id && Ash.get(Arbiter.Beads.Workspace, state.workspace_id) do
          {:ok, ws} -> Arbiter.Beads.Workspace.review_required?(ws)
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  # Park at :awaiting_tribunal and spawn the reviewer. The branch + merge title
  # are stashed in meta so tribunal_verdict/2 can fire the same merge path on
  # approval without re-deriving them.
  defp enter_tribunal(%State{} = state, branch) do
    meta = Map.put(state.meta || %{}, :tribunal_branch, branch)

    parked = %State{
      state
      | status: :awaiting_tribunal,
        step_started_at: DateTime.utc_now(),
        meta: meta
    }

    case spawn_tribunal(parked, branch) do
      # Stash the monitor ref so a Tribunal that dies before reporting can't
      # silently strand us at :awaiting_tribunal (see the :DOWN handler).
      {:ok, ref} ->
        %State{parked | meta: Map.put(parked.meta, :tribunal_ref, ref)}

      # Tests drive tribunal_verdict/2 directly (review_spawn: false).
      :skip ->
        parked

      # The Tribunal couldn't start — don't park unreviewed work forever; treat
      # it as an inconclusive review and escalate (no merge). bd-2y0gd5.
      :error ->
        apply_tribunal_verdict(
          parked,
          {:no_verdict, "Tribunal failed to start; merge blocked pending review."}
        )
    end
  end

  # Spawn the Tribunal (which runs the distinct reviewer acolyte). The
  # `:review_spawn` meta flag (default true) lets tests park the polecat at
  # :awaiting_tribunal and drive tribunal_verdict/2 directly, in isolation from a
  # live reviewer subprocess. `:review_command` is the reviewer argv test escape
  # hatch (forwarded to the Tribunal → ClaudeSession), mirroring sling's
  # `:claude_command`.
  # Spawn the Tribunal and MONITOR it. Returns {:ok, monitor_ref} so the author
  # can detect a Tribunal that dies before reporting, :skip when review_spawn is
  # off (tests drive tribunal_verdict/2 directly), or :error when it can't start.
  defp spawn_tribunal(%State{meta: meta} = state, branch) do
    if Map.get(meta, :review_spawn, true) do
      opts =
        [
          author: self(),
          bead_id: state.bead_id,
          workspace_id: state.workspace_id,
          rig: state.rig,
          worktree_path: Map.get(meta, :worktree_path),
          branch: branch,
          target_branch: Map.get(meta, :target_branch, "main")
        ]
        |> maybe_opt(:command, Map.get(meta, :review_command))
        |> maybe_opt(:timeout_ms, Map.get(meta, :review_timeout_ms))

      case Arbiter.Polecat.Tribunal.start(opts) do
        {:ok, pid} ->
          {:ok, Process.monitor(pid)}

        {:error, reason} ->
          Logger.warning(
            "Polecat: failed to start Tribunal for bead=#{state.bead_id}: #{inspect(reason)}"
          )

          :error
      end
    else
      :skip
    end
  end

  # Apply a Tribunal verdict from :awaiting_tribunal.
  defp apply_tribunal_verdict(%State{} = state, {:approve, findings}) do
    record_tribunal_outcome(state, :approve, findings)
    branch = Map.get(state.meta, :tribunal_branch) || mergeable_branch(state.meta)
    merge_branch(state, branch)
  end

  defp apply_tribunal_verdict(%State{} = state, {:request_changes, findings}) do
    park_rejected(state, :request_changes, findings)
  end

  defp apply_tribunal_verdict(%State{} = state, {:no_verdict, findings}) do
    park_rejected(state, :no_verdict, findings)
  end

  defp apply_tribunal_verdict(%State{} = state, :no_verdict) do
    park_rejected(state, :no_verdict, "Reviewer produced no parseable VERDICT line.")
  end

  # Reject path: record findings, escalate to the Admiral, and park the polecat
  # at :failed WITHOUT merging. failure_reason stays a short atom; the full
  # findings live in meta + bead notes + the escalation message (well under the
  # Run.failure_reason length cap).
  defp park_rejected(%State{} = state, verdict, findings) do
    record_tribunal_outcome(state, verdict, findings)
    escalate_tribunal(state, verdict, findings)

    meta =
      state.meta
      |> Map.put(:tribunal_verdict, verdict)
      |> Map.put(:tribunal_findings, findings)

    fail_now(%State{state | meta: meta}, fail_reason_for(verdict))
  end

  defp fail_reason_for(:no_verdict), do: :tribunal_inconclusive
  defp fail_reason_for(_), do: :tribunal_rejected

  # Append the verdict + findings to the bead's notes so it surfaces in
  # `arb show` / the UI. Best-effort: a DB hiccup is logged, never fatal.
  defp record_tribunal_outcome(%State{bead_id: bead_id}, verdict, findings) do
    block = format_tribunal_note(verdict, findings)

    with {:ok, bead} <- Ash.get(Arbiter.Beads.Issue, bead_id) do
      notes =
        [bead.notes, block]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")

      case Ash.update(bead, %{notes: notes}, action: :update) do
        {:ok, _} -> :ok
        {:error, reason} -> log_tribunal_warning(bead_id, reason)
      end
    end

    :ok
  rescue
    e -> log_tribunal_warning(bead_id, e)
  end

  defp format_tribunal_note(verdict, findings) do
    header =
      case verdict do
        :approve -> "Tribunal verdict: APPROVE"
        :request_changes -> "Tribunal verdict: REQUEST_CHANGES"
        :no_verdict -> "Tribunal verdict: INCONCLUSIVE (no verdict)"
      end

    stamp = DateTime.utc_now() |> DateTime.to_iso8601()
    "## #{header} (#{stamp})\n\n#{findings}"
  end

  # On a non-approve verdict, raise an escalation to the Admiral's mailbox with
  # the reviewer's findings. Requires a workspace (messages are workspace-scoped).
  defp escalate_tribunal(%State{workspace_id: ws_id, bead_id: bead_id}, verdict, findings)
       when is_binary(ws_id) do
    subject =
      case verdict do
        :no_verdict -> "Tribunal: review inconclusive for #{bead_id}"
        _ -> "Tribunal: changes requested for #{bead_id}"
      end

    Arbiter.Messages.Message.send_mail(%{
      kind: :escalation,
      to_ref: "admiral",
      from_ref: bead_id,
      workspace_id: ws_id,
      directive_ref: bead_id,
      subject: subject,
      body: findings
    })

    :ok
  rescue
    e -> log_tribunal_warning(bead_id, e)
  catch
    :exit, _ -> :ok
  end

  defp escalate_tribunal(_state, _verdict, _findings), do: :ok

  defp log_tribunal_warning(bead_id, reason) do
    Logger.warning(
      "Polecat.record_tribunal_outcome swallowed for bead=#{bead_id}: #{inspect(reason)}"
    )

    :error
  end

  @impl true
  def terminate(_reason, %State{bead_id: bead_id} = state) do
    # Finalize the run row before we tear down. This is the normal-path
    # bookkeeping the boot reconciler (bd-6k8519) was silently masking: the
    # real acolyte-completion path is `arb done` -> bead closes -> the bead
    # `:close` after-action StopPolecat calls `Polecat.stop` -> terminate/2
    # from a NON-terminal state (:running/:idle/:awaiting/:awaiting_review).
    # Nothing on that path ever marks the row terminal, so it stayed :running
    # until the next server boot. See finalize_run_on_terminate/1.
    finalize_run_on_terminate(state)

    # Explicitly unregister so callers that ask `whereis/1` immediately after
    # `GenServer.stop/1` see `nil` deterministically. Registry's own
    # monitor-based cleanup runs asynchronously and was the source of a flaky
    # test where `whereis/1` returned the dead pid briefly after stop.
    PRegistry.unregister(bead_id)
    broadcast_lifecycle(:stopped, state)
    :ok
  end

  # On termination, guarantee the polecat_runs row is closed out.
  #
  #   * :completed / :failed — the row was already stamped by complete_now/2 or
  #     fail_now/2 (the explicit complete/fail paths). Don't double-write.
  #   * any non-terminal status (:idle/:running/:awaiting/:awaiting_review) —
  #     the polecat is being torn down without an explicit terminal transition
  #     (the normal `arb done` -> bead :close -> StopPolecat teardown). Treat
  #     the termination as completion and stamp the row :completed + completed_at
  #     so `arb polecat show` reflects the finished run immediately, with no
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

  defp call(bead_id, msg) when is_binary(bead_id) do
    case whereis(bead_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, msg)
    end
  end

  defp snapshot(%State{} = s) do
    %{
      bead_id: s.bead_id,
      workspace_id: s.workspace_id,
      rig: s.rig,
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
  # and spawn the Warden. Returns `{:ok, mr_ref, new_state}` on success or
  # `{:error, reason, unchanged_state}` on failure.
  #
  # Shared by the explicit open_mr/5 API (handle_call) and the acolyte
  # completion path (the arb-done handler) so the branch is always integrated
  # through the same code, regardless of how completion was triggered. For the
  # default Direct strategy this performs the local `git merge --no-ff`
  # synchronously; the Warden then completes the polecat on its first poll.
  defp do_open_mr(%State{} = state, branch, title, description, opts) do
    case resolve_merger(state, opts) do
      {:ok, adapter, workspace} ->
        Arbiter.Mergers.prepare(workspace)
        open_opts = build_open_opts(state, opts)

        case safe_open(adapter, branch, title, description, open_opts) do
          {:ok, mr_ref} ->
            merger_url = safe_link_for(adapter, mr_ref)

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

            start_warden(new_state, workspace, opts)
            {:ok, mr_ref, new_state}

          {:error, reason} ->
            Logger.warning(
              "Polecat.open_mr: adapter open failed for bead=#{state.bead_id}: #{inspect(reason)}"
            )

            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Resolve {adapter, workspace} for an open_mr/5 call. An explicit `:adapter`
  # in opts wins (test/advanced override); otherwise resolve from the polecat's
  # workspace via Arbiter.Mergers.for_workspace/1.
  defp resolve_merger(%State{} = state, opts) do
    cond do
      adapter = Map.get(opts, :adapter) ->
        {:ok, adapter, Map.get(opts, :workspace)}

      is_binary(state.workspace_id) ->
        case Ash.get(Arbiter.Beads.Workspace, state.workspace_id) do
          {:ok, ws} -> {:ok, Arbiter.Mergers.for_workspace(ws), ws}
          _ -> {:error, :workspace_not_found}
        end

      true ->
        {:error, :no_workspace}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # Build the opts map handed to the adapter's open/4. Carries the bead-domain
  # keys and, when the caller didn't supply them, defaults from the polecat's
  # meta:
  #
  #   * :repo_path — the rig path (local checkout where the target branch
  #     lives) the Direct adapter runs `git merge --no-ff` inside. Seeded into
  #     meta at sling time; falls back to the worktree path for older callers.
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

  # Spawn the Warden that polls for approval. auto_merge + poll interval come
  # from the workspace config (opts may override, primarily for tests).
  defp start_warden(%State{} = state, workspace, opts) do
    auto_merge =
      case Map.fetch(opts, :auto_merge) do
        {:ok, v} -> v
        :error -> workspace_auto_merge?(workspace)
      end

    warden_opts =
      [
        bead_id: state.bead_id,
        polecat: self(),
        mr_ref: state.mr_ref,
        adapter: state.merger_adapter,
        workspace: workspace,
        auto_merge: auto_merge
      ]
      |> maybe_opt(:interval_ms, Map.get(opts, :interval_ms))
      |> maybe_opt(:initial_delay_ms, Map.get(opts, :initial_delay_ms))

    case Arbiter.Polecat.Warden.start(warden_opts) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Polecat.open_mr: failed to start Warden for bead=#{state.bead_id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp workspace_auto_merge?(%Arbiter.Beads.Workspace{} = ws),
    do: Arbiter.Beads.Workspace.auto_merge?(ws)

  defp workspace_auto_merge?(_), do: false

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
