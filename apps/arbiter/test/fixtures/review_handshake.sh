#!/bin/sh
# Fixture: a REVIEWER (ReviewGate) pass that pauses at a handshake so a test can
# act while the round is genuinely in flight — the bd-bq8c8a collision window.
#
#   $1 — branch name to compare the head against (`origin/$1`).
#   $2 — handshake directory. Pass N writes `$2/ready.N` and then blocks until
#        the test creates `$2/go.N` (30s cap, so a broken test fails fast
#        instead of hanging the suite).
#
# Pass 1 always REQUEST_CHANGES with one Medium finding on `guard.txt` (the file
# `revise_commit.sh` really touches), routing the gate into a fix round. Pass 2+
# APPROVEs iff the head it is reading is the one `origin/$1` carries, so a
# regression reads as a REQUEST_CHANGES rather than a false pass.
# Never invokes the paid CLI.
branch="${1:-main}"
hold="$2"
git_dir="$(git rev-parse --git-dir)"
counter="$git_dir/handshake_pass"
pass=0
[ -f "$counter" ] && pass="$(cat "$counter")"
pass=$((pass + 1))
echo "$pass" > "$counter"

if [ -n "$hold" ]; then
  mkdir -p "$hold"
  : > "$hold/ready.$pass"
  waited=0
  while [ ! -f "$hold/go.$pass" ] && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
fi

if [ "$pass" = "1" ]; then
  echo "reviewing the diff for the first time"
  echo "VERDICT: REQUEST_CHANGES"
  echo "- **Medium**: the over-match guard is missing (guard.txt:1)."
  echo "  Suggested fix: anchor the match instead of using a bare contains check."
  echo "VERIFICATION: FULL"
  echo "arb done"
  exit 0
fi

local_head="$(git rev-parse HEAD 2>/dev/null)"
remote_head="$(git rev-parse "origin/$branch" 2>/dev/null)"
echo "re-reviewing head $local_head against origin/$branch $remote_head"

if [ -n "$remote_head" ] && [ "$local_head" = "$remote_head" ]; then
  echo "VERDICT: APPROVE"
  echo "DISPOSITIONS:"
  echo "- [ADDRESSED] F1.1 — the guard is anchored in guard.txt:1"
else
  echo "VERDICT: REQUEST_CHANGES"
  echo "- **High**: UNPUSHED-HEAD — $local_head is not on origin/$branch ($remote_head)."
fi

echo "VERIFICATION: FULL"
echo "arb done"
exit 0
