#!/bin/sh
# Fixture: an IMPLEMENTER worker for the bd-2eyf9y commit-gate tests that edits
# a file but never commits it — unlike `revise.sh` (touches nothing) and
# `revise_commit.sh` (edits AND commits). Leaves the ReviewGate worktree dirty
# on exit so `finish_revise/1`'s commit gate must treat it as "uncommitted
# work", not "no changes at all". Stateless and safe to invoke twice in a row
# (the initial revise round and the one-shot commit-nudge retry): each run
# just rewrites the same untracked file, so the tree is dirty again either way.
# Never invokes the paid CLI.
echo "implementer: addressing the reviewer's findings on this branch"
echo "uncommitted guard" > dirty.txt
echo "FIXED: added the requested guard to feature.txt:1"
echo "arb done"
exit 0
