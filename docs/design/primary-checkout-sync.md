# Primary-Checkout Sync on Merge — Design Note

**Status:** implemented
**Last updated:** 2026-07-31
**Task:** bd-bqqnin

---

## Problem

A workspace's `repo_paths`/`rig_paths` config points at a repo's *primary*
local checkout — a shared directory a human/coordinator may `cd` into
directly, distinct from a worker's isolated per-task worktree. Before this
change, nothing in Arbiter ever fast-forwarded that checkout's local branch
after a merge.

`Arbiter.Worker.Worktree.fetch_origin/2`, called from `Dispatch` before
provisioning work into a shared checkout, keeps `refs/remotes/origin/<base>`
fresh — but its own docstring is explicit that this is refs-only: it never
touches HEAD, the index, the working tree, or any local branch. So a plain
`git log`/`git status` run directly in the primary checkout kept drifting
further behind `origin/main` with every merge, with nothing to signal the
drift.

This produced a real incident: a `task`-type worker read a primary checkout
about a month stale and confidently reported already-shipped PHI-encryption
work as unmerged (bd-87qv66 / see `feedback-audit-worker-stale-checkout-false-positive.md`
in project memory).

## Design

### Where it hooks in

`Arbiter.Workflows.MergeQueue.close_task_and_finalize/2` is the single
funnel every merge-success path already routes through — a fresh
`adapter.merge/1` call, a poll that discovers the MR was merged externally,
and the `strategy: "direct"` (no-PR, worker-pushed) path alike. A new
`safe_sync_primary_checkout/2` call was added there, following the same
`rescue`/`catch :exit` "never crash the merge queue" shape as the module's
existing `safe_notify_resolution/2` and `safe_escalate/4` helpers.

### Safety model

`Arbiter.Worker.PrimarySync.fast_forward/2` performs the actual sync. It
only ever does a zero-risk fast-forward — the equivalent of
`git pull --ff-only` — and skips (not errors) otherwise:

1. Fetch `origin/<base>` fresh (reuses `Worktree.fetch_origin/2`).
2. If the checkout isn't currently *on* `base_branch` → `{:skipped, :not_on_default_branch}`.
3. If the working tree has any uncommitted changes (staged, unstaged, or
   untracked — reuses `Worktree.has_uncommitted?/1`) → `{:skipped, :uncommitted_changes}`.
4. Otherwise attempt `git merge --ff-only origin/<base>`. If history has
   diverged (or local is already ahead) → `{:skipped, :not_fast_forwardable}`.
5. Already at the tip → `:ok`, no-op.

None of the skip paths touch the checkout in any way — no reset, no stash,
no branch switch. A human mid-work in that checkout is never at risk of
losing anything.

### Opt-in, not on-by-default

`Workspace.auto_sync_primary?/1` reads `config["merge"]["auto_sync_primary"]`
(default `false`), mirroring the existing `auto_merge?/1` boolean-flag
pattern — a JSON key, no migration required. Fast-forwarding a checkout a
human may have open is powerful enough (even constrained to safe
fast-forwards) that it should be an explicit per-workspace choice, not a
silent behavior change for every existing workspace. See
`ARBITER_OPERATOR.md` §6 (Freshness) for the operator-facing explanation and
how to turn it on (`arb config set merge.auto_sync_primary true`).

### Repo-path resolution

`repo_paths`/`rig_paths` values are a JSON map keyed by the same `repo`
string `MergeQueue` items already carry (`item.repo`, resolved from the
task's most recent worker run). The lookup — exact key match, falling back
to a normalized underscore/hyphen-insensitive match — previously lived only
as a private helper in `Arbiter.Worker.Dispatch`. It's now
`Arbiter.Tasks.RepoConfig.find_path/2`, a shared public helper; `Dispatch`
was refactored to delegate to it (behavior-preserving) rather than
duplicating the logic for `MergeQueue`.

## What this does *not* do

- It never touches a worker's isolated per-task worktree — those are always
  freshly branched from `origin/<base>` at creation time and are unaffected.
- It does not run for a repo with no `auto_sync_primary` opt-in, or with no
  primary checkout registered in `repo_paths`/`rig_paths` for the merged
  repo key.
- It is best-effort: a git failure (missing repo, missing `origin` remote,
  fetch failure) is logged as a warning and never blocks task close or
  crashes the merge queue.
