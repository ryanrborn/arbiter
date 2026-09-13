defmodule Arbiter.Tasks.Verification do
  @moduledoc """
  Post-merge verification (bd-9so315) — the `:awaiting_verification` half of the
  task FSM.

  ## Why this exists

  The largest escaped-defect class in the 2026-09-13 follow-up-rate
  investigation was changes whose only execution context is the long-lived
  server: `capture_source` reading a deleted key, `doctor` staying green while
  repo discovery returned zero repos, env/config plumbing that reached no
  worker, shipped dead code. All merged green, all auto-closed by the merge
  queue, all found broken a median ~8 hours later. Nothing in the pipeline ever
  asked "is this live and working?" — and a single observation after a restart
  would have caught every one of them.

  So a task flagged `verify_after_deploy: true` does not close on merge. It
  parks at `:awaiting_verification`, the coordinator is notified (with whether
  the running server predates the merge, i.e. whether a restart is needed
  first), and the task leaves the state only through a recorded verdict:

      Verification.observed(task, "restarted; /api/doctor now reports 3 repos")
      Verification.failed(task, "after restart capture_source still reads headers")

  ## Upstream tracker close: at merge, not deferred

  The upstream issue is closed at **merge** time, exactly as before the flag
  existed, for both flagged and unflagged tasks. Deferring it would be a
  fiction: the PR body carries a `Closes #N` keyword, so GitHub closes the
  upstream issue the moment the PR merges whatever Arbiter does, and a local
  record claiming the upstream is still open is precisely the drift
  `Arbiter.Tasks.Claim`'s check exists to catch. `failed/2` reopens the
  upstream issue along with the task (the `:reopen` action's own
  `SyncTracker`), so the two stay consistent through a failed round too.

  ## Evidence is persisted before the transition

  `record_verification` (evidence + verdict) runs as its own action *before*
  the `:close` / `:reopen`, so a failure in the follow-on transition still
  leaves the evidence durable on the task rather than losing what was observed.
  """

  require Logger

  alias Arbiter.Tasks.Issue

  @type outcome :: :observed | :failed
  @type error :: :not_awaiting_verification | :evidence_required | {:invalid, term()}

  @doc """
  Record a successful restart-and-observe: persist `evidence` + the `:observed`
  verdict, then close the task.

  `close_upstream: false` — the upstream issue was already closed at merge time
  (see the moduledoc), and a second close transition would overshoot a Jira
  workflow and add a redundant API write everywhere else.
  """
  @spec observed(Issue.t(), String.t()) :: {:ok, Issue.t()} | {:error, error()}
  def observed(%Issue{} = task, evidence) do
    with {:ok, evidence} <- validate_evidence(evidence),
         :ok <- ensure_awaiting(task),
         {:ok, recorded} <- record(task, :observed, evidence) do
      case Ash.update(recorded, %{close_upstream: false}, action: :close) do
        {:ok, closed} -> {:ok, closed}
        {:error, err} -> {:error, {:invalid, err}}
      end
    end
  end

  @doc """
  Record a failed restart-and-observe: persist `evidence` + the `:failed`
  verdict, then reopen the task for another attempt.

  Reopening (rather than filing a linked bug) keeps the original ticket — and
  its acceptance criteria — as the single place the fix is tracked, and the
  `:reopen` action already clears `pr_ref`/`source_pr` so the retry opens a
  fresh PR instead of re-finalizing the merged one. `verify_after_deploy`
  survives, so the retry re-enters verification when it merges.
  """
  @spec failed(Issue.t(), String.t()) :: {:ok, Issue.t()} | {:error, error()}
  def failed(%Issue{} = task, evidence) do
    with {:ok, evidence} <- validate_evidence(evidence),
         :ok <- ensure_awaiting(task),
         {:ok, recorded} <- record(task, :failed, evidence) do
      case Ash.update(recorded, %{}, action: :reopen) do
        {:ok, reopened} -> {:ok, reopened}
        {:error, err} -> {:error, {:invalid, err}}
      end
    end
  end

  @doc """
  Record a verdict by its string/atom name — the shape the CLI, REST and MCP
  surfaces all arrive in.
  """
  @spec record_outcome(Issue.t(), outcome() | String.t(), String.t()) ::
          {:ok, Issue.t()} | {:error, error()}
  def record_outcome(task, outcome, evidence)

  def record_outcome(%Issue{} = task, outcome, evidence) when outcome in [:observed, "observed"],
    do: observed(task, evidence)

  def record_outcome(%Issue{} = task, outcome, evidence) when outcome in [:failed, "failed"],
    do: failed(task, evidence)

  def record_outcome(%Issue{}, outcome, _evidence),
    do: {:error, {:invalid, "unknown verification outcome: #{inspect(outcome)}"}}

  @doc """
  The single merge-success funnel: close the task, or — when it carries
  `verify_after_deploy: true` — park it at `:awaiting_verification` and notify
  the coordinator exactly once.

  Every path that finalizes a merged PR routes through here — the merge queue's
  own merge, `MergedPRFinalizer`'s sweep for a PR merged outside the queue, and
  `Arbiter.Worker.Driver`'s close of a worker the Watchdog completed with
  `:merged` — so the flag cannot be honoured on one path and silently ignored
  on another.

  Options:

    * `:close_upstream` (default `true`) — propagate the close to the linked
      tracker. Applies to BOTH branches: the upstream close is not deferred by
      verification (see the moduledoc).
    * `:mr_ref` — the PR/MR ref to name in the escalation; falls back to the
      task's `pr_ref`.
    * `:merged_at` (default now) — when the merge landed, compared against the
      running node's boot time to say whether a restart is needed first.

  Returns `{:ok, :closed | :awaiting_verification, issue}` or `{:error, reason}`.
  """
  @spec finalize_merged(Issue.t(), keyword()) ::
          {:ok, :closed | :awaiting_verification, Issue.t()} | {:error, term()}
  def finalize_merged(task, opts \\ [])

  def finalize_merged(%Issue{verify_after_deploy: true} = task, opts) do
    # The park is attempted FIRST. Only once the local transition has actually
    # landed do we push the upstream close — otherwise a refused park (the task
    # raced to `:closed`, a DB error) would leave the tracker issue closed with
    # nothing local to match it, and a retry would push a second close. This
    # mirrors the unflagged branch, where `SyncTracker` runs as an after-action
    # *inside* the transition and so cannot fire without it.
    case Ash.update(task, %{}, action: :await_verification) do
      {:ok, awaiting} ->
        if Keyword.get(opts, :close_upstream, true) do
          # Not deferred: the PR body's `Closes #N` has already closed the
          # upstream issue on merge, so pushing our own close keeps the local
          # record honest rather than leaving `Tasks.Claim`'s drift check
          # staring at a mismatch. `close_and_verify/1` is the same
          # transition-then-verify-then-retry pair `SyncTracker` performs on
          # the `:close` action (and it carries the same `review_only` guard),
          # so a flagged task is no less likely than an unflagged one to end
          # with its tracker issue actually closed.
          Arbiter.Trackers.Sync.close_and_verify(awaiting)
        end

        Arbiter.Messages.CoordinatorNotifier.awaiting_verification(
          %{task_id: task.id, workspace_id: task.workspace_id},
          Keyword.get(opts, :mr_ref) || task.pr_ref,
          Keyword.get(opts, :merged_at) || DateTime.utc_now()
        )

        {:ok, :awaiting_verification, awaiting}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def finalize_merged(%Issue{} = task, opts) do
    close_upstream = Keyword.get(opts, :close_upstream, true)

    case Ash.update(task, %{close_upstream: close_upstream}, action: :close) do
      {:ok, closed} -> {:ok, :closed, closed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  When a parked task's wait started — the `awaiting_verification_at` stamp,
  falling back to `updated_at` (and then `inserted_at`) for rows that entered
  the state before the column existed, so an age is always renderable.

  Accepts an `Issue` struct or any map with those keys, so the board snapshot
  and any other surface that has already loaded the rows shares one definition
  of "how long has this been waiting" rather than re-deriving the fallback.
  """
  @spec awaiting_since(Issue.t() | map()) :: DateTime.t() | nil
  def awaiting_since(issue) do
    Map.get(issue, :awaiting_verification_at) || Map.get(issue, :updated_at) ||
      Map.get(issue, :inserted_at)
  end

  # ---- internals ---------------------------------------------------------

  defp ensure_awaiting(%Issue{status: :awaiting_verification}), do: :ok
  defp ensure_awaiting(%Issue{}), do: {:error, :not_awaiting_verification}

  defp validate_evidence(evidence) when is_binary(evidence) do
    case String.trim(evidence) do
      "" -> {:error, :evidence_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_evidence(_), do: {:error, :evidence_required}

  defp record(task, outcome, evidence) do
    case Ash.update(
           task,
           %{verification_outcome: outcome, verification_evidence: evidence},
           action: :record_verification
         ) do
      {:ok, recorded} ->
        {:ok, recorded}

      {:error, err} ->
        Logger.warning(
          "Verification: failed to record #{outcome} verdict for task=#{task.id}: #{inspect(err)}"
        )

        {:error, {:invalid, err}}
    end
  end
end
