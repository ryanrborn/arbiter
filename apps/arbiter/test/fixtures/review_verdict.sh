#!/bin/sh
# Fixture: simulates a reviewer (Tribunal) worker for TribunalTest. Prints a
# canned verdict sentinel — $1 is "APPROVE" or "REQUEST_CHANGES" — followed by a
# findings line and the "arb done" marker, then exits. Stands in for a real
# `claude --print` reviewer so tests never invoke the paid CLI.
verdict="${1:-APPROVE}"
echo "reviewing the diff..."
echo "VERDICT: ${verdict}"
echo "findings: the change looks consistent with the acceptance criteria"
echo "arb done"
exit 0
