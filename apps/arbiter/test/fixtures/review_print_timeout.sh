#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker running on agy whose print-mode
# turn hit agy's own internal --print-timeout mid-review — it prints agy's
# fixed timeout warning (no VERDICT line, since the turn was cut off before
# producing one) and exits ZERO, the same way agy reports this case for real
# (bd-1xss5z): the CLI still emits a terminal "SUCCESS" result for a turn it
# cut short. Exercises the reviewing-phase print-timeout classification: the
# ReviewGate must recognize this as an infrastructure failure (a timeout, not
# a reviewer that simply omitted its VERDICT line) and escalate with the real
# reason instead of silently re-prompting the same session, which would hit
# the same 5-minute wall identically.
#
# Always fails this way — no marker/retry-pass branch — since a verdict
# re-prompt starts a fresh session that hits the same print-timeout wall.
echo "reviewing the diff..."
echo "[agy] print timeout after 5m0s with turn in progress; returning partial output"
echo "gemini session SUCCESS · 297s · ~300k tok"
exit 0
