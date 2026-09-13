#!/bin/sh
# Fixture: an IMPLEMENTER worker that commits a real change on its FIRST
# invocation (like `revise_commit.sh`), then on every later invocation only
# talks and touches nothing (like `revise.sh`). Needed for bd-c6tdbu: a test
# that drives round 1 to a genuine commit (so the loop advances to round 2)
# and then needs round 2's fix round — triggered by the bd-6r8caj
# `:unaddressed_findings` approval-gap guard, not a plain REQUEST_CHANGES — to
# be a real no-op, reproducing "the reviewer approved, the gate rejected the
# approval, and the implementer genuinely had nothing left to fix."
git_dir="$(git rev-parse --git-dir)"
counter_file="$git_dir/revise_commit_once_pass"
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
  echo "implementer: nothing left to change — the finding this round cites was already fixed"
fi
echo "arb done"
exit 0
