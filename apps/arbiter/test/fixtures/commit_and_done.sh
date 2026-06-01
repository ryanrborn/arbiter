#!/bin/sh
# Fixture: simulates a --with-claude acolyte that does real work. Runs with the
# polecat's worktree as cwd, makes a commit on the per-bead branch, then emits
# the "arb done" completion marker. Used by CompletionMergeTest to prove the
# completion path integrates the branch (git merge --no-ff) into main.
set -e
git config user.email "acolyte@example.com"
git config user.name "Acolyte"
git config commit.gpgsign false
echo "work from the acolyte" > acolyte_work.txt
git add acolyte_work.txt
git commit -q -m "acolyte: implement the thing"
echo "arb done"
exit 0
