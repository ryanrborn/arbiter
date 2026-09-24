#!/bin/sh
# Fixture: an IMPLEMENTER worker for bd-28u8v4 — the round-1 pass timer
# collision. The round-1 revise pass sleeps for most of the per-pass
# `review_timeout_ms` budget (but still comfortably within it) before
# committing; the round-2 revise pass commits immediately. Paired with
# `review_reject_twice.sh` (the reviewer, which rejects rounds 1 and 2 then
# approves), this reproduces the exact collision from bd-28u8v4: round 1's
# implementer and round 2's implementer are both the SECOND pass launched in
# their own round (`attempt` 2), so a timer armed for round 1's implementer
# and never cancelled/disambiguated would fire while round 2's implementer is
# still well within its own fresh budget.
#
# `$1` is the sleep duration in tenths of a second for the FIRST (round-1)
# pass; `$2` is the sleep duration in tenths of a second for the SECOND
# (round-2) pass (default 0). Every later pass commits immediately. A counter
# (kept in `.git`) tells the passes apart.
sleep_tenths_1="${1:-13}"
sleep_tenths_2="${2:-0}"
git_dir="$(git rev-parse --git-dir)"
counter_file="$git_dir/revise_slow_then_fast_pass"
pass=0
[ -f "$counter_file" ] && pass="$(cat "$counter_file")"
pass=$((pass + 1))
echo "$pass" > "$counter_file"

sleep_tenths=0
if [ "$pass" -eq 1 ]; then
  sleep_tenths="$sleep_tenths_1"
elif [ "$pass" -eq 2 ]; then
  sleep_tenths="$sleep_tenths_2"
fi

if [ "$sleep_tenths" -gt 0 ]; then
  # sleep supports fractional seconds via a tenths-to-decimal conversion.
  whole=$((sleep_tenths / 10))
  tenth=$((sleep_tenths % 10))
  sleep "${whole}.${tenth}"
fi

echo "implementer: addressing the reviewer's findings on this branch (pass $pass)"
echo "anchored guard (pass $pass)" >> guard.txt
git add guard.txt >/dev/null 2>&1
git -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q -m "address reviewer finding F1.1 (pass $pass)" >/dev/null 2>&1
echo "FIXED: anchored the match in guard.txt:1 (pass $pass)"
echo "arb done"
exit 0
