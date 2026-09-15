#!/bin/sh
# Fixture: a reviewer that commits a drive-by change into the worktree and THEN
# approves (bd-2jkrqu, acceptance 2).
#
# Real reviewers do sometimes write to the worktree. When they commit, the head
# the gate would stamp and record coverage for is a commit that exists only
# locally — the PR carries the previous one. The stamping path must refuse to
# name it rather than record a review of a commit the PR does not have.
echo "reviewing the diff..."
echo "reviewer drive-by" >> reviewer-note.txt
git add reviewer-note.txt >/dev/null 2>&1
git -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q -m "reviewer drive-by commit" >/dev/null 2>&1
echo "VERDICT: APPROVE"
echo "findings: the change looks consistent with the acceptance criteria"
echo "VERIFICATION: FULL"
echo "arb done"
exit 0
