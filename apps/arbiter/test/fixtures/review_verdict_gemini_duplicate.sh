#!/bin/sh
# Fixture (bd-869mmg): reproduces the exact shape of the gemini reviewer
# transcript from bd-atyrrq's 72947341 run — a `⚙ gemini session started`
# preamble line, then a REQUEST_CHANGES verdict block emitted, then an "arb
# done" line, then the IDENTICAL verdict block repeated (mimicking gemini's
# own re-emission after "arb done") before a final "arb done". Stands in for
# a real `claude --print`/`gemini` reviewer so tests never invoke the paid CLI.
echo "⚙ gemini session started"
echo "VERDICT: REQUEST_CHANGES"
echo ""
echo "1. Severity: minor"
echo "   Location: \`ARBITER_OPERATOR.md:385\`"
echo "   Description: stale RefreshProbe documentation."
echo "   Suggested fix: update the table."
echo ""
echo "VERIFICATION: PARTIAL — mix test failed for unrelated environment reasons."
echo ""
echo "arb done"
echo "VERDICT: REQUEST_CHANGES"
echo ""
echo "1. Severity: minor"
echo "   Location: \`ARBITER_OPERATOR.md:385\`"
echo "   Description: stale RefreshProbe documentation."
echo "   Suggested fix: update the table."
echo ""
echo "VERIFICATION: PARTIAL — mix test failed for unrelated environment reasons."
echo ""
echo "arb done"
exit 0
