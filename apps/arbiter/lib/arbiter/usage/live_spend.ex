defmodule Arbiter.Usage.LiveSpend do
  @moduledoc """
  A task's worker spend **including the pass that is still running**
  (bd-8vnuy3).

  `Arbiter.Usage.Event` writes one row per *finished* session, so the settled
  ledger (`Arbiter.Usage.Budget.settled_by_task/2`) cannot see a pass until it
  ends. A 25-minute review round contributed $0 to its task's total right up to
  the moment it jumped by $3; a runaway pass stuck in one long session is
  invisible for exactly as long as it runs. The Claude CLI appends every turn
  to its session JSONL as it happens, and `Arbiter.Usage.ClaudeSessionFile`
  already knows how to read one (message-id dedupe, `:since` windowing for a
  `--resume`-shared file, rollover guard). This module points it at the
  sessions that are in flight and adds what it finds to the ledger.

  ## What is "in flight"

  A worker whose agent port is open: `agent_live: true` on a
  `Arbiter.Worker.list_children/0` snapshot. **Not** a `Workers.Run` row with
  `completed_at: nil` — that row spans the worker's whole life, including the
  time it sits parked at `awaiting_review` long after its session ended and
  was billed (run `ca240465` on vs-5yjnn6 stayed `running` for an hour after
  its session's ledger row landed). Reading off the run row would re-read a
  settled session for as long as the worker stayed parked.

  ## The key: the live worker's project directory

  For each live worker of the task (the author, a `#review` round, an `#impl`
  round, a `:fixpass` / `:conflict` pass — every id that folds to the task),
  the session files are found by listing

      <meta.config_dir>/projects/<project_slug(meta.cwd)>/*.jsonl

  — the directory the CLI writes *every* session it runs from that cwd into —
  and keeping the files modified since the worker started. Why that is
  complete: every agent session Arbiter spawns for a task is a port owned by a
  `Worker` whose task id folds to it, and that worker records the exact
  `CLAUDE_CONFIG_DIR` and cwd it spawned the CLI under (`meta.config_dir` /
  `meta.cwd`, stamped at spawn time, before any session id exists). Whatever
  session id the CLI ends up writing under — one that never reached
  `worker_runs`, one that rolled over mid-run — its file is in that directory
  and was written after the worker started. Keying off `run.session_id` misses
  those: vs-5yjnn6's review round `1aaccf48` had no `worker_runs` row keyed to
  its session id while it ran, and ran in the *author's* worktree directory.

  Two exclusions keep a shared directory honest. A file whose session id the
  ledger already attributes to a *different* task is never counted. And when
  another task's worker has recorded the same config dir + cwd (a repo used as
  its own worktree), the directory is ambiguous: only the session ids this
  task's own live workers report are read — under-reporting an unattributable
  file beats billing it to the wrong task.

  ## Never counted twice

  A pass's ledger row carries its `session_id` and lands (`occurred_at`) when
  its terminal `result` event arrives — after its last turn. So each file is
  read with `since:` the later of the worker's start and that session's newest
  ledger row: turns already billed are before the cutoff, a `--resume` /
  nudge relaunch's new turns are after it. Ledger rows and cutoffs come from
  the same ledger state, so at the moment a pass ends its cost moves from
  `live_usd` to `settled_usd` — the total does not jump by it twice.

  ## An estimate, not billing

  Claude Code 2.1.270+ writes no `cost-state` record, so a live figure is the
  file's deduped tokens priced by `Arbiter.Usage.ClaudePricing` — the same
  estimator a disk-reconciled ledger row uses, and it matches the CLI's own
  `costUSD` for a single-model session. Surfaces must still render it as an
  in-flight estimate (`live?`), distinct from a settled total.

  ## Degraded and unpriced

    * `degraded?` — a live session could not be read cleanly: the file is
      missing, unreadable, or has a line that is not JSON (torn by a crash, or
      caught mid-write). That session's live share is **withheld**, never
      partially counted, so the figure falls back toward the settled ledger
      and says so. A worker with no recorded config dir / cwd / start time is
      degraded the same way.
    * `unpriced?` — some of the spend has no price: a ledger row with
      `cost_usd: nil`, a live agy/antigravity (or other non-Claude) pass, whose
      cost is `nil` by design (bd-481sz7), or a live session on a model the
      price table does not know. `total_usd` is then a floor — or `nil` when
      nothing at all was priced, which surfaces render as "n/a", never
      `$0.00`.
  """

  alias Arbiter.Usage.Budget
  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Usage.Estimate
  alias Arbiter.Usage.Event

  require Ash.Query
  require Logger

  @claude_providers [nil, "claude"]

  # SQLite's expression-tree limit, as in `Budget`.
  @sid_chunk 200

  @type t :: %{
          task_id: String.t(),
          settled_usd: float(),
          live_usd: float(),
          total_usd: float() | nil,
          live?: boolean(),
          degraded?: boolean(),
          unpriced?: boolean()
        }

  @no_settled %{spend: 0.0, priced_rows: 0, unpriced_rows: 0}
  @no_live %{usd: 0.0, priced?: false, live?: false, degraded?: false, unpriced?: false}

  @doc "`for_tasks/2` for one (base) task id."
  @spec for_task(String.t(), keyword()) :: t()
  def for_task(task_id, opts \\ []) when is_binary(task_id) do
    [task_id] |> for_tasks(opts) |> Map.fetch!(task_id)
  end

  @doc """
  Settled + in-flight worker spend for each **base** task id in `task_ids`
  (a `#review` / `:fixpass` id is folded into its task, never keyed itself).
  Every id gets a key.

  Options:

    * `:workers` — worker snapshots, as `Arbiter.Worker.list_children/0`
      returns them (the default). Callers that already listed the workers pass
      them to avoid a second round of `:snapshot` calls.
    * `:settled` — a precomputed `Budget.settled_by_task/2` result.

  Raises only if the ledger read does; session-file trouble is reported as
  `degraded?`, never raised.
  """
  @spec for_tasks([String.t()], keyword()) :: %{String.t() => t()}
  def for_tasks(task_ids, opts \\ []) when is_list(task_ids) do
    ids = task_ids |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.uniq()
    settled = Keyword.get_lazy(opts, :settled, fn -> Budget.settled_by_task(ids, opts) end)
    workers = Keyword.get_lazy(opts, :workers, &list_workers/0)
    live = live_by_task(ids, workers)

    Map.new(ids, fn id ->
      {id, compose(id, Map.get(settled, id, @no_settled), Map.get(live, id, @no_live))}
    end)
  end

  @doc """
  `for_tasks/2` keyed by each worker snapshot's own `task_id` — a `#review`
  row and its author's row both map to the *task's* figure, so every row of
  `arb worker list` reports the number the issue page shows for that task.

  `opts` are `for_tasks/2`'s; `:workers` defaults to `snaps` themselves, which
  a caller that filtered the list (to one workspace, say) should override with
  the unfiltered one — a project dir shared with a worker outside the filter
  is still shared.
  """
  @spec by_worker_task([map()], keyword()) :: %{String.t() => t()}
  def by_worker_task(snaps, opts \\ []) when is_list(snaps) do
    pairs =
      for %{task_id: id} <- snaps, is_binary(id) and id != "", do: {id, Estimate.fold_task_id(id)}

    spends =
      pairs
      |> Enum.map(&elem(&1, 1))
      |> for_tasks(Keyword.put_new(opts, :workers, snaps))

    Map.new(pairs, fn {id, base} -> {id, Map.fetch!(spends, base)} end)
  end

  @doc """
  The cost fields `worker_list` / `worker_show` and `GET /api/workers[/:id]`
  carry, off one `t()` (or `nil` when the read failed — every field `nil`, so
  a client prints nothing rather than a `$0.00` nobody measured).

    * `cost_usd` — `total_usd`: settled + in flight, `nil` when nothing was
      priced (render "n/a").
    * `cost_settled_usd` / `cost_live_usd` — the two halves.
    * `cost_live` — the figure includes an in-flight estimate.
    * `cost_degraded` — a live session file could not be read; its share is
      missing from `cost_usd`.
    * `cost_unpriced` — some spend has no price; `cost_usd` is a floor, or nil.
  """
  @spec cost_fields(t() | nil) :: map()
  def cost_fields(%{} = spend) do
    %{
      cost_usd: spend.total_usd,
      cost_settled_usd: spend.settled_usd,
      cost_live_usd: spend.live_usd,
      cost_live: spend.live?,
      cost_degraded: spend.degraded?,
      cost_unpriced: spend.unpriced?
    }
  end

  def cost_fields(nil) do
    %{
      cost_usd: nil,
      cost_settled_usd: nil,
      cost_live_usd: nil,
      cost_live: nil,
      cost_degraded: nil,
      cost_unpriced: nil
    }
  end

  defp compose(task_id, settled, live) do
    unpriced? = settled.unpriced_rows > 0 or live.unpriced?

    total =
      cond do
        settled.priced_rows > 0 or live.priced? -> money(settled.spend + live.usd)
        unpriced? -> nil
        true -> 0.0
      end

    %{
      task_id: task_id,
      settled_usd: settled.spend,
      live_usd: money(live.usd),
      total_usd: total,
      live?: live.live?,
      degraded?: live.degraded?,
      unpriced?: unpriced?
    }
  end

  defp list_workers do
    Arbiter.Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # ---- the live half -------------------------------------------------------

  defp live_by_task(ids, workers) do
    wanted = MapSet.new(ids)
    entries = Enum.map(workers, &entry/1)

    # Which tasks have recorded each project dir — live or parked, since a
    # parked worker's sessions still sit in the directory it ran from.
    dir_tasks =
      entries
      |> Enum.filter(& &1.dir)
      |> Enum.group_by(& &1.dir, & &1.task)
      |> Map.new(fn {dir, tasks} -> {dir, MapSet.new(tasks)} end)

    # A session a worker of some *other* task reports as its own.
    claimed =
      entries
      |> Enum.filter(& &1.session_id)
      |> Map.new(&{&1.session_id, &1.task})

    plans =
      entries
      |> Enum.filter(&(&1.live? and MapSet.member?(wanted, &1.task)))
      |> Enum.group_by(& &1.task)
      |> Enum.map(fn {task, mine} -> plan(task, mine, dir_tasks) end)

    ledger =
      plans
      |> Enum.flat_map(& &1.files)
      |> Enum.map(& &1.sid)
      |> Enum.uniq()
      |> ledger_by_session()

    Map.new(plans, fn plan -> {plan.task, read_plan(plan, ledger, claimed)} end)
  end

  defp entry(snap) do
    meta = Map.get(snap, :meta) || %{}
    config_dir = Map.get(meta, :config_dir)
    cwd = Map.get(meta, :cwd) || Map.get(meta, :worktree_path)
    task_id = Map.get(snap, :task_id)

    %{
      task: if(is_binary(task_id), do: Estimate.fold_task_id(task_id)),
      live?: Map.get(snap, :agent_live) == true,
      claude?: provider(meta) in @claude_providers,
      dir: if(present?(config_dir) and present?(cwd), do: {config_dir, cwd}),
      started_at: Map.get(snap, :started_at),
      session_id: if(present?(Map.get(meta, :session_id)), do: Map.get(meta, :session_id))
    }
  end

  defp provider(meta) do
    case Map.get(meta, :provider) || get_in(meta, [:routing_config, :provider]) do
      nil -> nil
      p -> to_string(p)
    end
  end

  defp present?(v), do: is_binary(v) and v != ""

  # Which files to read for one task, and whether anything already rules the
  # figure incomplete (a worker we cannot locate, a known session with no file).
  defp plan(task, mine, dir_tasks) do
    {claude, other} = Enum.split_with(mine, & &1.claude?)
    {located, unlocated} = Enum.split_with(claude, &(&1.dir && match?(%DateTime{}, &1.started_at)))

    {files, missing?} =
      located
      |> Enum.group_by(& &1.dir)
      |> Enum.map(fn {dir, workers} ->
        shared? = MapSet.size(Map.get(dir_tasks, dir, MapSet.new())) > 1
        candidates(dir, workers, shared?)
      end)
      |> Enum.reduce({[], false}, fn {files, missing?}, {acc, any?} ->
        {files ++ acc, any? or missing?}
      end)

    %{
      task: task,
      files: Enum.uniq_by(files, & &1.path),
      degraded?: unlocated != [] or missing?,
      unpriced?: other != []
    }
  end

  defp candidates({config_dir, cwd}, workers, shared?) do
    dir = Path.join([config_dir, "projects", ClaudeSessionFile.project_slug(cwd)])
    floor = workers |> Enum.map(& &1.started_at) |> Enum.min(DateTime)
    own = workers |> Enum.map(& &1.session_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    # A session this task's own worker says it is running must have a file.
    missing? = Enum.any?(own, &(not File.exists?(Path.join(dir, &1 <> ".jsonl"))))

    sids =
      if shared? do
        own
      else
        case File.ls(dir) do
          {:ok, names} ->
            for name <- names, String.ends_with?(name, ".jsonl"), do: Path.rootname(name)

          # No directory yet: the CLI has not written its first line.
          {:error, _} ->
            []
        end
      end

    # mtime is whole seconds; a second of slack keeps a file written in the
    # worker's first second in scope. The `since:` cutoff does the real work.
    floor_unix = DateTime.to_unix(floor) - 1

    files =
      for sid <- sids,
          path = Path.join(dir, sid <> ".jsonl"),
          touched_since?(path, floor_unix),
          do: %{path: path, sid: sid, floor: floor}

    {files, missing?}
  end

  defp touched_since?(path, floor_unix) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} -> mtime >= floor_unix
      _ -> false
    end
  end

  # `%{session_id => %{last_at: DateTime | nil, owners: MapSet}}` over every
  # ledger row carrying one of `sids` — the billing watermark per session, and
  # which tasks the ledger says each session belongs to.
  defp ledger_by_session([]), do: %{}

  defp ledger_by_session(sids) do
    sids
    |> Enum.chunk_every(@sid_chunk)
    |> Enum.flat_map(fn chunk ->
      Event
      |> Ash.Query.filter(session_id in ^chunk)
      |> Ash.Query.select([:session_id, :task_id, :base_task_id, :occurred_at])
      |> Ash.read!()
    end)
    |> Enum.group_by(& &1.session_id)
    |> Map.new(fn {sid, rows} ->
      {sid,
       %{
         last_at: rows |> Enum.map(& &1.occurred_at) |> Enum.reject(&is_nil/1) |> max_time(),
         owners: rows |> Enum.map(&Budget.fold_event_id/1) |> MapSet.new()
       }}
    end)
  end

  defp read_plan(plan, ledger, claimed) do
    init = %{@no_live | live?: true, degraded?: plan.degraded?, unpriced?: plan.unpriced?}

    plan.files
    |> Enum.filter(&own_session?(&1.sid, plan.task, ledger, claimed))
    |> Enum.reduce(init, fn file, acc ->
      watermark = get_in(ledger, [file.sid, :last_at])
      absorb(acc, read_file(file, max_time([file.floor, watermark])))
    end)
  end

  defp own_session?(sid, task, ledger, claimed) do
    ledger_ok? =
      case Map.get(ledger, sid) do
        nil -> true
        %{owners: owners} -> MapSet.member?(owners, task)
      end

    ledger_ok? and Map.get(claimed, sid, task) == task
  end

  defp read_file(file, since) do
    case ClaudeSessionFile.read_totals(file.path, since: since, session_id: file.sid) do
      {:ok, %{malformed_lines: n}} when n > 0 -> :degraded
      {:ok, %{message_count: 0}} -> :empty
      {:ok, %{cost_usd: cost}} when is_number(cost) -> {:priced, cost}
      {:ok, _unpriced} -> :unpriced
      {:error, _reason} -> :degraded
    end
  rescue
    e ->
      Logger.warning("LiveSpend: reading #{file.path} raised: #{Exception.message(e)}")
      :degraded
  end

  defp absorb(acc, {:priced, cost}), do: %{acc | usd: acc.usd + cost, priced?: true}
  defp absorb(acc, :unpriced), do: %{acc | unpriced?: true}
  defp absorb(acc, :degraded), do: %{acc | degraded?: true}
  defp absorb(acc, :empty), do: acc

  defp max_time(times) do
    times
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> case do
      [] -> nil
      list -> Enum.max(list, DateTime)
    end
  end

  defp money(value), do: Float.round(value / 1, 2)
end
