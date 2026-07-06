---
name: test-driven-development
description: Write a failing test before the code that makes it pass. Use for any change to product/source behavior.
---
# Test-Driven Development

Follow RED → GREEN → REFACTOR for every behavior change:

1. **RED** — Write one small test for the next bit of behavior. Run it. Watch it fail, and confirm it fails for the *right* reason (the behavior is missing — not a typo or import error).
2. **GREEN** — Write the minimum code to make that test pass. No more. Run the test; see it pass.
3. **REFACTOR** — Clean up code and tests while green. Re-run; stay green.

Rules:
- Never write implementation before a failing test that demands it.
- One behavior per cycle; keep tests small and fast.
- If a test is hard to write, treat that as a design signal — reconsider the interface before pushing on.
- A bug fix starts with a test that reproduces the bug (fails), then the fix (passes).
