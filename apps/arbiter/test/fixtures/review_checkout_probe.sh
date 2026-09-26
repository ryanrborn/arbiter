#!/bin/sh
# Fixture: a ReviewGate reviewer that records WHERE it ran (bd-a22hib).
#
# The in-gate reviewer used to run inside the implementer's own writable
# worktree. It now runs in a detached, throwaway checkout at the pushed head.
# This fixture appends one line per pass to `$1` so a test can assert the
# reviewer's cwd, the commit it saw, and whether the implementer's
# uncommitted scratch (`dirty.txt`) leaked into it:
#
#   cwd=<pwd> head=<git rev-parse HEAD> dirty=<yes|no>
#
#   $1 — the probe log (absolute path, outside every checkout).
#   $2 — "APPROVE" (default): one pass, APPROVE.
#        "HANG": record, write this pass's pid to `$1.pid`, then hang, so a
#        test can kill the reviewer mid-round.
#        "ROUND2": round 1 REQUEST_CHANGES with a Medium finding on guard.txt
#        (the file `revise_commit.sh` really touches); round 2 APPROVEs and
#        dispositions it. The round marker lives in the COMMON git dir: every
#        round's checkout is a different linked worktree with its own
#        `--git-dir`.
#
# Stands in for a real `claude --print` reviewer; never invokes the paid CLI.
log="$1"
mode="${2:-APPROVE}"

dirty=no
[ -e dirty.txt ] && dirty=yes
echo "cwd=$(pwd -P) head=$(git rev-parse HEAD 2>/dev/null) dirty=$dirty" >> "$log"

case "$mode" in
  HANG)
    echo "$$" > "$log.pid"
    echo "hanging reviewer pass..."
    exec sleep 60
    ;;
  ROUND2)
    marker="$(git rev-parse --path-format=absolute --git-common-dir)/review_checkout_probe_round"
    if [ ! -f "$marker" ]; then
      : > "$marker"
      echo "VERDICT: REQUEST_CHANGES"
      echo "- **Medium**: the over-match guard is missing (guard.txt:1)."
      echo "  Suggested fix: anchor the match instead of using a bare contains check."
      echo "VERIFICATION: FULL"
      echo "arb done"
      exit 0
    fi
    echo "VERDICT: APPROVE"
    echo "DISPOSITIONS:"
    echo "- [ADDRESSED] F1.1 — the guard now lands in guard.txt:1"
    echo "VERIFICATION: FULL"
    echo "arb done"
    exit 0
    ;;
  *)
    echo "VERDICT: APPROVE"
    echo "findings: none"
    echo "VERIFICATION: FULL"
    echo "arb done"
    exit 0
    ;;
esac
