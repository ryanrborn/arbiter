#!/bin/sh
# Fixture: a reviewer that produces a content-free REQUEST_CHANGES on the LAST
# allowed round of a 3-round (default-difficulty) revise-and-rediscuss loop.
# Tests the bd-40v3w1 scenario: empty-findings at round 3 of 3 must not consume
# that round — the re-prompt's real findings must still reach the implementer, and
# a round-4 reviewer (max_rounds extended to 4) then approves → merge.
#
# Pass 1 (round 1 reviewer):  REQUEST_CHANGES with real findings.
# Pass 2 (round 2 reviewer):  REQUEST_CHANGES with real findings.
# Pass 3 (round 3 reviewer):  REQUEST_CHANGES with NO findings (malformed).
# Pass 4 (round 3 re-prompt): REQUEST_CHANGES with real findings.
# Pass 5+ (round 4 reviewer): $1 verdict (default APPROVE).
#
# Marker files in the CWD (the shared worktree, unique per test run) track which
# pass is running. Stands in for a real `claude --print` reviewer.
verdict="${1:-APPROVE}"
M1="./.rounds_empty_last_m1"
M2="./.rounds_empty_last_m2"
M3="./.rounds_empty_last_m3"
M4="./.rounds_empty_last_m4"

if [ ! -f "$M1" ]; then
  touch "$M1"
  echo "VERDICT: REQUEST_CHANGES"
  echo "findings: [high] feature.txt:1 missing nil guard"
  echo "arb done"
elif [ ! -f "$M2" ]; then
  touch "$M2"
  echo "VERDICT: REQUEST_CHANGES"
  echo "findings: [medium] feature.txt:1 guard expression incomplete"
  echo "arb done"
elif [ ! -f "$M3" ]; then
  touch "$M3"
  # Content-free verdict in the LAST allowed round — the bd-40v3w1 scenario.
  # Includes the real ⚙ session-stats footer that the harness appends so that
  # findings_present?/1 must strip it (bd-3n1j8m regression).
  echo "VERDICT: REQUEST_CHANGES"
  echo "arb done"
  echo "⚙ claude session success · 183.5s · \$1.1489"
elif [ ! -f "$M4" ]; then
  touch "$M4"
  # Re-prompt for round 3: real findings this time.
  echo "VERDICT: REQUEST_CHANGES"
  echo "findings: [low] feature.txt:1 guard wording could be clearer"
  echo "arb done"
else
  # Round 4 reviewer (only reached after the fix extends max_rounds to 4).
  echo "VERDICT: ${verdict}"
  echo "all findings addressed, change looks good"
  echo "arb done"
fi
exit 0
