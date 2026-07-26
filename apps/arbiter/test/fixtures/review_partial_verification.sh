#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker that produces a well-formed
# REQUEST_CHANGES verdict with real findings, but discloses `VERIFICATION:
# PARTIAL` — it abandoned verification (e.g. gave up waiting on a slow test
# run) before finalizing. Exercises the partial-verification guard (bd-4te55l):
# ReviewGate must re-prompt for a fully-verified pass rather than accepting the
# unverified findings at face value.
#
#   $1 — "APPROVE_PARTIAL" selects the APPROVE-side of the guard instead: the
#        first pass emits `VERDICT: APPROVE` with `VERIFICATION: PARTIAL`
#        (bd-4te55l round 2 finding 3b — exercises
#        `handle_partial_verification_approve/2`, the sibling of the
#        REQUEST_CHANGES path below). $2 then selects the re-prompt behavior:
#        "APPROVE" (fully-verified approve) or "PARTIAL" (default; stays
#        unverified so the second pass proceeds with the warning banner).
#      — otherwise, what to emit on the re-prompt pass: "APPROVE" /
#        "REQUEST_CHANGES", or "PARTIAL" (default) to keep disclosing partial
#        verification so the second unverified result proceeds with the
#        warning banner.
#
# A marker file in the CWD (the reviewer's worktree, unique per test) tells the
# first pass apart from later ones — the ReviewGate re-runs this same argv, so
# the script itself must remember it already ran. Stands in for a real `claude
# --print` reviewer so tests never invoke the paid CLI.
marker="./.review_gate_partial_verification_attempt"

if [ "$1" = "APPROVE_PARTIAL" ]; then
  retry="${2:-PARTIAL}"

  if [ -f "$marker" ]; then
    # Re-prompt pass.
    if [ "$retry" = "APPROVE" ]; then
      echo "re-reviewing the diff, this time waiting for tests to finish"
      echo "VERDICT: APPROVE"
      echo "VERIFICATION: FULL"
      echo "arb done"
    else
      echo "tests are still slow; giving up again"
      echo "VERDICT: APPROVE"
      echo "VERIFICATION: PARTIAL — mix test abandoned again, verified via code reading only"
      echo "arb done"
    fi
  else
    # First pass: tests are still running, reviewer gives up waiting and
    # approves anyway without confirming the diff is actually clean.
    : > "$marker"
    echo "Tests are still running. Let me wait a bit more."
    echo "The tests seem to be taking a very long time."
    echo "VERDICT: APPROVE"
    echo "VERIFICATION: PARTIAL — mix test abandoned after a long wait, not re-confirmed against the current diff"
    echo "arb done"
  fi
  exit 0
fi

retry="${1:-PARTIAL}"

if [ -f "$marker" ]; then
  # Re-prompt pass.
  case "$retry" in
    APPROVE)
      echo "re-reviewing the diff, this time waiting for tests to finish"
      echo "VERDICT: APPROVE"
      echo "VERIFICATION: FULL"
      echo "arb done"
      ;;
    REQUEST_CHANGES)
      echo "re-reviewing the diff, this time waiting for tests to finish"
      echo "VERDICT: REQUEST_CHANGES"
      echo "- [high] feature.txt:1 confirmed still missing a guard on re-check"
      echo "VERIFICATION: FULL"
      echo "arb done"
      ;;
    *)
      echo "tests are still slow; giving up again"
      echo "VERDICT: REQUEST_CHANGES"
      echo "- [high] feature.txt:1 restating my earlier concern"
      echo "VERIFICATION: PARTIAL — mix test abandoned again, verified via code reading only"
      echo "arb done"
      ;;
  esac
else
  # First pass: tests are still running, reviewer gives up waiting and flushes
  # findings drafted before the wait was abandoned.
  : > "$marker"
  echo "Tests are still running. Let me wait a bit more."
  echo "The tests seem to be taking a very long time."
  echo "VERDICT: REQUEST_CHANGES"
  echo "- [high] feature.txt:1 stale contract id on error (restating round-1 finding)"
  echo "VERIFICATION: PARTIAL — mix test abandoned after a long wait, not re-confirmed against the current diff"
  echo "arb done"
fi
exit 0
