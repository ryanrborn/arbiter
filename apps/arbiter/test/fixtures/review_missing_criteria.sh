#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker that issues a bare holistic
# `VERDICT: APPROVE` on a criteria-bearing task WITHOUT any CRITERIA breakdown
# at all — it judges the diff's code quality and never accounts for the stated
# acceptance criteria. This is the original bug's exact shape (bd-4yhv4x
# occurrences #1/#2). ReviewGate must NOT clean-merge such an APPROVE: with
# criteria present but no per-criterion breakdown it must re-prompt / route to
# reject, the same fail-closed treatment the unmet-criteria guard gives.
#
#   $1 — what to emit on the re-prompt pass:
#        "MET"     — supply the missing breakdown, marking every criterion
#                    `- [MET]`, so the re-prompt converges to a clean APPROVE.
#        "MISSING" (default) — keep emitting a bare APPROVE with no breakdown so
#                    the gate exhausts its retry budget and proceeds to reject.
#
# A marker file in the CWD (the reviewer's worktree, unique per test) tells the
# first pass apart from later ones — ReviewGate re-runs this same argv, so the
# script itself must remember it already ran. Stands in for a real `claude
# --print` reviewer so tests never invoke the paid CLI.
retry="${1:-MISSING}"
marker="./.review_gate_missing_criteria_attempt"

if [ -f "$marker" ]; then
  # Re-prompt pass.
  case "$retry" in
    MET)
      echo "re-reviewing the diff against each acceptance criterion"
      echo "VERDICT: APPROVE"
      echo "CRITERIA:"
      echo "- [MET] Criterion one — implemented in feature.txt and exercised by the added test"
      echo "- [MET] Criterion two — the second path is now covered end to end"
      echo "VERIFICATION: FULL"
      echo "arb done"
      ;;
    *)
      echo "re-reviewing; the diff still looks clean to me"
      echo "VERDICT: APPROVE"
      echo "VERIFICATION: FULL"
      echo "arb done"
      ;;
  esac
else
  # First pass: a holistic APPROVE with no CRITERIA breakdown whatsoever — the
  # exact "judges code quality, not criteria satisfaction" bug this guard closes.
  : > "$marker"
  echo "reviewing the diff; the code quality looks fine and the tests are green"
  echo "VERDICT: APPROVE"
  echo "VERIFICATION: FULL"
  echo "arb done"
fi
exit 0
