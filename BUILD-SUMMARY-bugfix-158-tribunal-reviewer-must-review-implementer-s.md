# BUILD SUMMARY — bugfix/158-tribunal-reviewer-must-review-implementer-s

**Bead:** bd-1mksks  
**Branch:** bugfix/158-tribunal-reviewer-must-review-implementer-s

## What was done

Fixed two failure modes where the Tribunal reviewer would see an empty diff
and incorrectly report "no work done," plus added explicit HEAD SHA anchoring
so the reviewed commit is always provable.

### Failure modes addressed

**(B) Timing race / revise-round gap**: The polecat commit gate (bd-ofql8k)
guards the INITIAL implementer's completion but the revise-round implementer
polecat bypasses it — its meta has no `worktree_path`, so `commit_gate/1`
skips. A revise implementer that prints `arb done` without committing would
hand the next reviewer an empty diff.

**(C) Stale HEAD**: The reviewer always runs in the same worktree as the
implementer (shared `worktree_path`) so there is no stale-remote-ref issue
in the local-only setup. The risk is more the reviewer not knowing which
commit to verify it's on.

### Changes — `tribunal.ex`

1. **`reviewer_commit_check/1`** (new): before spawning any reviewer (first
   review or re-review), verify the branch has ≥1 commit ahead of the target
   branch. If not, escalate immediately as REQUEST_CHANGES. Uses the same
   branch-guard as the polecat gate: only fires when the worktree is checked
   out on the per-bead branch, avoiding false positives from test setups that
   reuse the rig repo with HEAD on main.

2. **`head_sha: nil` in state**: the HEAD SHA at reviewer-spawn time is
   captured via `current_head_sha_in/1` and stored. Propagated through revise
   rounds in `finish_revise/1`.

3. **`head_sha_instruction/1`** (new): embeds the verified SHA into
   `review_prompt/1` (and transitively `rereview_prompt/1` and
   `verdict_reprompt_prompt/1`). The reviewer is told the expected SHA and
   instructed to verify `git log --oneline -1` matches before diffing.

4. **`note_head_change/1`** (new): called in `finish_revise/1` after the
   revise implementer exits. Compares old `head_sha` to the current HEAD.
   Appends a system entry to `state.thread` (in-memory; NOT persisted to
   durable mailbox) noting whether new commits landed or the round was a
   rebuttal only. The next reviewer sees this in `rereview_prompt/1`.

5. **`handle_continue(:spawn_reviewer)`**: now calls `reviewer_commit_check/1`
   first; only proceeds to spawn the reviewer on `{:ok, head_sha}`.

### Architecture note

Reviewer and implementer share one worktree — confirmed in `spawn_tribunal`
and `start_acolyte_session`: both receive `worktree_path: state.worktree_path`
(the same physical directory). No git fetch is needed for the local-only
setup; the shared worktree means local commits are immediately visible.

### Changes — `tribunal_test.exs`

3 new tests:

- **Pre-spawn commit gate escalates on a zero-commit worktree**: uses a git
  sub-worktree checked out on a branch with 0 commits ahead of main, bypasses
  the polecat gate by omitting worktree_path from polecat meta, then directly
  starts a Tribunal. Verifies the Tribunal escalates as `tribunal_rejected`
  without spawning a reviewer.

- **`review_prompt` includes the HEAD SHA when worktree is on the expected
  branch**: creates a commit, passes `head_sha` in state, checks prompt.

- **`review_prompt` omits the HEAD SHA anchor when `head_sha` is nil**: covers
  the ad-hoc / no-worktree path.

## What was punted

- **git fetch before review**: the local-only architecture doesn't need it.
  If a remote-push workflow is added later, a best-effort `git fetch` could
  be inserted in `reviewer_commit_check/1` before `has_commits_ahead?`.

- **Commit gate for revise implementer's polecat**: the Tribunal's internal
  gate covers this now. The polecat itself could be enhanced to carry
  `worktree_path` for revise-round spawns, but that's a separate concern.

## Test results

34 tribunal tests, 0 failures (31 pre-existing + 3 new). No regressions in
the full suite beyond the 8 pre-existing unrelated failures.
