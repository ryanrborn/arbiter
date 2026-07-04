#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker whose FIRST pass HANGS past the
# ReviewGate's per-pass timeout (never emitting a verdict), then APPROVEs on the
# retried pass. Exercises the reviewing-phase timeout retry (bd-78vg4v): a hung /
# overloaded reviewer session should get one clean second attempt with a fresh
# mind before the gate escalates as timed-out.
#
#   $1 — the verdict for the RETRY pass: "APPROVE" (default) or "REQUEST_CHANGES".
#
# A marker file in the CWD (the reviewer's worktree, unique per test) tells the
# hung first pass apart from the retry — the ReviewGate respawns a fresh reviewer
# mind, so the script itself must remember it already ran. Stands in for a real
# `claude --print` reviewer so tests never invoke the paid CLI.
retry_verdict="${1:-APPROVE}"
marker="./.review_gate_timeout_attempt"

if [ -f "$marker" ]; then
  # Retry pass: emit a real verdict promptly.
  echo "retry pass: re-reviewing the diff, now within budget"
  echo "VERDICT: ${retry_verdict}"
  echo "findings: [low] feature.txt:1 settled on the retry"
  echo "arb done"
else
  # First pass: hang well past the (short, test-configured) timeout so the
  # ReviewGate must fire its timeout and retry. The gate stops this worker
  # before respawning, which kills this sleep.
  : > "$marker"
  echo "first pass: hanging, no verdict will be produced..."
  sleep 30
fi
exit 0
