defmodule Arbiter.Workflows.Conductor do
  @moduledoc """
  Per-Graph engine. A supervised GenServer that drives a single **running**
  `Arbiter.Tasks.Graph` to completion: it kicks the graph off, then keeps the
  ready set flowing into `Arbiter.Worker.Dispatch` as work closes.

  This is C4 of #482 — effective concurrency cap + swappable quota gate. The
  cap each drain cycle is:

      effective_cap = min(workspace_max_concurrent, system_max_concurrent, quota_headroom)

  where `quota_headroom` comes from the pluggable `Arbiter.Workflows.QuotaGate`
  behaviour (`:unlimited` when quota is healthy, `0` to hold all dispatch).
  Failure handling (C5) and crash-safety / restart (C6) are separate children.

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
      can dispatch more than this many members at once. Default from
      `:arbiter, :conductor_system_max_concurrent`, else `16`.
    * `:quota_gate` — module implementing `Arbiter.Workflows.QuotaGate` (default
      from `:arbiter, :conductor_quota_gate`, else
      `Arbiter.Workflows.QuotaGate.Default`).
    * `:dispatcher` — module implementing `dispatch/2` (default from
      `:arbiter, :conductor_dispatcher`, else `Arbiter.Worker.Dispatch`).
    * `:dispatch_depth` — recursion depth minted into dispatched workers'
      scopes (default `0`).
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Graph
  alias Arbiter.Tasks.GraphMember
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.ConductorSupervisor

  @topic "tasks"
  @gating_types [:depends_on, :blocks]
  @default_system_max 16

  defmodule State do
    @moduledoc false
    defstruct [
      :graph_id,
      :workspace_id,
      :workspace_max_concurrent,
      :system_max_concurrent,
      :quota_gate,
      :dispatcher,
      :dispatch_depth,
      member_ids: MapSet.new(),
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

    system_max = resolve_system_max(opts)
    workspace_max = resolve_workspace_max(opts, workspace_id, system_max)

    :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, @topic)

    state = %State{
      graph_id: graph_id,
      workspace_id: workspace_id,
      workspace_max_concurrent: workspace_max,
      system_max_concurrent: system_max,
      quota_gate: resolve_quota_gate(opts),
      dispatcher: Keyword.get(opts, :dispatcher, default_dispatcher()),
      dispatch_depth: Keyword.get(opts, :dispatch_depth, 0),
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

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  @impl true
  def handle_call(:drain, _from, %State{} = state) do
    {dispatched, state} = do_drain(state)
    {:reply, dispatched, state}
  end

  def handle_call(:state, _from, %State{} = state) do
    {:reply, snapshot(state), state}
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

  defp resolve_system_max(opts) do
    Keyword.get(
      opts,
      :system_max_concurrent,
      Application.get_env(:arbiter, :conductor_system_max_concurrent, @default_system_max)
    )
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
         quota_gate: gate,
         workspace_id: ws_id
       }) do
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
      case safe_dispatch(state.dispatcher, task_id, depth: depth) do
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
      system_max_concurrent: state.system_max_concurrent,
      dispatch_depth: state.dispatch_depth,
      member_ids: state.member_ids,
      drained?: state.drained?
    }
  end

  defp default_dispatcher do
    Application.get_env(:arbiter, :conductor_dispatcher, Arbiter.Worker.Dispatch)
  end
end
