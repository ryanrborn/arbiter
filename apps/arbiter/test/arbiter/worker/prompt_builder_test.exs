defmodule Arbiter.Worker.PromptBuilderTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Tasks.Issue
  alias Arbiter.Worker.PromptBuilder

  # bd-8u5uaw: golden-output tests pinning the exact prompt text for fixed
  # inputs. These moved byte-for-byte from `Arbiter.Worker.Dispatch` — the
  # point of this file is to catch any future accidental drift in the
  # generated prompt, not to re-describe every branch (that coverage already
  # lives in dispatch_test.exs against `Dispatch.prompt_for_task/2`, which now
  # delegates here).

  defp task(overrides) do
    struct!(
      %Issue{
        id: "bd-golden1",
        title: "Fix the null guard",
        description: "The parser crashes on empty input.",
        acceptance: "Empty input returns {:error, :empty} instead of raising.",
        issue_type: :bug,
        tracker_type: :none,
        tracker_ref: nil,
        pr_ref: nil,
        source_pr: nil
      },
      overrides
    )
  end

  test "work prompt is byte-identical for fixed inputs" do
    prompt =
      PromptBuilder.prompt_for_task(task(%{}), worktree_path: "/tmp/wt-golden")

    assert prompt == """
           You are a worker working autonomously on task bd-golden1.

           Title: Fix the null guard

           Description:
           The parser crashes on empty input.

           Acceptance:
           Empty input returns {:error, :empty} instead of raising.

           Your current directory is a fresh git worktree on a per-task branch.

           FILESYSTEM ISOLATION — Your worktree is at:

               /tmp/wt-golden

           You MUST only write files inside this directory. Do NOT use absolute
           paths that point outside it — especially not to the main repo checkout
           (e.g. /home/ryan/dev/arbiter/...). Writing to the main repo corrupts
           Phoenix hot-reload and cascades to kill every other running worker.
           Always use relative paths or paths rooted at /tmp/wt-golden.


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

           READ DISCIPLINE — avoid whole-file reads of large modules: they refill
           the context window faster than autocompact can shed it and can abort your
           session mid-task ("Autocompact is thrashing"). Prefer grep/symbol search
           to locate the relevant span first, then read a bounded offset+limit range
           rather than the entire file. For a large `gh`/API command's output, pipe
           it to a file and read bounded slices rather than dumping it whole into
           context.

           Work the task to completion: load context, design, implement, test,
           commit on this branch, and push it.

           Do NOT open a pull request yourself (no `gh pr create` / `glab mr
           create`). The MergeQueue opens the single canonical PR for this task, on
           the correct base branch, using the body you author in the next step.
           Opening your own PR creates a duplicate on the wrong base.

           Author the PR description and persist it on the task — the MergeQueue opens
           the PR with this exact body, so write it as the PR writeup, not a restatement
           of the ticket. Do this AFTER the work is implemented and tested, so it
           reflects what actually changed:

             * **Summary** — what changed and why, in a few sentences.
             * **Test plan** — the checks you ran, with checked boxes for what passed.
             * **References** — the task id (bd-golden1) and any linked ticket/PRs.

           If the repo has a PR template (`.github/pull_request_template.md`), FILL it
           rather than discard it. Persist the finished body verbatim by calling the
           `task_update_progress` MCP tool with its `pr_body` argument set to the full
           PR body (Markdown). Use the MCP tool, which is available in this session —
           do NOT shell out to the `arb` CLI for this.

           Do this before printing `arb done`.

           Coordination: at the start of each step, check your mailbox by running

               arb inbox bd-golden1

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

  test "task-type prompt is byte-identical for fixed inputs" do
    prompt = PromptBuilder.prompt_for_task(task(%{issue_type: :task}), [])

    assert prompt == """
           You are a worker working autonomously on task bd-golden1.

           Title: Fix the null guard

           Description:
           The parser crashes on empty input.

           Acceptance:
           Empty input returns {:error, :empty} instead of raising.

           This is a `task`-type directive: it has NO branch or pull request of its
           own, and none will be opened for it.

           No worktree is provisioned by default — you are not expected to edit a repo.
           If the work genuinely requires inspecting code you may read files, but do
           not author a branch or open a PR.


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

           READ DISCIPLINE — avoid whole-file reads of large modules: they refill
           the context window faster than autocompact can shed it and can abort your
           session mid-task ("Autocompact is thrashing"). Prefer grep/symbol search
           to locate the relevant span first, then read a bounded offset+limit range
           rather than the entire file. For a large `gh`/API command's output, pipe
           it to a file and read bounded slices rather than dumping it whole into
           context.

           Your job:
             1. Do the investigation / ops work the directive describes.
             2. Write your findings to the directive's `notes` field by calling the
                `task_update_progress` MCP tool with its `notes` argument (Markdown is
                fine). Make it self-contained: what you investigated, what you found,
                and any recommendation or conclusion the coordinator needs — they read it
                via `arb show bd-golden1` and the dashboard.

           A notes gate enforces this: if you print `arb done` while `notes` is still
           blank, you will be reprompted to write your findings before the directive
           can close. Do NOT shell out to the `arb` CLI for the notes — use the
           `task_update_progress` MCP tool.

           Coordination: at the start of each step, check your mailbox by running

               arb inbox bd-golden1

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

  test "review prompt is byte-identical for fixed inputs" do
    prompt = PromptBuilder.prompt_for_task(task(%{}), review: true)

    assert prompt == """
           You are a reviewer worker. Review the pull/merge request linked to task
           bd-golden1 and post a verdict. You are not the author; do not modify the
           branch.

           Title: Fix the null guard

           Description:
           The parser crashes on empty input.

           Acceptance:
           Empty input returns {:error, :empty} instead of raising.

           Your current directory is the repo's local checkout. There is
           no per-task branch and no worktree was provisioned — this is a review-only
           directive.

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

           READ DISCIPLINE — avoid whole-file reads of large modules: they refill
           the context window faster than autocompact can shed it and can abort your
           session mid-task ("Autocompact is thrashing"). Prefer grep/symbol search
           to locate the relevant span first, then read a bounded offset+limit range
           rather than the entire file. For a large `gh`/API command's output, pipe
           it to a file and read bounded slices rather than dumping it whole into
           context.

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

           #{Arbiter.Worker.ReviewVerification.anti_stale_reflag_block()}
           After you post the review to the tracker, print your conclusion on its
           own line, EXACTLY one of:

               VERDICT: APPROVE
               VERDICT: REQUEST_CHANGES

           If you REQUEST_CHANGES you MUST have posted an ENUMERATED list of concrete
           findings through the tracker CLI — each with a severity, a location, and a
           suggested fix. A REQUEST_CHANGES verdict that names no findings is invalid.

           #{Arbiter.Worker.ReviewVerification.disclosure_block()}
           Then print, on a line by itself:

               arb done
           """
  end

  test "review prompt is byte-identical when a review checkout was provisioned (bd-199giy)" do
    prompt =
      PromptBuilder.prompt_for_task(task(%{}),
        review: true,
        review_checkout: %{
          path: "/tmp/arbiter-worktrees/review-abc123def456-1",
          branch: "bugfix/bd-golden1-fix-null-guard",
          head_sha: "abc123def456",
          base_branch: "main"
        }
      )

    assert prompt == """
           You are a reviewer worker. Review the pull/merge request linked to task
           bd-golden1 and post a verdict. You are not the author; do not modify the
           branch.

           Title: Fix the null guard

           Description:
           The parser crashes on empty input.

           Acceptance:
           Empty input returns {:error, :empty} instead of raising.

           Your current directory (/tmp/arbiter-worktrees/review-abc123def456-1) is a
           throwaway git worktree checked out DETACHED at `bugfix/bd-golden1-fix-null-guard`
           head abc123def456 — the exact commit under review. It is yours alone and is
           destroyed when this review ends. Read, Grep, Glob and Bash work here; Edit,
           Write and NotebookEdit are denied, so you cannot modify the code you are
           reviewing and cannot advance the branch.

           Use it: open the real files at the reviewed commit, grep for call sites the
           diff never shows, and run the tests against the actual tree. The diff is your
           entry point, not the limit of what you can check. Report findings only on
           code the diff actually touches — anything the checkout surfaces outside the
           diff belongs in your summary prose, not as an inline comment.

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

           READ DISCIPLINE — avoid whole-file reads of large modules: they refill
           the context window faster than autocompact can shed it and can abort your
           session mid-task ("Autocompact is thrashing"). Prefer grep/symbol search
           to locate the relevant span first, then read a bounded offset+limit range
           rather than the entire file. For a large `gh`/API command's output, pipe
           it to a file and read bounded slices rather than dumping it whole into
           context.

           Steps:
             1. Read the diff under review with `git diff origin/main...HEAD` in this
                worktree (the tracker CLI — `gh pr diff <ref>` for GitHub, `glab mr
                diff <ref>` for GitLab — is the fallback if that base ref is
                unavailable). The commit under review is ALREADY checked out here; do
                not check out or create any other branch.
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

           #{Arbiter.Worker.ReviewVerification.anti_stale_reflag_block()}
           After you post the review to the tracker, print your conclusion on its
           own line, EXACTLY one of:

               VERDICT: APPROVE
               VERDICT: REQUEST_CHANGES

           If you REQUEST_CHANGES you MUST have posted an ENUMERATED list of concrete
           findings through the tracker CLI — each with a severity, a location, and a
           suggested fix. A REQUEST_CHANGES verdict that names no findings is invalid.

           #{Arbiter.Worker.ReviewVerification.disclosure_block()}
           Then print, on a line by itself:

               arb done
           """
  end

  test "review checkout with no known base branch falls back to the tracker CLI for the diff" do
    prompt =
      PromptBuilder.prompt_for_task(task(%{}),
        review: true,
        review_checkout: %{
          path: "/tmp/wt-review",
          branch: "bugfix/bd-golden1",
          head_sha: "abc123def456",
          base_branch: nil
        }
      )

    assert prompt =~ "throwaway git worktree checked out DETACHED"

    assert prompt =~
             "  1. Read the diff under review via the configured tracker's CLI (`gh pr\n" <>
               "     diff <ref>` for GitHub, `glab mr diff <ref>` for GitLab)."

    refute prompt =~ "git diff origin/"
  end

  test "prompt_for_task/2 delegates through Dispatch identically" do
    t = task(%{})

    assert PromptBuilder.prompt_for_task(t, worktree_path: "/tmp/wt-x") ==
             Arbiter.Worker.Dispatch.prompt_for_task(t, worktree_path: "/tmp/wt-x")

    assert PromptBuilder.conflict_resolve_briefing(t, "feature/x", "main") ==
             Arbiter.Worker.Dispatch.conflict_resolve_briefing(t, "feature/x", "main")
  end
end
