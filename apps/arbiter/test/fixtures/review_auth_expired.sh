#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker whose subprocess dies mid-run because
# the agent CLI's credentials expired — it prints an auth-failure signature (no
# VERDICT line, since the process never got that far) and exits non-zero.
# Exercises the reviewing-phase auth-expiry classification (bd-b2glhm): the
# ReviewGate must recognize this as an infrastructure failure and escalate with
# the real reason instead of silently re-prompting a session that is doomed to
# fail identically (credentials are still expired) and reporting a generic
# "no parseable VERDICT line" message.
#
# Always fails this way — no marker/retry-pass branch — since a verdict
# re-prompt against the same expired credentials would fail identically.
echo "reviewing the diff..."
echo "Error: OAuth token has expired. Please run \`claude /login\` to re-authenticate."
exit 1
