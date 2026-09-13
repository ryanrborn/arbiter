#!/bin/sh
# Fixture (bd-869mmg round 4): drives a two-round scenario that reproduces the
# exact shape a stale `verdict_scan(s)` carry-over would misfire on.
#
#   pass 1 (round 1, first pass)   — concedes :no_verdict (its scan is recorded)
#   pass 2 (round 1, re-prompt)    — a real REQUEST_CHANGES, feeding the revise loop
#   pass 3 (round 2, first pass)   — concedes :no_verdict again
#   pass 4 (round 2, re-prompt)    — waits on a go-file, then ALSO concedes :no_verdict
#
# The go-file wait on pass 4 gives the test a deterministic window to mutate
# round 1 pass 1's already-closed durable transcript so it now holds a
# (stale) parseable verdict, before round 2's final escalation runs. If
# `state.verdict_scans` is not reset per round, `recover_verdict_from_scans/1`
# would resurrect that round-1 pass's transcript during round 2's escalation
# and dispatch a review of code the implementer already revised past.
git_dir="$(git rev-parse --git-dir)"
counter_file="$git_dir/review_scan_reset_pass"
go_file="$git_dir/review_scan_reset_go"
pass=0
[ -f "$counter_file" ] && pass="$(cat "$counter_file")"
pass=$((pass + 1))
echo "$pass" > "$counter_file"

case "$pass" in
  1)
    echo "reviewing the diff for the first time: no verdict yet"
    echo "arb done"
    ;;
  2)
    echo "VERDICT: REQUEST_CHANGES"
    echo "1. round 1 finding: add a guard before merge"
    echo "arb done"
    ;;
  3)
    echo "reviewing the revised diff: no verdict yet"
    echo "arb done"
    ;;
  *)
    i=0
    while [ ! -f "$go_file" ] && [ "$i" -lt 100 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    echo "re-reviewing again, still no verdict from me"
    echo "arb done"
    ;;
esac
exit 0
