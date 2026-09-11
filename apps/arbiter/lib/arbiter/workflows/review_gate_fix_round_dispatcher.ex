defmodule Arbiter.Workflows.ReviewGateFixRoundDispatcher do
  @moduledoc """
  Auto-dispatch an implementer **fix round** after the ReviewGate returns a
  `request_changes` verdict (bd-a9zb7w, #1544).

  ## The gap this closes

  `Arbiter.Worker.park_rejected/3` records the run `:failed` with
  `failure_reason: :review_gate_rejected`, escalates the findings, and stops.
  Nothing then dispatched the implementer: the task sat `:in_progress` with no
  live worker until a human ran `worker_resume`. Seven occurrences over
  2026-09-09/10 (vs-ciouz8, vs-382bg7, vs-bg7rue, vs-8q9xu8 ×2, vs-2d0xxa,
  vs-7fv3n4) were every one of them cleared by a plain manual `worker_resume`
  that took immediately — nothing was structurally blocking the implementer, it
  simply was never scheduled. vs-ciouz8 sat overnight and blocked a whole epic
  chain behind it.

  This is the mirror of bd-di4t6d / #1537, which re-dispatches the *reviewer*
  out of `:awaiting_review`. Here the reviewer already ran and produced a
  verdict; the missing actor is the implementer and the terminal state is
  `:review_gate_rejected`, a different branch entirely.

  ## Rejected-and-fixable vs. rejected-and-converged

  Not every rejection deserves another implementer. The worker
  (`Arbiter.Worker.maybe_dispatch_fix_round/3`) applies three gates before
  calling `dispatch/1`, and escalates through `escalate_exhausted/4` instead of
  dispatching when any of them says stop:

    * **verdict** — only `:request_changes` gets a fix round. A `:no_verdict`
      rejection (`:review_gate_inconclusive`) means the reviewer produced
      nothing actionable; handing an implementer an empty finding set is not a
      fix round, it is a coin flip. Those still escalate as they always did.
    * **budget** — `meta[:review_gate_fix_round_attempts]` counts fix rounds
      that already ran for this task, re-stamped on each resumed worker by
      `Arbiter.Worker.Dispatch` (the same mechanism bd-8eheb6 uses for
      `:awaiting_review_resume_attempts`; a fresh worker per round means the
      counter has to ride the meta or the cap would never bind). The cap is
      `config["review_gate"]["max_fix_rounds"]`, default 1 (see
      `default_max_fix_rounds/0`); `0` restores the pre-bd-a9zb7w behaviour
      exactly.
    * **convergence** — if this rejection's findings are byte-identical to the
      set the previous fix round was dispatched against
      (`meta[:review_gate_findings_digest]`), the round moved nothing. Another
      identical round would burn the budget to reach the same escalation later,
      so it escalates now as `:not_converging`.

  Bounding it this way is the whole point: an unbounded "rejected → re-dispatch"
  edge is a retry loop between the gate and the implementer, which is worse than
  the stall it replaces.

  ## Behaviour

  `ReviewGateFixRoundDispatcher` is a behaviour so the worker accepts a
  swappable implementation. The module is resolved per call from
  `Application.get_env(:arbiter, :review_gate_fix_round_dispatcher, __MODULE__)`,
  and the test environment points that at
  `Arbiter.Test.StubFixRoundDispatcher` so the suite never spawns a real agent.
  """

  alias Arbiter.Messages.Message
  alias Arbiter.Worker.Dispatch

  require Logger

  # This module both defines the behaviour and ships the default implementation,
  # so it implements itself. The `@impl true` annotations require this.
  @behaviour __MODULE__

  @default_max_fix_rounds 1

  @type dispatch_args :: %{
          required(:task_id) => String.t(),
          required(:attempt) => pos_integer(),
          required(:verdict) => atom(),
          required(:findings) => String.t(),
          required(:findings_digest) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:claude_command) => [String.t()]
        }

  @typedoc """
  Why no fix round was dispatched (or why the one we tried never ran):

    * `:budget_exhausted` — `max_fix_rounds` fix rounds have already run for
      this task and the gate still rejects. Another one is not obviously
      productive; this is where a human takes over.
    * `:not_converging` — the reviewer raised the *same* findings the last fix
      round was already dispatched against. The round changed nothing the
      reviewer cares about, so repeating it is a loop.
    * `{:dispatch_failed, reason}` — the fix round was in budget and warranted
      but could not start. Typically `:no_outpost` (the worktree was cleaned
      up, so there is nothing to re-attach to and a fresh dispatch is needed
      rather than a resume).
  """
  @type give_up_reason ::
          :budget_exhausted
          | :not_converging
          | {:dispatch_failed, term()}

  @doc """
  Re-attach a fresh implementer to the task's preserved worktree, briefed with
  the reviewer's findings — the programmatic equivalent of the `worker_resume`
  a coordinator has been running by hand.

  `args.attempt` is the 1-based number of *this* fix round; it is threaded into
  the new worker's `meta[:review_gate_fix_round_attempts]` so the next rejection
  on the same task can tell how much of the budget is left.
  `args.findings_digest` rides along the same way so the next rejection can tell
  whether this round moved anything.
  """
  @callback dispatch(args :: dispatch_args()) :: {:ok, map()} | {:error, term()}

  @doc """
  Page the coordinator that no fix round will be dispatched for this rejection.

  The real implementation posts an `:escalation` mailbox message; test stubs
  implement it to intercept escalations for assertion.
  """
  @callback escalate_exhausted(
              task_id :: String.t(),
              workspace_id :: String.t() | nil,
              attempts :: non_neg_integer(),
              reason :: give_up_reason()
            ) :: :ok | {:error, :no_workspace_id}

  @doc """
  The configured dispatcher module.

  Resolved per call rather than at compile time so the test environment (and an
  operator flipping it at runtime) can swap the implementation.
  """
  @spec impl() :: module()
  def impl,
    do: Application.get_env(:arbiter, :review_gate_fix_round_dispatcher, __MODULE__)

  @doc """
  The default fix-round budget when a workspace has no
  `config["review_gate"]["max_fix_rounds"]` override.

  One. The observed remedy in all seven bd-a9zb7w occurrences was a single
  `worker_resume`, and the resumed worker re-enters the ReviewGate — which runs
  its own `max_rounds` revise loop again — so "one fix round" is already several
  reviewer/implementer exchanges of headroom, not one prompt.
  """
  @spec default_max_fix_rounds() :: pos_integer()
  def default_max_fix_rounds, do: @default_max_fix_rounds

  @doc """
  A stable digest of a reviewer's findings text, used to detect a fix round that
  changed nothing the reviewer cares about.

  Whitespace-normalised so a reviewer rewrapping the same complaint doesn't read
  as progress, and truncated to a short hex prefix because it only ever needs to
  be compared for equality (and it rides the worker's meta).
  """
  @spec findings_digest(term()) :: String.t()
  def findings_digest(findings) do
    findings
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Default implementation of `dispatch/1`. Backs onto `Dispatch.resume/2`, which
  stops the lingering `:failed` worker, reuses the preserved worktree, links the
  new run to the prior one and hands the fresh agent the existing PR ref.
  """
  @impl true
  @spec dispatch(dispatch_args()) :: {:ok, map()} | {:error, term()}
  def dispatch(%{task_id: task_id, attempt: attempt} = args)
      when is_binary(task_id) and is_integer(attempt) and attempt > 0 do
    Logger.info(
      "ReviewGateFixRoundDispatcher: dispatching implementer fix round #{attempt} " <>
        "for task=#{task_id} after a ReviewGate #{inspect(Map.get(args, :verdict))} verdict"
    )

    opts =
      [
        revise_feedback: briefing(args),
        review_gate_fix_round_attempts: attempt,
        review_gate_findings_digest: Map.get(args, :findings_digest)
      ]
      |> maybe_put(:claude_command, Map.get(args, :claude_command))

    Dispatch.resume(task_id, opts)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp maybe_put(opts, _key, cmd) when cmd in [nil, []], do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Prepended to the resume briefing by `Dispatch.prepend_revise_feedback/2`, so
  # the fresh implementer reads the findings before the git-derived "work so
  # far" context — same shape the bd-95lsjb human-review revise pass uses.
  defp briefing(%{task_id: task_id} = args) do
    """
    ## ReviewGate requested changes — fix round #{args.attempt}

    The internal ReviewGate reviewed your work on task #{task_id} and did NOT
    approve it. Address every finding below on the SAME branch (do not open a new
    PR — the existing one, if any, updates in place), then finish as usual so the
    gate can re-review.

    If a finding is wrong, rebut it explicitly in your final output rather than
    silently ignoring it.

    ### Findings

    #{Map.get(args, :findings) |> to_string() |> String.trim()}

    """
  end

  @doc """
  Default implementation of `escalate_exhausted/4`.

  The subject deliberately names the fix round, not a generic resume: a
  coordinator reading `arb inbox` should be able to tell "the gate rejected and
  the fleet already tried to fix it" apart from "the gate rejected" without a
  `worker_show`.

  Best-effort: a DB hiccup is logged but never re-raised, so a failed page can
  never take down the worker teardown it runs alongside.
  """
  @impl true
  @spec escalate_exhausted(
          String.t(),
          String.t() | nil,
          non_neg_integer(),
          give_up_reason()
        ) :: :ok | {:error, :no_workspace_id}
  def escalate_exhausted(task_id, workspace_id, attempts, reason)
      when is_binary(task_id) and is_binary(workspace_id) and is_integer(attempts) do
    Message.send_mail(%{
      kind: :escalation,
      to_ref: Message.coordinator_ref(),
      from_ref: task_id,
      workspace_id: workspace_id,
      task_ref: task_id,
      subject: subject(task_id, attempts, reason),
      body: body(task_id, attempts, reason)
    })

    :ok
  rescue
    e ->
      Logger.warning(
        "ReviewGateFixRoundDispatcher.escalate_exhausted swallowed for task=#{task_id}: " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  # No (binary) workspace_id → the `:escalation` mailbox has no workspace to
  # address, so the page can't be delivered. Mirrors
  # `AutoResumeDispatcher.escalate_exhausted/5`: log loudly rather than swallow,
  # so a give-up that never reached a coordinator is still visible.
  def escalate_exhausted(task_id, _workspace_id, attempts, reason) do
    Logger.warning(
      "ReviewGateFixRoundDispatcher.escalate_exhausted: cannot page coordinator for " <>
        "task=#{inspect(task_id)} (#{attempts} fix round(s), #{inspect(reason)}) — " <>
        "workspace_id is nil; the escalation was not sent"
    )

    {:error, :no_workspace_id}
  end

  defp subject(task_id, attempts, :budget_exhausted),
    do: "#{task_id}: ReviewGate fix rounds exhausted after #{attempts} round(s)"

  defp subject(task_id, _attempts, :not_converging),
    do: "#{task_id}: ReviewGate fix round is not converging (identical findings)"

  defp subject(task_id, attempts, {:dispatch_failed, _}),
    do: "#{task_id}: ReviewGate fix round FAILED to dispatch after #{attempts} round(s)"

  defp body(task_id, attempts, :budget_exhausted) do
    """
    Task #{task_id} was rejected by the ReviewGate (REQUEST_CHANGES) and the
    automatic implementer fix round is out of budget after #{attempts} round(s).

    #{lede(attempts)}

    Next step is human judgement, not another `worker_resume`: read the findings
    (`review_gate_rounds_list #{task_id}`) and decide whether the work needs a
    different approach, the acceptance criteria need revising, or the reviewer is
    wrong. Raise the workspace's `review_gate.max_fix_rounds` if this task class
    legitimately needs more exchanges.
    """
  end

  defp body(task_id, attempts, :not_converging) do
    """
    Task #{task_id} was rejected by the ReviewGate with the SAME findings the last
    automatic fix round was already dispatched against, so that round changed
    nothing the reviewer cares about.

    #{attempts} fix round(s) have run. Dispatching another identical one would
    burn the remaining budget to arrive at this same escalation later, so it was
    stopped here instead.

    Look at whether the implementer is failing to understand the finding, or the
    finding is unactionable as written: `review_gate_rounds_list #{task_id}` shows
    both sides of the exchange.
    """
  end

  defp body(task_id, attempts, {:dispatch_failed, reason}) do
    """
    Task #{task_id} was rejected by the ReviewGate (REQUEST_CHANGES) and the
    automatic implementer fix round could not start: #{inspect(reason)}.

    The fix round was still within budget (#{attempts} round(s) used), so this is
    not a review that refuses to converge — the dispatch itself could not run. The
    usual cause is `:no_outpost`: the task's worktree was cleaned up, so there is
    nothing to re-attach to and a fresh dispatch is needed rather than a resume.

    #{attempts_note(attempts)}
    """
  end

  # Mirrors bd-di4t6d's note: "0 rounds" reads like the fleet declined to try.
  # It did try — the counter records fix rounds that previously *ran*, so a
  # first rejection is legitimately 0.
  defp attempts_note(0) do
    """
    ("0 round(s)" is not a decline: a fix round WAS dispatched and it errored. The
    counter records fix rounds that previously ran to completion, and this was the
    first rejection for this task.)
    """
  end

  defp attempts_note(_attempts), do: ""

  defp lede(0) do
    """
    No fix round ran: this workspace's `review_gate.max_fix_rounds` is 0, so the
    rejection was escalated straight away, exactly as it was before bd-a9zb7w.
    """
  end

  defp lede(attempts) do
    """
    This is NOT a fresh rejection: the fleet already re-attached an implementer to
    the preserved worktree #{attempts} time(s) (the `worker_resume` equivalent) and
    the gate rejected the result again.
    """
  end
end
