defmodule Arbiter.Tasks.ReviewPark do
  @moduledoc """
  The ReviewGate park (bd-9zuvbh) — guard class C's terminal state, from design
  #1635 §5.3.

  ## Why this exists

  A ReviewGate guard answers two different questions, and until P9 both were
  answered the same way:

    * *"Should this APPROVE merge?"* — must **fail closed**. bd-6r8caj (an
      APPROVE that never revisits its own open finding) and bd-4yhv4x (an
      APPROVE carrying a `[NOT MET]` criterion) are real, and nothing here
      changes what gets accepted or merged.
    * *"Should this run be marked failed?"* — must **fail open**. That half is
      the entire $226.97: `:review_gate_inconclusive` alone ended 52 runs in 31
      days, and all four chain-B incidents (bd-6dxit2, bd-869mmg, bd-1xss5z,
      bd-c6tdbu) ended the same way — a failed run on work that was fine.

  A park is what "fail open on liveness" looks like on the record. The branch is
  pushed, the PR is open, the round is recorded honestly (`converged: false`)
  and the work is one human decision away from merging — so the durable run row
  says `:review_parked`, not `:failed`, and the task carries a named reason a
  human can act on.

  ## A flag, not a status

  The park does **not** move the task out of `:in_progress`. `Tasks.Claim`, the
  board and the dependency graph keep seeing live work, and `Dispatch.resume/2`
  can re-attach to the parked worker the moment someone acts. Contrast
  `:awaiting_verification` (bd-9so315), which is a real status because that task
  *is* finished and merged; a review-parked task is not finished.

  ## Leaving the park

  Two human actions clear it, per §5.3's "human decides" terminal:

    * **re-run the review** — `clear/2`, called when a fresh ReviewGate starts
      for the task (an `arb worker resume` / re-dispatch), and available
      directly for a coordinator that merges by hand;
    * **close the task** — the `:close` action clears the flag inline, so an
      abandoned park does not linger in `arb prime`.
  """

  require Logger

  alias Arbiter.Tasks.Issue

  @typedoc """
  Why the gate parked. Each value maps one-to-one onto a §2.1 guard's terminal
  arm, so the mail subject, `arb prime` and the task API all name the same
  thing the `review_gate_rounds` row does.
  """
  @type reason ::
          :inconclusive
          | :reviewer_failed
          | :reviewer_timeout
          | :verdict_guard_exhausted
          | :no_changes_after_approval_gap
          | :commit_gate_no_changes
          | :commit_gate_uncommitted
          | :empty_diff
          | :review_rerun

  @reasons %{
    inconclusive:
      "the reviewer produced no parseable VERDICT line, even after a re-prompt (G5–G7)",
    reviewer_timeout: "the reviewing pass timed out with no verdict (G3/G4)",
    reviewer_failed:
      "the reviewer's own session died of an infrastructure failure — credentials, " <>
        "quota, a dead gateway — before it could produce a verdict (G3)",
    verdict_guard_exhausted:
      "a verdict guard refused the reviewer's APPROVE and its re-prompt budget is spent (G9–G13)",
    no_changes_after_approval_gap:
      "the fix round that stood in for a guard-rejected APPROVE made no code change (G16)",
    commit_gate_no_changes: "a fix round left HEAD unmoved and the worktree clean (G15/G16)",
    commit_gate_uncommitted:
      "the implementer left uncommitted work and HEAD did not move, twice (G15/G16)",
    empty_diff: "the target branch has already absorbed this branch's commits (G2)"
  }

  # The phrase each reason contributes to the escalation subject. These are
  # load-bearing wording, not decoration: bd-2eyf9y gave the two commit-gate
  # shapes distinct subjects precisely so "the implementer left work
  # uncommitted" could not be read as "the fix round found nothing to do", and
  # P9 must not flatten them back into one generic "parked" line.
  @subjects %{
    inconclusive: "review inconclusive",
    reviewer_failed: "the reviewer's session failed",
    reviewer_timeout: "reviewing pass timed out",
    verdict_guard_exhausted: "a verdict guard refused the reviewer's APPROVE",
    no_changes_after_approval_gap:
      "fix round produced no changes after an approval-gap rejection",
    commit_gate_no_changes: "fix round produced no changes",
    commit_gate_uncommitted: "implementer left uncommitted work",
    empty_diff: "the target branch already absorbed these commits"
  }

  @doc """
  The mail-subject phrase for `reason` — what a coordinator reads in `arb inbox`
  before opening anything.
  """
  @spec subject_phrase(reason() | String.t()) :: String.t()
  def subject_phrase(reason) when is_atom(reason),
    do: Map.get(@subjects, reason, Atom.to_string(reason))

  def subject_phrase(reason) when is_binary(reason) do
    case existing_atom(reason) do
      {:ok, atom} -> subject_phrase(atom)
      :error -> reason
    end
  end

  @doc "Every park reason, with the one-line explanation shown to a human."
  @spec reasons() :: %{reason() => String.t()}
  def reasons, do: @reasons

  @doc """
  The human-readable explanation for `reason`, or a generic line for one this
  module does not know (a new guard must still park rather than fail, so an
  unknown reason is rendered, never rejected).
  """
  @spec explain(reason() | String.t()) :: String.t()
  def explain(reason) when is_atom(reason), do: Map.get(@reasons, reason, generic(reason))

  def explain(reason) when is_binary(reason) do
    case existing_atom(reason) do
      {:ok, atom} -> explain(atom)
      :error -> generic(reason)
    end
  end

  defp generic(reason), do: "the review gate reached a terminal no-verdict state (#{reason})"

  # Never `String.to_atom/1` on a value that reached us from the API or the
  # database — an unknown string renders as itself rather than growing the atom
  # table. Answering `:error` (rather than handing the string back) is what
  # keeps the two `is_binary` clauses above from recursing into themselves.
  defp existing_atom(reason) do
    {:ok, String.to_existing_atom(reason)}
  rescue
    ArgumentError -> :error
  end

  @doc """
  Stamp the park on `task_id`, and report whether this call is the one that
  claimed the episode.

  The park row **is** the escalation claim (invariant I3: one escalation per
  episode, keyed by `{task_id, mr_ref, guard, episode}`). A task already parked
  for the same reason is the same episode, so it answers `:already_parked` and
  the caller stays quiet; a different reason, or a park the human cleared and
  the gate then re-reached, is a new episode and pages again. That keeps the
  claim in one atomic-ish place rather than in a counter the worker would lose
  on restart — the same reason `ReviewPatrol.claim_review_cap_escalation/1`
  claims in the row rather than in memory.

  Best-effort by design: this runs on the worker's terminal path, and a DB
  hiccup here must not turn a park back into a crash. Callers log and continue.
  """
  @spec park(String.t(), reason()) ::
          {:ok, :claimed | :already_parked, Issue.t()} | {:error, term()}
  def park(task_id, reason) when is_binary(task_id) and is_atom(reason) do
    stamped = Atom.to_string(reason)

    with {:ok, task} <- Ash.get(Issue, task_id) do
      if Map.get(task, :review_park_reason) == stamped do
        # Same episode: answer the claim WITHOUT re-running `:park_review`. The
        # action stamps `review_parked_at` unconditionally, and re-stamping it
        # would reset the wait clock `arb prime` sorts on (oldest first) — so a
        # gate that re-parks for the same reason would keep resetting itself to
        # the bottom of the list and the park most likely to have been forgotten
        # would never surface. Nothing else about the row changes here, so
        # there is nothing to write.
        {:ok, :already_parked, task}
      else
        case Ash.update(task, %{review_park_reason: stamped}, action: :park_review) do
          {:ok, parked} -> {:ok, :claimed, parked}
          {:error, _} = err -> err
        end
      end
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Clear the park on `task_id`. `by` names the human action that cleared it and
  is logged, so "who unparked this" is answerable from the journal.

  A task that is not parked is a no-op success: clearing is idempotent because
  both of its callers (a re-run review, a close) can legitimately fire twice.
  """
  @spec clear(String.t(), atom()) :: {:ok, Issue.t()} | {:error, term()}
  def clear(task_id, by \\ :unspecified) when is_binary(task_id) do
    with {:ok, task} <- Ash.get(Issue, task_id) do
      if parked?(task) do
        Logger.info("ReviewPark: clearing the park on #{task_id} (#{by})")
        Ash.update(task, %{}, action: :clear_review_park)
      else
        {:ok, task}
      end
    end
  rescue
    e -> {:error, e}
  end

  @doc "True when `task` carries a ReviewGate park."
  @spec parked?(Issue.t() | map()) :: boolean()
  def parked?(task) do
    case Map.get(task, :review_park_reason) do
      r when is_binary(r) and r != "" -> true
      _ -> false
    end
  end
end
