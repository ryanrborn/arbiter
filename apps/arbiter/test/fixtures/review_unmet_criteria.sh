#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker that issues `VERDICT: APPROVE` but
# whose per-criterion CRITERIA breakdown discloses at least one `- [NOT MET]`
# acceptance criterion. Exercises the unmet-criteria guard (bd-4yhv4x):
# ReviewGate must NOT clean-merge an APPROVE whose own criteria breakdown shows
# unmet acceptance criteria — it must re-prompt / route to revise instead, the
# same fail-closed treatment the partial-verification guard gives.
#
#   $1 — what to emit on the re-prompt pass:
#        "MET"   — mark every criterion `- [MET]` so the re-prompt converges to
#                  a clean, fully-satisfied APPROVE.
#        "UNMET" (default) — keep disclosing a `- [NOT MET]` criterion so the
#                  second unmet-criteria result proceeds down the reject path.
#
# A marker file in the CWD (the reviewer's worktree, unique per test) tells the
# first pass apart from later ones — ReviewGate re-runs this same argv, so the
# script itself must remember it already ran. Stands in for a real `claude
# --print` reviewer so tests never invoke the paid CLI.
retry="${1:-UNMET}"
marker="./.review_gate_unmet_criteria_attempt"

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
      echo "re-reviewing; the second criterion is still not satisfied"
      echo "VERDICT: APPROVE"
      echo "CRITERIA:"
      echo "- [MET] Criterion one — implemented in feature.txt"
      echo "- [NOT MET] Criterion two — still no coverage for the second path"
      echo "VERIFICATION: FULL"
      echo "arb done"
      ;;
  esac
else
  # First pass: approves on code quality but its own criteria breakdown admits
  # one criterion is not met — the exact bug this guard closes.
  : > "$marker"
  echo "reviewing the diff; the code quality looks fine"
  echo "VERDICT: APPROVE"
  echo "CRITERIA:"
  echo "- [MET] Criterion one — implemented in feature.txt"
  echo "- [NOT MET] Criterion two — the diff does not deliver the second path at all"
  echo "VERIFICATION: FULL"
  echo "arb done"
fi
exit 0
