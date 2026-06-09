#!/bin/sh
# Fixture: a reviewer that produces a content-free REQUEST_CHANGES in the middle
# of a revise-and-rediscuss loop (bd-79goxj). Used to verify that an
# empty-findings verdict does not consume a revision round.
#
# Pass 1 (round 1 reviewer):  REQUEST_CHANGES with real findings.
# Pass 2 (round 2 reviewer):  REQUEST_CHANGES with NO findings (malformed).
# Pass 3 (round 2 re-prompt): REQUEST_CHANGES with real findings.
# Pass 4+ (round 3 reviewer): $1 verdict (default APPROVE).
#
# Marker files in the CWD (the shared worktree, unique per test run) track which
# pass is running. Stands in for a real `claude --print` reviewer.
verdict="${1:-APPROVE}"
marker1="./.rounds_empty_mid_pass1"
marker2="./.rounds_empty_mid_pass2"
marker3="./.rounds_empty_mid_pass3"

if [ ! -f "$marker1" ]; then
  : > "$marker1"
  echo "VERDICT: REQUEST_CHANGES"
  echo "findings: [high] feature.txt:1 missing guard"
  echo "arb done"
elif [ ! -f "$marker2" ]; then
  : > "$marker2"
  # Content-free verdict — the bug this fixture exercises.
  echo "VERDICT: REQUEST_CHANGES"
  echo "arb done"
elif [ ! -f "$marker3" ]; then
  : > "$marker3"
  # Re-prompt for round 2: real findings this time.
  echo "VERDICT: REQUEST_CHANGES"
  echo "findings: [medium] feature.txt:1 guard logic needs adjustment"
  echo "arb done"
else
  # Round 3 reviewer (only reached after the fix extends max_rounds to 3).
  echo "VERDICT: ${verdict}"
  echo "all findings addressed, change looks good"
  echo "arb done"
fi
exit 0
