#!/bin/sh
# Fixture: a reviewer (Tribunal) worker that emits substantive review output but
# FORGETS the verdict sentinel on its first pass, then supplies one when the
# Tribunal re-prompts. Exercises the verdict re-prompt path (bd-8v8ays).
#
#   $1 — the verdict to emit on the re-prompt pass: "APPROVE" / "REQUEST_CHANGES",
#        or "NONE" (the default) to keep withholding the verdict so the second
#        empty result escalates as inconclusive.
#
# A marker file in the CWD (the reviewer's worktree, unique per test) tells the
# first pass apart from later ones — the Tribunal re-runs this same argv, so the
# script itself must remember it already ran. Stands in for a real `claude
# --print` reviewer so tests never invoke the paid CLI.
retry_verdict="${1:-NONE}"
marker="./.tribunal_reprompt_attempt"

if [ -f "$marker" ]; then
  # Re-prompt pass.
  if [ "$retry_verdict" = "NONE" ]; then
    echo "re-reviewing, but still no verdict from me"
    echo "arb done"
  else
    echo "re-reviewing the diff, now with a verdict"
    echo "VERDICT: ${retry_verdict}"
    echo "findings: settled on re-prompt"
    echo "arb done"
  fi
else
  # First pass: a substantive review that omits the required sentinel.
  : > "$marker"
  echo "reviewing the diff: this looks consistent, but I forgot the sentinel"
  echo "arb done"
fi
exit 0
