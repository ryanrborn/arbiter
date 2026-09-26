#!/bin/sh
# Fixture: a reviewer that commits a drive-by change into the worktree and THEN
# approves (bd-2jkrqu, acceptance 2).
#
# Real reviewers do sometimes write to their checkout. Before bd-a22hib that
# checkout was the implementer's worktree, so a reviewer commit moved the head
# the gate would stamp to a commit only the worktree had. The reviewer now runs
# in a detached throwaway checkout: the commit lands there, the branch never
# moves, and the stamp names the pushed head the reviewer was handed.
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
