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

## `coordinator_session_v2_1_270.jsonl`

Derived the same way from the coordinator session that was **live when phase 6
first deployed** (`~/.claude/projects/-home-ryan-dev-admiral/202434c2-….jsonl`,
CLI 2.1.270): 24 consecutive `assistant` lines stripped to
`type / timestamp / sessionId / uuid / requestId / version` plus
`message.{id, model, role, usage}`, with the usage buckets copied verbatim and
`message.content` dropped entirely. Same guarantee as above — no prompt, no
model output, no tool input or output, no path, no credential. The `usage` maps
are reduced to the four billed buckets (the real ones also carry
`iterations`, `service_tier`, `server_tool_use` and friends, which nothing
reads).

It is the counter-example to the file above, and exists because both of its
properties broke the first deploy:

1. **Not one `cost-state` record.** Claude Code 2.1.270 stopped writing them;
   every row reconciled off such a file landed with `cost_usd: nil` until
   `Arbiter.Usage.ClaudePricing`'s token-priced fallback. Deduped, the 24 lines
   are 11 turns worth $3.0781575 at `claude-opus-5` list prices.
2. **It straddles midnight UTC** (2026-09-13T23:47 → 2026-09-14T00:09), which
   is what `read_totals/2`'s per-UTC-day split and the ingest's one-row-per-day
   dating are tested against.

## `bridge_session_sample.jsonl`

One `assistant` line (the same shape and values as the first line of
`coordinator_session_v2_1_270.jsonl` above — no prompt, no model output, no
credential) followed by one `bridge-session` record, in the shape §8.3's
spike measured: `type / sessionId / bridgeSessionId / lastSequenceNum /
ownerAccountUuid / ownerOrganizationUuid`. The ids are synthetic (an
all-zeros UUID, a made-up `cse_…` bridge session id) — this fixture proves
`Arbiter.Sessions.BridgeVerification` recognizes the record shape, not that
it round-trips a real one. Used by `bridge_verification_test.exs`'s
"bridge came up" case; the absent case just polls an empty/assistant-only
file.
