---
name: verification-before-completion
description: Prove the change works by observing real behavior before signalling done or opening a PR.
---
# Verification Before Completion

Before you signal `arb done` or open a PR, verify the change actually does what the task asked — by observing real behavior, not by assuming.

- Run the full relevant test suite; it must pass. New/changed behavior must have a test that exercises it.
- Drive the actual affected code path (run the command, hit the endpoint, exercise the flow) and observe the result. "It compiles" and "types check" are not verification.
- Re-read the task's acceptance criteria and confirm each point is met.
- If you could not verify something, say so explicitly in your completion notes — do not imply it was checked.
- Never report work as done on the strength of the diff alone.
