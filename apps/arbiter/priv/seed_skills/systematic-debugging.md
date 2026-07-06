---
name: systematic-debugging
description: Reproduce, isolate root cause, fix the cause not the symptom, verify. Use when something fails or misbehaves.
---
# Systematic Debugging

When something fails, resist the first patch. Work the problem:

1. **Reproduce** — Get a reliable, minimal repro. If you can't reproduce it, you can't confirm a fix.
2. **Read the evidence** — Read the actual error, stack trace, and logs before theorizing. Quote the real failure.
3. **Hypothesize** — Form one specific, testable hypothesis about the cause. Change one thing at a time.
4. **Find the root cause** — Trace to the true origin. A fix that makes the symptom disappear without explaining the cause is a red flag.
5. **Fix + verify** — Apply the minimal fix, then confirm the repro now passes AND you understand why. Add a regression test.
