#!/bin/sh
# Fixture: the bd-6r8caj / #1137 shape — a reviewer that raises a real Medium
# finding in round 1 and then, in round 2, returns `VERDICT: APPROVE` /
# `VERIFICATION: FULL` without ever accounting for that finding. Reproduces the
# observed bd-8mtb0q (#1132) failure, where the implementer round produced an
# EMPTY diff for the cited file and the gate approved anyway in 94.7s.
#
#   $1 — what round 2+ emits:
#        "BLIND" (default) — APPROVE with no DISPOSITIONS block at all. The gate
#                  must NOT honor this: the round-1 finding was never addressed.
#        "ADDRESSED" — APPROVE with `- [ADDRESSED] F1.1`, naming guard.txt (the
#                  file the paired `revise_commit.sh` implementer really changed),
#                  so the gate converges legitimately.
#        "OBSOLETE" — APPROVE with `- [OBSOLETE] F1.1`, the escape hatch for a
#                  finding a different change invalidated (AC5): must also merge.
#        "NOT_ADDRESSED" — APPROVE that openly admits `- [NOT ADDRESSED] F1.1`.
#                  An approval that admits an open Medium finding must be
#                  rejected the same way an admitted `[NOT MET]` criterion is.
#
# A marker file in the CWD (the reviewer's worktree, unique per test) tells the
# first pass apart from later ones — ReviewGate spawns a fresh reviewer mind per
# round, so the script itself must remember it already ran. Stands in for a real
# `claude --print` reviewer so tests never invoke the paid CLI.
mode="${1:-BLIND}"
marker="./.review_gate_unaddressed_attempt"

if [ -f "$marker" ]; then
  echo "re-reviewing the updated diff after the implementer's revision"
  echo "VERDICT: APPROVE"
  case "$mode" in
    ADDRESSED)
      echo "DISPOSITIONS:"
      echo "- [ADDRESSED] F1.1 — the guard now lands in guard.txt:1"
      ;;
    OBSOLETE)
      echo "DISPOSITIONS:"
      echo "- [OBSOLETE] F1.1 — the branch that could over-match was deleted wholesale"
      ;;
    NOT_ADDRESSED)
      echo "DISPOSITIONS:"
      echo "- [NOT ADDRESSED] F1.1 — still unguarded, but the rest of the diff reads fine"
      ;;
    *)
      # BLIND: the defect. An approval with no disposition for F1.1 at all.
      echo "The change looks good; no issues found."
      ;;
  esac
  echo "VERIFICATION: FULL"
  echo "arb done"
else
  : > "$marker"
  echo "reviewing the diff for the first time"
  echo "VERDICT: REQUEST_CHANGES"
  echo "- **Medium**: the over-match guard is missing (guard.txt:1)."
  echo "  Suggested fix: anchor the match instead of using a bare contains check."
  echo "VERIFICATION: FULL"
  echo "arb done"
fi
exit 0
