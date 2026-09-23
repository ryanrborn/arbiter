#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker for bd-28u8v4 — the round-1
# REVIEWER pass-timer collision (the sibling of `revise_slow_then_fast.sh` /
# `review_reject_twice.sh`, which cover the IMPLEMENTER side). Pass 1
# (round-1 reviewer, `attempt` 1) sleeps close to the per-pass timeout before
# REQUEST_CHANGES; every later pass (round-2+ reviewer, `attempt` 1 again —
# `dispatch_next_review/2` resets `attempt` per round) sleeps briefly before
# APPROVE. Paired with an implementer that commits immediately, this drives a
# round-1 reviewer timer to fire WHILE the round-2 reviewer — at the same
# `attempt` number — is still mid-flight, without ever depending on the
# implementer pass to absorb the collision.
#
# `$1` is the sleep duration in tenths of a second for the FIRST (round-1)
# pass; `$2` is the sleep duration in tenths of a second for every LATER
# pass (default 0). A counter (kept in `.git`, so it never shows up in `git
# status --porcelain`) tells the passes apart.
sleep_tenths_1="${1:-19}"
sleep_tenths_later="${2:-0}"
git_dir="$(git rev-parse --git-dir)"
counter_file="$git_dir/review_reject_slow_then_approve_fast_pass"
pass=0
[ -f "$counter_file" ] && pass="$(cat "$counter_file")"
pass=$((pass + 1))
echo "$pass" > "$counter_file"

if [ "$pass" -eq 1 ]; then
  sleep_tenths="$sleep_tenths_1"
else
  sleep_tenths="$sleep_tenths_later"
fi

if [ "$sleep_tenths" -gt 0 ]; then
  whole=$((sleep_tenths / 10))
  tenth=$((sleep_tenths % 10))
  sleep "${whole}.${tenth}"
fi

if [ "$pass" -eq 1 ]; then
  echo "reviewing pass $pass: rejecting"
  echo "VERDICT: REQUEST_CHANGES"
  echo "findings: [high] guard.txt:1 needs another pass"
  echo "arb done"
else
  echo "reviewing pass $pass: approving"
  echo "VERDICT: APPROVE"
  echo "DISPOSITIONS:"
  echo "- [ADDRESSED] F1.1 — anchored in guard.txt:1 on the round-1 revise"
  echo "findings: none"
  echo "arb done"
fi
exit 0
