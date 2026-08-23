defmodule Arbiter.Board.Snapshot do
  @moduledoc """
  The board, derived. One read of the world in, four columns and a dispatch
  decision out.

  The operator console's board is not a stored object — Arbiter has no "board"
  table and deliberately doesn't want one. Every column is a *view* of state
  that already exists (issues, live workers, merge requests), so the board can
  never drift from the system it describes: there is nothing to keep in sync.

  ## The four columns

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
      MR is open and the Watchdog is polling). Longest wait first, because a
      stalled card is the thing worth seeing.
    * **Closed today** — issues closed since midnight UTC. The day's evidence
      of progress, and the only column with no action on it.

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
    * anything else flags only when its merge block is one nothing in Arbiter
      can clear: `:conflict`, `:needs_approval`, `:needs_nonauthor_approval`.
      A `:behind_base` or a `:ci_failed` does not, because the merge queue is
      already rebasing or dispatching a fix pass against it.
    * a `:failed` worker with no block at all flags: nothing retries a parked
      failure.

  The block reason is read through `Arbiter.Worker.Watchdog`
  (`effective_block_reason/1`, itself gated on `classify/1 == :approved`), the
  same surface the merge-queue screen reads, so the flag can never disagree
  with the status text rendered next to it. The list is expected to *shrink*
  as more auto-recovery lands — it measures "still needs a human today", not
  "something is imperfect".

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
  alias Arbiter.Worker.Watchdog

  require Ash.Query

  @typedoc "Worker statuses that hold a live agent, and so a worker slot."
  @slot_statuses [:idle, :resuming, :running, :awaiting, :awaiting_review_gate]

  # Live agent working; the author is still "running" while a reviewer reads.
  @running_statuses [:idle, :resuming, :running, :awaiting_review_gate]

  # Worker is done; the outcome is somebody else's to produce.
  @waiting_statuses [:awaiting, :failed, :awaiting_review]

  # Merge blocks no amount of waiting or retrying clears — see the moduledoc.
  @needs_human_block_reasons [:conflict, :needs_approval, :needs_nonauthor_approval]

  # Board-level dispatch is per-issue, so containers never queue: an epic is a
  # rollup of children, not something a worker can be handed.
  @non_dispatchable_types [:epic]

  @default_system_max 16

  @type t :: %{
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
  ids), `:changed_files` (task id → repo-relative paths a worktree has
  touched), `:now`, `:slots_total`, `:quota`, `:paused` and `:ready_order`.
  Every key has a sane default, so a caller may pass only what it has.

  `:ready_order` is the operator's hand-ranking of the Ready queue — the ids
  it names lead the queue in that order, and everything else follows in
  priority order behind them. Because the scheduler promotes the first
  eligible card, dragging a card to the top of Ready is how a human overrides
  the machine's idea of what matters most without dispatching anything by
  hand.
  """
  @spec derive(map()) :: t()
  def derive(input) when is_map(input) do
    issues = Map.get(input, :issues) || []
    workers = Map.get(input, :workers) || []
    blocked_by = Map.get(input, :blocked_by) || %{}
    changed = Map.get(input, :changed_files) || %{}
    now = Map.get(input, :now) || DateTime.utc_now()
    slots_total = Map.get(input, :slots_total) || 0
    quota = Map.get(input, :quota) || :ok
    paused? = Map.get(input, :paused) == true
    ready_order = Map.get(input, :ready_order) || []

    issues_by_id = Map.new(issues, &{&1.id, &1})
    {authors, reviewers} = Enum.split_with(workers, &(worker_role(&1) != :reviewer))
    reviewers_by_author = Map.new(reviewers, &{reviews_task(&1), &1})
    worked = MapSet.new(authors, & &1.task_id)

    running = running_cards(authors, issues_by_id, reviewers_by_author)
    slots_free = max(slots_total - Enum.count(authors, &(&1.status in @slot_statuses)), 0)

    plan =
      Scheduler.plan(%{
        ready: ready_cards(issues, worked, blocked_by, ready_order),
        running: in_flight(authors, issues_by_id, changed),
        slots_free: slots_free,
        quota: quota,
        paused: paused?
      })

    %{
      ready: plan.entries,
      running: running,
      waiting: waiting_cards(authors, issues_by_id),
      closed_today: closed_today_cards(issues, now),
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
  `:issues`, `:workers`, `:changed_files`. Every read is best-effort — a board
  that renders four columns beats one that raises.
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    issues = Keyword.get_lazy(opts, :issues, &load_issues/0)
    workers = Keyword.get_lazy(opts, :workers, &load_workers/0)

    derive(%{
      issues: issues,
      workers: workers,
      blocked_by: Keyword.get_lazy(opts, :blocked_by, fn -> load_blockers(issues) end),
      changed_files: Keyword.get(opts, :changed_files, %{}),
      now: Keyword.get(opts, :now) || DateTime.utc_now(),
      slots_total: Keyword.get(opts, :slots_total) || system_max_concurrent(),
      quota: Keyword.get_lazy(opts, :quota, &quota_hold/0),
      paused: Keyword.get(opts, :paused, false),
      ready_order: Keyword.get(opts, :ready_order, [])
    })
  end

  @doc """
  A board with four empty columns and nothing to promote.

  What a caller renders when its read of the world failed. It reports itself
  `paused: true` on purpose: a queue nobody could read is not one anything
  should be dispatching from, and every Ready card would otherwise claim a
  position in a queue that isn't moving.
  """
  @spec empty(DateTime.t() | nil) :: t()
  def empty(now \\ nil) do
    %{
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
  Whether quota permits a dispatch right now, as `:ok` or `{:hold, reason}`.

  Distinguishes an actually-exhausted window ("the provider is refusing") from
  one that has crossed the throttle threshold ("we chose to stop here"),
  because the operator's next move differs: wait for the reset, or raise the
  ceiling.
  """
  @spec quota_hold(String.t() | nil) :: Scheduler.quota()
  def quota_hold(workspace_id \\ nil) do
    workspace_id = workspace_id || default_workspace_id()

    with ws_id when is_binary(ws_id) <- workspace_id,
         workspace <- safe_workspace(ws_id),
         snapshot when not is_nil(snapshot) <- latest_quota(ws_id) do
      describe_quota(snapshot, workspace)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # ---- ready ---------------------------------------------------------------

  defp ready_cards(issues, worked, blocked_by, ready_order) do
    ranked = ranking(ready_order)

    issues
    |> Enum.filter(fn issue ->
      issue.status == :open and
        Map.get(issue, :issue_type) not in @non_dispatchable_types and
        not MapSet.member?(worked, issue.id)
    end)
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
        blocked_by: Map.get(blocked_by, issue.id, [])
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

  defp running_cards(workers, issues_by_id, reviewers_by_author) do
    workers
    |> Enum.filter(&(&1.status in @running_statuses))
    |> Enum.map(fn w ->
      w
      |> base_card(issues_by_id)
      |> Map.merge(%{
        step: Map.get(w, :current_step),
        activity: activity(w, Map.get(reviewers_by_author, w.task_id)),
        since: since(w)
      })
    end)
    |> Enum.sort_by(& &1.since, {:asc, DateTime})
  end

  # One column, so one card shape: a parked worker's card still carries the
  # (empty) merge fields and a merge-parked one still carries a (nil) reason.
  # The view reads whichever it has instead of branching on which half of the
  # union produced the card.
  defp waiting_cards(workers, issues_by_id) do
    workers
    |> Enum.filter(&(&1.status in @waiting_statuses))
    |> Enum.map(fn w ->
      w
      |> base_card(issues_by_id)
      |> Map.merge(%{
        reason: waiting_reason(w),
        mr_ref: Map.get(w, :mr_ref),
        merger_url: Map.get(w, :merger_url),
        merger_status: get_meta(w, :last_merger_status),
        needs_you: needs_you?(w),
        since: since(w)
      })
    end)
    |> Enum.sort_by(& &1.since, {:asc, DateTime})
  end

  defp waiting_reason(%{status: :awaiting_review}), do: nil
  defp waiting_reason(worker), do: halt_reason(worker)

  # A question has no retry, so it is always the human's.
  defp needs_you?(%{status: :awaiting}), do: true

  defp needs_you?(worker) do
    case Watchdog.effective_block_reason(get_meta(worker, :last_merger_status) || %{}) do
      # No block the forge will admit to: an open MR is simply mid-review (the
      # machine's turn), while a parked failure has nothing left to turn.
      nil -> worker.status == :failed
      reason -> reason in @needs_human_block_reasons
    end
  end

  defp closed_today_cards(issues, now) do
    today = DateTime.to_date(now)

    issues
    |> Enum.filter(fn issue ->
      issue.status == :closed and same_day?(Map.get(issue, :updated_at), today)
    end)
    |> Enum.sort_by(&Map.get(&1, :updated_at), {:desc, DateTime})
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        issue_type: Map.get(issue, :issue_type),
        workspace_id: Map.get(issue, :workspace_id),
        assignee: Map.get(issue, :assignee),
        closed_at: Map.get(issue, :updated_at)
      }
    end)
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

  defp activity(%{status: :awaiting_review_gate}, reviewer) do
    case reviewer && live_label(reviewer) do
      nil -> "in review"
      label -> "in review · #{label}"
    end
  end

  defp activity(worker, _reviewer), do: live_label(worker) || "working"

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

  defp get_meta(worker, key) do
    case Map.get(worker, :meta) do
      %{} = meta -> Map.get(meta, key)
      _ -> nil
    end
  end

  defp since(worker), do: Map.get(worker, :step_started_at) || Map.get(worker, :started_at)

  defp same_day?(%DateTime{} = ts, today), do: DateTime.to_date(ts) == today
  defp same_day?(_, _), do: false

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

  # Open gating blockers per issue: `:depends_on` targets and `:blocks` sources
  # that are not themselves closed. Mirrors `Arbiter.Tasks.Issue.ready/0`'s
  # gating rule, but keeps the blocked issues instead of dropping them — the
  # board shows *why* a card can't go, which means it has to show the card.
  defp load_blockers(issues) do
    open_ids = for i <- issues, i.status == :open, into: MapSet.new(), do: i.id
    closed = for i <- issues, i.status == :closed, into: MapSet.new(), do: i.id

    Arbiter.Tasks.Dependency
    |> Ash.read!()
    |> Enum.flat_map(fn dep ->
      case dep.type do
        :depends_on -> [{dep.from_issue_id, dep.to_issue_id}]
        :blocks -> [{dep.to_issue_id, dep.from_issue_id}]
        _ -> []
      end
    end)
    |> Enum.filter(fn {blocked, blocker} ->
      MapSet.member?(open_ids, blocked) and not MapSet.member?(closed, blocker)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, blockers} -> {id, blockers |> Enum.uniq() |> Enum.sort()} end)
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

  defp latest_quota(ws_id) do
    Arbiter.Quota.latest_for_provider(ws_id, :claude)
  rescue
    _ -> nil
  end

  defp describe_quota(snapshot, workspace) do
    if Arbiter.Quota.Gate.over_cap?(snapshot, workspace) do
      {:hold, quota_phrase(snapshot, workspace)}
    else
      :ok
    end
  end

  # "Exhausted" and "near exhaustion" are different operator problems: the
  # first clears when the window resets, the second clears if you raise the
  # ceiling. Naming the ceiling in the second case saves the lookup.
  defp quota_phrase(snapshot, workspace) do
    case Arbiter.Quota.Gate.Snapshot.normalize(snapshot) do
      nil ->
        "quota exhausted"

      %{status: status} when status not in [nil, "allowed"] ->
        "quota exhausted"

      %{utilization: utilization} ->
        "quota near exhaustion (#{percent(utilization)} of window used, " <>
          "ceiling #{percent(Arbiter.Quota.Gate.threshold(workspace))})"
    end
  end

  defp percent(nil), do: "—"
  defp percent(n) when is_number(n), do: "#{round(n * 100)}%"
  defp percent(_), do: "—"
end
