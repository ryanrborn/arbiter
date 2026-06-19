defmodule Arbiter.Worker.ReviewGate do
  @moduledoc """
  The review gate ("ReviewGate") that sits between an worker's `arb done` and the
  merger. A standing order: an worker must not merge its own work — a separate
  reviewer mind code-reviews the diff first.

  ## Where it fits

  When an worker signals done (`arb done`), the author `Arbiter.Worker` checks
  whether its workspace requires review (`Workspace.review_required?/1`). If so it
  parks at `:awaiting_review_gate` and spawns a ReviewGate **instead of** calling the
  merger. The ReviewGate then runs the review — and, on a request-changes verdict,
  the **revise-and-rediscuss loop** — and reports a single, terminal verdict back
  to the author (`Arbiter.Worker.review_gate_verdict/2`):

    * APPROVE → the author proceeds to the merger (`do_open_mr`).
    * REQUEST_CHANGES (after the loop is exhausted) / inconclusive / timed-out →
      the author parks the bead with the findings and escalates to the Admiral;
      the branch is **not** merged.

  ## The reviewer

  Each review pass spawns a **distinct** reviewer worker — a second
  `Arbiter.Worker` with a `#review`-suffixed bead id and its own
  `Arbiter.Worker.ClaudeSession`, running in the same worktree. A different
  process = a different Claude invocation = a different mind (no self-grading).
  It is handed the bead's acceptance criteria + description and asked to review
  the branch diff for correctness / regressions, **without booting the app** (the
  second-instance hazard, bd-9rouwh — the reviewer only reads the diff). Its
  stdout is captured (via the worker output PubSub topic); from it the ReviewGate
  parses a structured verdict — a sentinel line `VERDICT: APPROVE` or
  `VERDICT: REQUEST_CHANGES` plus findings.

  ## Stage 2 — the revise-and-rediscuss loop (bd-3jm700)

  Stage 1 ran a single review pass and escalated immediately on a non-approve
  verdict. Stage 2 turns a REQUEST_CHANGES into a bounded conversation:

    1. The reviewer's structured findings are posted to the implementer **via the
       mailbox** (`Arbiter.Messages`, kind `:flag`, reviewer id → author bead id)
       — a durable row, so the thread survives the workers that wrote it.
    2. A **fresh implementer** worker (a new mind, same branch/worktree)
       addresses each finding: fix it (and commit) or rebut it with
       justification. Its transcript is captured and posted back over the mailbox
       (author bead id → reviewer id).
    3. The reviewer re-reviews the updated diff (its prompt carries the prior
       thread so it can accept each rebuttal or hold the line).

  The loop is **hard-capped** at `config["review"]["rounds"]` rounds (default 2;
  one round = one reviewer pass). If it has not converged on APPROVE after the
  cap, the ReviewGate **escalates to Darth Gnosis** — reporting a REQUEST_CHANGES
  whose findings are the FULL implementer↔reviewer transcript (every message,
  both directions, all rounds, in order), the unresolved findings, and the
  current diff. He judges with the complete argument in hand, not a summary.

  The reviewer must be a DIFFERENT mind than the author at every round, and each
  implementer revision is a fresh mind too.

  ## Reviewer commit gate and HEAD-SHA anchoring (bd-1mksks)

  Before spawning the reviewer (both on first review and on each re-review after a
  revise round), the ReviewGate verifies that the branch has at least one commit
  ahead of the target branch. If it does not, the ReviewGate escalates immediately as
  `REQUEST_CHANGES` rather than spawning a reviewer that would see an empty diff and
  conclude "no work was done." This is a second layer of defence on top of the
  worker commit gate (bd-ofql8k): the worker gate fires for the initial
  implementer, but the revise-round implementer worker has no `worktree_path` in
  its meta and therefore bypasses the worker gate.

  The current HEAD SHA is captured at reviewer-spawn time and embedded in the
  review prompt so the reviewer can verify it is on the correct commit before
  diffing. After each revise round, the ReviewGate checks whether HEAD advanced (new
  commits → reviewer sees an updated diff) or stayed the same (implementer only
  rebutted → reviewer evaluates the rebuttal). The observation is recorded in the
  in-memory thread (and therefore in the escalation payload and the re-review
  prompt) but is NOT persisted to the durable mailbox — it is ReviewGate
  bookkeeping, not part of the implementer↔reviewer conversation.

  ## Stage 3 — same-mind continuity (bd-1na62i)

  Literal session resume (`claude --resume <id>`) was dropped: session ids are
  transient, are invalidated by a billing pause or crash, and have no
  Gemini/agy equivalent — it violates the provider-agnostic constraint. Stage 3
  instead **approximates** continuity the way the `arb resume` path does
  (bd-auma3z): each revise-round implementer is briefed with the worktree's git
  state — commits since the branch cut plus uncommitted work-in-progress
  (`Arbiter.Worker.ResumeContext.work_so_far/2`) — prepended to its revise
  prompt. Combined with the reviewer findings and the original directive (both
  already in that prompt), the fresh mind continues the prior round's thread
  with full context rather than re-deriving it from a raw diff. The reviewer's
  own continuity is the prior implementer↔reviewer thread carried in
  `rereview_prompt/1`.

  ## Verdict protocol

  The reviewer emits, on its own line:

      VERDICT: APPROVE
      VERDICT: REQUEST_CHANGES

  Case-insensitive; surrounding whitespace tolerated. Everything from the verdict
  line onward is captured as the findings.

  ## Verdict re-prompt (bd-8v8ays)

  A reviewer that produces a substantive review but simply *forgets* the sentinel
  line is a common, costly failure: the work is good but `:no_verdict` escalates
  it as inconclusive, wasting the whole pass. Before giving up, the ReviewGate
  **re-prompts for a verdict** within the same round: on a `:no_verdict` result
  it spawns one more minimal follow-up pass (a fresh reviewer + session — there
  is no live Claude session resume yet — that re-supplies the diff context but
  demands the sentinel). Only if that pass *also* yields no parseable verdict
  does the ReviewGate report `:no_verdict` and let the author escalate as
  inconclusive. The number of re-prompts is capped (default 1) via the
  `:verdict_retries` opt and is a **per-round budget** — it resets at the start
  of each new revise round so that a reprompt used in round N does not prevent a
  reprompt in round N+1.

  A timed-out or unspawnable reviewer is a different failure (a hung/crashed
  mind, not a forgotten sentinel) and still escalates directly without a
  re-prompt.

  The same re-prompt path also covers a **content-free REQUEST_CHANGES**
  (bd-3y2mda): a verdict that requests changes but lists no concrete findings is
  useless — the implementer has nothing to act on — so it is treated as malformed
  and re-prompted (the follow-up names exactly what was missing) rather than
  entering the revise loop empty-handed. If the re-prompt still yields no findings
  it escalates as inconclusive; it is never silently merged.

  ## Clean worker context (bd-3y2mda)

  Reviewer (and revise-implementer) workers are spawned with an isolated
  `CLAUDE_CONFIG_DIR` (`Arbiter.Agents.Claude.ConfigDir`) so the host operator's
  personal `~/.claude/CLAUDE.md` — which may carry a roleplay persona — cannot
  bleed into the review and crowd out structured findings.

  ## Testing

  `start/1` accepts a `:command` argv (the reviewer) and a `:revise_command` argv
  (the implementer), forwarded to `ClaudeSession`, so tests can spawn echo
  scripts that print canned verdicts / revisions instead of invoking real Claude.
  `parse_verdict/1` is a pure function and is unit-tested directly.
  """

  use GenServer
  require Logger

  alias Arbiter.Agents
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.ResumeContext

  # Default ceiling on how long we wait for a reviewer / implementer pass before
  # escalating as timed out. Real Claude work can take a while; tests override.
  @default_timeout_ms 20 * 60 * 1000

  # How many times we re-prompt for a verdict when a reviewer finishes without
  # one before escalating as inconclusive. Capped; default 1. See bd-8v8ays.
  @default_verdict_retries 1

  # Default revise-and-rediscuss round cap when no difficulty is available and
  # no workspace override is set — matches D2 (moderate). See bd-3jm700.
  @default_rounds 3

  # Difficulty → default round cap. D0/D1 are straightforward; D3/D4 are
  # architecturally significant and may need more back-and-forth to converge.
  @rounds_by_difficulty %{0 => 2, 1 => 2, 2 => 3, 3 => 4, 4 => 4}

  # Defensive cap on the escalation diff so a huge branch can't bloat the
  # Admiral's mailbox row beyond reason.
  @diff_cap_bytes 50_000

  @verdict_approve ~r/^\s*VERDICT:\s*APPROVE\b/im
  @verdict_request_changes ~r/^\s*VERDICT:\s*(REQUEST_CHANGES|REJECT)\b/im

  @type verdict ::
          {:approve, String.t()} | {:request_changes, String.t()} | :no_verdict

  @type opt ::
          {:author, pid()}
          | {:bead_id, String.t()}
          | {:workspace_id, String.t() | nil}
          | {:repo, String.t()}
          | {:worktree_path, String.t() | nil}
          | {:branch, String.t()}
          | {:target_branch, String.t()}
          | {:command, [String.t()] | nil}
          | {:revise_command, [String.t()] | nil}
          | {:timeout_ms, non_neg_integer()}
          | {:verdict_retries, non_neg_integer()}
          | {:rounds, pos_integer()}

  @doc """
  Start a ReviewGate under `Arbiter.Worker.Supervisor`.

  Required opts: `:author` (the author worker pid to report back to),
  `:bead_id`, `:repo`, `:branch`. Optional: `:workspace_id`, `:worktree_path`,
  `:target_branch` (default `"main"`), `:command` (test override for the reviewer
  argv), `:revise_command` (test override for the implementer argv), `:rounds`
  (the revise-loop cap), `:timeout_ms`.
  """
  @spec start([opt()]) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(Arbiter.Worker.Supervisor, {__MODULE__, opts})
  end

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  The bead id used for the reviewer worker — the author bead id with a
  `#review` suffix so it registers as a distinct worker and records its own run
  row without colliding with the author.
  """
  @spec reviewer_bead_id(String.t()) :: String.t()
  def reviewer_bead_id(bead_id) when is_binary(bead_id), do: bead_id <> "#review"

  @doc """
  The default revise-and-rediscuss round cap for a bead's difficulty level.

  | Difficulty | Label    | Default rounds |
  |------------|----------|---------------|
  | 0          | trivial  | 2             |
  | 1          | simple   | 2             |
  | 2          | moderate | 3             |
  | 3          | hard     | 4             |
  | 4          | extreme  | 4             |
  | nil        | unknown  | 3 (D2)        |

  Used by `Arbiter.Worker.resolve_review_rounds/1` to derive the default cap
  from the bead's difficulty when no workspace `config["review_gate"]["max_rounds"]`
  override is set.
  """
  @spec rounds_for_difficulty(0..4 | nil) :: pos_integer()
  def rounds_for_difficulty(difficulty) do
    Map.get(@rounds_by_difficulty, difficulty, @default_rounds)
  end

  # ---- verdict parsing (pure) --------------------------------------------

  @doc """
  Parse a reviewer's output lines into a verdict.

  Returns `{:approve, findings}`, `{:request_changes, findings}`, or
  `:no_verdict` when no recognizable sentinel is present. `findings` is the
  transcript from the verdict line onward (trimmed), so the author can persist /
  escalate the reviewer's reasoning verbatim.
  """
  @spec parse_verdict([String.t()]) :: verdict()
  def parse_verdict(lines) when is_list(lines) do
    text = Enum.join(lines, "\n")

    cond do
      Regex.match?(@verdict_approve, text) ->
        {:approve, findings_from(text, @verdict_approve)}

      Regex.match?(@verdict_request_changes, text) ->
        {:request_changes, findings_from(text, @verdict_request_changes)}

      true ->
        :no_verdict
    end
  end

  # Findings = everything from the matched verdict line to the end, trimmed.
  # Falls back to the whole transcript if the index can't be located.
  defp findings_from(text, regex) do
    case Regex.run(regex, text, return: :index) do
      [{start, _len} | _] ->
        text |> binary_part(start, byte_size(text) - start) |> String.trim()

      _ ->
        String.trim(text)
    end
  end

  # ---- GenServer ----------------------------------------------------------

  @impl true
  def init(opts) do
    author = Keyword.fetch!(opts, :author)
    bead_id = Keyword.fetch!(opts, :bead_id)

    state = %{
      author: author,
      bead_id: bead_id,
      review_id: reviewer_bead_id(bead_id),
      workspace_id: Keyword.get(opts, :workspace_id),
      repo: Keyword.get(opts, :repo, "unknown"),
      worktree_path: Keyword.get(opts, :worktree_path),
      branch: Keyword.fetch!(opts, :branch),
      target_branch: Keyword.get(opts, :target_branch, "main"),
      command: Keyword.get(opts, :command),
      revise_command: Keyword.get(opts, :revise_command),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      retries_left: Keyword.get(opts, :verdict_retries, @default_verdict_retries),
      # Stored so finish_revise/1 can reset retries_left at the start of each
      # new round — the retry budget is per-round, not ReviewGate-lifetime.
      initial_retries: Keyword.get(opts, :verdict_retries, @default_verdict_retries),
      max_rounds: max(Keyword.get(opts, :rounds, @default_rounds), 1),
      # phase: :reviewing while a reviewer pass is in flight, :revising while an
      # implementer addresses findings between rounds.
      phase: :reviewing,
      round: 1,
      # The implementer<->reviewer thread, oldest-first. Each entry:
      # %{round:, role: :reviewer | :implementer | :system, subject:, body:}.
      # Mirrors the durable mailbox rows; the source for the escalation payload.
      thread: [],
      attempt: 0,
      # The id of the worker whose output/exit we are currently waiting on, so a
      # stale message from a prior (stopped) reviewer/implementer is ignored.
      current_id: nil,
      reviewer_pid: nil,
      lines: [],
      reported?: false,
      # The short HEAD SHA of the branch at the time the current reviewer was
      # spawned. Set by handle_continue(:spawn_reviewer) and updated by
      # finish_revise/1 after each revise round. Used to:
      #   1. prove which commit the reviewer saw (surfaces in the prompt and thread)
      #   2. detect whether the revise implementer actually committed new changes
      head_sha: nil
    }

    Process.monitor(author)
    {:ok, state, {:continue, :spawn_reviewer}}
  end

  @impl true
  def handle_continue(:spawn_reviewer, state) do
    # bd-1mksks: verify that commits exist on the branch BEFORE spawning the
    # reviewer. The worker commit gate (bd-ofql8k) already guards the initial
    # dispatch, but this check is a second layer of defence that also covers the
    # revise-loop case (the revise implementer's worker has no worktree_path in
    # meta, so its commit gate does not fire). If we spawned a reviewer over a
    # zero-commit branch it would see an empty diff and report "no work" — the
    # bug this bead fixes.
    case reviewer_commit_check(state) do
      {:error, reason} ->
        Logger.warning("ReviewGate: branch has no commits for bead=#{state.bead_id}: #{reason}")

        report(state, {:request_changes, reason})
        {:stop, :normal, %{state | reported?: true}}

      {:ok, head_sha} ->
        state = %{state | head_sha: head_sha}

        case launch_acolyte(
               state,
               state.review_id,
               :reviewer,
               review_prompt(state),
               state.command
             ) do
          {:ok, state} ->
            {:noreply, state}

          {:error, reason} ->
            Logger.warning(
              "ReviewGate: failed to spawn reviewer for bead=#{state.bead_id}: #{inspect(reason)}"
            )

            report(
              state,
              {:request_changes, "ReviewGate could not spawn a reviewer: #{inspect(reason)}"}
            )

            {:stop, :normal, %{state | reported?: true}}
        end
    end
  end

  # A ReviewGate is NOT a worker, but it lives under Arbiter.Worker.Supervisor —
  # so a stray enumeration (dashboard / list_children) could probe it with the
  # worker `:snapshot` call. Answer gracefully instead of crashing the gate and
  # stranding the author at :awaiting_review_gate. See bd-2y0gd5.
  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot(state), state}
  end

  # Capture output only from the worker we're currently waiting on; a late line
  # from a prior (stopped) reviewer/implementer must not contaminate this pass.
  @impl true
  def handle_info({:worker_output, id, line}, %{current_id: id} = state) do
    {:noreply, %{state | lines: [line | state.lines]}}
  end

  def handle_info({:worker_output, _other, _line}, state), do: {:noreply, state}

  # The current worker's subprocess exited — its transcript is complete. Dispatch
  # by phase: a finished reviewer yields a verdict (or a re-prompt / a revise); a
  # finished implementer closes the round and triggers the next reviewer pass.
  # (Each worker worker also self-completes on its own `arb done`; either way
  # the exit is our reliable "transcript done" signal.)
  def handle_info({:worker_exited, id, _status}, %{current_id: id, phase: :reviewing} = state) do
    case attempt_finish(state) do
      {:done, state} -> {:stop, :normal, state}
      {:reprompt, state} -> {:noreply, state}
      {:revise, state} -> {:noreply, state}
    end
  end

  def handle_info({:worker_exited, id, _status}, %{current_id: id, phase: :revising} = state) do
    case finish_revise(state) do
      {:done, state} -> {:stop, :normal, state}
      {:continue, state} -> {:noreply, state}
    end
  end

  # A stale exit from an worker we've moved on from.
  def handle_info({:worker_exited, _other, _status}, state), do: {:noreply, state}

  # Timeouts are tagged with the attempt that scheduled them so a stale timer
  # from a prior pass can't escalate a pass that has already advanced.
  def handle_info({:timeout, _attempt}, %{reported?: true} = state), do: {:noreply, state}

  def handle_info({:timeout, attempt}, %{attempt: attempt} = state) do
    Logger.warning(
      "ReviewGate: #{state.phase} pass timed out for bead=#{state.bead_id} (round #{state.round})"
    )

    msg =
      "ReviewGate #{state.phase} pass timed out after #{div(state.timeout_ms, 1000)}s " <>
        "with no verdict (round #{state.round})."

    payload = if state.thread == [], do: msg, else: msg <> "\n\n" <> escalation_payload(state)

    report(state, {:request_changes, payload})
    {:stop, :normal, %{state | reported?: true}}
  end

  def handle_info({:timeout, _stale}, state), do: {:noreply, state}

  # Author died before we could report — nothing to do.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{author: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Stop the current worker worker if it's still alive (e.g. on timeout).
    if is_pid(state.reviewer_pid) and Process.alive?(state.reviewer_pid) do
      safe(fn -> Worker.stop(state.reviewer_pid, :normal) end)
    end

    :ok
  end

  # ---- review pass outcome -----------------------------------------------

  # Parse the captured reviewer transcript. On APPROVE, report and stop. On
  # REQUEST_CHANGES, enter the revise loop (rounds remaining) or escalate with the
  # full transcript (exhausted). On a missing verdict, re-prompt (capped) before
  # escalating as inconclusive. Returns `{:done, state}` to stop, `{:reprompt,
  # state}` to wait on a verdict follow-up, or `{:revise, state}` to wait on an
  # implementer.
  defp attempt_finish(%{reported?: true} = state), do: {:done, state}

  defp attempt_finish(state) do
    case parse_verdict(Enum.reverse(state.lines)) do
      :no_verdict ->
        maybe_reprompt(state, :no_verdict)

      {:approve, _} = verdict ->
        {:done, finish(state, verdict)}

      {:request_changes, findings} ->
        # A REQUEST_CHANGES verdict that names no concrete findings is useless: the
        # implementer has nothing to act on, the gate stalls, and a full review is
        # wasted (bd-3y2mda). Treat it as malformed and re-prompt for findings
        # (capped, shares the verdict-retry budget) rather than entering the revise
        # loop with empty hands.
        if findings_present?(findings) do
          handle_reject(state, findings)
        else
          maybe_reprompt(state, :empty_findings)
        end
    end
  end

  # Whether a REQUEST_CHANGES verdict carries actionable findings. `findings`
  # spans from the `VERDICT:` line onward (see `findings_from/2`); strip that
  # sentinel line and any `arb done` marker / blank lines, and require something
  # substantive to remain. Deliberately conservative — this catches the truly
  # content-free case (verdict + nothing, or verdict + a bare flourish line) while
  # not second-guessing a terse-but-real finding; persona removal upstream is the
  # primary defense against flourishes.
  @min_findings_chars 16

  defp findings_present?(findings) when is_binary(findings) do
    body =
      findings
      |> String.split("\n")
      # Drop the matched `VERDICT:` line itself (always first in `findings`).
      |> Enum.drop(1)
      |> Enum.reject(fn line ->
        String.trim(line) == "" or Regex.match?(~r/\barb done\b/, line)
      end)
      |> Enum.join("\n")
      |> String.trim()

    String.length(body) >= @min_findings_chars
  end

  # Strip the `VERDICT: REQUEST_CHANGES` sentinel line (always the first line in
  # `findings`, per `findings_from/2`) and any `arb done` markers from the
  # reviewer's findings before embedding them in the implementer's revise prompt.
  # The raw findings (including sentinels) are preserved in the durable thread and
  # re-review prompt for the reviewer's continuity; the implementer only needs the
  # actionable content. Leaving `arb done` in the prompt risks the model treating
  # it as an instruction to stop rather than as reviewer output (bd-79goxj).
  defp clean_findings(findings) when is_binary(findings) do
    findings
    |> String.split("\n")
    # The first line is always `VERDICT: REQUEST_CHANGES` — drop it; the
    # implementer prompt already states the reviewer requested changes.
    |> Enum.drop(1)
    |> Enum.reject(fn line -> Regex.match?(~r/^\s*arb done\s*$/i, line) end)
    |> Enum.join("\n")
    |> String.trim()
  end

  # A REQUEST_CHANGES verdict with the round budget exhausted: record the final
  # findings into the thread, then escalate to Darth Gnosis with the FULL
  # transcript + unresolved findings + current diff.
  defp handle_reject(%{round: round, max_rounds: max} = state, findings) when round >= max do
    state = record_thread(state, :reviewer, round_subject(state, "REQUEST_CHANGES"), findings)

    Logger.info(
      "ReviewGate: bead=#{state.bead_id} not converged after #{max} round(s); escalating with transcript"
    )

    {:done, finish(state, {:request_changes, escalation_payload(state)})}
  end

  # Rounds remain: post the findings to the implementer and spawn a fresh
  # implementer mind to address them on the same branch.
  defp handle_reject(state, findings), do: enter_revise(state, findings)

  # Stage 2: post the reviewer's findings to the implementer over the mailbox,
  # then spawn a fresh implementer worker (same branch/worktree) to fix or rebut
  # each one. Returns `{:revise, state}` so the loop waits on the implementer, or
  # `{:done, state}` (escalated) if the implementer couldn't be spawned.
  defp enter_revise(state, findings) do
    state = record_thread(state, :reviewer, round_subject(state, "REQUEST_CHANGES"), findings)

    # The reviewer's subprocess has exited; stop its worker so it can't linger
    # (it may not have self-completed if it never printed `arb done`).
    stop_acolyte(state)

    impl_id = implementer_bead_id(state.review_id, state.round)

    case launch_acolyte(
           %{state | phase: :revising},
           impl_id,
           :implementer,
           revise_prompt(state, findings),
           state.revise_command
         ) do
      {:ok, state} ->
        Logger.info(
          "ReviewGate: bead=#{state.bead_id} round #{state.round} requested changes; revising"
        )

        {:revise, state}

      {:error, reason} ->
        state =
          record_thread(
            state,
            :system,
            "Round #{state.round} revise could not start",
            "The implementer worker could not be spawned: #{inspect(reason)}"
          )

        {:done, finish(state, {:request_changes, escalation_payload(state)})}
    end
  end

  # The implementer finished addressing the round's findings. Capture its
  # transcript, post it back to the reviewer over the mailbox, and open the next
  # reviewer round (its prompt carries the prior thread). Returns `{:continue,
  # state}` to keep looping or `{:done, state}` (escalated) if the next reviewer
  # couldn't be spawned.
  defp finish_revise(%{reported?: true} = state), do: {:done, state}

  defp finish_revise(state) do
    response =
      state.lines
      |> Enum.reverse()
      |> Enum.join("\n")
      |> String.trim()

    response = if response == "", do: "(implementer produced no output)", else: response

    state = record_thread(state, :implementer, "Round #{state.round} response", response)

    # bd-1mksks: detect whether the revise implementer committed new changes.
    # If HEAD is unchanged from when the reviewer last ran, the implementer's
    # round was a rebuttal only (no code change). Record this in the thread so
    # the re-reviewer knows it is evaluating a rebuttal, not new code. If HEAD
    # advanced, record the new commit so the re-reviewer can verify it too.
    {state, new_head_sha} = note_head_change(state)

    # The implementer's subprocess has exited; stop its worker so it can't linger.
    stop_acolyte(state)

    # Reset the per-round retry budget so a reprompt used in this round does not
    # prevent a reprompt in the next round (bug bd-79goxj).
    next = %{
      state
      | round: state.round + 1,
        phase: :reviewing,
        head_sha: new_head_sha,
        retries_left: state.initial_retries
    }

    review_id = reviewer_round_id(next.review_id, next.round)

    case launch_acolyte(next, review_id, :reviewer, rereview_prompt(next), next.command) do
      {:ok, state} ->
        {:continue, state}

      {:error, reason} ->
        next =
          record_thread(
            next,
            :system,
            "Round #{next.round} re-review could not start",
            "The reviewer worker could not be spawned: #{inspect(reason)}"
          )

        {:done, finish(next, {:request_changes, escalation_payload(next)})}
    end
  end

  # bd-1mksks: compare HEAD SHA before and after a revise round to detect whether
  # the implementer committed new changes. Appends a system entry to the in-memory
  # thread (for the escalation payload / re-review prompt context) but does NOT
  # persist it to the durable mailbox — HEAD-change notes are internal ReviewGate
  # bookkeeping, not part of the implementer↔reviewer conversation. Returns
  # {updated_state, new_head_sha}.
  defp note_head_change(state) do
    new_sha = current_head_sha(state)
    old_sha = state.head_sha

    cond do
      is_nil(new_sha) or is_nil(old_sha) ->
        # No worktree or git unavailable — pass through without a note.
        {state, new_sha}

      new_sha == old_sha ->
        entry = %{
          round: state.round,
          role: :system,
          subject:
            "Round #{state.round} — HEAD unchanged after revise (rebuttal only, no new commits)",
          body:
            "HEAD remained at #{new_sha} after the revise round. " <>
              "The implementer's response was a rebuttal, not a code change. " <>
              "The re-reviewer evaluates the rebuttal argument; the diff is the same as the previous round."
        }

        {%{state | thread: state.thread ++ [entry]}, new_sha}

      true ->
        entry = %{
          round: state.round,
          role: :system,
          subject: "Round #{state.round} — implementer committed new changes",
          body:
            "HEAD advanced from #{old_sha} to #{new_sha} during the revise round. " <>
              "The re-reviewer sees the updated diff."
        }

        {%{state | thread: state.thread ++ [entry]}, new_sha}
    end
  end

  # ---- verdict re-prompt (bd-8v8ays) -------------------------------------

  # A reviewer pass produced a malformed result: either no parseable VERDICT line
  # (`:no_verdict`) or a REQUEST_CHANGES with no actionable findings
  # (`:empty_findings`). If we have a re-prompt budget left, spawn one more minimal
  # follow-up pass (a fresh reviewer mind — there is no Claude session resume yet —
  # that re-reads the diff but is told exactly what it got wrong). Otherwise
  # escalate as inconclusive. This stays in the current round: a malformed verdict
  # is not a revision.
  defp maybe_reprompt(%{retries_left: budget} = state, reason) when budget > 0 do
    stop_acolyte(state)

    retry_id = reprompt_bead_id(state.review_id, state.attempt)

    # A content-free REQUEST_CHANGES is a malformed verdict — the reviewer did
    # not produce a legitimate review result for this round. Extend the round cap
    # by 1 so the re-prompt's real findings can still reach the implementer: the
    # empty verdict must not rob the bead of a revision opportunity (bd-79goxj).
    # Only extend when the ReviewGate has a revise loop (max_rounds > 1): a
    # single-pass setup (max_rounds == 1) has no revise loop by design and the
    # extension would incorrectly trigger enter_revise for that configuration.
    max_ext = if reason == :empty_findings and state.max_rounds > 1, do: 1, else: 0

    case launch_acolyte(
           %{state | retries_left: budget - 1, max_rounds: state.max_rounds + max_ext},
           retry_id,
           :reviewer,
           verdict_reprompt_prompt(state, reason),
           state.command
         ) do
      {:ok, state} ->
        Logger.info(
          "ReviewGate: reviewer for bead=#{state.bead_id} returned #{reason}; re-prompting (attempt #{state.attempt})"
        )

        {:reprompt, state}

      {:error, spawn_error} ->
        Logger.warning(
          "ReviewGate: verdict re-prompt failed to spawn for bead=#{state.bead_id}: #{inspect(spawn_error)}"
        )

        {:done,
         finish(
           state,
           {:no_verdict, "Reviewer produced no usable verdict; re-prompt could not be spawned."}
         )}
    end
  end

  defp maybe_reprompt(state, :empty_findings) do
    {:done,
     finish(
       state,
       {:no_verdict,
        "Reviewer returned REQUEST_CHANGES with no concrete findings, even after a re-prompt."}
     )}
  end

  defp maybe_reprompt(state, _reason) do
    {:done,
     finish(
       state,
       {:no_verdict,
        "Reviewer produced no parseable VERDICT line, even after a verdict re-prompt."}
     )}
  end

  # ---- reporting ----------------------------------------------------------

  # Report the given verdict to the author exactly once and mark reported.
  defp finish(%{reported?: true} = state, _verdict), do: state

  defp finish(state, verdict) do
    report(state, verdict)
    %{state | reported?: true}
  end

  # Report the verdict to the author exactly once. An inconclusive review
  # (`:no_verdict`) is forwarded as such; the author's safe default for it is to
  # escalate without merging.
  defp report(state, verdict) do
    safe(fn -> Worker.report(state.author, :review_gate_rounds, state.round) end)
    safe(fn -> Worker.review_gate_verdict(state.author, normalize_verdict(verdict)) end)
    :ok
  end

  defp normalize_verdict({:approve, _} = v), do: v
  defp normalize_verdict({:request_changes, _} = v), do: v

  defp normalize_verdict(:no_verdict),
    do: {:no_verdict, "Reviewer produced no parseable VERDICT line."}

  defp normalize_verdict({:no_verdict, _findings} = v), do: v

  # ---- the persisted thread ----------------------------------------------

  # Append an entry to the in-memory thread AND persist it as a durable mailbox
  # row, so the implementer<->reviewer back-and-forth survives the workers that
  # wrote it and the escalation can present the full, ordered argument.
  defp record_thread(state, role, subject, body) do
    persist_message(state, role, subject, body)
    entry = %{round: state.round, role: role, subject: subject, body: body}
    %{state | thread: state.thread ++ [entry]}
  end

  # Persist one thread entry as an inter-agent `:flag` message scoped to the
  # bead's workspace. directive_ref = the author bead id, so `Messages.thread/2`
  # reconstructs the ordered conversation for the bead. Best-effort: a workspace-
  # less ReviewGate (ad-hoc run) or a DB hiccup never breaks the loop.
  defp persist_message(%{workspace_id: ws} = state, role, subject, body) when is_binary(ws) do
    {from_ref, to_ref} = thread_refs(state, role)

    safe(fn ->
      Arbiter.Messages.Message.send_mail(%{
        kind: :flag,
        from_ref: from_ref,
        to_ref: to_ref,
        workspace_id: ws,
        directive_ref: state.bead_id,
        subject: cap(subject, 500),
        body: body
      })
    end)

    :ok
  end

  defp persist_message(_state, _role, _subject, _body), do: :ok

  # reviewer findings travel review_id -> bead (the implementer); the
  # implementer's response travels bead -> review_id; system notes are attributed
  # to the ReviewGate (review_id) and addressed at the bead.
  defp thread_refs(state, :reviewer), do: {state.review_id, state.bead_id}
  defp thread_refs(state, :implementer), do: {state.bead_id, state.review_id}
  defp thread_refs(state, :system), do: {state.review_id, state.bead_id}

  # Compose the escalation payload Darth Gnosis judges with: the FULL ordered
  # transcript, plus the current diff of the branch under review.
  defp escalation_payload(state) do
    """
    ReviewGate escalation — not converged after #{state.round} round(s) of review
    (cap #{state.max_rounds}). The implementer and reviewer did not reach
    agreement; the full argument follows for your judgement.

    ## Full implementer↔reviewer transcript

    #{render_thread(state.thread)}

    ## Current diff (#{state.branch} vs #{state.target_branch})

    ```
    #{current_diff(state)}
    ```

    ## Worktree status (uncommitted changes, if any)

    ```
    #{worktree_status(state)}
    ```
    """
    |> String.trim()
  end

  defp render_thread([]), do: "(no messages were exchanged)"

  defp render_thread(thread) do
    thread
    |> Enum.map(fn %{round: round, role: role, subject: subject, body: body} ->
      "### Round #{round} — #{role_label(role)}: #{subject}\n\n#{String.trim(body)}"
    end)
    |> Enum.join("\n\n---\n\n")
  end

  defp role_label(:reviewer), do: "Reviewer → Implementer"
  defp role_label(:implementer), do: "Implementer → Reviewer"
  defp role_label(:system), do: "ReviewGate"

  # The current diff of the branch under review, capped. Best-effort: the
  # escalation is still useful without it.
  defp current_diff(%{worktree_path: wt, target_branch: tb}) when is_binary(wt) do
    case System.cmd("git", ["-C", wt, "diff", "#{tb}...HEAD"], stderr_to_stdout: true) do
      {out, 0} -> cap(out, @diff_cap_bytes)
      {out, _} -> "(could not compute diff)\n" <> cap(out, 2_000)
    end
  rescue
    _ -> "(diff unavailable)"
  catch
    :exit, _ -> "(diff unavailable)"
  end

  defp current_diff(_state), do: "(diff unavailable — no worktree)"

  # bd-ofql8k defense-in-depth: an empty `base..HEAD` diff is NOT the same as
  # "no work" — the worker may have edited files and forgotten to commit. Pair
  # the diff with `git status --porcelain` so the escalation payload makes the
  # uncommitted state visible and the recipient (the reviewer prompt, Darth
  # Gnosis, the operator) can recognize it as "work present but uncommitted"
  # rather than the misdiagnosis the Worker's commit gate already guards
  # against. The gate is the primary defense; this is the backstop.
  defp worktree_status(%{worktree_path: wt}) when is_binary(wt) do
    case System.cmd("git", ["-C", wt, "status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> "(clean — no uncommitted changes)"
      {out, 0} -> cap(out, 4_000)
      {out, _} -> "(could not run git status)\n" <> cap(out, 2_000)
    end
  rescue
    _ -> "(status unavailable)"
  catch
    :exit, _ -> "(status unavailable)"
  end

  defp worktree_status(_state), do: "(status unavailable — no worktree)"

  # ---- pre-spawn commit check (bd-1mksks) ---------------------------------

  # Verify that the branch under review has commits ahead of target_branch
  # before spawning the reviewer. Returns {:ok, head_sha_or_nil} when safe
  # to proceed, {:error, human_message} when the reviewer would see an empty
  # diff.
  #
  # This is a second layer of defence on top of the worker commit gate
  # (bd-ofql8k). It covers two cases the worker gate misses:
  #   (B) the revise-round implementer worker has no worktree_path in meta,
  #       so the worker commit gate does not fire for revise rounds; and
  #   (C) the ReviewGate is started in an ad-hoc configuration without going
  #       through the normal worker dispatch path.
  #
  # When worktree_path is nil or git fails, the check is skipped (fail-open):
  # a transient git hiccup must not strand a legitimate review.
  defp reviewer_commit_check(%{worktree_path: wt, branch: branch, target_branch: target})
       when is_binary(wt) do
    # Mirror the worker commit gate's branch guard (bd-ofql8k): only check
    # for commits when the worktree is actually checked out on the per-bead
    # branch. Some test setups and ad-hoc runs reuse the repo as the
    # "worktree" with HEAD on `main`; in that case `rev-list main..HEAD` is
    # meaningless (always 0) and the check would manufacture a false positive.
    # Production worktrees provisioned via Worktree.create/3 are always on the
    # per-bead branch, so the gate fires correctly in production.
    case Arbiter.Worker.Worktree.current_branch(wt) do
      {:ok, ^branch} ->
        # Worktree IS on the expected branch — verify commits exist.
        # has_commits_ahead?/2 is fail-open: git errors resolve to {:ok, true},
        # so {:ok, false} is the only genuine "no commits" result.
        case Arbiter.Worker.Worktree.has_commits_ahead?(wt, target) do
          {:ok, true} ->
            {:ok, current_head_sha_in(wt)}

          {:ok, false} ->
            {:error,
             "Branch `#{branch}` has no commits ahead of `#{target}`. " <>
               "The reviewer would see an empty diff and report 'no work'. " <>
               "The implementer must commit before the review gate can proceed. " <>
               "Run `git log --oneline #{target}..HEAD` in the worktree to diagnose."}
        end

      _ ->
        # Worktree is on a different branch (or current_branch failed). Skip
        # the commit check — a HEAD mismatch is not "no work done".
        {:ok, current_head_sha_in(wt)}
    end
  end

  defp reviewer_commit_check(_state), do: {:ok, nil}

  # Return the short HEAD SHA for the worktree at `path`, or nil on any error.
  defp current_head_sha_in(path) when is_binary(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Resolve the current HEAD SHA from state.worktree_path. Used by
  # note_head_change/1 to detect whether the revise implementer committed.
  defp current_head_sha(%{worktree_path: wt}) when is_binary(wt),
    do: current_head_sha_in(wt)

  defp current_head_sha(_state), do: nil

  # ---- worker spawning ---------------------------------------------------

  # Subscribe to the worker's output topic, spawn it, arm a fresh (attempt-
  # tagged) timeout, and reset the line buffer for this pass. Used for every
  # reviewer pass (first review, re-review, verdict re-prompt) and every
  # implementer revision; returns the updated state on success. Subscribe BEFORE
  # spawning so we can't miss the worker's first output lines or its exit signal
  # (the subprocess may finish almost immediately — a fast worker or a test
  # fixture). The topic is known from the id alone, so subscribing ahead of the
  # port open is safe.
  defp launch_acolyte(state, id, role, prompt, command) do
    Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:" <> id)
    attempt = state.attempt + 1

    case spawn_acolyte(state, id, role, prompt, command) do
      {:ok, pid} ->
        Process.send_after(self(), {:timeout, attempt}, state.timeout_ms)
        {:ok, %{state | reviewer_pid: pid, current_id: id, attempt: attempt, lines: []}}

      {:error, _reason} = err ->
        err
    end
  end

  # Start an worker as a distinct worker + claude session under `id`. The
  # worker gets workspace_id: nil so its completion stays silent — no Admiral
  # notification, no MergeQueue pickup for the synthetic id — while still recording
  # its own run row.
  defp spawn_acolyte(state, id, role, prompt, command) do
    with {:ok, pid} <- start_acolyte_worker(state, id, role),
         :ok <- start_acolyte_session(state, pid, role, prompt, command) do
      _ = Worker.advance(pid, step_for(role))
      {:ok, pid}
    end
  end

  defp start_acolyte_worker(state, id, role) do
    case Worker.start(
           bead_id: id,
           repo: state.repo,
           workspace_id: nil,
           meta: acolyte_meta(state, role)
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:acolyte_start_failed, reason}}
    end
  end

  defp acolyte_meta(state, :reviewer), do: %{role: :reviewer, reviews: state.bead_id}
  defp acolyte_meta(state, :implementer), do: %{role: :implementer, revises: state.bead_id}

  defp step_for(:reviewer), do: :reviewing
  defp step_for(:implementer), do: :revising

  defp start_acolyte_session(state, pid, role, prompt, command) do
    case build_session_opts(state, pid, role, prompt, command) do
      {:ok, session_opts} ->
        case ClaudeSession.start(session_opts) do
          {:ok, _port} -> :ok
          {:error, reason} -> {:error, {:acolyte_session_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:acolyte_session_failed, reason}}
    end
  end

  # Assemble `ClaudeSession.start/1` opts for an worker. The fixture-friendly
  # `command:` escape hatch (test path) bypasses the adapter — when set we spawn
  # the provided argv verbatim. Otherwise we route through `Arbiter.Agents` so
  # the reviewer role honors `workspace.config["review_agent"]["config"]`
  # (model + api keys), and the implementer role honors the worker `agent`
  # block. A workspace-less ReviewGate (ad-hoc run) falls back to today's
  # behaviour — `ClaudeSession`'s built-in default argv, no model flag.
  defp build_session_opts(state, pid, _role, _prompt, command) when is_list(command) do
    {:ok, [owner: pid, worktree_path: state.worktree_path, command: command]}
  end

  defp build_session_opts(state, pid, role, prompt, nil) do
    base = [owner: pid, worktree_path: state.worktree_path]

    case load_workspace(state.workspace_id) do
      nil ->
        {:ok, base ++ [prompt: prompt]}

      %Workspace{} = ws ->
        {adapter, role_atom} = adapter_for(ws, role)
        :ok = Agents.prepare(ws, role_atom)

        # The reviewer/implementer worker gets the same per-domain security
        # posture as a worker spawn — resolved from the workspace, never the
        # operator's ~/.claude (bd-9u10op).
        agent_opts =
          agent_opts_for_role(ws, role_atom, state.bead_id) ++
            [security: SecurityPolicy.resolve(ws)]

        case adapter.default_argv(prompt, agent_opts) do
          {:ok, argv} ->
            env = safe_spawn_env(adapter, agent_opts)
            {:ok, base ++ [command: argv, env: env, provider: adapter.provider()]}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp adapter_for(%Workspace{} = ws, :reviewer),
    do: {Agents.reviewer_for_workspace(ws), :review_agent}

  defp adapter_for(%Workspace{} = ws, :implementer), do: {Agents.for_workspace(ws), :agent}

  # The reviewer slot has its own config under `review_agent.config.*`
  # (falls back to the worker `agent` block so a workspace that names only
  # `agent` still spawns a reviewer). The model/tier/thinking knobs are
  # read directly from the configured block — the reviewer doesn't route
  # by difficulty (the bead's difficulty drives the *worker*; the reviewer
  # has its own fixed config).
  defp agent_opts_for_role(%Workspace{config: config}, :review_agent, _bead_id) do
    block =
      get_in(config || %{}, ["review_agent", "config"]) ||
        get_in(config || %{}, ["agent", "config"]) || %{}

    [
      model: Map.get(block, "model"),
      model_tier: Map.get(block, "model_tier"),
      thinking: Map.get(block, "thinking"),
      config: block
    ]
  end

  # The implementer slot is a worker session on the same bead — route it
  # through the configured policy (`:static` / `:by_priority` /
  # `:by_difficulty` / ...) so a revise round picks the same model the
  # initial dispatch would have, not a flat workspace default. Best-effort:
  # a missing bead falls back to the workspace's `agent.config`.
  defp agent_opts_for_role(%Workspace{} = ws, :agent, bead_id) do
    case load_issue(bead_id) do
      nil ->
        block = get_in(ws.config || %{}, ["agent", "config"]) || %{}

        [
          model: Map.get(block, "model"),
          model_tier: Map.get(block, "model_tier"),
          thinking: Map.get(block, "thinking"),
          config: block
        ]

      %Issue{} = bead ->
        config = bead |> Routing.choose(ws, %{}) |> Map.get(:config) || %{}

        [
          model: Map.get(config, "model"),
          model_tier: Map.get(config, "model_tier"),
          thinking: Map.get(config, "thinking"),
          config: config
        ]
    end
  end

  defp load_issue(bead_id) when is_binary(bead_id) do
    case Ash.get(Issue, bead_id) do
      {:ok, %Issue{} = bead} -> bead
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp load_issue(_), do: nil

  defp safe_spawn_env(adapter, agent_opts) do
    if function_exported?(adapter, :spawn_env, 1) do
      adapter.spawn_env(agent_opts)
    else
      []
    end
  end

  defp load_workspace(nil), do: nil

  defp load_workspace(ws_id) when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{} = ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Stop the current worker worker if it's still alive. Best-effort — used
  # before spawning the next worker so one that finished without printing `arb
  # done` (and so never self-completed) can't linger.
  defp stop_acolyte(state) do
    if is_pid(state.reviewer_pid) and Process.alive?(state.reviewer_pid) do
      safe(fn -> Worker.stop(state.reviewer_pid, :normal) end)
    end

    :ok
  end

  # ---- synthetic worker ids ----------------------------------------------

  # The synthetic bead id for a re-prompt reviewer: a fresh, distinct id per
  # attempt so it registers as its own worker / run row and never collides with
  # the original (possibly still-terminating) reviewer.
  defp reprompt_bead_id(review_id, attempt), do: review_id <> "#v#{attempt + 1}"

  # The reviewer id for a later round (round >= 2): distinct per round.
  defp reviewer_round_id(review_id, round), do: review_id <> "#r#{round}"

  # The implementer id for a given round's revision: distinct per round.
  defp implementer_bead_id(review_id, round), do: review_id <> "#impl#{round}"

  # ---- misc ---------------------------------------------------------------

  defp round_subject(state, verdict), do: "Round #{state.round} findings (#{verdict})"

  # Public only so the UTF-8-boundary behaviour can be unit-tested directly
  # (mirrors parse_verdict/1); not part of the documented API.
  @doc false
  def cap(text, max) when is_binary(text) do
    if byte_size(text) > max do
      valid_prefix(binary_part(text, 0, max)) <> "\n… (truncated)"
    else
      text
    end
  end

  # binary_part/3 slices on a raw byte offset, which can sever a multibyte UTF-8
  # codepoint mid-sequence and yield an invalid-UTF-8 binary. Downstream String
  # ops (String.trim/1 in escalation_payload/1) and the Postgres UTF8 column both
  # choke on such bytes — and escalation diffs routinely carry em-dashes/arrows.
  # Shave at most 3 trailing bytes back to a valid codepoint boundary.
  defp valid_prefix(bin) when byte_size(bin) == 0, do: bin

  defp valid_prefix(bin) do
    if String.valid?(bin), do: bin, else: valid_prefix(binary_part(bin, 0, byte_size(bin) - 1))
  end

  # Minimal snapshot for a ReviewGate probed as if it were a worker. The ReviewGate
  # is a review gate, not an worker; this exists only so an accidental
  # :snapshot call gets a sane reply rather than crashing it. See bd-2y0gd5.
  defp snapshot(state) do
    %{
      bead_id: state.bead_id,
      review_id: state.review_id,
      status: :reviewing,
      current_step: "review_gate",
      repo: state.repo,
      role: :review_gate,
      phase: state.phase,
      round: state.round,
      max_rounds: state.max_rounds,
      reviewer_alive: is_pid(state.reviewer_pid) and Process.alive?(state.reviewer_pid)
    }
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ---- prompts ------------------------------------------------------------

  @doc """
  Build the reviewer's prompt: the bead's acceptance criteria + description, the
  branch under review, the verdict protocol, and the hard no-boot constraint.
  Public so it can be inspected in tests.
  """
  @spec review_prompt(map()) :: String.t()
  def review_prompt(state) do
    bead = load_bead(state.bead_id)

    """
    You are a REVIEWER worker — a ReviewGate. You did NOT write this code; a
    different worker did. Your job is to code-review its work before it merges.
    You must reach an independent verdict — do not rubber-stamp.

    Bead under review: #{state.bead_id}
    Title: #{bead.title}

    Description:
    #{bead.description}

    Acceptance criteria:
    #{bead.acceptance}

    The work is on branch `#{state.branch}`, cut from `#{state.target_branch}`.
    #{head_sha_instruction(state)}
    Review ONLY the diff. Inspect it with, e.g.:

        git diff #{state.target_branch}...HEAD
        git log --oneline #{state.target_branch}..HEAD

    Judge the change against the acceptance criteria AND for correctness,
    regressions, and obvious defects.

    NOTE (bd-ofql8k): if `git diff #{state.target_branch}...HEAD` looks empty,
    also run `git status` BEFORE concluding "no code exists". An empty
    `base..HEAD` plus a non-empty `git status` means the implementer edited
    files but forgot to commit — the work is in the worktree, just not in
    history. In that case REQUEST_CHANGES with a finding that names the
    uncommitted files and asks for a commit, rather than reporting "no work."

    *** ABSOLUTE RULE: DO NOT boot the app. No `mix phx.server`, no `iex -S mix`,
    no `mix run`. Running a second app instance is hazardous. You review the diff
    by reading it — you do not run the application. (Reading files and running
    `git` is fine.)

    When you have decided, print your verdict on its own line, EXACTLY one of:

        VERDICT: APPROVE
        VERDICT: REQUEST_CHANGES

    If you REQUEST_CHANGES you MUST follow the verdict with an ENUMERATED list of
    concrete findings — each with a severity, a `file:line` location, and a
    suggested fix. A REQUEST_CHANGES verdict that names no findings is invalid and
    will be rejected: the implementer would have nothing to act on. Output only
    structured review content — no roleplay persona, character, or theatrical
    flourish. Then print, on a line by itself:

        arb done
    """
  end

  @doc """
  Build the verdict re-prompt used when a prior pass produced a malformed result:
  a missing sentinel (`:no_verdict`) or a REQUEST_CHANGES with no findings
  (`:empty_findings`). Since there is no live Claude session resume yet, the
  follow-up pass is a fresh reviewer mind with no memory of the prior pass — so it
  re-supplies the full review context, prefixed with an instruction naming exactly
  what went wrong so it isn't repeated. Public for inspection in tests.
  """
  @spec verdict_reprompt_prompt(map(), :no_verdict | :empty_findings) :: String.t()
  def verdict_reprompt_prompt(state, reason \\ :no_verdict)

  def verdict_reprompt_prompt(state, :empty_findings) do
    """
    A prior review pass of this diff returned `VERDICT: REQUEST_CHANGES` but listed
    NO concrete findings — only a verdict (or a content-free flourish). That is
    useless: the implementer has nothing to act on. Review the diff again and:

      * if the change is acceptable, finish with `VERDICT: APPROVE`; or
      * if it genuinely needs changes, finish with `VERDICT: REQUEST_CHANGES`
        followed by an ENUMERATED list of findings — each with a severity, a
        `file:line` location, and a concrete suggested fix.

    A REQUEST_CHANGES with no enumerated findings will be rejected again. Do not
    include any roleplay or persona text — structured findings only.

    """ <> review_prompt(state)
  end

  def verdict_reprompt_prompt(state, _no_verdict) do
    """
    A prior review pass of this diff finished WITHOUT emitting the required
    verdict line, so its conclusion was lost. Review the diff again and this time
    you MUST finish with EXACTLY one line, one of:

        VERDICT: APPROVE
        VERDICT: REQUEST_CHANGES

    Do not skip the verdict line — without it your review cannot be honored.

    """ <> review_prompt(state)
  end

  @doc """
  Build the implementer's revise prompt for a round of the revise-and-rediscuss
  loop: the reviewer's findings, and the instruction to address EACH one (fix or
  rebut) on the same branch, committing any code changes so the next review can
  see them.

  Stage 3 (bd-1na62i) prepends a git-derived "work so far" briefing
  (`ResumeContext.work_so_far/2`) so this fresh implementer mind continues the
  prior round's thread with full context — the same provider-agnostic
  continuity the `arb resume` path uses — instead of re-deriving what was done
  from a raw diff. Combined with the reviewer findings and the bead directive
  below, that approximates the original implementer resuming its own session.
  Public for inspection in tests.
  """
  @spec revise_prompt(map(), String.t()) :: String.t()
  def revise_prompt(state, findings) do
    bead = load_bead(state.bead_id)

    """
    You are an IMPLEMENTER worker. A reviewer (a ReviewGate) has reviewed the work
    on branch `#{state.branch}` and REQUESTED CHANGES. Your job is to address each
    finding so the work can pass review.

    Bead: #{state.bead_id}
    Title: #{bead.title}

    Description:
    #{bead.description}

    Acceptance criteria:
    #{bead.acceptance}
    #{work_so_far_briefing(state)}
    Reviewer findings (round #{state.round}):
    #{clean_findings(findings)}

    For EACH finding, do ONE of:
      * FIX it — edit the code on branch `#{state.branch}` and COMMIT the change
        (`git add -A && git commit -m "..."`), so the reviewer can see it in the
        diff on re-review; or
      * REBUT it — if you believe the finding is mistaken, leave the code as-is
        and explain, concretely, why it is not a problem.

    State clearly, for each finding, whether you FIXED or REBUTTED it and why —
    your reply here is forwarded back to the reviewer as your side of the record.

    The work is on branch `#{state.branch}`, cut from `#{state.target_branch}`:

        git diff #{state.target_branch}...HEAD
        git log --oneline #{state.target_branch}..HEAD

    *** ABSOLUTE RULE: DO NOT boot the app. No `mix phx.server`, no `iex -S mix`,
    no `mix run`. (Reading files, editing, and running `git` is fine.)

    When you have addressed every finding, print, on a line by itself:

        arb done
    """
  end

  # Stage 3 (bd-1na62i): the same-mind-continuity briefing prepended to a
  # revise-round implementer. Each revision is a FRESH mind (literal Claude/Gemini
  # session resume was dropped — provider-specific and fragile across billing
  # pauses/crashes), so we hand it the git-derived picture of what the prior
  # round(s) actually did — commits since the branch cut + any uncommitted work —
  # exactly as the `arb resume` path (bd-auma3z) briefs a resumed worker. Skipped
  # (empty string) for a worktree-less ReviewGate: an ad-hoc / test run with nothing
  # on disk to summarize falls back to today's directive-only prompt.
  defp work_so_far_briefing(%{worktree_path: wt, target_branch: tb})
       when is_binary(wt) and is_binary(tb) do
    """

    Work done so far on this branch by the prior round(s) — continue from here,
    do NOT restart; build on what is already committed:

    #{ResumeContext.work_so_far(wt, tb)}
    """
  end

  defp work_so_far_briefing(_state), do: ""

  # bd-1mksks: embed the verified HEAD SHA into the review prompt so the
  # reviewer can confirm it is on the correct commit before running `git diff`.
  # When no SHA is available (no worktree, or git failed at spawn time), the
  # instruction is omitted — the review proceeds without the explicit anchor.
  defp head_sha_instruction(%{head_sha: sha, branch: branch, target_branch: target})
       when is_binary(sha) do
    """
    The ReviewGate verified before dispatching this review that branch `#{branch}`
    has commits ahead of `#{target}`. The implementer's HEAD at dispatch time was
    commit `#{sha}`. Before running `git diff`, confirm you are on the correct
    commit:

        git log --oneline -1
        # Expected: #{sha} <commit message>

    If `git log --oneline -1` shows a different commit than `#{sha}`, stop and
    report REQUEST_CHANGES noting the HEAD mismatch — do not review the wrong diff.

    """
  end

  defp head_sha_instruction(_state), do: ""

  @doc """
  Build the reviewer's re-review prompt for round >= 2: the base review prompt,
  prefixed with the prior implementer↔reviewer thread so the reviewer can accept
  each fix/rebuttal or hold the line on the UPDATED diff. Public for inspection.
  """
  @spec rereview_prompt(map()) :: String.t()
  def rereview_prompt(state) do
    """
    This is review round #{state.round} of a revise-and-rediscuss loop. The
    implementer has addressed your prior findings. Re-review the UPDATED diff. For
    each prior finding, decide whether to ACCEPT the fix/rebuttal or HOLD THE
    LINE, then issue a fresh verdict on the current state of the branch.

    Prior discussion (oldest first):

    #{render_thread(state.thread)}

    ----------------------------------------------------------------------

    """ <> review_prompt(state)
  end

  defp load_bead(bead_id) do
    case Ash.get(Issue, bead_id) do
      {:ok, %Issue{} = bead} ->
        %{
          title: bead.title || "(untitled)",
          description: bead.description || "(none)",
          acceptance: bead.acceptance || "(none)"
        }

      _ ->
        %{title: "(unknown)", description: "(none)", acceptance: "(none)"}
    end
  rescue
    _ -> %{title: "(unknown)", description: "(none)", acceptance: "(none)"}
  end
end
