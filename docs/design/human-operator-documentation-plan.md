# Human-Operator Documentation — Plan

**Status:** deferred planning — no implementation yet
**Ticket:** bd-c596rk
**Depends on:** the `arb init` coordinator-template round settling (`AGENTS.md.eex`,
`OPERATOR_FIELD_GUIDE.md.eex`, `docs/*.eex`) — re-scope this plan once that
shape stops changing, since human docs will cross-reference it.

---

## Problem

Everything `arb init` generates today — `AGENTS.md`, `AGENTS.local.md`,
`OPERATOR_FIELD_GUIDE.md`, `docs/{deploy,monitoring,reviewgate,
worktrees-and-workers,quota-and-auth,external-trackers,pr-patrol}.md` — is
written for the **coordinator agent session**: an LLM with MCP tool access,
`arb prime` as its orientation ritual, and CLI shown as the fallback when an
MCP tool doesn't exist yet. `OPERATOR_FIELD_GUIDE.md.eex` is explicit about
this: *"This preference is yours [the coordinator's], not the operator's —
they only have a terminal."* But nothing is actually written **for** that
terminal-only operator. The closest things that exist are:

- **`README.md`** — install steps, quick-start, systemd service, remote
  access (`ARB_HOST`/`ARB_TOKEN`), the encryption key, secret storage, a CLI
  command table, and the vernacular/alias system. This is real
  human-facing content, but it's a single flat file mixing setup,
  operations, and reference — it wasn't designed as a doc set with an
  index.
- **`ARBITER_OPERATOR.md`** (repo root) — this reads like an **older,
  pre-MCP snapshot** of the coordinator guide (no MCP framing, stale legacy
  vernacular section), not a human-operator doc. Worth confirming whether
  it's dead weight or an artifact worth pruning once the template round
  lands — out of scope for this ticket, but flag it in the follow-up.

There is no conceptual doc written for a person skimming (workspace / repo /
issue / worker / review gate / merge queue, and how they relate) that doesn't
assume the reader already has the full command grammar loaded the way an
agent's moduledoc does. There's also no single walkthrough of installation
**topology decisions** (dev `mix phx.server` vs. `arb install-service`
systemd vs. a future init.d/Docker-only path) — that information is scattered
across README sections written at different times.

## What human docs need that agent docs don't (and shouldn't carry)

| Need | Why the agent templates are the wrong home for it |
|---|---|
| Topology decision guide — when to run dev-mode vs. systemd vs. (future) containerized, tradeoffs of each | Irrelevant to a coordinator session already running inside a chosen topology; belongs in an install-time decision doc |
| A plain `arb` command reference, organized by resource (`issue`, `worker`, `repo`, `config`, `workspace`), with no MCP-first framing | The agent docs deliberately lead with MCP and note CLI as fallback — inverted priority for a human, and duplicating the CLI's own `--help` output is a maintenance trap worth avoiding structurally |
| Conceptual model (workspace → repo → issue → worker → review gate → merge queue) written for a first-time reader, vernacular aliases explained *before* they're used | Agent templates assume the reader already resolved vernacular and knows the resource graph — they optimize for token economy over teaching |
| First-run walkthrough: `arb init`, workspace creation, adding a repo, dispatching one issue end-to-end, watching it merge | Agent templates assume the workspace already exists and is configured; there's no "day zero" narrative for them to carry, nor should there be — it'd bloat every session's context for a one-time task |
| Troubleshooting framed as "my command didn't do what I expected" (wrong PATH, stale escript, `ARB_HOST` misconfigured, missing `ARBITER_CLOAK_KEY`) | Agent-facing runbooks (`docs/quota-and-auth.md`, `docs/deploy.md`) assume the agent is *operating* a working install, not diagnosing whether the install itself is broken |

## What should stay out of scope for human docs

- Anything already covered well by README's install/quick-start sections —
  extend or restructure those rather than forking a duplicate narrative.
- MCP tool semantics, coordinator loop mechanics, ReviewGate escalation
  etiquette — these are agent-operating-procedure, not end-user reference.
  A human running `arb` directly doesn't need to know how a coordinator
  session should phrase a ReviewGate ruling.
- Vernacular preset authoring internals — link to `arb help vernacular`
  rather than re-explaining the alias resolution mechanism.

## Candidate shape (not a commitment — revisit after the template round)

1. **`docs/operator/getting-started.md`** — topology decision + first `arb
   init`/workspace/repo/issue walkthrough, replacing the scattered README
   quick-start content (or the README keeps a short version and links out).
2. **`docs/operator/concepts.md`** — workspace/repo/issue/worker/review
   gate/merge queue, and the vernacular alias system, written bottom-up for
   a reader with zero context.
3. **`docs/operator/cli-reference.md`** — generated or hand-maintained
   plain reference by resource, cross-linked from `arb <resource> --help`;
   decide during implementation whether to hand-write this or generate it
   from the CLI's own command tree to avoid drift.
4. **`docs/operator/troubleshooting.md`** — the "why doesn't this work"
   doc: PATH/escript staleness, `ARB_HOST`/`ARB_TOKEN`, `ARBITER_CLOAK_KEY`,
   Docker/Postgres not up.
5. Decide whether `ARBITER_OPERATOR.md` at repo root is superseded/removed
   once this lands, or whether it's independently stale and should be
   pruned regardless.

## Open questions for the next planning pass

- Does this doc set live in the arbiter repo (for arbiter's own
  contributors) or does `arb init` also scaffold a human-docs stub into
  *installed* projects, the way it scaffolds `AGENTS.md`? The ticket
  description leans toward "documentation aimed at the human operator",
  which could mean either the arbiter project's own docs or a generated
  artifact — needs an explicit call before implementation starts.
- How much of the CLI reference should be generated vs. hand-authored, to
  avoid the two-source-of-truth problem the agent-facing docs deliberately
  avoid by pointing at moduledocs.
- Whether `docs/operator/` should be a new top-level docs namespace or
  live alongside the existing `docs/*.eex` runbooks with a naming
  convention that distinguishes "for a human" from "for the coordinator".

## Explicit non-goals for this ticket

Per the ticket description, **no documentation was written or restructured
as part of bd-c596rk** — this file is the planning artifact. Re-open a
follow-up ticket once the coordinator-facing `arb init` template round
(`AGENTS.md.eex`, `OPERATOR_FIELD_GUIDE.md.eex`, `docs/*.eex`) has settled,
since the human-facing doc set will need to cross-reference whatever that
round lands on (file names, section structure, vernacular presentation).
