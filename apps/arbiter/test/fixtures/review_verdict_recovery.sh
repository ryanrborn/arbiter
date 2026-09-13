#!/bin/sh
# Fixture (bd-869mmg round 3): reproduces the bd-atyrrq / run 72947341 shape
# deterministically — a first pass whose own scan finds no verdict (for
# reasons the surviving artifacts can't fully explain, exactly like the real
# incident), followed by a re-prompt pass that ALSO comes back with no
# verdict of its own. Unlike `review_verdict_gemini_*`, this fixture does not
# try to inject the verdict into the first pass's live output — no code path
# can make a pass's own scan see a verdict it didn't produce. Instead the
# TEST mutates the first pass's already-closed durable transcript directly
# (simulating a verdict that was on disk the whole time but never re-checked)
# and this script's re-prompt pass waits on a "go" file before exiting, so
# the test has a deterministic window to make that mutation before the
# ReviewGate's final escalation runs.
marker="$(git rev-parse --git-dir)/review_gate_recovery_attempt"
go_file="$(git rev-parse --git-dir)/review_gate_recovery_go"

if [ -f "$marker" ]; then
  # Re-prompt pass: wait for the test to signal it has mutated the first
  # pass's durable transcript, then concede with no verdict of its own.
  i=0
  while [ ! -f "$go_file" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  echo "re-reviewing, still no verdict from me"
  echo "arb done"
else
  : > "$marker"
  echo "reviewing the diff: this looks consistent, but I forgot the sentinel"
  echo "arb done"
fi
exit 0
