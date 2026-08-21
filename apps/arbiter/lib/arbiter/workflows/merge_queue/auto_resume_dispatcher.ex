defmodule Arbiter.Workflows.MergeQueue.AutoResumeDispatcher do
  @moduledoc """
  Auto-resume a worker that timed out waiting for its MR to be reviewed
  (bd-8eheb6, #1287).

  `{:awaiting_review_timeout, N}` is not a failure in the usual sense. The
  worker did its work, opened its MR and exited 0; the Watchdog then burned its
  poll budget without the forge producing a terminal outcome and registered that
  timeout as the run's `failure_reason`. The MR is frequently mergeable and
  conflict-free the whole time — the run is *cleanly resumable*, which is why a
  coordinator's remedy has always been a plain `worker_resume`.

  Before this module the Watchdog just left such a worker parked in `:failed`
  and waited for a human to notice (only a `worker_failed` event or the
  dashboard's active-worker count surfaced it). Now it calls `resume/1` here
  instead, so the common case self-heals.

  ## Bounded, not infinite

  Auto-resume is capped (`Watchdog`'s `:max_auto_resumes`, default 3) via a
  per-task attempt counter carried on the worker's `meta`
  (`:awaiting_review_resume_attempts`) and re-stamped on each resumed run by
  `Arbiter.Worker.Dispatch`. A review that never converges — e.g. the ReviewGate
  INCONCLUSIVE-no-verdict flake — therefore burns a bounded budget and then
  pages the coordinator through `escalate_exhausted/5` rather than looping
  silently forever. That escalation says "auto-resume exhausted after N
  attempts", which is deliberately distinct from a first-time genuine failure:
  the coordinator should not have to re-derive that context via `worker_show`.

  ## Behaviour

  `AutoResumeDispatcher` is a behaviour so the Watchdog accepts a swappable
  implementation (defaults to this module). Tests inject a stub
  (`Arbiter.Test.StubAutoResumeDispatcher`) so they don't boot a real Claude
  session or shell out to git.
  """

  alias Arbiter.Messages.Message
  alias Arbiter.Worker.Dispatch

  require Logger

  # This module both defines the behaviour and ships the default implementation,
  # so it implements itself. The `@impl true` annotations require this.
  @behaviour __MODULE__

  @type resume_args :: %{
          required(:task_id) => String.t(),
          required(:attempt) => pos_integer(),
          optional(:workspace_id) => String.t() | nil,
          optional(:mr_ref) => String.t() | nil,
          optional(:claude_command) => [String.t()]
        }

  @doc """
  Re-attach a fresh worker to the task's preserved worktree — the programmatic
  equivalent of `worker_resume` / `arb resume`.

  `args.attempt` is the 1-based number of *this* auto-resume; it is threaded
  into the new worker's `meta[:awaiting_review_resume_attempts]` so the next
  Watchdog episode on the same task can tell how much of the budget is left.

  Returns `Arbiter.Worker.Dispatch.resume/2`'s `{:ok, dispatch_result()}` /
  `{:error, reason}`. A `{:error, _}` (e.g. `:no_outpost` — the worktree was
  cleaned up, so there is nothing to resume) means the Watchdog must fall back
  to escalating rather than assume the task is healing.

  `args.claude_command` is the same test escape hatch the sibling dispatchers
  carry (`ConflictResolver`, `FixPassDispatcher`, `ReviseDispatcher`): an argv
  override so an integration test can drive this real resume against a real
  worktree without spawning a real agent subprocess. Never set in production —
  the Watchdog does not thread it.
  """
  @callback resume(args :: resume_args()) :: {:ok, map()} | {:error, term()}

  @typedoc """
  Why the Watchdog gave up self-healing this task:

    * `:budget_exhausted` — the auto-resume budget is spent (or configured to
      `0`). The headline case.
    * `{:resume_failed, reason}` — an auto-resume was still in budget but could
      not run at all (typically `:no_outpost`: the worktree was cleaned up).
      Distinct because "we tried N times and it didn't stick" and "we could not
      try" call for different coordinator actions.
  """
  @type give_up_reason :: :budget_exhausted | {:resume_failed, term()}

  @doc """
  Page the coordinator that the Watchdog has stopped auto-resuming this task.

  The real implementation posts an `:escalation` mailbox message; test stubs
  implement it to intercept escalations for assertion.
  """
  @callback escalate_exhausted(
              task_id :: String.t(),
              workspace_id :: String.t() | nil,
              mr_ref :: String.t() | nil,
              attempts :: non_neg_integer(),
              reason :: give_up_reason()
            ) :: :ok | {:error, :no_workspace_id}

  @doc """
  Default implementation of `resume/1`. Backs onto `Dispatch.resume/2`, which
  stops the lingering `:failed` worker, reuses the preserved worktree, links the
  new run to the prior one and hands the fresh agent the existing PR ref.
  """
  @impl true
  @spec resume(resume_args()) :: {:ok, map()} | {:error, term()}
  def resume(%{task_id: task_id, attempt: attempt} = args)
      when is_binary(task_id) and is_integer(attempt) and attempt > 0 do
    Logger.info(
      "AutoResumeDispatcher: auto-resuming task=#{task_id} after an " <>
        "awaiting_review timeout (attempt #{attempt})"
    )

    opts =
      case Map.get(args, :claude_command) do
        cmd when is_list(cmd) and cmd != [] -> [claude_command: cmd]
        _ -> []
      end

    Dispatch.resume(task_id, Keyword.put(opts, :awaiting_review_resume_attempts, attempt))
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Default implementation of `escalate_exhausted/5`.

  The `:budget_exhausted` wording — "auto-resume exhausted after N attempts" —
  is deliberate: a coordinator reading `arb inbox` can tell this apart from a
  fresh, first-time failure without a `worker_show`. The fleet already tried the
  obvious remedy N times and it did not stick, so the next step is human
  judgement (is the review actually stuck? is the gate flaking?) rather than
  another `worker_resume`.

  Best-effort: a DB hiccup is logged but never re-raised so the Watchdog's
  shutdown isn't disrupted.
  """
  @impl true
  @spec escalate_exhausted(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          non_neg_integer(),
          give_up_reason()
        ) :: :ok | {:error, :no_workspace_id}
  def escalate_exhausted(task_id, workspace_id, mr_ref, attempts, reason)
      when is_binary(task_id) and is_binary(workspace_id) and is_integer(attempts) do
    Message.send_mail(%{
      kind: :escalation,
      to_ref: Message.coordinator_ref(),
      from_ref: task_id,
      workspace_id: workspace_id,
      task_ref: task_id,
      subject: subject(task_id, attempts, reason),
      body: body(task_id, mr_ref, attempts, reason)
    })

    :ok
  rescue
    e ->
      Logger.warning(
        "AutoResumeDispatcher.escalate_exhausted swallowed for task=#{task_id}: " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  # No (binary) workspace_id → the `:escalation` mailbox has no workspace to
  # address, so the page can't be delivered. Mirrors
  # `ConflictResolver.escalate_unresolved/4`: log loudly rather than swallow, so
  # a give-up that never reached a coordinator is still visible.
  def escalate_exhausted(task_id, _workspace_id, _mr_ref, attempts, reason) do
    Logger.warning(
      "AutoResumeDispatcher.escalate_exhausted: cannot page coordinator for " <>
        "task=#{inspect(task_id)} (#{attempts} attempts, #{inspect(reason)}) — " <>
        "workspace_id is nil; the escalation was not sent"
    )

    {:error, :no_workspace_id}
  end

  defp subject(task_id, attempts, :budget_exhausted),
    do: "#{task_id}: auto-resume exhausted after #{attempts} attempts (awaiting_review)"

  defp subject(task_id, attempts, {:resume_failed, _}),
    do: "#{task_id}: auto-resume FAILED after #{attempts} attempts (awaiting_review)"

  defp body(task_id, mr_ref, attempts, :budget_exhausted) do
    """
    Task #{task_id} timed out at :awaiting_review on MR #{mr_ref || "(unknown)"} and
    auto-resume is exhausted after #{attempts} attempt(s).

    #{lede(attempts)}

    #{diagnosis(task_id)}
    """
  end

  defp body(task_id, mr_ref, attempts, {:resume_failed, reason}) do
    """
    Task #{task_id} timed out at :awaiting_review on MR #{mr_ref || "(unknown)"} and
    the Watchdog could not auto-resume it: #{inspect(reason)}.

    Auto-resume was still within budget (#{attempts} attempt(s) used), so this is not
    a review that refuses to converge — the resume itself could not run. The usual
    cause is `:no_outpost`: the task's worktree was cleaned up, so there is nothing
    to re-attach to and a fresh dispatch is needed rather than a resume.

    #{diagnosis(task_id)}
    """
  end

  defp lede(0) do
    """
    Auto-resume did not run: this workspace's awaiting-review auto-resume budget is 0
    (`merge.max_awaiting_review_resumes`), so the timeout was escalated straight away,
    exactly as it was before bd-8eheb6.
    """
  end

  defp lede(attempts) do
    """
    This is NOT a fresh failure: the Watchdog already re-attached a worker to the
    preserved worktree #{attempts} time(s) (the `worker_resume` equivalent) and the MR
    still never reached a terminal outcome. Another plain resume is unlikely to help.
    """
  end

  defp diagnosis(task_id) do
    """
    Likely causes: a review that never converges (e.g. a ReviewGate
    INCONCLUSIVE-with-no-verdict loop), a required check that never reports, or a
    reviewer/approval that is simply not coming. Inspect the MR and the run with
    `worker_show #{task_id}` before resuming again.
    """
  end
end
