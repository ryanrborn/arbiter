#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker that reports whether the head it is
# reading is actually ON `origin/<branch>` — the bd-2jkrqu question.
#
# The vs-5l45oz incident had the reviewer read a local-only commit and APPROVE
# it while the MR still held the unfixed code. A fixture that merely emitted a
# canned verdict could not tell the fix from the bug, so this one *checks*:
# the verdict itself encodes the push state the reviewer saw.
#
#   $1 — branch name to compare against (`origin/$1`).
#   $2 — "ROUND1" (default): a single pass; APPROVE iff the head is pushed.
#        "ROUND2": round 1 always REQUEST_CHANGES with a Medium finding on
#        guard.txt (the file `revise_commit.sh` really touches), and round 2
#        APPROVEs — dispositioning that finding — iff the fix-round head is
#        pushed.
#
# Stands in for a real `claude --print` reviewer; never invokes the paid CLI.
branch="${1:-main}"
mode="${2:-ROUND1}"
marker="$(git rev-parse --git-common-dir)/review_gate_push_check_attempt"
# Sentinel: proves the reviewer really ran, so a test can assert it did NOT.
: > "$(git rev-parse --git-common-dir)/review_gate_push_check_ran"

local_head="$(git rev-parse HEAD 2>/dev/null)"
remote_head="$(git rev-parse "origin/$branch" 2>/dev/null)"

pushed=no
if [ -n "$remote_head" ] && [ "$local_head" = "$remote_head" ]; then
  pushed=yes
fi

if [ "$mode" = "ROUND2" ] && [ ! -f "$marker" ]; then
  : > "$marker"
  echo "reviewing the diff for the first time"
  echo "VERDICT: REQUEST_CHANGES"
  echo "- **Medium**: the over-match guard is missing (guard.txt:1)."
  echo "  Suggested fix: anchor the match instead of using a bare contains check."
  echo "VERIFICATION: FULL"
  echo "arb done"
  exit 0
fi

echo "reviewing head $local_head against origin/$branch $remote_head"

if [ "$pushed" = "yes" ]; then
  echo "VERDICT: APPROVE"
  if [ "$mode" = "ROUND2" ]; then
    echo "DISPOSITIONS:"
    echo "- [ADDRESSED] F1.1 — the guard now lands in guard.txt:1"
  fi
else
  echo "VERDICT: REQUEST_CHANGES"
  echo "- **High**: UNPUSHED-HEAD — this pass read $local_head, which is not on"
  echo "  origin/$branch ($remote_head). The PR does not carry the reviewed code."
fi

echo "VERIFICATION: FULL"
echo "arb done"
exit 0
