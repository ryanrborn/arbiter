#!/bin/sh
# Fixture: a REVIEWER (ReviewGate) pass that makes the remote branch advance
# underneath the gate, the way PRPatrol's fix worker did in bd-bq8c8a.
#
#   $1 — path to a sibling clone that already holds an UNPUSHED commit on $2.
#        Pass 1 pushes it, so `origin/$2` moves on while round 1 is still
#        deciding — the 16:30:10 push in the incident timeline.
#   $2 — branch name.
#
# Pass 1 always REQUEST_CHANGES with one Medium finding (routing the gate into
# a fix round). Pass 2+ APPROVEs iff the head it is reading is the one
# `origin/$2` carries — so a gate that re-reviewed an orphaned local commit
# shows up as a REQUEST_CHANGES rather than as a test passing for the wrong
# reason. Never invokes the paid CLI.
other="$1"
branch="${2:-main}"
git_dir="$(git rev-parse --git-common-dir)"
counter="$git_dir/remote_advance_pass"
pass=0
[ -f "$counter" ] && pass="$(cat "$counter")"
pass=$((pass + 1))
echo "$pass" > "$counter"

if [ "$pass" = "1" ]; then
  git -C "$other" push -q origin "$branch" >/dev/null 2>&1
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
  echo "- [ADDRESSED] F1.1 — the guard is anchored in guard.txt:1 on the head origin carries"
else
  echo "VERDICT: REQUEST_CHANGES"
  echo "- **High**: ORPHANED-HEAD — this pass read $local_head, which is not on"
  echo "  origin/$branch ($remote_head)."
fi

echo "VERIFICATION: FULL"
echo "arb done"
exit 0
