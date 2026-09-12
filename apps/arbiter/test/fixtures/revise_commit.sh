#!/bin/sh
# Fixture: an IMPLEMENTER worker for the revise-and-rediscuss loop that actually
# COMMITS a change (unlike `revise.sh`, which only talks). Needed by the
# bd-6r8caj disposition-guard tests: the mechanical backstop reads the set of
# files a revision really touched, so proving a finding was legitimately
# addressed requires a real commit to the file the finding cited.
#
# Writes `guard.txt` — the file the paired `review_unaddressed_finding.sh`
# reviewer cites in its round-1 finding — and commits it in the CWD (the
# ReviewGate worktree). Deliberately NOT `feature.txt`: the test harness leaves
# the worktree on the target branch, so touching the branch's own file here
# would produce an add/add conflict at merge time and mask what is under test.
# Never invokes the paid CLI.
#
# A pass counter (kept in `.git`, same reasoning as the reviewer fixtures'
# markers) makes each invocation append distinct content, so a test that
# drives this fixture across multiple revise rounds (round 1, round 2, ...)
# gets a genuinely new commit — and HEAD really moves — every time, not just
# the first. Without this, a second invocation would re-stage identical
# content and `git commit` would have nothing to commit, leaving HEAD
# unchanged and tripping bd-2eyf9y's "fix round produced no changes" gate on
# what should be an ordinary multi-round revise.
git_dir="$(git rev-parse --git-dir)"
counter_file="$git_dir/revise_commit_pass"
pass=0
[ -f "$counter_file" ] && pass="$(cat "$counter_file")"
pass=$((pass + 1))
echo "$pass" > "$counter_file"

echo "implementer: addressing the reviewer's findings on this branch"
echo "anchored guard (pass $pass)" >> guard.txt
git add guard.txt >/dev/null 2>&1
git -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q -m "address reviewer finding F1.1 (pass $pass)" >/dev/null 2>&1
echo "FIXED: anchored the match in guard.txt:1"
echo "arb done"
exit 0
