#!/bin/sh
# Fixture for testing that the verdict retry budget resets per round (bd-79goxj).
# Simulates a multi-round review where empty-findings verdicts appear in BOTH
# round 1 and round 2 — verifying that round 2 gets its own reprompt even after
# round 1 already consumed the initial retry budget.
#
# Pass sequence (tracked by marker files in CWD = shared worktree):
#   1. No markers  → round 1, first pass  → empty findings (REQUEST_CHANGES, no body)
#   2. M1 only     → round 1, re-prompt   → REQUEST_CHANGES with real findings
#   3. M1+M2       → round 2, first pass  → empty findings (REQUEST_CHANGES, no body)
#   4. M1+M2+M3    → round 2, re-prompt   → $1 verdict (default APPROVE)
#
# $1 — the final verdict on the round 2 re-prompt: "APPROVE" (→ merge) or
#      "REQUEST_CHANGES" (→ escalate after cap). Default APPROVE.
#
# Stands in for a real `claude --print` reviewer so tests never invoke the CLI.
verdict="${1:-APPROVE}"
M1="./.trib_retry_reset_m1"
M2="./.trib_retry_reset_m2"
M3="./.trib_retry_reset_m3"

if [ ! -f "$M1" ]; then
  touch "$M1"
  echo "reviewing the diff for the first time (round 1)"
  echo "VERDICT: REQUEST_CHANGES"
  echo "arb done"
elif [ ! -f "$M2" ]; then
  touch "$M2"
  echo "re-prompted for round 1: now providing findings"
  echo "VERDICT: REQUEST_CHANGES"
  echo "findings: [high] feature.txt:1 needs a nil guard before merge"
  echo "arb done"
elif [ ! -f "$M3" ]; then
  touch "$M3"
  echo "reviewing the updated diff (round 2)"
  echo "VERDICT: REQUEST_CHANGES"
  echo "arb done"
else
  echo "round 2 re-prompt: looks good after both rounds of revision"
  echo "VERDICT: ${verdict}"
  echo "arb done"
fi
exit 0
