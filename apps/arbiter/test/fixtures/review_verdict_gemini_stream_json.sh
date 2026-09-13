#!/bin/sh
# Fixture (bd-869mmg round 2): reproduces the bd-atyrrq / run 72947341
# transcript through the REAL agy stream-json wire schema, not pre-rendered
# text. The captured incident transcript's preamble (`⚙ gemini session
# started`, no `(model …)` suffix) and closing line (`⚙ gemini session
# SUCCESS · …`, uppercase status) match agy's `{"event":"init"}` /
# `{"event":"result"}` clauses, not upstream gemini's `{"type":"message"}`
# schema — so this fixture emits agy's actual event shape, with the VERDICT
# sentinel deliberately split mid-word across two `text_delta` chunks (a
# known agy chunking hazard, bd-2fzwlc round 2) to prove ReviewGate records a
# round when fed the real wire protocol, not pre-joined text.
cat <<'JSONL'
{"event":"init","conversation_id":"c1","init":{"cwd":".","tools":[],"permission_mode":"default"}}
{"event":"step_update","step_update":{"conversation_id":"c1","step_index":0,"state":"IN_PROGRESS","step_type":"agent_response","text_delta":"VERDICT: REQUEST_"}}
{"event":"step_update","step_update":{"conversation_id":"c1","step_index":0,"state":"DONE","step_type":"agent_response","text_delta":"CHANGES\n\n1. Severity: minor\n   Location: `ARBITER_OPERATOR.md:385`\n   Description: stale RefreshProbe documentation.\n   Suggested fix: update the table.\n\nVERIFICATION: PARTIAL — mix test failed for unrelated environment reasons.\n\narb done\n"}}
{"event":"result","result":{"conversation_id":"c1","status":"SUCCESS","response":"done","duration_seconds":298.9,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":1,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":2}}}
JSONL
exit 0
