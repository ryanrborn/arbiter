# Session-JSONL archive (bd-db0p38)

Every run's agent CLI writes a complete, structured record of itself to disk.
Arbiter reads that file — for token reconciliation
(`Arbiter.Usage.ClaudeSessionFile`) and for retroactive step rows
(`Arbiter.Workers.StepBackfill`) — and, until this change, never kept a copy.
The CLI prunes it. This document covers what is archived, where, what it is
allowed to contain, and what an operator must do about that.

## What was being lost

Everything else Arbiter persists about a run is a *rendering* of it:

| Surface | What survives |
|---|---|
| `worker_run_steps.input_summary` | 200 chars of one picked field — a 5 KB tool input keeps ~4% |
| `worker_run_steps.output_summary` | 2,000 chars — a 21.5 KB tool result keeps 9% |
| `<run_id>.log` (`Arbiter.Worker.OutputLog`) | every rendered line, but each tool result truncated to 40 lines |
| `worker_runs.output_lines` | rendered lines, 1000-line tail only |
| thinking blocks | **nowhere** |
| per-message token usage, model, effort, requestId, uuid lineage | **nowhere** |

The session JSONL has all of it. `Arbiter.Workers.StepBackfill`'s own moduledoc
has said so since bd-apwfmy: it "is the only retroactive source of ground
truth: the rendered transcript has thrown the structure away."

## Retention reality — why this is a race, not a chore

**Claude Code prunes its session store at ~21 days.** No `cleanupPeriodDays` is
configured, so the CLI default applies. Measured 2026-09-12 over 16,596 files:

```
age: 0-6d: 6173   7-13d: 5885   14-20d: 4436   21-27d: 102   then nothing
```

At that point 45.2% of runs carrying a `session_id` had already lost their
file — the entire July corpus, irrecoverably.

The other two providers behave differently and were **not** observed pruning:
Gemini (`~/.gemini/antigravity-cli/`, 2,485 files) and Codex (21,817 files).
Only Claude Code is on a clock — which is exactly why archiving it is the
prerequisite, and why nothing downstream can be built on "we'll read the
session file when we need it". **Transcript distillation is only possible
because the archive exists**; by the time a distillation pass wants the
material, the CLI has deleted it.

## Path convention (stable — external readers may rely on it)

```
<output_log_root>/<run_id>.log                          # rendered transcript
<output_log_root>/<run_id>.prompt                       # composed prompt
<output_log_root>/<run_id>.jsonl.gz                     # session JSONL, gzipped
<output_log_root>/<run_id>.subagents/agent-*.jsonl.gz   # subagent transcripts
<output_log_root>/<run_id>.subagents/agent-*.meta.json.gz
```

`output_log_root` defaults to `~/dev/arbiter-worker-logs` and is overridable
with `config :arbiter, :output_log_root`. Keyed by `run_id`, exactly like its
two neighbours, so anything that can already fetch a run's transcript needs
nothing new. Read it back with `Arbiter.Worker.SessionArchive.read/1`, or
`zcat` it.

**Yes, things outside Arbiter should read this.** It is the intended input for
transcript distillation (bd-cyxzvq AMENDMENT 3) and the only structured record
of an interactive PTY session, where stdout is a repainted TUI. The path
convention above is the contract; treat `<run_id>.jsonl.gz` as stable.

Volume: ~16 MB/day raw, ~110 MB/week; gzip measures ~5:1, so ~22 MB/week on
disk. The one-time rescue of the surviving corpus wrote 149 MB.

## Redaction: the decision, and why

The raw JSONL is unredacted. `Arbiter.Worker.StepSummary` warns that a second
persistence path "is how a secret escapes redaction on one surface but not
another", and the risk is not theoretical — a live signing key was printed into
a coordinator transcript on 2026-07-16, and `ARBITER_CLOAK_KEY` into a subagent
transcript on 2026-09-12.

**The decision is: both.** Neither control is sufficient alone.

1. **Redact on ingest.** Every byte goes through `Arbiter.Redaction` — the same
   single choke-point every other surface uses — against the run's workspace
   secret values. Objection considered and rejected: "redaction damages the
   ground truth you are archiving." `Arbiter.Redaction` is a plain replace over
   values a human explicitly marked secret, so the only thing it can damage is
   precisely what must not be in a durable archive. It is also safe for JSONL:
   the `[REDACTED]` placeholder contains no JSON metacharacters and matching is
   verbatim, so a redacted line still parses. (Verified on the two rescued
   archives that actually contained a marked secret: 170 and 351 lines, all
   still valid JSON.)

2. **Treat the root as secret-bearing anyway.** Redaction only knows the
   secrets someone marked; it cannot catch a key a subprocess happened to
   print. So:

   - archive files are written **`0600`** (owner read/write only);
   - `output_log_root` is best-effort **`chmod 0700`** on every archive write.

   **Operators: `output_log_root` is secret-bearing storage.** Do not sync it
   to a shared drive, serve it from a web root, or include it in a backup with
   weaker access control than the host account. If you copy an archive out for
   analysis, the copy inherits that status.

Redaction on the **backfill** path is strictly weaker than on the live path: it
scrubs against the workspace's secrets *as they stand today*, not the ones the
run actually held, so a since-rotated credential is no longer in the list. That
is the second reason the permission control exists rather than being optional.

## Operating it

Live archiving needs nothing: `Arbiter.Worker.record_run_finished/1` archives
each run as it completes. A run whose file is already gone logs a warning and
carries on — best-effort, never fatal.

The one-time rescue of pre-existing runs:

```sh
mix arbiter.archive_sessions                      # dry-run (default)
mix arbiter.archive_sessions --apply              # write the archives
mix arbiter.archive_sessions --limit 500 --apply  # in batches
mix arbiter.archive_sessions --force --apply      # re-archive existing
```

It is idempotent — a run that already has an archive is skipped — so re-running
converges.

### Reading the report

```
runs archived:       1274
already archived:    0
subagent files:      49
no session file:     1012   (pruned by the CLI — irrecoverable)
no session id:       1093
no config dir:       32     (non-Claude run — nothing was lost)
```

- **`no session file`** is the real loss: the CLI pruned it before we got
  there. This number only grows if the sweep is delayed.
- **`no session id`** is almost always a workflow-mode (bookkeeping-only) run
  that never opened an agent session at all. Not a loss.
- **`no config dir`** is **not** a loss. `config_dir` is a Claude-only column,
  so a run with a `session_id` and no `config_dir` ran on another provider.

### Monitoring coverage

`transcript_capture_stats` reports the two artifacts separately, because they
are lost independently and a single rate hides the richer one:

- `claude_sessions` / `transcript_missing` / `capture_rate_pct` — the rendered
  `<run_id>.log`, over every session-bearing run.
- `jsonl_sessions` / `jsonl_archived` / `jsonl_missing` /
  `jsonl_archive_rate_pct` — the `<run_id>.jsonl.gz` archive, over
  Claude-driven runs only, with `non_claude_sessions` reporting the rest.

## The "September loss channel", diagnosed

The bd-db0p38 audit flagged 31 runs missing their JSONL well inside the 21-day
retention window — the newest dated the day of the audit — and named three
hypotheses: `--resume` appending to a parent's file, a reaped config dir, or a
session that never wrote one.

**All three are wrong. Those runs are not Claude runs.** Evidence:

- All 32 such rows (this is the complete all-time set, not just September)
  carry a blank `config_dir` and a `NULL` `model`.
- 31 of 32 are `#review` runs; reviewers were running on Gemini.
- Every one of their `session_id`s resolves to
  `~/.gemini/antigravity-cli/conversations/<session_id>.db` — present and
  intact. Spot-checked: `3ab7e7ea-…`, `8e868ae1-…`, `2ea5c539-…`,
  `e4ffa5d2-…`, `1efb9898-…`.

Nothing was lost. The audit's denominator conflated "has a `session_id`" with
"is a Claude session". `transcript_capture_stats` and the backfill report now
split on `config_dir` so this cannot recur.

### What about `--resume`, then?

It is still real: `Arbiter.Worker.Dispatch.resume_session/2` re-spawns with
`--resume <sid>` and the CLI appends to the same `<sid>.jsonl`, while Arbiter
opens a new `Run` row. The token reader and the step backfill each *window*
that file by timestamp, because attributing another run's tokens or tool calls
is a correctness bug.

Archiving is the opposite case. Windowing would drop undated lines and
re-introduce exactly the lossiness this exists to end, so **the whole file is
archived under each run id that points at it**: the parent's archive and the
child's are byte-identical and each is complete. A resumed run is a small
minority of the corpus, and a few duplicated megabytes are cheaper than a
truncated ground truth.
