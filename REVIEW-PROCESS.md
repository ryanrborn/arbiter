# Peer-review process for arbiter

This repo is local-only (no GitHub). Peer review happens via markdown files in `reviews/`. This doc defines the convention.

## Roles

- **Builder Acolyte** (polecat) — writes the code, opens a branch, writes a self-summary
- **Reviewer Acolyte** (polecat) — reads the diff, writes a structured review, gives a verdict
- **Admiral** (mayor) — dispatches Acolytes, mediates disagreements, merges when reviewer approves

## Flow

```
1. Admiral slings a Directive to a builder Acolyte
   → builder works in worktree at ~/dev/arbiter-worktrees/<branch-name>/
   → builder commits + pushes branch (still local)
   → builder writes BUILD-SUMMARY-<branch>.md and commits to the branch

2. Admiral slings a review Directive to a reviewer Acolyte
   → reviewer checks out the branch into its own worktree
   → reviewer runs `git diff main..<branch>` and reads
   → reviewer writes reviews/<branch>.md (see template below)
   → reviewer commits the review file to MAIN (not the feature branch)

3. If reviewer requests changes:
   → Admiral re-slings the builder Directive with the review findings
   → Builder addresses, updates BUILD-SUMMARY, pushes
   → Reviewer re-reviews (appends to existing review file)

4. When reviewer approves:
   → Admiral merges the feature branch into main via `git merge --squash --ff-only`
   → Admiral closes the Directive
   → Worktree cleaned up
```

## Review file template

`reviews/<branch-name>.md`:

```markdown
# Review: <branch-name>

**Directive:** bd-NNNNNN
**Builder:** server/<acolyte-name>
**Reviewer:** server/<other-acolyte-name>
**Date:** YYYY-MM-DD HH:MM

## Diff summary
<reviewer's 1-paragraph summary of what changed>

## Acceptance criteria check
- [ ] <criterion 1 from the Directive>
- [x] <criterion 2 from the bead>
...

## Findings
### Required (must address before merge)
- **<file>:<line>** — <description of issue>

### Suggested (nice to have)
- **<file>:<line>** — <suggestion>

### Praise (good patterns to keep)
- <thing reviewer wants the builder to remember>

## Code quality checks
- [ ] mix compile clean
- [ ] mix test green
- [ ] mix format --check-formatted
- [ ] mix credo --strict clean
- [ ] mix dialyzer clean (if applicable)
- [ ] No new TODO comments without bead references
- [ ] Acceptance criteria covered by tests

## Verdict
**[APPROVED / CHANGES_REQUESTED / NEEDS_ADMIRAL]**

<one-sentence rationale>
```

## Reviewer rules

- **Do not push code.** Only the builder writes code. Reviewer writes the review file.
- **Cite specifics.** Vague feedback ("looks weird") is forbidden. Always cite file:line + what specifically.
- **Match Directive scope.** Don't request features the Directive didn't ask for. File a follow-up Directive instead.
- **Escalate, don't guess.** If reviewer can't tell whether something is right, verdict = `NEEDS_ADMIRAL` with a clear question.
- **Run the gate suite.** Don't rely on the builder's claim. Re-run the checks.

## Builder rules

- **Self-check before requesting review.** Run the full gate suite locally before saying "ready to review."
- **Write the BUILD-SUMMARY.** What you did, what you punted on (with reasons), what you noticed could be improved separately.
- **Respond to every finding.** Even if to disagree. Reviewer's findings live in the review file; your responses go in BUILD-SUMMARY.

## Admiral rules

- **Don't merge with open `Required` findings.** Even if you'd write the code differently than the reviewer suggested, the reviewer's call stands until they re-review.
- **Merge with `--squash --ff-only`.** Keeps main history linear. The branch's commit messages are subsumed into a single squash commit referencing the Directive.
- **Close the Directive with a link to the merge commit.**
- **Archive the worktree.** Delete the local worktree after merge; the branch ref stays in git for history.

## Escalation triggers

Admiral pings human (Ryan) when:
- Reviewer + builder disagree after 2 cycles
- Reviewer verdict is `NEEDS_ADMIRAL`
- Directive grew >2× its original scope
- An architectural decision not in the decision doc surfaces
- Tooling bugs eat >2 hours on a single dispatch
- Anything destructive (force-push, schema drop, etc.)
- End of each phase → demo + go/no-go

## Admiral-as-builder special case

When the Admiral (current session) does work directly (rather than dispatching an Acolyte), the same review process applies — but the reviewer must be a fresh Acolyte or a fresh Admiral session, NOT the same session that built it.

For overnight autonomous work where Ryan is AFK: Admiral commits the work on a branch with a clear `BUILD-SUMMARY-<branch>.md`, but does NOT merge to main until reviewed in the morning. Ryan or a fresh reviewer Acolyte reviews and approves before any merge.
