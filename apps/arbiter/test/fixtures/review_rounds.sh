#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker for the Stage 2 revise-and-rediscuss
# loop (bd-3jm700). It REQUEST_CHANGES on its first pass, then emits $1 on every
# later pass — so a test can drive "reject once, then converge / keep rejecting".
#
#   $1 — the verdict for round 2+ : "APPROVE" (converge → merge) or
#        "REQUEST_CHANGES" (hold the line → escalate after the cap). Default
#        APPROVE.
#
# A marker file in the CWD (the shared worktree, unique per test) tells the first
# pass apart from later ones — the ReviewGate spawns a fresh reviewer mind per
# round, so the script itself must remember it already ran. The implementer
# fixture runs in the same CWD between passes but uses a different marker name.
# Stands in for a real `claude --print` reviewer so tests never invoke the paid
# CLI.
#
# Round 2+ carries a DISPOSITIONS block accounting for the round-1 finding
# (bd-6r8caj): an APPROVE that leaves a prior Medium+ finding undispositioned is
# now rejected. The disposition is `[OBSOLETE]` rather than `[ADDRESSED]` because
# the paired `revise.sh` implementer only argues — it commits nothing — so an
# "addressed" claim would (correctly) fail the mechanical no-diff backstop. A
# reviewer persuaded by a rebuttal is exactly the case `[OBSOLETE]` exists for.
later_verdict="${1:-APPROVE}"
marker="./.review_gate_round_attempt"

if [ -f "$marker" ]; then
  echo "re-reviewing the updated diff after the implementer's revision"
  echo "VERDICT: ${later_verdict}"
  echo "DISPOSITIONS:"
  echo "- [OBSOLETE] F1.1 — the rebuttal stands; the guard this asked for is unnecessary here"
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
