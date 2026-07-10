#!/bin/sh
# Fixture for bd-ofql8k: simulates the root-cause failure mode. The worker
# EDITS a file in its worktree correctly, prints "arb done"... but never
# `git commit`s, so HEAD stays at the base branch with the work uncommitted.
# Before bd-ofql8k the ReviewGate then diffed `base..HEAD`, saw empty, and
# reported "no code exists" while sitting on the very changes it claimed
# were missing.
set -e
echo "work the worker forgot to commit" > forgotten_work.txt
# Deliberately NO `git add` / `git commit` — that is the whole point.
echo "arb done"
exit 0
