defmodule Arbiter.Reviews.GateActivity do
  @moduledoc """
  Is a fleet-authored PR's task currently inside the `Arbiter.Worker.ReviewGate`?

  bd-bq8c8a / #1860. On 2026-09-17 two arbiter components wrote to one task
  branch inside thirty seconds. `Arbiter.Workflows.PRPatrol` saw two unresolved
  Copilot threads on PR #424 — a PR the fleet had authored and whose task was
  still parked at `:awaiting_review_gate` — filed a follow-up, and its fix
  worker committed and pushed `aed4457` to `origin/<branch>`. The gate's own
  round-1 implementer committed `19665a3` on the worktree twenty seconds later,
  its push was rejected `:diverged`, and the task parked `head_not_pushed`.
  Neither component knew the other was on the branch.

  The operator cannot configure this away: `pr_patrol.author_logins` is scoped
  to the fleet identity *precisely so* patrol answers review threads on fleet
  PRs. So the patrol has to ask the question instead, and this module is the
  question: while the gate holds a branch, the gate is the authority on the
  diff, and nothing else may commit to it.

  ## What counts as "inside the gate"

  Three signals, any one of which gates the PR:

    * `:awaiting_review_gate` — the authoring worker is parked waiting on the
      gate. This is the whole gate lifetime, from the moment the author hands
      off until a verdict lands, and it is the signal that would have caught
      the reported incident.
    * `:round_running` — a reviewer or implementer worker is registered for the
      task (`meta.reviews` / `meta.revises`). Redundant with the above in the
      normal case, but it still fires if the author's registration is missing —
      an ad-hoc gate, a re-run gate, a restarted author.
    * `:review_parked` — the gate gave up and stamped
      `Arbiter.Tasks.ReviewPark`. The branch is mid-incident and a human owns
      it; a patrol commit landing on top is exactly what made the reported
      recovery manual.

  ## Cost

  One `Issue` read plus in-memory registry lookups. No forge call — callers
  run this as a cheap pre-gate *before* spending a forge request (see
  `PRPatrol.dispatch_candidate?/2`).
  """

  require Ash.Query
  require Logger

  alias Arbiter.Tasks.{Issue, ReviewPark}
  alias Arbiter.Worker
  alias Arbiter.Workflows.PatrolRepoScope

  @typedoc "Why the PR's branch is spoken for. See the moduledoc."
  @type reason :: :awaiting_review_gate | :round_running | :review_parked

  @type t :: :clear | {:gated, reason(), Issue.t()}

  # The trailing PR/MR number in a merge ref: `owner/repo#424`, `github:owner/repo#424`,
  # `#424`, or GitLab's `!424`.
  @number ~r/[#!](\d+)$/

  @doc """
  Whether PR `pr_number` in `repo` belongs to a task the ReviewGate is holding.

  Returns `{:gated, reason, task}` when it does, `:clear` otherwise — including
  when no task in the workspace authored that PR at all (an outside
  contributor's PR is nobody's branch to protect).

  Never raises: any read failure resolves to `:clear`, which is the fail-open
  direction. This guard exists to stop a *collision*, and a DB hiccup must not
  silently freeze every follow-up the patrol would otherwise file.
  """
  @spec engaged(String.t(), term(), String.t()) :: t()
  def engaged(workspace_id, pr_number, repo)
      when is_binary(workspace_id) and is_binary(repo) do
    with {:ok, number} <- normalize_number(pr_number),
         %Issue{} = task <- authoring_task(workspace_id, number, repo) do
      classify(task)
    else
      _ -> :clear
    end
  rescue
    error ->
      Logger.warning("GateActivity: could not resolve gate activity: #{inspect(error)}")
      :clear
  end

  def engaged(_workspace_id, _pr_number, _repo), do: :clear

  @doc "Boolean form of `engaged/3`."
  @spec engaged?(String.t(), term(), String.t()) :: boolean()
  def engaged?(workspace_id, pr_number, repo) do
    match?({:gated, _, _}, engaged(workspace_id, pr_number, repo))
  end

  @doc """
  One sentence naming the hold, for a log line or a task note.
  """
  @spec describe({:gated, reason(), Issue.t()}) :: String.t()
  def describe({:gated, :awaiting_review_gate, %Issue{id: id}}),
    do: "task #{id} is parked at :awaiting_review_gate — the ReviewGate owns the branch"

  def describe({:gated, :round_running, %Issue{id: id}}),
    do: "a ReviewGate round is running for task #{id} — the gate owns the branch"

  def describe({:gated, :review_parked, %Issue{id: id} = task}),
    do:
      "task #{id} is review-parked (#{task.review_park_reason}) — a human owns the branch " <>
        "until the park clears"

  # ---- internals -----------------------------------------------------------

  defp classify(%Issue{} = task) do
    cond do
      ReviewPark.parked?(task) -> {:gated, :review_parked, task}
      author_awaiting_gate?(task.id) -> {:gated, :awaiting_review_gate, task}
      round_running?(task.id) -> {:gated, :round_running, task}
      true -> :clear
    end
  end

  defp author_awaiting_gate?(task_id) do
    match?(%{status: :awaiting_review_gate}, Worker.state(task_id))
  catch
    :exit, _ -> false
  end

  # A reviewer/implementer pass registers its own synthetic worker whose meta
  # points back at the author (the same `:reviews` / `:revises` link the board
  # folds gate cards onto their author's card with).
  defp round_running?(task_id) do
    Enum.any?(Worker.list_children(), fn worker ->
      meta = Map.get(worker, :meta) || %{}
      Map.get(meta, :reviews) == task_id or Map.get(meta, :revises) == task_id
    end)
  end

  # The open task in this workspace whose OWN PR is `number` in `repo`. `pr_ref`
  # is what the merger stamps when it opens a task's PR; a review engagement
  # carries `source_pr` instead and so is never selected here.
  defp authoring_task(workspace_id, number, repo) do
    Issue
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and not is_nil(pr_ref) and status != :closed
    )
    |> Ash.read!()
    |> Enum.find(fn %Issue{pr_ref: ref} ->
      PatrolRepoScope.ref_matches_repo?(ref, repo) and number_of_ref(ref) == number
    end)
  end

  defp number_of_ref(ref) when is_binary(ref) do
    case Regex.run(@number, String.trim(ref)) do
      [_, digits] -> digits
      _ -> nil
    end
  end

  defp number_of_ref(_ref), do: nil

  defp normalize_number(n) when is_integer(n), do: {:ok, Integer.to_string(n)}

  defp normalize_number(n) when is_binary(n) do
    case String.trim(n) do
      "" -> :error
      trimmed -> {:ok, String.replace_leading(trimmed, "#", "")}
    end
  end

  defp normalize_number(_n), do: :error
end
