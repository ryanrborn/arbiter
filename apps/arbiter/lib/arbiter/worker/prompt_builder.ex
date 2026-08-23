defmodule Arbiter.Worker.PromptBuilder do
  @moduledoc """
  Pure prompt-generation for dispatched workers.

  Extracted from `Arbiter.Worker.Dispatch` (bd-8u5uaw): this module has zero
  GenServer/dispatch-lifecycle coupling — every function here is a pure
  transform from an `Issue` (+ opts) to a `String.t()` prompt. `Dispatch`
  keeps thin public wrappers (`prompt_for/1`, `prompt_for_task/2`,
  `conflict_resolve_briefing/3`) that delegate here, since those are called
  externally (`ConflictResolver`, tests) as `Arbiter.Worker.Dispatch.*`.
  """

  require Ash.Query

  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.Issue
  alias Arbiter.Trackers
  alias Arbiter.Worker.ReviewVerification

  @doc false
  def prompt_for(%Issue{} = task), do: prompt_for_task(task, [])

  @doc false
  def prompt_for_task(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :review, false) == true -> review_prompt(task, opts)
      task.issue_type == :task -> task_prompt(task, opts)
      true -> work_prompt(task, opts)
    end
  end

  @doc """
  Briefing for a **conflict-resolve** worker (#354, Phase 2b).

  The Watchdog (`Arbiter.Worker.Watchdog`) dispatches a short-lived worker
  against the task's existing worktree when an *approved* PR is blocked as
  `:conflict` — mergeable in isolation but no longer applying cleanly on top of
  the current base. The worker's job is narrow: rebase the branch onto the
  current base, resolve the conflicts **honoring the task's original intent**,
  fix anything the rebase broke, and force-push so the Watchdog's next poll can
  re-attempt the merge.

  The original intent (title / description / acceptance) is embedded so a
  semantic conflict is resolved the way the task *meant*, not guessed. This
  supersedes and hardens the narrower #122 auto-conflict-resolver prompt: it
  adds the intent context and an explicit "run the tests, fix what the rebase
  broke" step the old mechanical-only prompt lacked.
  """
  @spec conflict_resolve_briefing(Issue.t(), String.t(), String.t()) :: String.t()
  def conflict_resolve_briefing(%Issue{} = task, branch, target_branch)
      when is_binary(branch) and is_binary(target_branch) do
    """
    You are a conflict-resolution worker for task #{task.id}.

    Your branch (#{branch}) is APPROVED but CONFLICTS with the current head of
    #{target_branch}: it was mergeable in isolation, but the base has moved and
    it no longer applies cleanly. Your ONLY job is to rebase it onto the current
    base, resolve the conflicts, and force-push — NOT to re-implement the change
    or open a new PR.

    ## Original intent — resolve conflicts so the result still satisfies THIS

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}

    ## Steps

      1. Fetch the latest base: `git fetch origin #{target_branch}`
      2. Rebase your branch onto it: `git rebase origin/#{target_branch}`
      3. Resolve every conflict so the result still honors the intent above.
         Most collisions are parallel edits to non-overlapping sections — keep
         both sides. Where two changes touch the same logic, keep the behaviour
         the acceptance criteria describe, then `git rebase --continue`.
      4. Run the test suite and fix anything the rebase broke — a clean rebase
         that fails tests is NOT done. Re-run until green.
      5. Force-push with lease to update the existing PR in place:
         `git push --force-with-lease origin #{branch}`
      6. Print `arb done` on a line by itself.

    DO NOT:
      * re-implement the change set or open a new PR,
      * touch files unrelated to the conflict,
      * abandon the rebase silently (`git rebase --abort` then exit).

    If a conflict is SEMANTIC — two changes both rewrote the same predicate or
    invariant such that no mechanical merge can honor both — STOP and escalate:

        arb message coordinator "Conflict on #{task.id} needs human review: <one-line why>"

    then print `arb done`. A loud escalation beats a silent miscompile in
    #{target_branch}.
    """
  end

  # When resuming (bd-auma3z) the work prompt is prefixed with a git-derived
  # briefing of the prior worker's committed + uncommitted work, so the fresh
  # agent continues from the preserved worktree instead of redoing finished
  # steps. `:resume_context` is built by `Arbiter.Worker.ResumeContext`; it's
  # absent (empty prefix) on a normal fresh dispatch.
  defp work_prompt(%Issue{} = task, opts) do
    resume_prefix = Keyword.get(opts, :resume_context) || ""
    resume_prefix <> base_work_prompt(task, opts)
  end

  # The resolved-skills advertisement block (DECISION C): always-on skills get
  # an imperative `/name` directive, situational skills are listed as available.
  # Empty string when no skills resolved (the common case today).
  defp skills_section(opts) do
    Arbiter.Skills.Materializer.prompt_section(Keyword.get(opts, :resolved_skills, []))
  end

  # bd-8cn795: whole-file reads of large modules (or a large PR body / API
  # dump piped straight into context) refill the window faster than
  # autocompact can shed it, tripping the CLI's own thrash detector
  # ("Autocompact is thrashing...") and aborting the session before any real
  # work happens. This is deterministic for a given file set, so the fix has
  # to be read discipline, not a retry. Shared between the work and review
  # prompts since both failure instances (bd-3cpcw2, lt-5jhqs8) were reads,
  # not writes.
  # Shared between `base_work_prompt/2` and `task_prompt/2` (bd-6v2my2): any
  # dispatch that provisions a worktree needs the same "don't write outside it"
  # warning, regardless of whether the directive is reviewable code or a
  # `:task`-type follow-up that also happens to get a checkout.
  defp isolation_section(worktree_path) when is_binary(worktree_path) do
    """

    FILESYSTEM ISOLATION — Your worktree is at:

        #{worktree_path}

    You MUST only write files inside this directory. Do NOT use absolute
    paths that point outside it — especially not to the main repo checkout
    (e.g. /home/ryan/dev/arbiter/...). Writing to the main repo corrupts
    Phoenix hot-reload and cascades to kill every other running worker.
    Always use relative paths or paths rooted at #{worktree_path}.
    """
  end

  defp isolation_section(_), do: ""

  # bd-fjlx01: a worker verifying a UI/server change locally (e.g. booting
  # `mix phx.server`/`rails server`/`npm run dev` to check it in a browser)
  # sometimes tears that process down with a name- or pattern-matching kill
  # (`pkill -f "phx.server"`, `killall node`, `fuser -k <port>`). Process
  # command lines are visible host-wide, not scoped to the worker's own
  # worktree or session — a pattern broad enough to match your own instance is
  # also broad enough to match Arbiter's own server (dispatch is frequently
  # dogfooded: the coordinator that dispatched you may be running the exact
  # same command on this same host) or another concurrent worker's instance.
  # This has taken down the coordinator and every in-flight worker with it in
  # production use. Shared between the work and task prompts for the same
  # reason `isolation_section/1` is: any dispatch that might shell out to
  # start a long-running process carries the same hazard.
  defp process_kill_discipline_section do
    """

    PROCESS DISCIPLINE — if you start a local server or any other long-running
    process to verify your work (e.g. booting a dev server to check a page in
    a browser), you are responsible for stopping ONLY that exact process.
    NEVER use `pkill`, `killall`, `fuser -k`, or any other name/pattern-based
    kill — process command lines are visible across the whole host, not just
    your worktree, and a pattern that matches your own instance can just as
    easily match the coordinator's own server or another worker's, taking
    them down too. Capture the exact PID when you start the process (e.g.
    `some_server & SERVER_PID=$!`) and stop only that PID (`kill $SERVER_PID`).
    If you cannot reliably track that PID across your own tool calls, do not
    start the process at all — rely on the automated test suite instead of
    live/manual verification.
    """
  end

  defp read_discipline_section do
    """
    READ DISCIPLINE — avoid whole-file reads of large modules: they refill
    the context window faster than autocompact can shed it and can abort your
    session mid-task ("Autocompact is thrashing"). Prefer grep/symbol search
    to locate the relevant span first, then read a bounded offset+limit range
    rather than the entire file. For a large `gh`/API command's output, pipe
    it to a file and read bounded slices rather than dumping it whole into
    context.
    """
  end

  defp base_work_prompt(%Issue{} = task, opts) do
    worktree_path = Keyword.get(opts, :worktree_path)
    isolation_section = isolation_section(worktree_path)

    """
    You are a worker working autonomously on task #{task.id}.

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}
    #{prior_review_findings_section(task)}
    Your current directory is a fresh git worktree on a per-task branch.
    #{isolation_section}
    #{process_kill_discipline_section()}
    #{read_discipline_section()}#{skills_section(opts)}
    Work the task to completion: load context, design, implement, test,
    commit on this branch, and push it.

    Do NOT open a pull request yourself (no `gh pr create` / `glab mr
    create`). The MergeQueue opens the single canonical PR for this task, on
    the correct base branch, using the body you author in the next step.
    Opening your own PR creates a duplicate on the wrong base.
    #{pr_review_instruction(task)}#{pr_body_step(task)}#{completion_notes_step(task)}
    Coordination: at the start of each step, check your mailbox by running

        arb inbox #{task.id}

    This shows any direction from the coordinator or flags from sibling workers
    (e.g. an upstream API shape changed) and marks them read. To leave a flag
    for another worker, use `arb message <their-task-id> <text>`.

    Between major steps, also check for `.arbiter/INBOX` in your working
    directory using `[ -f .arbiter/INBOX ] && cat .arbiter/INBOX` (this does
    NOT error when the file is absent — the normal case). If it exists, read
    it, act on any coordinator instructions it contains, then delete the file to
    acknowledge receipt. Treat it as a real-time message from the coordinator — it
    takes precedence over your current task if it redirects you.

    CRITICAL — continuation discipline: NEVER end a response with only a plan
    or a statement of the next step (for example, announcing that you will now
    write a test instead of writing it). After ANY check (mailbox /
    `.arbiter/INBOX` / git status), immediately continue with the next
    concrete tool call in the same turn. Your session is non-interactive: a
    turn that contains no tool call ENDS the session. The only correct way to
    finish is to print `arb done` once the work is complete — if you are about
    to stop without having printed `arb done`, keep working.

    *** ASYNC TOOLS: You may run tests, linters, compilers, or any diagnostic
    tool — including in parallel or with background execution modes. However,
    you MUST wait for every background task to complete and read its full
    output before printing `arb done`. Do not signal done while any background
    task is still running — the work is incomplete until every tool you launched
    has finished and you have read its result.

    When you are completely done, print the line:

        arb done

    on a line by itself, exactly. The worker watches your stdout and
    will mark the task complete when it sees that marker.
    """
  end

  # bd-5lc99r: briefing for a `task` issue type — non-reviewable ops/research/
  # spike work. The deliverable is a findings/results summary written to the
  # directive's `notes` field via the `task_update_progress` MCP tool, NOT a code
  # change, commit, or PR. The notes gate (Arbiter.Worker) blocks `arb done`
  # until `notes` is non-blank, so this prompt frames the whole job around
  # producing those findings and deliberately omits the commit/push/PR-body
  # steps the standard work prompt carries.
  #
  # bd-6v2my2: a PRPatrol follow-up (`source_pr` set) is also dispatched as a
  # `:task` — it has no branch/PR of its own either — but unlike a pure
  # research/ops task it MAY legitimately need to push a code fix. That fix
  # belongs on the ORIGINAL PR's branch, never a fresh one, so `pr_follow_up_note/1`
  # swaps in that guidance (and the worktree it runs from, when one was
  # provisioned) in place of the generic "you are not expected to edit a repo"
  # line.
  defp task_prompt(%Issue{} = task, opts) do
    """
    You are a worker working autonomously on task #{task.id}.

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}

    This is a `task`-type directive: it has NO branch or pull request of its
    own, and none will be opened for it.
    #{pr_follow_up_note(task)}#{isolation_section(Keyword.get(opts, :worktree_path))}
    #{process_kill_discipline_section()}
    #{read_discipline_section()}
    Your job:
      1. Do the investigation / ops work the directive describes.
      2. Write your findings to the directive's `notes` field by calling the
         `task_update_progress` MCP tool with its `notes` argument (Markdown is
         fine). Make it self-contained: what you investigated, what you found,
         and any recommendation or conclusion the coordinator needs — they read it
         via `arb show #{task.id}` and the dashboard.

    A notes gate enforces this: if you print `arb done` while `notes` is still
    blank, you will be reprompted to write your findings before the directive
    can close. Do NOT shell out to the `arb` CLI for the notes — use the
    `task_update_progress` MCP tool.
    #{completion_notes_step(task)}
    Coordination: at the start of each step, check your mailbox by running

        arb inbox #{task.id}

    This shows any direction from the coordinator or flags from sibling workers and
    marks them read. To leave a flag for another worker, use
    `arb message <their-task-id> <text>`.

    Between major steps, also check for `.arbiter/INBOX` in your working
    directory. If it exists, read it, act on any coordinator instructions it
    contains, then delete the file to acknowledge receipt.

    *** ASYNC TOOLS: You may run any diagnostic tool — including in parallel or
    with background execution modes. However, you MUST wait for every background
    task to complete and read its full output before printing `arb done`.

    When you are completely done — findings written to `notes` — print the line:

        arb done

    on a line by itself, exactly. The worker watches your stdout and will mark
    the task complete when it sees that marker.
    """
  end

  # bd-6v2my2: a PRPatrol follow-up carries `source_pr` — the PR it was auto-filed
  # against (unresolved review threads / CHANGES_REQUESTED / a failing required
  # check, see `Arbiter.Workflows.PRPatrol`). Unlike plain research/ops `:task`
  # work, it may need to push a real fix, but that fix must land on the
  # ORIGINAL PR's branch: pushing a new branch from this directive's own
  # (unintegrated) worktree previously became a byte-identical duplicate PR
  # against the original's entire diff (lt-divfvo -> verus_server#3682). Like
  # any `:task`, this directive gets no branch worktree — its current
  # directory (when one is provisioned) is a disposable, detached checkout
  # with no branch of its own, so `gh pr checkout` there is always safe: there
  # is nothing Arbiter-owned to collide with or lose.
  defp pr_follow_up_note(%Issue{id: id, source_pr: source_pr})
       when is_binary(source_pr) and source_pr != "" do
    """

    This directive is a PRPatrol follow-up against EXISTING pull request ##{source_pr}.
    If the reviewer's findings were already addressed — or your job here is only
    to reply / resolve / escalate on the review threads — completing with no
    code change at all is SUCCESS. Do not force a commit just to have one.

    Your current directory is already a checkout of the repository (read-only
    by convention, not a branch of its own) — good enough to inspect the code
    and run `gh`/`git`. If a fix genuinely is needed: check out the ORIGINAL
    PR's branch directly — `gh pr checkout #{source_pr}` — right there, and
    commit + push (`git push`), which updates PR ##{source_pr} in place. Do
    NOT `git push -u origin <new-branch>` or `gh pr create` — that opens a
    duplicate PR against the original's entire diff.

    If the fix is too large or risky to fold in now, do not silently open a new
    PR either — that must never be a side effect of this dispatch. Push back on
    the thread explaining why (see the protocol above), or, only when a
    genuinely separate deliverable is warranted, file it as an explicit,
    recorded decision: `arb create <title> --parent #{id} --type feature` —
    a distinct task that gets its own branch/PR by design.
    """
  end

  defp pr_follow_up_note(_task) do
    """

    No worktree is provisioned by default — you are not expected to edit a repo.
    If the work genuinely requires inspecting code you may read files, but do
    not author a branch or open a PR.
    """
  end

  # The worker authors the PR/MR body and persists it on the task; the
  # MergeQueue (not the worker) opens the one canonical PR with it (bd-53xrmi).
  # Authoring it *after* implementing is what makes it worker-quality — the
  # Test plan reflects what actually passed, not what the spec hoped for. If
  # the repo ships a PR template we fill it rather than discard it (GitHub
  # injects the bare template only when the body is empty — the empty-body
  # incident #3606). Persisted via the `task_update_progress` MCP tool
  # (`pr_body` field), which the MergeQueue reads back as `pr_body`. We use the
  # MCP tool rather than the `arb` escript so completion never depends on
  # `~/.local/bin/arb` being present (it is transiently deleted by test runs).
  defp pr_body_step(%Issue{id: id, tracker_type: tracker_type, tracker_ref: tracker_ref}) do
    closes_guidance =
      case {tracker_type, is_binary(tracker_ref) && Regex.match?(~r/^\d+$/, tracker_ref)} do
        {:github, true} ->
          "\n\n    For GitHub-tracked tasks, include a closing keyword `Closes ##{tracker_ref}`" <>
            " in the References section — GitHub will auto-close the issue on merge, " <>
            "acting as a backstop independent of Arbiter's own close mechanism."

        _ ->
          ""
      end

    """

    Author the PR description and persist it on the task — the MergeQueue opens
    the PR with this exact body, so write it as the PR writeup, not a restatement
    of the ticket. Do this AFTER the work is implemented and tested, so it
    reflects what actually changed:

      * **Summary** — what changed and why, in a few sentences.
      * **Test plan** — the checks you ran, with checked boxes for what passed.
      * **References** — the task id (#{id}) and any linked ticket/PRs.#{closes_guidance}

    If the repo has a PR template (`.github/pull_request_template.md`), FILL it
    rather than discard it. Persist the finished body verbatim by calling the
    `task_update_progress` MCP tool with its `pr_body` argument set to the full
    PR body (Markdown). Use the MCP tool, which is available in this session —
    do NOT shell out to the `arb` CLI for this.

    Do this before printing `arb done`.
    """
  end

  # bd-dp7hiw: `task.notes` only carries a short per-round summary now (see
  # `Worker.format_review_gate_note/3`) — the actual findings text live in
  # `Arbiter.ReviewGate.Round`, one row per reviewer pass. Read the most
  # recent `role: :review` row directly (this worker tier can query the Ash
  # resource even though `review_gate_rounds_list` itself is coordinator-only)
  # and surface its findings here, so the re-dispatched worker sees them
  # immediately in its prompt without having to call task_show or gh pr view
  # first.
  defp prior_review_findings_section(%Issue{id: task_id}) when is_binary(task_id) do
    case latest_review_round_findings(task_id) do
      findings when is_binary(findings) and findings != "" ->
        """

        Prior review findings (address these before starting new work):
        #{findings}
        """

      _ ->
        ""
    end
  end

  defp prior_review_findings_section(_task), do: ""

  defp latest_review_round_findings(task_id) do
    Round
    |> Ash.Query.filter(task_id == ^task_id and role == :review)
    |> Ash.Query.sort(round: :desc, inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
    |> case do
      %Round{findings: findings} -> findings
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # When a PR is already open for this task, the re-slunged worker must read
  # the PR review comments to find what changed. The `Round`-derived findings
  # (above) are the primary source, but the PR reviews are the canonical
  # record — fetching them explicitly guards against a `Round` row being
  # stale or missing.
  defp pr_review_instruction(%Issue{pr_ref: pr_ref})
       when is_binary(pr_ref) and pr_ref != "" do
    """

    This task has an existing PR (##{pr_ref}). Read the PR review comments
    before starting work — the review findings are there:

        gh pr view #{pr_ref} --json reviews,reviewComments

    Address every finding (fix the code or rebut with justification), then
    push commits to the existing branch. Do NOT open a new PR.
    """
  end

  defp pr_review_instruction(_task), do: ""

  # For tracker-backed tasks (an upstream Jira/etc. ticket), completing the
  # work includes producing the gated completion notes the tracker requires
  # before it will transition the ticket forward. We make this an explicit,
  # non-optional step in the worker's prompt and tell it exactly how to
  # persist the notes on the task (the `task_update_progress` MCP tool), so the
  # downstream tracker-sync has the fields to push. We use the MCP tool rather
  # than the `arb` escript so completion never depends on `~/.local/bin/arb`
  # being present (it is transiently deleted by test runs — bd-53xrmi). Untracked
  # tasks get nothing extra.
  defp completion_notes_step(%Issue{tracker_type: :none}), do: ""

  defp completion_notes_step(%Issue{tracker_ref: ref}) when ref in [nil, ""], do: ""

  defp completion_notes_step(%Issue{} = issue) do
    adapter = Trackers.for_task(issue)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :gating_fields, 2) do
      """

      This task is backed by an external tracker ticket. Before you finish, you
      MUST produce its completion notes and persist them on the task — the
      tracker gates the ticket's forward transition until both are filled. Call
      the `task_update_progress` MCP tool (available in this session) with these
      arguments:

        * `qa_notes` — What QA should verify: the user-facing behaviour to
          exercise, edge cases, and how to confirm the fix.
        * `deployment_notes` — Rollout considerations: DB migrations, feature
          flags, config/env changes, ordering, and any backout steps. Write
          'None' only if there genuinely are none.

      Use the MCP tool — do NOT shell out to the `arb` CLI for this. Base the
      notes on the change you actually made. This is part of "done": do it before
      printing `arb done`.
      """
    else
      ""
    end
  end

  defp review_prompt(%Issue{} = task, opts) do
    tracker_line =
      case task.pr_ref do
        pr when is_binary(pr) and pr != "" ->
          "Tracker ref (PR/MR to review): #{task.tracker_type}:#{pr}\n\n"

        _ ->
          case task.tracker_ref do
            ref when is_binary(ref) and ref != "" ->
              "Tracker ref (PR/MR to review): #{task.tracker_type}:#{ref}\n\n"

            _ ->
              ""
          end
      end

    tracker_context_section =
      case Keyword.get(opts, :tracker_context) do
        %{ref: ref, type: type, title: title, description: desc}
        when is_binary(ref) and ref != "" ->
          context_body =
            [title && "Title: #{title}", desc] |> Enum.filter(& &1) |> Enum.join("\n\n")

          """

          --- Tracker context (read-only, #{type}:#{ref}) ---
          #{context_body}
          --- End tracker context ---

          """

        _ ->
          ""
      end

    """
    You are a reviewer worker. Review the pull/merge request linked to task
    #{task.id} and post a verdict. You are not the author; do not modify the
    branch.

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}
    #{tracker_context_section}
    #{tracker_line}Your current directory is the repo's local checkout. There is
    no per-task branch and no worktree was provisioned — this is a review-only
    directive.
    #{process_kill_discipline_section()}
    #{read_discipline_section()}
    Steps:
      1. Read the PR/MR diff via the configured tracker's CLI (`gh pr diff
         <ref>` for GitHub, `glab mr diff <ref>` for GitLab, `git diff` for
         the Direct local strategy). Do not check out the branch.
      2. Identify real correctness, security, or contract issues against the
         task's intent. Skip style nits.
      3. Post inline comments for each finding through the same tracker CLI.
      4. Post a single review-level verdict — `approve` or `request_changes`
         — with a one-paragraph summary.

    Forbidden:
      * Do NOT push code.
      * Do NOT merge or close the PR/MR.
      * Do NOT modify any branch, including the PR's head.

    *** ASYNC TOOLS: You may run tests, linters, or any diagnostic tool —
    including in parallel or with background execution modes. However, you
    MUST wait for every background task to complete and read its full output
    before printing `arb done`. Do not signal done while any background task
    is still running.

    #{ReviewVerification.anti_stale_reflag_block()}
    After you post the review to the tracker, print your conclusion on its
    own line, EXACTLY one of:

        VERDICT: APPROVE
        VERDICT: REQUEST_CHANGES

    If you REQUEST_CHANGES you MUST have posted an ENUMERATED list of concrete
    findings through the tracker CLI — each with a severity, a location, and a
    suggested fix. A REQUEST_CHANGES verdict that names no findings is invalid.

    #{ReviewVerification.disclosure_block()}
    Then print, on a line by itself:

        arb done
    """
  end
end
