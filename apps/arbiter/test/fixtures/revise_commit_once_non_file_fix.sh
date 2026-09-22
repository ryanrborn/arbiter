#!/bin/sh
# Fixture: bd-cb7wpq (Finding 2, round 2). Like `revise_commit_once.sh`
# (real commit on the FIRST pass, no-op on every later pass), except the
# no-op pass declares its resolution with the `NO-FILE-CHANGE:` marker
# instead of just talking. Needed to prove `commit_gate_outcome/3`'s
# `approval_gap_pending?(state)` clause is checked BEFORE
# `non_file_fix_declared?(response)` — a guard-rejected APPROVE's
# gap-specific escalation must still win even when the implementer also
# printed the marker. Never invokes the paid CLI.
git_dir="$(git rev-parse --git-dir)"
counter_file="$git_dir/revise_commit_once_non_file_fix_pass"
pass=0
[ -f "$counter_file" ] && pass="$(cat "$counter_file")"
pass=$((pass + 1))
echo "$pass" > "$counter_file"

if [ "$pass" -eq 1 ]; then
  echo "implementer: addressing the reviewer's findings on this branch"
  echo "anchored guard (pass $pass)" >> guard.txt
  git add guard.txt >/dev/null 2>&1
  git -c user.email=fixture@example.com -c user.name=Fixture \
    commit -q -m "address reviewer finding F1.1 (pass $pass)" >/dev/null 2>&1
  echo "FIXED: anchored the match in guard.txt:1"
else
  echo "implementer: nothing left to change on this branch — resolved via PR metadata"
  echo "NO-FILE-CHANGE: nothing left to fix; the open finding is a disposition disagreement"
fi
echo "arb done"
exit 0
