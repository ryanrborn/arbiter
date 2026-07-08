defmodule Arbiter.Workflows.ReviewThreadFollowUp do
  @moduledoc """
  Shared "review thread follow-up protocol" instructions text (bd-76ydsu),
  folded into the briefing of every author-side follow-up dispatch:

    * `Arbiter.Workflows.PRPatrol.create_follow_up/3` — a NEW PR opened for a
      flagged PR (CHANGES_REQUESTED / unresolved threads).
    * `Arbiter.Workflows.MergeQueue.ReviseDispatcher.render_feedback/1` — a
      resumed worker pushing to the SAME PR/branch after a human
      CHANGES_REQUESTED review.

  Both dispatch a full autonomous coding-agent worker with `gh` CLI access —
  not an internal `Arbiter.Workflow` step-run — so the fix lives in prompt
  text instructing the worker to reply/resolve/escalate itself, mirroring
  (in spirit) `Arbiter.Workflows.ReviewReply`'s reply-to-review-comment
  plumbing and `Arbiter.Mergers.Merger.resolve_review_thread/3`.

  Root problem this addresses: a follow-up worker that implements every
  finding and pushes fixes but posts zero thread replies and resolves
  nothing leaves the human reviewer with no acknowledgement at all.

  Also covers the bd-7ezcqb gap: a reply that DEFERS work to a follow-up
  must not be posted unless that follow-up has actually been filed (via
  `arb create --parent <task-id>`) and its key cited in the reply — a
  promised-but-unfiled follow-up is a dangling commitment under the
  operator's name.
  """

  @doc """
  Renders the protocol instructions block for a follow-up dispatch briefing.

  `policy` is a plain map (workspace config already resolved by the caller),
  read with defaults so callers can pass `%{}`:

    * `:resolve_bot_threads` (default `true`) — resolve addressed bot/
      automated-reviewer threads (Copilot, `dependabot[bot]`, etc).
    * `:resolve_human_threads` (default `false`) — resolve addressed
      human-reviewer threads.
  """
  @spec instructions(map()) :: String.t()
  def instructions(policy) when is_map(policy) do
    resolve_bot? = Map.get(policy, :resolve_bot_threads, true)
    resolve_human? = Map.get(policy, :resolve_human_threads, false)

    """
    ## Review thread follow-up protocol (bd-76ydsu)

    Pushing a fix is not a complete response to a reviewer. For EACH review
    thread you addressed:

      1. Reply directly ON THAT THREAD (not a new top-level PR comment) with:
           "Addressed in <sha>: <one-line summary of what changed>"
         Use the forge CLI's thread-reply primitive (e.g.
         `gh api graphql -f query='mutation { addPullRequestReviewThreadReply(...) }'`
         or `gh pr comment --reply-to <comment-id>`) — a plain top-level
         comment does not satisfy this.

      2. Resolve policy:
           - Bot / automated-reviewer threads (Copilot, `dependabot[bot]`,
             other `[bot]` logins): #{bot_resolve_line(resolve_bot?)}
           - Human reviewer threads: #{human_resolve_line(resolve_human?)}
         Resolve via:
           `gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "<thread-id>"}) { thread { id isResolved } } }'`

    If a suggestion is WRONG or not applicable, do NOT implement it just to
    make the thread go away and do NOT fake an acknowledgement. Instead:
      * reply on the thread explaining, in your own words, why you're not
        making the change, AND
      * escalate to the coordinator mailbox so a human can weigh in.

    If instead you decide the right response is to DEFER the work (a
    follow-up, a separate PR, "later") rather than fix it now or push back:
    you MUST file that follow-up BEFORE you reply, and cite its key in the
    reply. A reply that promises future work ("I'll file a follow-up",
    "keeping this as a follow-up", "will track separately", etc.) posted
    without a filed, cited ticket is a dangling commitment under the
    operator's name and is NEVER acceptable (bd-7ezcqb) — do not post it.
      1. File it: `arb create <title> --parent <this task's id>` (this
         task's own id — the one you were dispatched with). If a tracker is
         configured this also files the upstream ticket; capture the printed
         `ID:` and, if present, `Tracker: <type>:<ref>` line.
      2. Reply ON THAT THREAD citing the filed key, e.g.:
           "Agreed — deferring this to a follow-up rather than folding it
            into this PR. Filed as <task-id> (<tracker-ref-if-any>)."
      3. Do NOT resolve a thread whose work was deferred, regardless of the
         resolve policy above — a deferred thread stays open until the
         filed follow-up lands.

    Never mark or imply a thread is addressed without an actual pushed fix
    and a posted reply.
    """
  end

  defp bot_resolve_line(true), do: "resolve it once you've replied"
  defp bot_resolve_line(false), do: "do NOT resolve — leave it to a human"

  defp human_resolve_line(true), do: "resolve it once you've replied"
  defp human_resolve_line(false), do: "do NOT resolve — leave it for the human reviewer to close"
end
