# Claude Code session JSONL fixtures

## `coordinator_session_sample.jsonl`

Derived from a **real** Claude Code session file on the dogfood host
(`~/.claude/projects/-home-ryan-dev-admiral/7acf03fe-….jsonl`, CLI 2.1.251),
for `Arbiter.Usage.ClaudeSessionFile`'s `cost-state` tests (bd-be804c).

Only two record types survived the strip:

* the first 40 `assistant` lines, reduced to
  `type / timestamp / sessionId / uuid / requestId / version` plus
  `message.{id, model, role, usage}` — the usage buckets are copied verbatim,
  and `message.content` (prose, `thinking`, `tool_use` blocks) is **dropped
  entirely**, as are `diagnostics` and `stop_details`;
* every `cost-state` line, verbatim — those records carry only numbers
  (`totalCostUSD`, `modelUsage[model].costUSD`, durations, line counts) and
  never any content.

So the file contains no prompt, no model output, no tool input or output, no
file path, and no credential. Verified by key inspection: the only keys present
are the ones listed above.

What makes it worth keeping over a hand-written fixture is that it reproduces
two things a synthetic file would not have predicted:

1. `cost-state` records carry **no `timestamp`** — they are placed in time by
   `startTime` (epoch ms, the CLI process start);
2. it spans **two CLI processes** (`startTime` 2026-08-31T15:27:00.708Z at
   $10.2622827, then 2026-09-01T02:01:40.812Z at $13.3112036). Those totals are
   *not* cumulative across the restart, so the file's real cost is their sum
   ($23.5734863), not their max.
