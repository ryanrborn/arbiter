#!/bin/sh
# Fixture: an IMPLEMENTER worker that emits a LARGE transcript — well past the
# ReviewGate transcript cap — to exercise cap_transcript/2 in finish_revise
# (bd-78vg4v). Left uncapped, this whole blob would be re-embedded into the
# round-2 re-review prompt and balloon it. It prints a distinctive HEAD marker,
# a big noisy middle, then a distinctive TAIL marker carrying the FIX
# conclusion, so a correct head+tail cap keeps BOTH ends and elides only the
# middle. Never invokes the paid CLI.
echo "IMPL_HEAD_MARKER: beginning to address the reviewer findings on this branch"
i=0
while [ "$i" -lt 4000 ]; do
  echo "noise line $i: reading files and narrating tool calls xxxxxxxxxxxxxxxxxxxxxxxx"
  i=$((i + 1))
done
echo "IMPL_TAIL_MARKER: FIXED feature.txt:1 by adding the requested guard, committed"
echo "arb done"
exit 0
