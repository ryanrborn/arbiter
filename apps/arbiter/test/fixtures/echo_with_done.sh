#!/bin/sh
# Fixture: simulates a Claude Code session for ClaudeSessionTest. Emits a few
# lines (one of which contains the "arb done" completion marker), then exits 0.
echo "starting fake claude session"
echo "doing important work"
echo "arb done"
echo "trailing line after done"
exit 0
