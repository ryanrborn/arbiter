#!/bin/sh
# Fixture: a reviewer (Tribunal) acolyte for the Stage 2 revise-and-rediscuss
# loop (bd-3jm700). It REQUEST_CHANGES on its first pass, then emits $1 on every
# later pass — so a test can drive "reject once, then converge / keep rejecting".
#
#   $1 — the verdict for round 2+ : "APPROVE" (converge → merge) or
#        "REQUEST_CHANGES" (hold the line → escalate after the cap). Default
#        APPROVE.
#
# A marker file in the CWD (the shared worktree, unique per test) tells the first
# pass apart from later ones — the Tribunal spawns a fresh reviewer mind per
# round, so the script itself must remember it already ran. The implementer
# fixture runs in the same CWD between passes but uses a different marker name.
# Stands in for a real `claude --print` reviewer so tests never invoke the paid
# CLI.
later_verdict="${1:-APPROVE}"
marker="./.tribunal_round_attempt"

if [ -f "$marker" ]; then
  echo "re-reviewing the updated diff after the implementer's revision"
  echo "VERDICT: ${later_verdict}"
  echo "findings: round-two assessment of the revised work"
  echo "arb done"
else
  : > "$marker"
  echo "reviewing the diff for the first time"
  echo "VERDICT: REQUEST_CHANGES"
  echo "findings: [high] feature.txt:1 needs a guard before it can merge"
  echo "arb done"
fi
exit 0
