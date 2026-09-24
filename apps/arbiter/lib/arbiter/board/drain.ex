defmodule Arbiter.Board.Drain do
  @moduledoc """
  "Is it safe to restart yet?" — the scheduler's drain state (bd-9fgg04 / #1903).

  Pausing the autopilot stops *new board dispatches* and nothing else. A CI
  `fix_pass`, a MergeQueue conflict resolver, a ReviewGate round, an `arb
  dispatch`, a Watchdog auto-resume — none of them consult the pause, by design:
  a pause drains, it does not abandon. So a bare `paused: true` cannot tell
  "paused and quiescent" from "paused and still draining", and the workers still
  running are exactly the ones that did *not* come from the scheduler. This
  module is the one definition of the difference; every surface that reports
  it (`scheduler_status` over MCP and REST, `arb scheduler status|wait`, `arb
  prime`, `arb server doctor`) reads `status/1`, so no two can disagree.

  ## States

    * `:running` — the autopilot is promoting. Never safe to restart: the next
      tick may dispatch.
    * `:draining` — paused, but work is still in flight (`in_flight` says what).
    * `:quiescent` — paused, and nothing of any kind is in flight. The only
      state with `safe_to_restart: true`.

  ## How in-flight work is enumerated — structurally, not by source

  Every code path that runs an agent for a task starts its process under
  `Arbiter.Worker.Supervisor` — `Arbiter.Worker.start/1` (and
  `start_or_reap_terminal/1`, which calls it), `Arbiter.Worker.ReviewGate.start/1`
  and `Arbiter.Worker.Driver.start/1` are the only `start_child` calls against
  it. So in-flight work is read off that supervisor's children, **not** from a
  list of known spawners: a spawn path added tomorrow is counted the day it
  lands, because it cannot run without becoming a child here. The per-source
  `kind` label is descriptive only — it never decides whether something counts.

  A child is in flight unless it is provably idle:

    * an `Arbiter.Worker` whose snapshot status is parked (`:awaiting_review`,
      `:awaiting_review_gate` — no agent, waiting on a reviewer or a merge) or
      terminal (`:completed`, `:failed`) is listed under `parked`, not
      `in_flight`. A parked worker is recovered on the next boot
      (`Workers.Reconciler` hands its open PR to PRPatrol), so it does not make
      a restart unsafe — unless it still owns a live agent session
      (`agent_live`), in which case it is in flight regardless of status;
    * an `Arbiter.Worker` that does not answer its snapshot in time is busy,
      not gone — in flight, kind `:unclassified`, status `:unknown`;
    * a `ReviewGate` or `Driver` is in flight for as long as it lives (a gate
      runs review/impl rounds; a driver ticks a live dispatch's workflow);
    * any other child — a module this code has never heard of — is in flight
      with kind `:unclassified`. Fail closed: an unrecognised process is
      exactly the thing a restart would destroy without anyone knowing.

  ## Live work that is not (yet) a child

  A few sources run agent work without being a child of that supervisor, and
  each is counted explicitly:

    * the autopilot's own promotion task, which provisions a worktree *before*
      `Worker.start/1` runs. `Autopilot.status/2` exposes it as `dispatching`;
      it is listed as kind `:board_promotion`;
    * any `Arbiter.Worker.Dispatch` dispatch / resume still provisioning — the
      Conductor/graph `DispatchQueue`, `arb dispatch`, Watchdog auto-resume, the
      autopilot — kind `:dispatch_pending`, until the call returns;
    * an external PR review (`Arbiter.Reviews.ExternalReview`), kind
      `:external_review`, which shells out to the agent CLI from a plain task;
    * a ReviewPatrol re-review or author reply, kinds `:patrol_rereview` and
      `:review_reply`, which run the agent CLI inside the patrol process.

  Those register themselves in `Arbiter.Board.Drain.Registry` through
  `track/3` for exactly as long as they run. The Registry drops an entry when
  its process dies, so a crashed or killed source can never pin the state at
  `:draining`. A new spawn path outside the worker supervisor must wrap
  itself in `track/3` — that is the one hand-maintained part of this list.

  Not counted, deliberately: `Arbiter.Workflows.Machine` bookkeeping (its state
  is persisted and resumed from the database on boot) and the operator's own
  interactive sessions (they run in tmux, outside this BEAM, and survive a
  restart).

  Quiescence is a point-in-time fact. Nothing here stops a MergeQueue tick or a
  Watchdog poll from spawning a resolver or a fix pass one second later — that
  is the pause working as designed. `arb scheduler wait` re-reads this state
  until it holds; restart promptly after it returns.
  """

  alias Arbiter.Board.Autopilot
  alias Arbiter.Worker
  alias Arbiter.Worker.Driver
  alias Arbiter.Worker.ReviewGate

  @type state :: :running | :draining | :quiescent

  @type kind ::
          :board_promotion
          | :dispatch_pending
          | :external_review
          | :patrol_rereview
          | :review_reply
          | :board_dispatch
          | :dispatch
          | :resume
          | :review_dispatch
          | :fix_pass
          | :conflict_resolver
          | :review_pass
          | :impl_pass
          | :review_gate
          | :driver
          | :unclassified

  @typedoc "The kinds `track/3` registers — agent work outside the worker supervisor."
  @type tracked_kind :: :dispatch_pending | :external_review | :patrol_rereview | :review_reply

  @type entry :: %{
          kind: kind(),
          task_id: String.t() | nil,
          registry_key: String.t() | nil,
          status: atom() | nil,
          agent_live: boolean() | nil,
          started_at: DateTime.t() | nil,
          detail: String.t() | nil,
          pid: pid() | nil
        }

  @type t :: %{
          state: state(),
          paused: boolean(),
          safe_to_restart: boolean(),
          changed_at: DateTime.t() | nil,
          changed_by: String.t() | nil,
          in_flight: [entry()],
          parked: [entry()],
          checked_at: DateTime.t()
        }

  # A worker in one of these statuses holds no agent: it is waiting on a
  # reviewer/merge (parked) or finished (terminal) and merely still resident.
  @idle_statuses [:awaiting_review, :awaiting_review_gate, :completed, :failed]

  # Bounded per-child probe. A worker that can't answer in this long is busy,
  # and counted in flight.
  @snapshot_timeout_ms 1_000

  @registry __MODULE__.Registry

  @tracked_kinds [:dispatch_pending, :external_review, :patrol_rereview, :review_reply]

  @doc """
  Run `fun` while it counts as in-flight work, and return its result.

  For agent work that runs outside `Arbiter.Worker.Supervisor` (see the
  moduledoc). The calling process is registered under `kind` with `meta` —
  `:task_id` and `:detail` (a PR ref, say) are reported — until `fun` returns
  or raises, or the process dies. Calls nest: each one is its own entry.

  Without the Registry running (a script that never started the app), `fun`
  still runs, just uncounted — tracking never blocks the work it describes.
  """
  @spec track(tracked_kind(), map(), (-> result)) :: result when result: term()
  def track(kind, meta, fun)
      when kind in @tracked_kinds and is_map(meta) and is_function(fun, 0) do
    key = {kind, make_ref()}
    registered? = register(key, Map.put_new(meta, :started_at, DateTime.utc_now()))

    try do
      fun.()
    after
      if registered?, do: Registry.unregister(@registry, key)
    end
  end

  defp register(key, value) do
    match?({:ok, _}, Registry.register(@registry, key, value))
  rescue
    ArgumentError -> false
  end

  @doc """
  Read the drain state now.

  Options (for tests; production uses the defaults):

    * `:autopilot` — the autopilot server (default `Arbiter.Board.Autopilot`).
    * `:supervisor` — the worker supervisor (default `Arbiter.Worker.Supervisor`).
    * `:registry` — the `track/3` registry (default `Arbiter.Board.Drain.Registry`).
  """
  @spec status(keyword()) :: t()
  def status(opts \\ []) do
    autopilot = autopilot_status(Keyword.get(opts, :autopilot, Autopilot))
    {in_flight, parked} = worker_entries(Keyword.get(opts, :supervisor, Worker.Supervisor))

    promotions = promotion_entries(autopilot)

    # The autopilot's promotion runs `Dispatch.dispatch/2`, which tracks itself
    # too: list that one promotion once, under its more specific kind.
    tracked =
      opts
      |> Keyword.get(:registry, @registry)
      |> tracked_entries()
      |> Enum.reject(&(&1.kind == :dispatch_pending and promoting?(promotions, &1.task_id)))

    in_flight = promotions ++ tracked ++ in_flight

    state =
      cond do
        not autopilot.paused? -> :running
        in_flight == [] -> :quiescent
        true -> :draining
      end

    %{
      state: state,
      paused: autopilot.paused?,
      safe_to_restart: state == :quiescent,
      changed_at: autopilot.changed_at,
      changed_by: autopilot.changed_by,
      in_flight: in_flight,
      parked: parked,
      checked_at: DateTime.utc_now()
    }
  end

  @doc """
  JSON-safe rendering of `status/1`, shared by the MCP tool and the REST
  endpoint so the two cannot drift. Keeps the original `paused` /
  `changed_at` / `changed_by` keys for existing consumers.
  """
  @spec to_json(t()) :: map()
  def to_json(%{} = status) do
    %{
      state: Atom.to_string(status.state),
      paused: status.paused,
      safe_to_restart: status.safe_to_restart,
      changed_at: status.changed_at,
      changed_by: status.changed_by,
      in_flight: Enum.map(status.in_flight, &entry_json/1),
      parked: Enum.map(status.parked, &entry_json/1),
      checked_at: status.checked_at
    }
  end

  defp entry_json(entry) do
    %{
      kind: Atom.to_string(entry.kind),
      task_id: entry.task_id,
      registry_key: entry.registry_key,
      status: entry.status && Atom.to_string(entry.status),
      agent_live: entry.agent_live,
      started_at: entry.started_at,
      detail: entry.detail
    }
  end

  # ---- autopilot -------------------------------------------------------------

  # An install that isn't running the autopilot at all has no board dispatches
  # to pause — read that as paused (nothing will promote) rather than raising.
  # A registered-but-unresponsive autopilot is NOT that case: its exit
  # propagates, and every caller already turns it into an error, never into a
  # "safe to restart".
  defp autopilot_status(server) do
    if registered?(server) do
      Autopilot.status(server)
    else
      %{paused?: true, changed_at: nil, changed_by: nil, dispatching: nil}
    end
  end

  defp registered?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp registered?(name), do: GenServer.whereis(name) != nil

  defp promotion_entries(%{dispatching: id}) when is_binary(id),
    do: [entry(:board_promotion, id, nil, :dispatching, nil, nil, nil)]

  defp promotion_entries(_), do: []

  defp promoting?(promotions, task_id), do: Enum.any?(promotions, &(&1.task_id == task_id))

  # ---- track/3 registry ------------------------------------------------------

  # A registry that isn't running has nothing registered in it: `track/3`
  # could not have registered anything either, so this is not a blind spot
  # the registry could have closed.
  defp tracked_entries(registry) do
    registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {{kind, _ref}, pid, meta} ->
      %{
        entry(kind, meta[:task_id], nil, nil, nil, meta[:started_at], pid)
        | detail: detail(meta[:detail])
      }
    end)
    |> Enum.sort_by(& &1.started_at, {:asc, DateTime})
  rescue
    ArgumentError -> []
  end

  defp detail(nil), do: nil
  defp detail(value) when is_binary(value), do: value
  defp detail(value), do: inspect(value)

  # ---- worker supervisor -----------------------------------------------------

  defp worker_entries(supervisor) do
    keys = registry_keys_by_pid()

    # Probed concurrently: each snapshot has its own bounded timeout, so a
    # few busy workers cost one timeout, not one each.
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.filter(fn {_id, pid, _type, _modules} -> is_pid(pid) end)
    |> Task.async_stream(
      fn {_id, pid, _type, modules} -> classify_child(pid, modules, keys) end,
      max_concurrency: 32,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, classified} -> classified end)
    |> Enum.split_with(fn {bucket, _entry} -> bucket == :in_flight end)
    |> then(fn {in_flight, parked} ->
      {Enum.map(in_flight, &elem(&1, 1)), Enum.map(parked, &elem(&1, 1))}
    end)
  end

  defp classify_child(pid, [Worker], keys) do
    case snapshot(pid) do
      %{} = snap ->
        entry =
          entry(
            worker_kind(snap),
            snap.task_id,
            Map.get(snap, :registry_key) || Map.get(keys, pid),
            snap.status,
            Map.get(snap, :agent_live),
            snap.started_at,
            pid
          )

        if snap.status in @idle_statuses and Map.get(snap, :agent_live) != true,
          do: {:parked, entry},
          else: {:in_flight, entry}

      nil ->
        {:in_flight,
         entry(:unclassified, key_task_id(keys, pid), keys[pid], :unknown, nil, nil, pid)}
    end
  end

  defp classify_child(pid, [ReviewGate], keys),
    do: {:in_flight, entry(:review_gate, key_task_id(keys, pid), keys[pid], nil, nil, nil, pid)}

  defp classify_child(pid, [Driver], keys),
    do: {:in_flight, entry(:driver, key_task_id(keys, pid), keys[pid], nil, nil, nil, pid)}

  defp classify_child(pid, _modules, keys),
    do: {:in_flight, entry(:unclassified, key_task_id(keys, pid), keys[pid], nil, nil, nil, pid)}

  defp snapshot(pid) do
    GenServer.call(pid, :snapshot, @snapshot_timeout_ms)
  catch
    :exit, _ -> nil
  end

  @doc false
  # The kind label for a worker snapshot. Descriptive only: it never decides
  # whether the worker counts (see the moduledoc).
  @spec worker_kind(map()) :: kind()
  def worker_kind(%{} = snap) do
    meta = Map.get(snap, :meta) || %{}

    case Map.get(snap, :role) || Map.get(meta, :role) do
      :fix_pass -> :fix_pass
      :conflict_resolver -> :conflict_resolver
      :reviewer -> :review_pass
      :implementer -> :impl_pass
      _ -> primary_kind(meta)
    end
  end

  defp primary_kind(meta) do
    cond do
      Map.get(meta, :review_only) == true -> :review_dispatch
      Map.get(meta, :dispatched_by) == "autopilot" -> :board_dispatch
      Map.get(meta, :resume) == true -> :resume
      true -> :dispatch
    end
  end

  defp entry(kind, task_id, key, status, agent_live, started_at, pid) do
    %{
      kind: kind,
      task_id: task_id,
      registry_key: key,
      status: status,
      agent_live: agent_live,
      started_at: started_at,
      detail: nil,
      pid: pid
    }
  end

  # `Arbiter.Worker.Registry` maps keys to pids; invert it so a non-Worker child
  # (a ReviewGate, a Driver) can still be named by the key it registered under.
  defp registry_keys_by_pid do
    Worker.Registry.all() |> Map.new(fn {key, pid} -> {pid, key} end)
  rescue
    _ -> %{}
  end

  defp key_task_id(keys, pid) do
    case Map.get(keys, pid) do
      key when is_binary(key) -> key |> String.split([":", "#"], parts: 2) |> hd()
      _ -> nil
    end
  end
end
