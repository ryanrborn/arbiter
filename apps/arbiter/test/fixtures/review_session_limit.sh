#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker refused by the agent CLI because the
# account's 5h plan allowance is spent. Reproduces the CLI's CURRENT wording
# byte-for-byte as observed on run 06bdc6ee (bd-dxgris#review#r2, 2026-09-06):
# three lines, no VERDICT, exit 1, in well under a second — the agent never ran.
#
# bd-6dxit2: this used to classify as :crashed (the old @quota_signature only
# knew "usage limit reached"), so the ReviewGate re-prompted a reviewer that
# could not possibly run and then escalated "Reviewer produced no parseable
# VERDICT line, even after a verdict re-prompt" — blaming a reviewer that never
# executed. It must classify as :quota_exhausted and escalate with that reason,
# spending no re-prompt.
echo "⚙ claude session started (model claude-opus-5)"
echo "You've hit your session limit · resets 4:50am (America/New_York)"
echo "⚙ claude session error · 0.7s · \$0.0"
exit 1
