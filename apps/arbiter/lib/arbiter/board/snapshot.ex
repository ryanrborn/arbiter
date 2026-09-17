defmodule Arbiter.Board.Snapshot do
  @moduledoc """
  The board, derived. One read of the world in, five columns and a dispatch
  decision out.

  The operator console's board is not a stored object — Arbiter has no "board"
  table and deliberately doesn't want one. Every column is a *view* of state
  that already exists (issues, live workers, merge requests), so the board can
  never drift from the system it describes: there is nothing to keep in sync.

  ## The five columns

    * **Backlog** — open, dispatchable issues nobody is working that nobody has
      refined yet (`refined == false`). Newest first, deliberately: an
      unrefined pile is a to-think-about list, not a queue, and ordering it by
      priority would imply a ranking the refinement hasn't earned.
    * **Ready** — open, dispatchable issues nobody is working. A real queue,
      ordered by priority then age, each card carrying the reason
      `Arbiter.Board.Scheduler` gave it (`next up — dispatching...`,
      `2 ahead in queue`, `blocked — waiting on bd-9`).
    * **Running** — workers with a live agent: `:idle`, `:resuming`,
      `:running`, and `:awaiting_review_gate` (parked while a *reviewer agent*
      reads the diff — automated, so still the machine's turn). Reviewer
      workers fold into the author's card rather than occupying one of their
      own; a review is a phase of the author's work, not a second piece of it.
    * **Waiting** — the worker is done and the outcome now depends on
      something outside it: `:awaiting` (it asked a human a question),
      `:failed` (parked; send it back or close it) and `:awaiting_review` (an
      MR is open and the Watchdog is polling) — plus an `in_progress` issue
      with **no live worker at all** (e.g. `arb worker stop` on an
      `:awaiting_review` worker, the documented pre-flight for `arb server
      deploy`), which always flags `needs_you` since nothing will retry it on
      its own. Longest wait first, because a stalled card is the thing worth
      seeing.
    * **Closed · last 24h** — issues closed in the last 24 hours (rolling window,
      keyed on `closed_at`). The day's evidence of progress, and the only column
      with no action on it. Epics are excluded here as they are everywhere
      else (bd-38of5i): the evidence of a day's progress is the children that
      closed, not the container that closed because they did.

  ## Backlog, and why refinement is not a status

  `refined` is a boolean on the issue, not a fourth FSM state: the task
  lifecycle still only knows `open` / `in_progress` / `closed`. It is a
  *column input*, exactly like a live worker or an open blocker — which is the
  whole reason the board can keep deriving itself rather than storing a stage.

  Backlog is therefore Ready's filter minus the flag, and nothing else. In
  particular it is **not** gated on dependency-satisfaction: refinement and
  dependency-readiness are orthogonal questions, so a refined card whose
  blocker is still open stays in Ready carrying its own
  `blocked — waiting on bd-9` reason. Blocked is a scheduling fact; Backlog is
  a refinement fact, and conflating them would lose both.

  ## Waiting, and the needs-you flag

  Waiting used to be two columns — Needs you and Merge queue — which split
  cards by *what* they wait on: a person, or a poll. That is not the split an
  operator acts on. Every card in the column is equally out of the worker's
  hands; the only question that changes what a human does next is whether the
  system has anything left to try on its own.

  So it is one column, and that narrower signal rides on the card as
  `:needs_you`:

    * `:awaiting` always flags — the worker asked a question, and there is no
      such thing as retrying a question.
    * `:failed` always flags — a parked worker is terminal by definition, so
      whatever it was last seen waiting on, nothing is going to turn it.
    * an open MR flags unless its block is one the Watchdog still resolves by
      itself — `:behind_base` (it rebases) and `:ci_failed` (it dispatches a
      fix pass). Everything else, from `:conflict` to `:needs_approval` to
      `:draft`, waits on a person; an unblocked MR is simply mid-review, which
      is still the machine's turn.

  The block reason is read through `Arbiter.Worker.Watchdog`
  (`effective_block_reason/1`, itself gated on `classify/1 == :approved`), the
  same surface the merge-queue screen reads, so the flag can never disagree
  with the status text rendered next to it. The exempt list is the Watchdog's
  own `auto_resolvable?/1` set rather than a hand-kept roster of human blocks,
  so it *shrinks* as more auto-recovery lands and a newly-invented block
  reason defaults to "a person's" instead of silently reading as pipeline
  wait. It measures "still needs a human today", not "something is imperfect".

  A worker at `:awaiting_review` holds an MR, not a subprocess, so it does not
  consume a worker slot; every other live status does. That is what makes
  `slots_free` mean "agents I could start right now" rather than "rows in the
  registry".

  ## Deriving vs loading

  `derive/1` is pure: hand it issues, worker snapshots and a clock and it
  computes the board, including the dispatch plan. `load/1` is the thin shell
  that reads those inputs from the repo, the worker supervisor, the settings
  and the quota gate. All the interesting rules live in the pure half, so the
  board's behaviour is testable without a database.
  """

  alias Arbiter.Board.FileScope
  alias Arbiter.Board.Scheduler
  alias Arbiter.Tasks.EdgeGate
  alias Arbiter.Usage.Budget
  alias Arbiter.Worker.Watchdog

  require Ash.Query

  @typedoc "Worker statuses that hold a live agent, and so a worker slot."
  @slot_statuses [:idle, :resuming, :running, :awaiting, :awaiting_review_gate]

  # Live agent working; the author is still "running" while a reviewer reads.
  @running_statuses [:idle, :resuming, :running, :awaiting_review_gate]

  # Worker is done; the outcome is somebody else's to produce.
  @waiting_statuses [:awaiting, :failed, :awaiting_review]

  # The only blocks the Watchdog still clears on its own — mirrors its
  # `auto_resolvable?/1`. Everything else needs a person today.
  @auto_resolving_block_reasons [:behind_base, :ci_failed]

  @default_system_max 16

  # bd-6bax7s: what a live worker's status is *called* on a card held back by a
  # `:conflicts_with` mutex, and — by omission — which statuses count as in
  # flight at all. `:failed` is absent on purpose: a parked worker is terminal,
  # so it holds nothing back. `:awaiting_review` is present even though it
  # holds no worker slot — an open MR on the counterpart is exactly the thing
  # a mutex exists to keep a second worker away from.
  @conflict_states %{
    idle: "running",
    running: "running",
    resuming: "resuming",
    awaiting: "awaiting input",
    awaiting_review_gate: "in review",
    awaiting_review: "awaiting review"
  }

  # A reviewer / implementer worker claims the mutex on behalf of the author it
  # is working for, for the window where the author's own worker has already
  # gone away.
  @reviewer_state "in review"
  @fix_pass_state "fix pass"

  # An issue flipped to :in_progress whose worker has not registered yet.
  @dispatching_state "dispatching"

  # Dispatch flips an issue to :in_progress before the worker is registered
  # (worktree provisioning, fetch, etc. — seconds on a large repo). Below this
  # age, treat it as mid-dispatch rather than orphaned.
  @orphan_grace_seconds 60

  @type t :: %{
          backlog: [map()],
          ready: [Scheduler.entry()],
          running: [map()],
          waiting: [map()],
          closed_today: [map()],
          promote: String.t() | nil,
          slots_total: non_neg_integer(),
          slots_free: non_neg_integer(),
          quota: Scheduler.quota(),
          paused: boolean(),
          now: DateTime.t()
        }

  @doc """
  Derive the board from an already-read picture of the world.

  Expected keys: `:issues`, `:workers`, `:blocked_by` (issue id → open blocker
  ids), `:conflicts_with` (`{a, b}` pairs from the mutex edges),
  `:changed_files` (task id → repo-relative paths a worktree has touched),
  `:now`, `:slots_total`, `:quota`, `:paused` and `:ready_order`. Every key has
  a sane default, so a caller may pass only what it has.

  `:ready_order` is the operator's hand-ranking of the Ready queue — the ids
  it names lead the queue in that order, and everything else follows in
  priority order behind them. Because the scheduler promotes the first
  eligible card, dragging a card to the top of Ready is how a human overrides
  the machine's idea of what matters most without dispatching anything by
  hand.
  """
  @spec derive(map()) :: t()
  def derive(input) when is_map(input) do
    issues = Map.get(input, :issues, [])
    workers = Map.get(input, :workers, [])
    blocked_by = Map.get(input, :blocked_by, %{})
    # bd-6bax7s: `{a, b}` pairs from the `:conflicts_with` edges, an *input*
    # like `:blocked_by` — the pure half never goes looking for rows.
    # `EdgeGate` folds them into symmetric adjacency, so a card is held
    # whichever direction the coordinator happened to store the edge in.
    conflicts = EdgeGate.adjacency(Map.get(input, :conflicts_with, []))
    changed = Map.get(input, :changed_files, %{})
    now = Map.get(input, :now) || DateTime.utc_now()
    slots_total = Map.get(input, :slots_total, 0)
    quota = Map.get(input, :quota, :ok)
    paused? = Map.get(input, :paused) == true
    ready_order = Map.get(input, :ready_order, [])
    # bd-38of5i: `{parent_id, child_id}` pairs from the `:parent_of` edges. An
    # *input*, like `:blocked_by` — the pure half never goes looking for rows.
    parent_of = Map.get(input, :parent_of, [])
    # bd-8jixav: which tasks have a live Watchdog. A Registry read, so it is an
    # *input* here rather than something `derive/1` goes and looks up — the
    # pure half stays pure and a caller that can't answer passes nothing, which
    # reads as "unknown" on the card rather than a false "no watchdog" alarm.
    watchdog_live = Map.get(input, :watchdog_live)
    # bd-8j9i9p (design bd-9jj5lf §3): the ids whose worker spend has passed
    # their estimate group's p90. An *input* like the two above — the flag is a
    # ledger question, and the pure half never goes to the ledger. A caller
    # that can't answer passes nothing, and no card flags.
    over_budget = over_budget_set(Map.get(input, :over_budget))

    issues_by_id = Map.new(issues, &{&1.id, &1})
    parents = parent_refs(parent_of, issues_by_id)

    {authors, gate_workers} =
      Enum.split_with(workers, &(worker_role(&1) not in [:reviewer, :implementer]))

    gate_workers_by_author =
      gate_workers
      |> Enum.sort_by(&since/1, {:asc, DateTime})
      |> Map.new(&{gate_author(&1), &1})

    worked = MapSet.new(authors, & &1.task_id)

    running = running_cards(authors, issues_by_id, gate_workers_by_author)
    slots_free = max(slots_total - Enum.count(authors, &(&1.status in @slot_statuses)), 0)

    plan =
      Scheduler.plan(%{
        ready: ready_cards(issues, worked, blocked_by, conflicts, ready_order),
        running: in_flight(authors, issues_by_id, changed),
        conflict_claims: conflict_claims(authors, gate_workers, issues, worked, now),
        slots_free: slots_free,
        quota: quota,
        paused: paused?
      })

    %{
      backlog:
        backlog_cards(issues, worked) |> with_parents(parents) |> with_over_budget(over_budget),
      ready:
        plan.entries
        |> with_parents_in_entries(parents)
        |> with_over_budget_in_entries(over_budget),
      running: running |> with_parents(parents) |> with_over_budget(over_budget),
      waiting:
        authors
        |> waiting(issues, issues_by_id, worked, now, watchdog_live)
        |> with_parents(parents)
        |> with_over_budget(over_budget),
      # A closed task that ran over is done — there is nothing left to act on,
      # so the Closed column never flags, whatever the input says.
      closed_today:
        closed_today_cards(issues, now) |> with_parents(parents) |> with_over_budget(nil),
      promote: plan.promote,
      slots_total: slots_total,
      slots_free: slots_free,
      quota: quota,
      paused: paused?,
      now: now
    }
  end

  @doc """
  Read the world and derive the board.

  Options mirror `derive/1`'s inputs and override what would otherwise be
  read: `:now`, `:slots_total`, `:quota`, `:paused`, `:ready_order`,
  `:issues`, `:workers`, `:changed_files`, `:workspace_id`. Every read is
  best-effort — a board that renders five columns beats one that raises.

  **Workspace-level scoping:** `slots_total` and `quota` are computed for the
  specified workspace (defaulting to the default workspace if not given).
  However, `:issues` and `:workers` span all workspaces. Per-workspace
  concurrency limits are correctly enforced by the Conductor; this board is
  a global view with workspace-specific slot constraints. Multi-workspace
  boards with workspace-specific caps are a known limitation (see #1359).
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    issues = Keyword.get_lazy(opts, :issues, &load_issues/0)
    workers = Keyword.get_lazy(opts, :workers, &load_workers/0)
    workspace_id = Keyword.get(opts, :workspace_id) || default_workspace_id()

    # One read of the dependency rows feeds both derived inputs — the gating
    # blockers and (bd-38of5i) the `parent_of` pairs. Skipped entirely when the
    # caller supplied both, which is how the pure tests stay repo-free.
    deps = dependency_rows(opts)

    derive(%{
      issues: issues,
      workers: workers,
      blocked_by: Keyword.get_lazy(opts, :blocked_by, fn -> blockers_from(deps, issues) end),
      parent_of: Keyword.get_lazy(opts, :parent_of, fn -> parent_of_from(deps) end),
      conflicts_with:
        Keyword.get_lazy(opts, :conflicts_with, fn -> EdgeGate.conflict_pairs(deps) end),
      changed_files: Keyword.get(opts, :changed_files, %{}),
      now: Keyword.get(opts, :now) || DateTime.utc_now(),
      slots_total: Keyword.get(opts, :slots_total) || effective_max_concurrent(workspace_id),
      quota: Keyword.get_lazy(opts, :quota, fn -> quota_hold(workspace_id) end),
      paused: Keyword.get(opts, :paused, false),
      ready_order: Keyword.get(opts, :ready_order, []),
      watchdog_live:
        Keyword.get_lazy(opts, :watchdog_live, fn -> watchdog_live(workers) end),
      over_budget: Keyword.get_lazy(opts, :over_budget, fn -> Budget.over_budget_ids(issues) end)
    })
  end

  @doc """
  Which of `workers` still has a live Watchdog (bd-8jixav). One Registry
  lookup per parked worker — cheap, and only for the `:awaiting_review` rows,
  which are the only ones the question means anything for.

  Public so a caller scoped to fewer than the whole fleet (e.g.
  `Arbiter.Tasks.EpicRollup`, bd-58z2tu) can build the same liveness set
  `needs_you?/2` expects without going through `load/1`.
  """
  @spec watchdog_live([map()]) :: MapSet.t() | nil
  def watchdog_live(workers) do
    workers
    |> Enum.filter(&(Map.get(&1, :status) == :awaiting_review and Watchdog.alive?(&1.task_id)))
    |> MapSet.new(& &1.task_id)
  rescue
    # A board that renders five columns beats one that raises: an unreadable
    # registry degrades to "unknown", not to a false alarm on every card.
    _ -> nil
  end

  @doc """
  A board with five empty columns and nothing to promote.

  What a caller renders when its read of the world failed. It reports itself
  `paused: true` on purpose: a queue nobody could read is not one anything
  should be dispatching from, and every Ready card would otherwise claim a
  position in a queue that isn't moving.
  """
  @spec empty(DateTime.t() | nil) :: t()
  def empty(now \\ nil) do
    %{
      backlog: [],
      ready: [],
      running: [],
      waiting: [],
      closed_today: [],
      promote: nil,
      slots_total: 0,
      slots_free: 0,
      quota: :ok,
      paused: true,
      now: now || DateTime.utc_now()
    }
  end

  @doc """
  The install-wide worker ceiling — the runtime `Arbiter.Settings` override,
  else app env, else #{@default_system_max}. Mirrors
  `Arbiter.Workflows.Conductor`'s resolution so the board counts slots the
  same way the graph engine spends them.
  """
  @spec system_max_concurrent() :: pos_integer()
  def system_max_concurrent do
    Arbiter.Settings.conductor_system_max_concurrent() ||
      Application.get_env(:arbiter, :conductor_system_max_concurrent, @default_system_max)
  rescue
    _ -> @default_system_max
  end

  @doc """
  The effective maximum concurrent workers for a workspace: the minimum of the
  workspace-level cap (if set) and the system-wide cap. Mirrors
  `Arbiter.Workflows.Conductor.effective_cap/1` (quota_headroom aside).

  When workspace_id is nil, returns the system max.
  """
  @spec effective_max_concurrent(String.t() | nil) :: pos_integer()
  def effective_max_concurrent(nil) do
    system_max_concurrent()
  end

  def effective_max_concurrent(workspace_id) when is_binary(workspace_id) do
    system_max = system_max_concurrent()

    case workspace_config_max(workspace_id) do
      n when is_integer(n) and n > 0 -> min(n, system_max)
      _ -> system_max
    end
  rescue
    _ -> system_max_concurrent()
  end

  # Read the workspace's conductor.max_concurrent config, if set.
  defp workspace_config_max(workspace_id) do
    case Ash.get(Arbiter.Tasks.Workspace, workspace_id) do
      {:ok, ws} -> Arbiter.Tasks.Workspace.max_concurrent(ws)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Whether quota permits a dispatch right now, as `:ok` or `{:hold, reason}`.

  Distinguishes an actually-exhausted window ("the provider is refusing") from
  one that has crossed the throttle threshold ("we chose to stop here"),
  because the operator's next move differs: wait for the reset, or raise the
  ceiling.

  Reads the workspace's default agent provider's snapshot
  (`Arbiter.Quota.default_provider/1`) and defers the over-cap decision to
  `Arbiter.Quota.Gate.hold_phrase/2` (`gating_window/2`) — the same shared implementation the
  Conductor's `Arbiter.Workflows.QuotaGate.Default` and the `dispatch/2`
  quota seam both use (bd-5j6nmn), so Autopilot's one-per-tick promotion gate
  and the Conductor's per-drain cap-clamp agree on the same underlying data.

  A `:continue`-mode workspace (`Arbiter.Quota.continue_mode?/1`) never holds
  here, mirroring `Arbiter.Workflows.QuotaGate.Default`'s short-circuit: the
  `dispatch/2` seam is the single choke point for the allow/overage decision,
  so the board must not show a `blocked — quota exhausted` hold that the
  dispatcher itself would not honor (reviewer round 1, finding 1).
  """
  @spec quota_hold(String.t() | nil) :: Scheduler.quota()
  def quota_hold(workspace_id \\ nil) do
    workspace_id = workspace_id || default_workspace_id()

    with ws_id when is_binary(ws_id) <- workspace_id,
         workspace <- safe_workspace(ws_id),
         false <- Arbiter.Quota.continue_mode?(workspace),
         snapshot when not is_nil(snapshot) <- latest_quota(ws_id, workspace) do
      describe_quota(snapshot, workspace)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # ---- shared column classification -----------------------------------------

  @doc """
  The board's own column classification, applied to an arbitrary set of
  issues rather than the whole board.

  Design bd-2s901b §3: an epic detail page groups its children into a
  "Children by status" mini-board using these same five columns, so it needs
  the same answer the board itself would give — this is that answer,
  factored out so the two surfaces can't drift apart.

  `workers` need only be the live workers for these issues' ids (a caller
  scoped to one epic's children has no reason to pass the whole fleet).
  Only author workers (not a reviewer/implementer gate pass) count here —
  matching `derive/1`'s own author/gate split. As on the board itself, an
  author worker's presence, not the issue's own `status`, is what separates
  Running/Waiting from Backlog/Ready: a worker attached before the issue
  record catches up still claims the issue.

  Returns `%{issue_id => :backlog | :ready | :running | :waiting | :closed}`.
  """
  @spec classify_columns([map()], [map()]) :: %{String.t() => atom()}
  def classify_columns(issues, workers \\ []) do
    authors = Enum.filter(workers, &(worker_role(&1) not in [:reviewer, :implementer]))
    worked = MapSet.new(authors, & &1.task_id)

    running =
      authors |> Enum.filter(&(&1.status in @running_statuses)) |> MapSet.new(& &1.task_id)

    Map.new(issues, &{&1.id, column_for(&1, worked, running)})
  end

  defp column_for(%{status: :closed}, _worked, _running), do: :closed

  defp column_for(issue, worked, running) do
    cond do
      MapSet.member?(running, issue.id) -> :running
      Map.get(issue, :status) == :awaiting_verification -> :waiting
      MapSet.member?(worked, issue.id) -> :waiting
      Map.get(issue, :status) == :in_progress -> :waiting
      refined?(issue) -> :ready
      true -> :backlog
    end
  end

  # ---- backlog / ready ------------------------------------------------------

  # The one filter both columns share: work that exists, is dispatchable in
  # principle, and nobody has picked up. `refined` is the only thing that
  # decides which side of it a card falls on.
  defp queueable?(issue, worked) do
    issue.status == :open and
      not dispatchable_type_excluded?(issue) and
      not MapSet.member?(worked, issue.id)
  end

  # Board-level dispatch is per-issue, so containers never queue: an epic is a
  # rollup of children, not something a worker can be handed. bd-38of5i
  # extended the same exclusion to Closed-today, the one column they still
  # leaked into; epics now live on `/epics` and reach the board only as the
  # `↳` chip a child card carries. bd-cnfwtr: the list itself lives on
  # `Arbiter.Tasks.Issue`, which `ready/1` also reads, so the two surfaces
  # can't drift apart.
  defp dispatchable_type_excluded?(issue) do
    Map.get(issue, :issue_type) in Arbiter.Tasks.Issue.non_dispatchable_types()
  end

  # Absent reads as unrefined. A hand-built map that predates the flag, or a
  # row mid-migration, belongs in the pile a human still has to look at — the
  # safe direction to be wrong in, since Backlog dispatches nothing.
  defp refined?(issue), do: Map.get(issue, :refined) == true

  # Newest first, and only newest first. This is provisional on purpose: the
  # moment Backlog grows a priority order it starts reading as a second queue,
  # and there is exactly one queue.
  defp backlog_cards(issues, worked) do
    issues
    |> Enum.filter(&(queueable?(&1, worked) and not refined?(&1)))
    |> Enum.sort_by(&created_at/1, {:desc, DateTime})
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        difficulty: Map.get(issue, :difficulty),
        issue_type: Map.get(issue, :issue_type),
        workspace_id: Map.get(issue, :workspace_id),
        assignee: Map.get(issue, :assignee),
        created_at: created_at(issue)
      }
    end)
  end

  defp ready_cards(issues, worked, blocked_by, conflicts, ready_order) do
    ranked = ranking(ready_order)

    issues
    |> Enum.filter(&(queueable?(&1, worked) and refined?(&1)))
    |> Enum.sort_by(&{Map.get(ranked, &1.id, :infinity), priority(&1), created_at(&1)}, :asc)
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        difficulty: Map.get(issue, :difficulty),
        issue_type: Map.get(issue, :issue_type),
        workspace_id: Map.get(issue, :workspace_id),
        assignee: Map.get(issue, :assignee),
        scope: FileScope.declared_paths(issue),
        blocked_by: Map.get(blocked_by, issue.id, []),
        conflicts_with: EdgeGate.conflicts(conflicts, issue.id)
      }
    end)
  end

  # Rank → sort key. Hand-ranked ids get their index; everything else sorts
  # behind them under `:infinity`, which compares greater than any integer in
  # Erlang's term order. Ranked ids that are no longer Ready just never match.
  defp ranking(ready_order) do
    ready_order
    |> Enum.with_index()
    |> Map.new()
  end

  # ---- running / waiting ----------------------------------------------------

  defp running_cards(workers, issues_by_id, gate_workers_by_author) do
    workers
    |> Enum.filter(&(&1.status in @running_statuses))
    |> Enum.map(fn w ->
      w
      |> base_card(issues_by_id)
      |> Map.merge(%{
        step: Map.get(w, :current_step),
        activity: activity(w, Map.get(gate_workers_by_author, w.task_id)),
        since: since(w)
      })
    end)
    |> Enum.sort_by(& &1.since, {:asc, DateTime})
  end

  # One column, so one card shape: a parked worker's card still carries the
  # (empty) merge fields and a merge-parked one still carries a (nil) reason,
  # and an orphaned issue (no live worker at all) still carries both, nil.
  # The view reads whichever it has instead of branching on which shape
  # produced the card.
  defp waiting(workers, issues, issues_by_id, worked, now, watchdog_live) do
    (waiting_cards(workers, issues_by_id, watchdog_live) ++
       orphaned_cards(issues, worked, now) ++
       awaiting_verification_cards(issues))
    |> Enum.sort_by(& &1.since, {:asc, DateTime})
  end

  # bd-9so315: a task merged but parked until someone restarts the server and
  # observes the new path. It has no worker (the merge tore it down), so it
  # produces no worker-derived card and would otherwise be invisible — which is
  # precisely the failure the state exists to fix. It is always `needs_you`:
  # nothing in the fleet can clear it, only a human observation can.
  defp awaiting_verification_cards(issues) do
    issues
    |> Enum.filter(&(Map.get(&1, :status) == :awaiting_verification))
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        difficulty: Map.get(issue, :difficulty),
        workspace_id: Map.get(issue, :workspace_id),
        assignee: Map.get(issue, :assignee),
        status: :awaiting_verification,
        reason: "merged — awaiting verification (restart and observe)",
        mr_ref: Map.get(issue, :pr_ref),
        merger_url: nil,
        merger_status: nil,
        watchdog_alive: nil,
        needs_you: true,
        collapsed_note: nil,
        since: awaiting_since(issue)
      }
    end)
  end

  # The parked-at stamp, falling back to `updated_at` for rows that entered the
  # state before the column existed, so the card still renders an age. Shared
  # with the rest of the verification surface so "how long has this waited" has
  # exactly one definition.
  defp awaiting_since(issue) do
    Arbiter.Tasks.Verification.awaiting_since(issue) || created_at(issue)
  end

  defp waiting_cards(workers, issues_by_id, watchdog_live) do
    workers
    |> Enum.filter(&(&1.status in @waiting_statuses))
    |> one_row_per_task()
    |> Enum.map(fn {w, group} ->
      alive = watchdog_alive(w, watchdog_live)

      w
      |> base_card(issues_by_id)
      |> Map.merge(%{
        reason: waiting_reason(w),
        mr_ref: Map.get(w, :mr_ref),
        merger_url: Map.get(w, :merger_url),
        merger_status: get_meta(w, :last_merger_status),
        watchdog_alive: alive,
        # The collapsed rows keep their vote: a dead fix pass under a
        # legitimately-parked primary still needs a human, even though the
        # primary row alone reads as "the machine has this".
        needs_you: child_needs_you?(group, watchdog_live),
        collapsed_note: collapsed_note(w, group),
        since: since(w)
      })
    end)
  end

  # What the collapsed subordinate rows say that the primary row's own fields
  # cannot: a `:failed` fix pass / conflict pass under the card. Nil when
  # nothing was collapsed away, or when the surviving row is itself the
  # subordinate (its own status already says it).
  defp collapsed_note(primary, group) do
    group
    |> Enum.reject(&(&1 == primary))
    |> Enum.filter(&(Map.get(&1, :status) == :failed))
    |> Enum.map(&(Arbiter.Worker.subordinate_label(&1) || "subordinate pass"))
    |> Enum.uniq()
    |> case do
      [] -> nil
      labels -> Enum.join(labels, ", ") <> " failed"
    end
  end

  # One task, one card (bd-8jixav). A task's primary row and a subordinate
  # `:fixpass` / `:conflict` pass's row are both in `@waiting_statuses` — a
  # parked `:awaiting_review` primary alongside a `:failed` fix pass is the
  # ordinary shape of a task the merge queue is working on — so the column used
  # to render one task as two cards that read at a glance as two different
  # stuck tickets.
  #
  # The primary row (`role: nil`) wins where both exist: it is the one holding
  # the MR, and the one whose fields the card's actions address. `Enum.min_by`
  # returns the first row of the minimal rank, so among rows of the same rank
  # the caller's order survives.
  #
  # Returns `{primary_row, all_rows_for_the_task}`: the card renders the
  # primary's fields, but the whole group is still there for the signals a
  # collapsed row would otherwise take with it (its `needs_you?` vote, its
  # failure).
  defp one_row_per_task(workers) do
    workers
    |> Enum.group_by(& &1.task_id)
    |> Enum.map(fn {_task_id, group} -> {Enum.min_by(group, &subordinate_rank/1), group} end)
  end

  defp subordinate_rank(worker), do: if(is_nil(Map.get(worker, :role)), do: 0, else: 1)

  # Whether a live Watchdog exists for this card's task — `true`/`false` only
  # where the question means something (an `:awaiting_review` park is the one
  # state that is *supposed* to have a Watchdog), and `nil` = unknown wherever
  # it doesn't, including when the caller supplied no liveness input at all.
  # A `:failed` or `:awaiting` worker holds no MR, so "no watchdog" is not a
  # finding about it.
  defp watchdog_alive(%{status: :awaiting_review} = worker, live) when is_struct(live, MapSet),
    do: MapSet.member?(live, worker.task_id)

  defp watchdog_alive(_worker, _live), do: nil

  # bd-2mv3lx: an issue stuck `in_progress` with no live worker — e.g. `arb
  # worker stop` on an `:awaiting_review` worker, the documented pre-flight
  # for `arb server deploy` — matches none of the worker-derived or
  # issue-open filters and used to vanish from the board entirely. It reads
  # truest as Waiting: the work is out of the machine's hands, and nothing
  # will retry it on its own, so it always flags `needs_you`.
  defp orphaned_cards(issues, worked, now) do
    issues
    |> Enum.filter(&orphaned?(&1, worked, now))
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        difficulty: Map.get(issue, :difficulty),
        workspace_id: Map.get(issue, :workspace_id),
        assignee: Map.get(issue, :assignee),
        status: :in_progress,
        reason: "worker stopped — resume or close",
        mr_ref: Map.get(issue, :pr_ref),
        merger_url: nil,
        merger_status: nil,
        # No live worker at all, so no Watchdog is expected either — the card
        # already says "worker stopped", which is the stronger statement.
        watchdog_alive: nil,
        needs_you: true,
        collapsed_note: nil,
        since: Map.get(issue, :updated_at) || created_at(issue)
      }
    end)
  end

  defp orphaned?(issue, worked, now) do
    issue.status == :in_progress and
      not dispatchable_type_excluded?(issue) and
      not MapSet.member?(worked, issue.id) and
      DateTime.diff(now, Map.get(issue, :updated_at) || created_at(issue)) >=
        @orphan_grace_seconds
  end

  defp waiting_reason(%{status: :awaiting_review}), do: nil
  defp waiting_reason(worker), do: halt_reason(worker)

  @doc """
  Whether a single live worker row needs the operator: an `:awaiting`
  question, a `:failed` park, or an open MR blocked for a reason outside the
  Watchdog's auto-resolvable set. `alive` is the `:awaiting_review`
  Watchdog-liveness bit (see `watchdog_alive/2`) — `false` always flags,
  since nothing is polling the MR.

  Public (bd-58z2tu) so `Arbiter.Tasks.EpicRollup` can classify a child's
  worker the same way the board's Waiting column does, through
  `child_needs_you?/2`, rather than re-deriving the rule.
  """
  @spec needs_you?(map(), boolean() | nil) :: boolean()
  # bd-8jixav: the MR is open and *nothing is polling it*. This outranks every
  # block-reason nuance below — a `:ci_failed` block the Watchdog would
  # ordinarily clear by itself is not getting cleared by a process that no
  # longer exists.
  def needs_you?(_worker, false), do: true

  # A question has no retry, so it is always the human's.
  def needs_you?(%{status: :awaiting}, _alive), do: true

  # A parked worker is terminal — the system has exhausted itself by
  # definition, whatever its last poll happened to record.
  def needs_you?(%{status: :failed}, _alive), do: true

  def needs_you?(worker, _alive) do
    case Watchdog.effective_block_reason(get_meta(worker, :last_merger_status) || %{}) do
      # No block the forge will admit to: the MR is simply mid-review, which is
      # still the machine's turn.
      nil -> false
      reason -> reason not in @auto_resolving_block_reasons
    end
  end

  @doc """
  Whether any of a task's live worker rows need the operator — the
  collapsed-group vote `waiting_cards/3` casts for a card, factored out so
  `Arbiter.Tasks.EpicRollup` can cast the same vote for an epic's child
  (bd-58z2tu). Pass every worker row for the task (a collapsed primary plus
  any subordinate fix/conflict pass), not just the primary, so a `:failed`
  fix pass under a legitimately-parked primary still counts. An empty list
  reads as `false` — a child with no live worker at all is not this
  function's question; the caller decides what "no worker" means for it.
  """
  @spec child_needs_you?([map()], MapSet.t() | nil) :: boolean()
  def child_needs_you?(workers, watchdog_live) do
    Enum.any?(workers, &needs_you?(&1, watchdog_alive(&1, watchdog_live)))
  end

  # ---- parent refs (bd-38of5i) ---------------------------------------------
  #
  # Design bd-2s901b §4: epics are gone from every column, so a child card is
  # the only place on the board an epic stays discoverable. Every card carries
  # a ref to its parent — id, title and the parent's own child progress —
  # which the view renders as a compact `↳ bd-epic` chip.
  #
  # Counts are derived from the edges and the issues already in hand rather
  # than from `Issue`'s `child_total` / `child_closed` calculations: the board
  # has read every issue anyway, and a pure `derive/1` must not go to a repo.

  defp with_parents(cards, parents) do
    Enum.map(cards, &Map.put(&1, :parent, Map.get(parents, &1.id)))
  end

  # ---- over-budget flag (bd-8j9i9p) ----------------------------------------
  #
  # Every card carries the key, `false` where it doesn't apply, so the view
  # reads one field everywhere instead of branching on which column built the
  # card — the same shape rule the parent ref follows.

  defp over_budget_set(nil), do: MapSet.new()
  defp over_budget_set(%MapSet{} = set), do: set
  defp over_budget_set(ids) when is_list(ids), do: MapSet.new(ids)

  defp with_over_budget(cards, nil),
    do: Enum.map(cards, &Map.put(&1, :over_budget, false))

  defp with_over_budget(cards, set),
    do: Enum.map(cards, &Map.put(&1, :over_budget, MapSet.member?(set, &1.id)))

  defp with_over_budget_in_entries(entries, set) do
    Enum.map(entries, fn entry ->
      %{entry | card: Map.put(entry.card, :over_budget, MapSet.member?(set, entry.card.id))}
    end)
  end

  # A Ready entry wraps its card; the ref belongs on the card, where every
  # other column's ref lives, so the view reads one key everywhere.
  defp with_parents_in_entries(entries, parents) do
    Enum.map(entries, fn entry ->
      %{entry | card: Map.put(entry.card, :parent, Map.get(parents, entry.card.id))}
    end)
  end

  defp parent_refs([], _issues_by_id), do: %{}

  defp parent_refs(parent_of, issues_by_id) do
    pairs = Enum.uniq(parent_of)
    children_by_parent = Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))

    pairs
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.reduce(%{}, fn {child_id, parent_ids}, acc ->
      case pick_parent(parent_ids, issues_by_id) do
        # A dangling edge (the parent is not among the issues the board read)
        # is not a chip: better none than one linking to a blank title.
        nil -> acc
        parent -> Map.put(acc, child_id, parent_ref(parent, children_by_parent, issues_by_id))
      end
    end)
  end

  # One card has room for one chip. Multiple `parent_of` parents are unusual
  # but legal, so it takes the most recently updated one — the same tie-break
  # the detail page's banner stacks by, so the two surfaces agree on which
  # parent leads.
  defp pick_parent(parent_ids, issues_by_id) do
    parent_ids
    |> Enum.sort()
    |> Enum.map(&Map.get(issues_by_id, &1))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parents -> Enum.max_by(parents, &parent_recency/1, DateTime)
    end
  end

  defp parent_recency(issue), do: Map.get(issue, :updated_at) || created_at(issue)

  defp parent_ref(parent, children_by_parent, issues_by_id) do
    children = children_by_parent |> Map.get(parent.id, []) |> Enum.uniq()

    %{
      id: parent.id,
      title: Map.get(parent, :title),
      issue_type: Map.get(parent, :issue_type),
      child_total: length(children),
      child_closed: Enum.count(children, &child_closed?(&1, issues_by_id))
    }
  end

  defp child_closed?(child_id, issues_by_id) do
    case Map.get(issues_by_id, child_id) do
      nil -> false
      issue -> Map.get(issue, :status) == :closed
    end
  end

  defp closed_today_cards(issues, now) do
    twenty_four_hours_ago = DateTime.add(now, -24, :hour)

    issues
    |> Enum.filter(fn issue ->
      issue.status == :closed and
        not dispatchable_type_excluded?(issue) and
        closed_within_24h?(
          Map.get(issue, :closed_at),
          Map.get(issue, :updated_at),
          twenty_four_hours_ago
        )
    end)
    |> Enum.sort_by(&closed_sort_key/1, {:desc, DateTime})
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        issue_type: Map.get(issue, :issue_type),
        workspace_id: Map.get(issue, :workspace_id),
        assignee: Map.get(issue, :assignee),
        closed_at: Map.get(issue, :closed_at) || Map.get(issue, :updated_at)
      }
    end)
  end

  defp closed_within_24h?(%DateTime{} = closed_at, _updated_at, cutoff) do
    DateTime.compare(closed_at, cutoff) != :lt
  end

  defp closed_within_24h?(nil, %DateTime{} = updated_at, cutoff) do
    DateTime.compare(updated_at, cutoff) != :lt
  end

  defp closed_within_24h?(nil, nil, _cutoff) do
    false
  end

  defp closed_sort_key(issue) do
    Map.get(issue, :closed_at) || Map.get(issue, :updated_at)
  end

  defp base_card(worker, issues_by_id) do
    issue = Map.get(issues_by_id, worker.task_id)

    %{
      id: worker.task_id,
      title: (issue && Map.get(issue, :title)) || worker.task_id,
      priority: issue && Map.get(issue, :priority),
      difficulty: issue && Map.get(issue, :difficulty),
      workspace_id: Map.get(worker, :workspace_id),
      assignee: issue && Map.get(issue, :assignee),
      status: worker.status
    }
  end

  # What the in-flight work has claimed: the issue's declared paths plus
  # whatever the worktree has actually changed. The union matters — a worker
  # ten minutes in has touched files its ticket never named.
  # bd-6bax7s: everything a `:conflicts_with` counterpart must not run beside,
  # as `%{task_id => state}`. Wider than `in_flight/3`, which answers the *file*
  # question and so only counts slot-holders: a counterpart at
  # `:awaiting_review` holds an open MR rather than a slot, and is still very
  # much mid-flight as far as a declared mutex is concerned.
  #
  # Three sources, in increasing authority:
  #
  #   * an issue flipped to `:in_progress` whose worker has not registered yet
  #     (inside `@orphan_grace_seconds`) — the window the bd-1780 incident
  #     dispatched into. Past the grace it reads as *orphaned* instead, and
  #     releases the mutex: nothing is going to retry it on its own, so holding
  #     its counterpart hostage would strand both.
  #   * a reviewer / implementer worker, claiming on behalf of the author it
  #     works for — covers a fix pass whose author worker has already gone.
  #   * the author's own live worker, which knows its status exactly.
  #
  # A counterpart that is `:closed`, parked at `:awaiting_verification`
  # (merged — the worktree is gone, nothing left to collide with) or `:failed`
  # (parked, terminal) appears in none of them.
  defp conflict_claims(authors, gate_workers, issues, worked, now) do
    issues
    |> Enum.filter(&mid_dispatch?(&1, worked, now))
    |> Map.new(&{&1.id, @dispatching_state})
    |> Map.merge(Map.new(claims_from(gate_workers, &gate_author/1, &gate_state/1)))
    |> Map.merge(Map.new(claims_from(authors, & &1.task_id, &author_state/1)))
  end

  defp claims_from(workers, id_fun, state_fun) do
    Enum.flat_map(workers, fn w ->
      case {id_fun.(w), state_fun.(w)} do
        {nil, _} -> []
        {_, nil} -> []
        {id, state} -> [{id, state}]
      end
    end)
  end

  defp author_state(worker), do: Map.get(@conflict_states, Map.get(worker, :status))

  defp gate_state(worker) do
    case worker_role(worker) do
      :implementer -> @fix_pass_state
      _ -> @reviewer_state
    end
  end

  # The inverse of `orphaned?/3` for an `:in_progress` issue: young enough that
  # the missing worker reads as "still provisioning", not "stopped".
  defp mid_dispatch?(issue, worked, now) do
    issue.status == :in_progress and
      not dispatchable_type_excluded?(issue) and
      not MapSet.member?(worked, issue.id) and
      DateTime.diff(now, Map.get(issue, :updated_at) || created_at(issue)) <
        @orphan_grace_seconds
  end

  defp in_flight(workers, issues_by_id, changed) do
    workers
    |> Enum.filter(&(&1.status in @slot_statuses))
    |> Enum.map(fn w ->
      declared =
        case Map.get(issues_by_id, w.task_id) do
          nil -> MapSet.new()
          issue -> FileScope.declared_paths(issue)
        end

      %{
        task_id: w.task_id,
        scope: MapSet.union(declared, MapSet.new(Map.get(changed, w.task_id, [])))
      }
    end)
  end

  defp activity(%{status: :awaiting_review_gate} = w, gate_worker) do
    case gate_worker && round_label(gate_worker.task_id, w.task_id) do
      nil ->
        case gate_worker && live_label(gate_worker) do
          nil -> "in review"
          label -> "in review · #{label}"
        end

      phase ->
        case live_label(gate_worker) do
          nil -> phase
          label -> "#{phase} · #{label}"
        end
    end
  end

  defp activity(worker, _gate_worker), do: live_label(worker) || "working"

  # A reviewer/implementer's synthetic id is `<base>#<suffix>` where suffix
  # may itself be a chain (e.g. `#review#impl2`, `#review#r2#v2`) —
  # `Arbiter.Worker.ReviewGate.base_task_id/1` recovers the base id
  # regardless of chain depth; recovering it here is how its card folds onto
  # the original issue's card instead of rendering a second one titled with
  # the raw suffixed id.
  defp gate_author(worker), do: reviews_task(worker) || revises_task(worker)

  # Human-readable round label for a fix-up round actively in progress: a
  # round-2+ reviewer pass (`#r<N>`) or an implementer revise pass
  # (`#impl<N>`). A plain first-round reviewer (`#review`, or a same-round
  # re-prompt `#v<N>`) has no fix-up in progress yet, so it renders as before
  # ("in review") rather than a manufactured "round 1 review".
  #
  # ReviewGate's real synthetic ids chain suffixes onto `#review`
  # (`<base>#review#impl<N>`, `<base>#review#r<N>`, possibly followed by a
  # re-prompt `#v<N>`), so the round marker is not necessarily the first
  # `#`-segment after the base id — it's whichever segment in the chain
  # matches `#impl<N>`/`#r<N>`, found by scanning from the end.
  defp round_label(gate_task_id, base_id) do
    if Arbiter.Worker.ReviewGate.base_task_id(gate_task_id) == base_id do
      gate_task_id
      |> String.split("#")
      |> Enum.drop(1)
      |> Enum.reverse()
      |> Enum.find_value(&parse_round_suffix/1)
    end
  end

  defp parse_round_suffix(segment) do
    cond do
      match = Regex.run(~r/^impl(\d+)$/, segment) -> "round #{Enum.at(match, 1)} implementation"
      match = Regex.run(~r/^r(\d+)$/, segment) -> "round #{Enum.at(match, 1)} review"
      true -> nil
    end
  end

  defp live_label(worker) do
    case get_meta(worker, :activity) do
      %{"label" => label} when is_binary(label) -> label
      %{label: label} when is_binary(label) -> label
      label when is_binary(label) -> label
      _ -> nil
    end
  end

  defp halt_reason(%{status: :awaiting} = worker),
    do: get_meta(worker, :await_reason) || "waiting on you"

  defp halt_reason(worker) do
    case get_meta(worker, :stop_reason) do
      %{summary: summary} when is_binary(summary) -> summary
      %{"summary" => summary} when is_binary(summary) -> summary
      summary when is_binary(summary) -> summary
      _ -> "failed"
    end
  end

  defp worker_role(worker), do: get_meta(worker, :role)
  defp reviews_task(worker), do: get_meta(worker, :reviews)
  defp revises_task(worker), do: get_meta(worker, :revises)

  defp get_meta(worker, key) do
    case Map.get(worker, :meta) do
      %{} = meta -> Map.get(meta, key)
      _ -> nil
    end
  end

  defp since(worker), do: Map.get(worker, :step_started_at) || Map.get(worker, :started_at)

  # nil priority sorts last: an unprioritised issue is not urgent by omission.
  defp priority(issue) do
    case Map.get(issue, :priority) do
      n when is_integer(n) -> n
      _ -> 99
    end
  end

  defp created_at(issue), do: Map.get(issue, :created_at) || ~U[1970-01-01 00:00:00Z]

  # ---- reads ---------------------------------------------------------------

  defp load_issues do
    Ash.read!(Arbiter.Tasks.Issue)
  rescue
    _ -> []
  end

  defp load_workers do
    Arbiter.Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp dependency_rows(opts) do
    if Enum.all?([:blocked_by, :parent_of, :conflicts_with], &Keyword.has_key?(opts, &1)) do
      []
    else
      Ash.read!(Arbiter.Tasks.Dependency)
    end
  rescue
    _ -> []
  end

  # bd-38of5i: `{parent_id, child_id}` for every `:parent_of` row. The board
  # reads every issue anyway, so `derive/1` turns these into per-card refs
  # (title + child progress) without a second query.
  defp parent_of_from(deps) do
    for %{type: :parent_of} = dep <- deps, do: {dep.from_issue_id, dep.to_issue_id}
  end

  # Open gating blockers per issue. The rule itself lives in
  # `Arbiter.Tasks.EdgeGate` (bd-6bax7s), shared with the Conductor so the two
  # schedulers cannot drift; this is only the read that feeds it.
  defp blockers_from(deps, issues) do
    EdgeGate.blockers(deps, issues)
  rescue
    _ -> %{}
  end

  defp default_workspace_id do
    case Arbiter.Quota.default_workspace_id() do
      {:ok, ws_id} -> ws_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_workspace(ws_id) do
    case Ash.get(Arbiter.Tasks.Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp latest_quota(ws_id, workspace) do
    provider = if workspace, do: Arbiter.Quota.default_provider(workspace), else: :claude
    Arbiter.Quota.latest_for_provider(ws_id, provider)
  rescue
    _ -> nil
  end

  # "Exhausted" and "near exhaustion" are different operator problems: the
  # first clears when the window resets, the second clears if you raise the
  # ceiling. A 7d hold is a third: it clears at the weekly reset, days away, so
  # `Arbiter.Quota.Gate.hold_phrase/2` labels it with the window explicitly
  # (`7d quota 0.91 ≥ 0.90`) rather than reusing the 5h wording (bd-1tuxv8).
  defp describe_quota(snapshot, workspace) do
    case Arbiter.Quota.Gate.hold_phrase(snapshot, workspace) do
      nil -> :ok
      phrase -> {:hold, phrase}
    end
  end
end
