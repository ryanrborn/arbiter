#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker whose subprocess dies mid-run because
# the agent CLI's 5h plan usage limit was reached — it prints the CLI's own
# usage-limit signature (no VERDICT line, since the process never got that
# far) and exits non-zero. Exercises the reviewing-phase quota classification
# (bd-3hr6g2): the ReviewGate must recognize this as an infrastructure failure
# and escalate with the real reason instead of silently re-prompting a session
# that is doomed to fail identically within the same usage window.
#
# Always fails this way — no marker/retry-pass branch — since a verdict
# re-prompt within the same exhausted window would fail identically.
echo "reviewing the diff..."
echo "Claude AI usage limit reached|1735689600"
exit 1
