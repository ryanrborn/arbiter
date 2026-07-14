defmodule Arbiter.Workflows.Conductor do
  @moduledoc """
  Per-Graph engine. A supervised GenServer that drives a single **running**
  `Arbiter.Tasks.Graph` to completion: it kicks the graph off, then keeps the
  ready set flowing into `Arbiter.Worker.Dispatch` as work closes.

  C4 added the effective concurrency cap + swappable quota gate:

      effective_cap = min(workspace_max_concurrent, system_max_concurrent, quota_headroom)

  C5 adds failure handling: when a member's worker fails, the Conductor pauses
  that node's downstream branch and escalates to the Admiral inbox. Independent
  branches keep running. The Admiral can resume via the `queue_resume` MCP tool
  or `arb queue resume <task_id>`.

  ## Crash-safe boot recovery (C6)

  All Conductor state is **derived from the DB** — graph scope (`GraphMember`),
  gating/conflict edges (`Dependency`), and member statuses (`Issue`) — never
  held only in memory. Nothing is lost when the node dies: the next boot
  reconstructs the in-flight picture by reading those rows.

  The boot entry point lives in `Arbiter.Workflows.ConductorReconciler`
  (`reconcile_running_graphs/1`, wired in `Arbiter.Application`, mirroring the
  `Workers.Reconciler` boot Task). For every graph still in `:running` it
  re-spawns a supervised Conductor (idempotent via the Registry), whose `init`
  rebuilds the member set from the DB and whose `:initial_drain` resumes the
  drain exactly where the crash left off. The sweep is gated on
  `Arbiter.SingleInstance.primary?/0`, so a second instance booting against the
  same DB starts no Conductors and cannot double-dispatch the primary's work.

  Two layers keep the resumed drain from re-dispatching work that was already in
  flight or completed at crash time:

    * **Status exclusion** — `Issue.ready/0` returns only `:open` issues, so a
      member that was `:in_progress` (mid-run) or `:closed` (just-completed) at
      crash time is never re-dispatched. Gated branches stay gated, so no ready
      work is lost either.
    * **Live-worker exclusion** — the drain additionally never dispatches a task
      that already has a live worker registered under `Arbiter.Worker.Registry`
      (belt-and-suspenders beyond the status check — closes the window where a
      worker is alive but its `:in_progress` write hasn't yet landed; injectable
      via `:worker_live?` for tests).

  ## Kickoff

  `kickoff/2` flips a graph `:draft → :running`, but **first** validates that the
  gating edges among its members form a DAG. A cyclic graph is refused —
  `{:error, {:cyclic, cycle}}` — and is left in `:draft` with no process
  started; the offending cycle is named (`cycle` is the closed walk of member
  issue ids). Only `:depends_on` / `:blocks` participate in the cycle check;
  `:conflicts_with` is a non-gating mutex and is excluded (see
  `Arbiter.Tasks.Dependency`).

  ## Event-driven drain

  The Conductor subscribes to the `"tasks"` PubSub topic and reacts to
  `{:task_lifecycle, :closed, issue}`. When a **member** of its graph closes, it
  recomputes the ready set (`Arbiter.Tasks.Issue.ready/0` filtered to graph
  members) and dispatches newly-ready directives. Closes outside the graph's
  scope are ignored cheaply (an O(1) membership check, no DB hit).

  ## Honoring the graph

  * **Ordering** — readiness is sourced from `Issue.ready/0`, which already
    gates on `:depends_on` / `:blocks`. The Conductor never dispatches a
    directive whose gating blockers are still open.
  * **Mutual exclusion** — two directives joined by `:conflicts_with` are never
    co-dispatched. A ready directive is held back if a conflicting peer is
    already `:in_progress`, or if a conflicting peer was already selected
    earlier in the same drain pass. `:conflicts_with` is symmetric, so the edge
    is honored regardless of which direction it was stored in.
  * **Concurrency** — the effective cap per drain cycle is
    `min(workspace_max_concurrent, system_max_concurrent, quota_headroom)`.
    Available slots = effective cap minus the members currently `:in_progress`.

  ## Quota gate

  Quota is consulted once per drain cycle via the `Arbiter.Workflows.QuotaGate`
  behaviour. The default implementation (`QuotaGate.Default`) reads the latest
  captured Anthropic quota snapshot from the DB and holds dispatch when
  `status_5h` is not "allowed" or `utilization_5h` exceeds the configured
  ceiling (default 0.85). A smarter throttle (#464) can replace it by passing
  `:quota_gate` at kickoff or via application config — the Conductor is
  unchanged.

  ## Dispatch

  Dispatch goes through `Arbiter.Worker.Dispatch.dispatch/2` (injectable for
  tests via `:dispatcher`). The Conductor is the root of its dispatch tree
  (operator-equivalent), so it dispatches at `dispatch_depth: 0` by default; the
  spawned workers carry that depth and the existing recursion guardrail
  (`Arbiter.MCP.max_depth/0`) caps any further chain. As a belt-and-suspenders,
  the Conductor refuses to dispatch when its own `dispatch_depth` has already
  reached the cap.

  ## Completion

  When every member of the graph is `:closed`, the graph is transitioned
  `:running → :drained` (terminal) and the Conductor stops normally.

  ## Configuration (start_link/1 opts)

    * `:graph_id` (string, required) — the graph this Conductor drives.
    * `:name` — process name (default `__MODULE__`); the supervisor forces a
      `{:via, Registry, …}` tuple keyed by `graph_id`.
    * `:workspace_max_concurrent` — per-workspace concurrency cap (default:
      resolved from workspace `config["conductor"]["max_concurrent"]`, else the
      system max). Alias `:max_concurrent` accepted for backwards compatibility.
    * `:system_max_concurrent` — install-wide concurrency ceiling; no workspace
      can dispatch more than this many members at once. When omitted (the
      normal case), it is resolved **live on every drain cycle** — first the
      runtime-settable `Arbiter.Settings.conductor_system_max_concurrent/0`
      (bd-2ogep0: readable/writable via the `installation_config_get/set` MCP
      tools with no redeploy), else the `:arbiter,
      :conductor_system_max_concurrent` application env, else `16` — so a
      change takes effect immediately for every running Conductor's next
      drain pass and for any newly kicked-off graph, no restart required.
      Passing this opt explicitly (e.g. in tests) pins the cap for that
      Conductor's whole lifetime instead.
    * `:quota_gate` — module implementing `Arbiter.Workflows.QuotaGate` (default
      from `:arbiter, :conductor_quota_gate`, else
      `Arbiter.Workflows.QuotaGate.Default`).
    * `:dispatcher` — module implementing `dispatch/2` (default from
      `:arbiter, :conductor_dispatcher`, else `Arbiter.Worker.Dispatch`).
    * `:dispatch_depth` — recursion depth minted into dispatched workers'
      scopes (default `0`).
    * `:worker_live?` — 1-arity fun `task_id -> boolean` deciding whether a task
      already has a live worker (default checks `Arbiter.Worker.Registry`). A
      task reported live is never dispatched — the C6 belt-and-suspenders against
      re-dispatching work that survived (or partially survived) a restart.
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Graph
  alias Arbiter.Tasks.GraphMember
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.ConductorSupervisor

  @topic "tasks"
  @events_topic "events"
  @gating_types [:depends_on, :blocks]
  @default_system_max 16

  defmodule State do
    @moduledoc false
    defstruct [
      :graph_id,
      :workspace_id,
      :workspace_max_concurrent,
      :system_max_concurrent,
      # true when :system_max_concurrent was pinned via an explicit opt; when
      # false, effective_cap/1 re-resolves the cap live every drain cycle
      # instead of trusting this stale snapshot.
      :system_max_explicit?,
      :quota_gate,
      :dispatcher,
      :dispatch_depth,
      # C6: liveness predicate `task_id -> boolean` — a task with a live worker
      # is never (re-)dispatched. Injectable for tests.
      :worker_live?,
      member_ids: MapSet.new(),
      # C5: members whose worker has failed
      failed_ids: MapSet.new(),
      # C5: members blocked by a failed upstream (their branch is paused)
      paused_ids: MapSet.new(),
      drained?: false
    ]
  end

  # ---- public API ---------------------------------------------------------

  @doc """
  Kick a graph off: validate acyclicity, transition `:draft → :running`, and
  start a supervised Conductor for it.

  Returns `{:ok, pid}` on success. Refuses with:

    * `{:error, :graph_not_found}` — no such graph.
    * `{:error, {:not_draft, run_state}}` — graph isn't in `:draft`.
    * `{:error, {:cyclic, cycle}}` — gating edges among members form a cycle;
      the graph is left in `:draft` and no process is started. `cycle` is the
      list of member issue ids forming the offending loop (closed walk).
    * `{:error, {:transition_failed, reason}}` — the FSM transition was rejected.

  `opts` are forwarded to `start_link/1` (`:workspace_max_concurrent`,
  `:system_max_concurrent`, `:quota_gate`, `:dispatcher`, …).
  """
  @spec kickoff(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def kickoff(graph_id, opts \\ []) when is_binary(graph_id) do
    with {:ok, graph} <- load_graph(graph_id),
         :ok <- ensure_draft(graph),
         :ok <- validate_acyclic(graph_id),
         {:ok, _running} <- transition_running(graph),
         {:ok, pid} <- start_under_supervisor(graph_id, opts) do
      {:ok, pid}
    end
  end

  @doc """
  Validate that the gating edges (`:depends_on` / `:blocks`) among `graph_id`'s
  members form a DAG.

  Returns `:ok`, or `{:error, {:cyclic, cycle}}` where `cycle` is the list of
  member issue ids forming the offending cycle as a closed walk (the first id
  repeats at the end). `:conflicts_with` is excluded — it is a non-gating mutex,
  not an ordering edge. Pure (no side effects); safe to call before kickoff.
  """
  @spec validate_acyclic(String.t()) :: :ok | {:error, {:cyclic, [String.t()]}}
  def validate_acyclic(graph_id) when is_binary(graph_id) do
    member_ids = member_issue_ids(graph_id)
    detect_cycle(member_ids, gating_edges(member_ids))
  end

  @doc """
  Start a Conductor. Prefer `kickoff/2`, which validates + transitions first.
  See the moduledoc for options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Synchronously run a drain cycle and return the list of issue ids dispatched in
  this pass. Mostly for tests / manual nudges — the live loop is event-driven.
  Unlike the event path, a synchronous drain never stops the process.
  """
  @spec drain(GenServer.server()) :: [String.t()]
  def drain(server), do: GenServer.call(server, :drain)

  @doc "Return a snapshot of the Conductor's state for inspection / tests."
  @spec state(GenServer.server()) :: map()
  def state(server), do: GenServer.call(server, :state)

  @doc """
  Resume a failed member: re-dispatch it, clear its downstream from the paused
  set, and continue the drain. Returns `:ok` on success, or:

    * `{:error, :not_member}` — `task_id` is not a member of this graph.
    * `{:error, :not_failed}` — `task_id` is a member but has not failed.
    * `{:error, :dispatch_failed}` — re-dispatch call returned `:error`.

  Use `resume_task/1` when you don't have the pid and want the system to
  locate the right conductor automatically.
  """
  @spec resume(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def resume(server, task_id) when is_binary(task_id),
    do: GenServer.call(server, {:resume, task_id})

  @doc """
  Find the running Conductor that has `task_id` in its failed set and resume it.

  Searches all running Conductors via the `ConductorSupervisor` Registry. The
  Admiral calls this when acknowledging a failure escalation — no need to know
  which graph the task belongs to.

  Returns `:ok`, `{:error, :not_found}` (no conductor holds the task as failed),
  or any `resume/2` error forwarded from the matched conductor.
  """
  @spec resume_task(String.t()) :: :ok | {:error, term()}
  def resume_task(task_id) when is_binary(task_id) do
    conductors = ConductorSupervisor.list_conductors()

    result =
      Enum.find_value(conductors, :not_found, fn {_graph_id, pid} ->
        # `list_conductors/0` is a best-effort Registry snapshot; a conductor
        # can terminate between the listing and this call. Guard the call so a
        # dying conductor is skipped (the scan continues) rather than letting
        # the `:exit` propagate out of `resume_task/1` — which `action_fallback`
        # (it only matches `{:error, _}`, not exits) would surface as a 500.
        try do
          snap = GenServer.call(pid, :state)

          if MapSet.member?(snap.failed_ids, task_id) do
            {:found, pid}
          else
            nil
          end
        catch
          :exit, _ -> nil
        end
      end)

    case result do
      :not_found -> {:error, :not_found}
      {:found, pid} -> resume(pid, task_id)
    end
  end

  # ---- GenServer callbacks ------------------------------------------------

  @impl true
  def init(opts) do
    graph_id =
      case Keyword.fetch(opts, :graph_id) do
        {:ok, id} when is_binary(id) and id != "" -> id
        _ -> raise ArgumentError, "Conductor requires :graph_id"
      end

    workspace_id =
      case Ash.get(Graph, graph_id) do
        {:ok, graph} -> graph.workspace_id
        _ -> Keyword.get(opts, :workspace_id)
      end

    {system_max, system_max_explicit?} = resolve_system_max(opts)
    workspace_max = resolve_workspace_max(opts, workspace_id, system_max)

    :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, @topic)

    # C5: subscribe to the workspace-scoped events topic so we receive
    # worker_failed broadcasts from the Driver without polling.
    events_sub =
      if workspace_id, do: "events:" <> workspace_id, else: @events_topic

    :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, events_sub)

    state = %State{
      graph_id: graph_id,
      workspace_id: workspace_id,
      workspace_max_concurrent: workspace_max,
      system_max_concurrent: system_max,
      system_max_explicit?: system_max_explicit?,
      quota_gate: resolve_quota_gate(opts),
      dispatcher: Keyword.get(opts, :dispatcher, default_dispatcher()),
      dispatch_depth: Keyword.get(opts, :dispatch_depth, 0),
      worker_live?: Keyword.get(opts, :worker_live?, &default_worker_live?/1),
      member_ids: MapSet.new(member_issue_ids(graph_id))
    }

    {:ok, state, {:continue, :initial_drain}}
  end

  @impl true
  def handle_continue(:initial_drain, %State{} = state) do
    {_dispatched, state} = do_drain(state)
    maybe_stop(state)
  end

  @impl true
  def handle_info({:task_lifecycle, :closed, %{id: id}}, %State{} = state)
      when is_binary(id) do
    if MapSet.member?(state.member_ids, id) do
      {_dispatched, state} = do_drain(state)
      maybe_stop(state)
    else
      {:noreply, state}
    end
  end

  # Other lifecycle events (created / updated / reopened) don't advance the
  # drain — readiness only changes on a close.
  def handle_info({:task_lifecycle, _event, _issue}, %State{} = state),
    do: {:noreply, state}

  # C5: a member's worker failed — pause its downstream branch and escalate.
  def handle_info({:event, %{topic: "worker_failed", task_id: id}}, %State{} = state)
      when is_binary(id) do
    if MapSet.member?(state.member_ids, id) do
      {:noreply, handle_member_failure(id, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  @impl true
  def handle_call(:drain, _from, %State{} = state) do
    {dispatched, state} = do_drain(state)
    {:reply, dispatched, state}
  end

  def handle_call(:state, _from, %State{} = state) do
    {:reply, snapshot(state), state}
  end

  # C5: resume a failed member — clear it from the failed set, recompute
  # paused_ids from remaining failed members, re-dispatch, then drain.
  def handle_call({:resume, task_id}, _from, %State{} = state) do
    cond do
      not MapSet.member?(state.member_ids, task_id) ->
        {:reply, {:error, :not_member}, state}

      not MapSet.member?(state.failed_ids, task_id) ->
        {:reply, {:error, :not_failed}, state}

      true ->
        new_failed_ids = MapSet.delete(state.failed_ids, task_id)
        edges = gating_edges(MapSet.to_list(state.member_ids))
        new_paused_ids = compute_all_paused(new_failed_ids, edges)
        state = %{state | failed_ids: new_failed_ids, paused_ids: new_paused_ids}

        case dispatch_one(task_id, state) do
          :ok ->
            {:reply, :ok, state}

          :error ->
            {:reply, {:error, :dispatch_failed}, state}
        end
    end
  end

  # ---- kickoff helpers ----------------------------------------------------

  defp load_graph(graph_id) do
    case Ash.get(Graph, graph_id) do
      {:ok, graph} -> {:ok, graph}
      {:error, _} -> {:error, :graph_not_found}
    end
  end

  defp ensure_draft(%{run_state: :draft}), do: :ok
  defp ensure_draft(%{run_state: state}), do: {:error, {:not_draft, state}}

  defp transition_running(graph) do
    case Ash.update(graph, %{run_state: :running}) do
      {:ok, graph} -> {:ok, graph}
      {:error, reason} -> {:error, {:transition_failed, reason}}
    end
  end

  defp start_under_supervisor(graph_id, opts) do
    case ConductorSupervisor.start_conductor(graph_id, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  # ---- cap resolution -----------------------------------------------------

  # `{cap, explicit?}` — an explicit opt pins the cap for this Conductor's
  # whole lifetime; otherwise the cap is left to be re-resolved live on every
  # drain cycle (see `effective_cap/1`) so a runtime setting change takes
  # effect without restarting an already-running Conductor.
  defp resolve_system_max(opts) do
    case Keyword.get(opts, :system_max_concurrent) do
      n when is_integer(n) and n > 0 -> {n, true}
      _ -> {live_system_max(), false}
    end
  end

  # bd-2ogep0: the install-wide Conductor concurrency ceiling, resolved fresh
  # each call — runtime-settable override (`Arbiter.Settings`), else the
  # `:arbiter, :conductor_system_max_concurrent` app env, else the hardcoded
  # default. Never raises: `Arbiter.Settings.conductor_system_max_concurrent/0`
  # already swallows DB errors and returns `nil`.
  defp live_system_max do
    Arbiter.Settings.conductor_system_max_concurrent() ||
      Application.get_env(:arbiter, :conductor_system_max_concurrent, @default_system_max)
  end

  # Workspace max: explicit opt wins (either key), then workspace config, then
  # system max. The `:max_concurrent` key is accepted as a backwards-compat
  # alias for `:workspace_max_concurrent`.
  defp resolve_workspace_max(opts, workspace_id, system_max) do
    explicit =
      Keyword.get(opts, :workspace_max_concurrent) || Keyword.get(opts, :max_concurrent)

    case explicit do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        workspace_config_max(workspace_id) || system_max
    end
  end

  defp workspace_config_max(nil), do: nil

  defp workspace_config_max(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> Workspace.max_concurrent(ws)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp resolve_quota_gate(opts) do
    Keyword.get(
      opts,
      :quota_gate,
      Application.get_env(
        :arbiter,
        :conductor_quota_gate,
        Arbiter.Workflows.QuotaGate.Default
      )
    )
  end

  # Effective cap this drain cycle: min of the two hardware caps, then further
  # bounded by the quota headroom returned by the gate. Returns 0 when the gate
  # holds all dispatch.
  defp effective_cap(%State{
         workspace_max_concurrent: w_max,
         system_max_concurrent: s_max,
         system_max_explicit?: explicit?,
         quota_gate: gate,
         workspace_id: ws_id
       }) do
    s_max = if explicit?, do: s_max, else: live_system_max()
    base = min(w_max, s_max)

    case safe_quota_headroom(gate, ws_id) do
      :unlimited -> base
      n -> min(base, n)
    end
  end

  defp safe_quota_headroom(gate, workspace_id) do
    gate.quota_headroom(workspace_id)
  rescue
    e ->
      Logger.warning("QuotaGate.quota_headroom/1 raised: #{Exception.message(e)}; allowing")
      :unlimited
  catch
    :exit, reason ->
      Logger.warning("QuotaGate.quota_headroom/1 exited: #{inspect(reason)}; allowing")
      :unlimited
  end

  # ---- drain loop ---------------------------------------------------------

  # Recompute the ready set within the graph and dispatch up to the available
  # slots, honoring conflicts_with. Returns `{dispatched_ids, state}`. Sets
  # `drained?: true` (after transitioning the graph) once every member is closed.
  defp do_drain(%State{graph_id: graph_id} = state) do
    member_ids = member_issue_ids(graph_id)
    state = %{state | member_ids: MapSet.new(member_ids)}

    case load_running_graph(graph_id) do
      {:ok, graph} -> drain_members(state, graph, member_ids)
      :not_running -> {[], state}
    end
  end

  # A graph with no members has nothing to drive — and nothing to "complete",
  # so it is NOT auto-drained (a still-being-assembled graph could legitimately
  # have zero members at kickoff).
  defp drain_members(state, _graph, []), do: {[], state}

  defp drain_members(state, graph, member_ids) do
    member_set = MapSet.new(member_ids)
    member_issues = load_member_issues(member_ids)

    if member_issues != [] and Enum.all?(member_issues, &(&1.status == :closed)) do
      :ok = transition_drained(graph)
      {[], %{state | drained?: true}}
    else
      active_ids =
        for issue <- member_issues, issue.status == :in_progress, into: MapSet.new(), do: issue.id

      cap = effective_cap(state)
      slots = max(0, cap - MapSet.size(active_ids))

      ready =
        [workspace_id: state.workspace_id]
        |> Issue.ready()
        |> Enum.filter(&MapSet.member?(member_set, &1.id))
        # C5: don't dispatch tasks whose branch is paused by a failed upstream
        |> Enum.reject(&MapSet.member?(state.paused_ids, &1.id))
        # C6: never (re-)dispatch a task that already has a live worker — guards
        # the boot window where a worker survived (or partially survived) a crash
        # and a non-primary/duplicate boot.
        |> Enum.reject(&worker_in_flight?(state, &1.id))
        |> Enum.sort_by(&{&1.priority, &1.id})

      conflicts = conflict_adjacency(member_ids)
      dispatched = select_and_dispatch(ready, slots, active_ids, conflicts, state)
      {dispatched, state}
    end
  end

  # Greedy admission: walk the ready set in (priority, id) order and dispatch
  # while slots remain, skipping any directive that conflicts with an already
  # active or already-selected directive. `claimed` accumulates active +
  # selected ids so the within-pass conflicts_with serialization holds.
  defp select_and_dispatch(ready, slots, active_ids, conflicts, state) do
    {dispatched, _claimed, _slots} =
      Enum.reduce(ready, {[], active_ids, slots}, fn issue, {acc, claimed, remaining} ->
        cond do
          remaining <= 0 ->
            {acc, claimed, remaining}

          conflicts_with_claimed?(issue.id, claimed, conflicts) ->
            {acc, claimed, remaining}

          true ->
            case dispatch_one(issue.id, state) do
              :ok -> {[issue.id | acc], MapSet.put(claimed, issue.id), remaining - 1}
              :error -> {acc, claimed, remaining}
            end
        end
      end)

    Enum.reverse(dispatched)
  end

  defp conflicts_with_claimed?(issue_id, claimed, conflicts) do
    case Map.get(conflicts, issue_id) do
      nil -> false
      neighbors -> not MapSet.disjoint?(neighbors, claimed)
    end
  end

  defp dispatch_one(task_id, %State{dispatch_depth: depth, graph_id: graph_id} = state) do
    max_depth = Arbiter.MCP.max_depth()

    if depth >= max_depth do
      Logger.warning(
        "Conductor[#{graph_id}]: refusing to dispatch #{task_id} — dispatch depth " <>
          "#{depth} has reached the cap (#{max_depth})"
      )

      :error
    else
      dispatch_opts =
        [depth: depth, start_claude: true]
        |> maybe_put_repo(member_repo(graph_id, task_id))

      case safe_dispatch(state.dispatcher, task_id, dispatch_opts) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Conductor[#{graph_id}]: dispatch of #{task_id} failed: #{inspect(reason)}"
          )

          :error
      end
    end
  end

  # A failing or crashing dispatch must never take the Conductor down — a single
  # bad directive shouldn't stall the whole graph.
  defp safe_dispatch(dispatcher, task_id, opts) do
    dispatcher.dispatch(task_id, opts)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # ---- graph / dependency reads -------------------------------------------

  defp load_running_graph(graph_id) do
    case Ash.get(Graph, graph_id) do
      {:ok, %{run_state: :running} = graph} -> {:ok, graph}
      _ -> :not_running
    end
  end

  defp transition_drained(graph) do
    case Ash.update(graph, %{run_state: :drained}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Conductor[#{graph.id}]: failed to transition :running → :drained: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp member_issue_ids(graph_id) do
    GraphMember
    |> Ash.Query.filter(graph_id == ^graph_id)
    |> Ash.read!()
    |> Enum.map(& &1.issue_id)
  end

  # bd-69c78q: without a repo opt, `Dispatch.resolve_repo_for_dispatch/2` errors
  # `{:ambiguous_repo, _}` on every dispatch in a workspace with more than one
  # configured repo — read straight from the DB (not cached in `State`) so a
  # `graph_add_directive` repo update mid-run takes effect on the very next
  # drain, per the module's "everything derived from the DB" contract.
  defp member_repo(graph_id, issue_id) do
    GraphMember
    |> Ash.Query.filter(graph_id == ^graph_id and issue_id == ^issue_id)
    |> Ash.read!()
    |> case do
      [%{repo: repo} | _] -> repo
      [] -> nil
    end
  end

  defp maybe_put_repo(opts, nil), do: opts
  defp maybe_put_repo(opts, repo), do: Keyword.put(opts, :repo, repo)

  defp load_member_issues([]), do: []

  defp load_member_issues(member_ids) do
    Issue
    |> Ash.Query.filter(id in ^member_ids)
    |> Ash.read!()
  end

  # All gating edges among members, normalized to "dependent → dependency"
  # directed edges (the dependent waits for the dependency):
  #   * depends_on(from, to) → from waits for to → {from, to}
  #   * blocks(from, to)     → to waits for from → {to, from}
  defp gating_edges(member_ids) do
    member_set = MapSet.new(member_ids)
    gating = @gating_types

    Dependency
    |> Ash.Query.filter(type in ^gating)
    |> Ash.read!()
    |> Enum.filter(fn d ->
      MapSet.member?(member_set, d.from_issue_id) and MapSet.member?(member_set, d.to_issue_id)
    end)
    |> Enum.map(fn
      %{type: :depends_on, from_issue_id: from, to_issue_id: to} -> {from, to}
      %{type: :blocks, from_issue_id: from, to_issue_id: to} -> {to, from}
    end)
  end

  # Symmetric conflicts_with adjacency among members: %{id => MapSet(peers)}.
  # The edge is stored in a single direction but means the same both ways, so
  # both endpoints get the other recorded.
  defp conflict_adjacency(member_ids) do
    member_set = MapSet.new(member_ids)
    conflicts_with = :conflicts_with

    Dependency
    |> Ash.Query.filter(type == ^conflicts_with)
    |> Ash.read!()
    |> Enum.reduce(%{}, fn d, acc ->
      if MapSet.member?(member_set, d.from_issue_id) and
           MapSet.member?(member_set, d.to_issue_id) do
        acc
        |> add_conflict(d.from_issue_id, d.to_issue_id)
        |> add_conflict(d.to_issue_id, d.from_issue_id)
      else
        acc
      end
    end)
  end

  defp add_conflict(map, a, b) do
    Map.update(map, a, MapSet.new([b]), &MapSet.put(&1, b))
  end

  # ---- cycle detection ----------------------------------------------------

  # Build a :digraph over member vertices + gating edges and look for the
  # shortest cycle through any vertex (sorted for determinism). Returns `:ok` or
  # `{:error, {:cyclic, cycle}}`.
  defp detect_cycle(member_ids, edges) do
    graph = :digraph.new()

    try do
      Enum.each(member_ids, &:digraph.add_vertex(graph, &1))
      Enum.each(edges, fn {a, b} -> :digraph.add_edge(graph, a, b) end)

      member_ids
      |> Enum.sort()
      |> Enum.find_value(fn vertex ->
        case :digraph.get_short_cycle(graph, vertex) do
          false -> nil
          cycle -> cycle
        end
      end)
      |> case do
        nil -> :ok
        cycle -> {:error, {:cyclic, cycle}}
      end
    after
      :digraph.delete(graph)
    end
  end

  # ---- misc ---------------------------------------------------------------

  defp maybe_stop(%State{drained?: true} = state), do: {:stop, :normal, state}
  defp maybe_stop(%State{} = state), do: {:noreply, state}

  defp snapshot(%State{} = state) do
    %{
      graph_id: state.graph_id,
      workspace_id: state.workspace_id,
      workspace_max_concurrent: state.workspace_max_concurrent,
      system_max_concurrent:
        if(state.system_max_explicit?, do: state.system_max_concurrent, else: live_system_max()),
      dispatch_depth: state.dispatch_depth,
      member_ids: state.member_ids,
      # C5: failure state
      failed_ids: state.failed_ids,
      paused_ids: state.paused_ids,
      drained?: state.drained?
    }
  end

  defp default_dispatcher do
    Application.get_env(:arbiter, :conductor_dispatcher, Arbiter.Worker.Dispatch)
  end

  # C6: a task is "in flight" if a worker GenServer is registered for it. On a
  # fresh boot the registry is empty (so recovery dispatches freely); mid-life,
  # or on a duplicate boot racing the primary, this prevents double-dispatch of
  # a task whose worker is already alive.
  defp worker_in_flight?(%State{worker_live?: live?}, task_id) when is_function(live?, 1) do
    live?.(task_id)
  rescue
    e ->
      Logger.warning(
        "Conductor: worker_live? check raised: #{Exception.message(e)}; assuming idle"
      )

      false
  end

  defp default_worker_live?(task_id), do: not is_nil(Arbiter.Worker.whereis(task_id))

  # ---- C5: failure handling -----------------------------------------------

  # Process a member failure: compute downstream, update state, escalate.
  defp handle_member_failure(failed_id, %State{} = state) do
    member_list = MapSet.to_list(state.member_ids)
    edges = gating_edges(member_list)
    downstream = compute_downstream(failed_id, edges)
    downstream_only = MapSet.delete(downstream, failed_id)

    new_state = %{
      state
      | failed_ids: MapSet.put(state.failed_ids, failed_id),
        paused_ids: MapSet.union(state.paused_ids, downstream)
    }

    post_failure_escalation(failed_id, downstream_only, new_state)

    new_state
  end

  # Post an addressed :escalation mailbox message to the Admiral.
  defp post_failure_escalation(failed_id, paused_ids, %State{
         workspace_id: ws_id,
         graph_id: graph_id
       })
       when is_binary(ws_id) do
    paused_count = MapSet.size(paused_ids)
    paused_list = paused_ids |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")

    subject =
      "#{failed_id} failed in graph #{graph_id} — #{paused_count} downstream task(s) paused"

    body =
      [
        "Worker for #{failed_id} failed. Its downstream branch has been paused.",
        paused_count > 0 && "Paused tasks: #{paused_list}",
        "Independent branches are still running.",
        "To resume: `arb queue resume #{failed_id}` or call the `queue_resume` MCP tool.",
        "Graph: #{graph_id}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join("\n")

    Message.send_mail(%{
      kind: :escalation,
      to_ref: "admiral",
      from_ref: failed_id,
      workspace_id: ws_id,
      directive_ref: failed_id,
      subject: subject,
      body: body
    })

    :ok
  rescue
    e ->
      Logger.debug(
        "Conductor[#{graph_id}]: failure escalation swallowed: #{Exception.message(e)}"
      )

      :ok
  end

  defp post_failure_escalation(_failed_id, _paused_ids, _state), do: :ok

  # Recompute the full paused set from the current failed set. Used after a
  # resume to remove nodes that are no longer transitively blocked.
  defp compute_all_paused(failed_ids, edges) do
    Enum.reduce(failed_ids, MapSet.new(), fn fid, acc ->
      MapSet.union(acc, compute_downstream(fid, edges))
    end)
  end

  # BFS forward from start_id in the reverse-dependency graph to find all
  # task IDs that transitively depend on start_id. Edges are [{from, to}]
  # where from depends on to; we walk backwards (from "to" to "from") to find
  # everything that will be unblocked only when start_id completes.
  defp compute_downstream(start_id, edges) do
    # reverse_adj: dependency → set of its direct dependents
    reverse_adj =
      Enum.reduce(edges, %{}, fn {from, to}, acc ->
        Map.update(acc, to, MapSet.new([from]), &MapSet.put(&1, from))
      end)

    bfs_downstream(MapSet.new([start_id]), MapSet.new([start_id]), reverse_adj)
  end

  defp bfs_downstream(frontier, visited, reverse_adj) do
    next =
      frontier
      |> Enum.flat_map(fn id ->
        Map.get(reverse_adj, id, MapSet.new()) |> MapSet.to_list()
      end)
      |> MapSet.new()
      |> MapSet.difference(visited)

    if MapSet.size(next) == 0 do
      visited
    else
      bfs_downstream(next, MapSet.union(visited, next), reverse_adj)
    end
  end
end
