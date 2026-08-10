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
echo "implementer: addressing the reviewer's findings on this branch"
echo "anchored guard" > guard.txt
git add guard.txt >/dev/null 2>&1
git -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q -m "address reviewer finding F1.1" >/dev/null 2>&1
echo "FIXED: anchored the match in guard.txt:1"
echo "arb done"
exit 0
