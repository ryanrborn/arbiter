#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker for bd-28u8v4 — the round-1 pass
# timer collision. REQUEST_CHANGES on its first TWO passes (round 1 and round
# 2), then APPROVE on every later pass. Paired with
# `revise_slow_then_fast.sh` (the implementer) to drive a gate through TWO
# revise rounds, so a round-1 implementer's stale timeout timer has a round-2
# implementer pass — at the same `attempt` number — to collide with.
#
# A counter (kept in `.git`, so it never shows up in `git status
# --porcelain`) tracks how many reviewing passes have run.
git_dir="$(git rev-parse --git-common-dir)"
counter_file="$git_dir/review_reject_twice_pass"
pass=0
[ -f "$counter_file" ] && pass="$(cat "$counter_file")"
pass=$((pass + 1))
echo "$pass" > "$counter_file"

if [ "$pass" -le 2 ]; then
  echo "reviewing pass $pass: rejecting"
  echo "VERDICT: REQUEST_CHANGES"
  echo "findings: [high] guard.txt:1 needs another pass"
  echo "arb done"
else
  echo "reviewing pass $pass: approving"
  echo "VERDICT: APPROVE"
  echo "DISPOSITIONS:"
  echo "- [ADDRESSED] F1.1 — anchored in guard.txt:1 on the round-1 revise"
  echo "- [ADDRESSED] F2.1 — anchored in guard.txt:1 on the round-2 revise"
  echo "findings: none"
  echo "arb done"
fi
exit 0
