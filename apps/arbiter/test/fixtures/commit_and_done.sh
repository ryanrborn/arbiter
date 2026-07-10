#!/bin/sh
# Fixture: simulates a --with-claude worker that does real work. Runs with the
# worker's worktree as cwd, makes a commit on the per-bead branch, then emits
# the "arb done" completion marker. Used by CompletionMergeTest to prove the
# completion path integrates the branch (git merge --no-ff) into main.
set -e
git config user.email "worker@example.com"
git config user.name "Worker"
git config commit.gpgsign false
echo "work from the worker" > worker_work.txt
git add worker_work.txt
git commit -q -m "worker: implement the thing"
echo "arb done"
exit 0
