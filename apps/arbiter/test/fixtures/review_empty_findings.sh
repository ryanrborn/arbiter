#!/bin/sh
# Fixture: a reviewer (Tribunal) worker that emits `VERDICT: REQUEST_CHANGES`
# with NO concrete findings on its first pass — the content-free verdict from
# bd-3y2mda that stalls the gate. It then either supplies a proper verdict on the
# Tribunal's re-prompt or keeps withholding findings.
#
#   $1 — re-prompt behavior:
#        "APPROVE" — approve on the re-prompt (proves the re-prompt ran).
#        "EMPTY"   — (default) keep returning a findings-less REQUEST_CHANGES so
#                    the second malformed result escalates as inconclusive.
#
# A marker file in the CWD (the reviewer's worktree, unique per test) tells the
# first pass apart from the re-prompt — the Tribunal re-runs this same argv.
# Stands in for a real `claude --print` reviewer so tests never invoke the CLI.
retry="${1:-EMPTY}"
marker="./.tribunal_empty_findings_attempt"

if [ -f "$marker" ]; then
  # Re-prompt pass.
  if [ "$retry" = "APPROVE" ]; then
    echo "VERDICT: APPROVE"
    echo "on a closer read the change is fine"
    echo "arb done"
  else
    echo "VERDICT: REQUEST_CHANGES"
    echo "arb done"
  fi
else
  # First pass: a verdict with no findings at all.
  : > "$marker"
  echo "VERDICT: REQUEST_CHANGES"
  echo "arb done"
fi
exit 0
