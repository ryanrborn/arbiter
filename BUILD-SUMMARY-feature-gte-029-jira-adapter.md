# gte-029 — Tracker.Jira adapter

Bead: gte-029
Branch: `feature/gte-029-jira-adapter`

## What

Full Jira Cloud REST API v3 adapter implementing the
`GtElixir.Trackers.Tracker` behaviour from gte-019. Ships:

- `GtElixir.Trackers.Jira` — adapter (`fetch/1`, `transition/2`,
  `update_fields/2`, `link_for/1`, `parse_ref/1`, `list_transitions/1`).
- `GtElixir.Trackers.Jira.ADF` — Markdown → ADF converter for rich-text
  fields (description, qa_notes, deployment_notes).
- `GtElixir.Trackers.Jira.Config` — workspace-scoped config resolver
  (host / project_key / email / token / status_map / field_ids), backed by
  per-process state with an Application-env fallback.
- `GtElixir.Trackers.Jira.Error` — normalised error struct with kinds
  mirroring `GtElixir.GitHub.Error` plus two Jira-specific kinds:
  `:transition_not_found` and `:config_missing`.

`GtElixir.Trackers.@adapters` now maps `:jira → Jira`. The pre-existing
`trackers_test.exs` was updated; `Trackers.for_type(:jira)` resolves cleanly.

## Files

- `apps/gt_elixir/lib/gt_elixir/trackers/jira.ex` — main adapter (~330 LOC).
- `apps/gt_elixir/lib/gt_elixir/trackers/jira/adf.ex` — Markdown → ADF.
- `apps/gt_elixir/lib/gt_elixir/trackers/jira/config.ex` — config resolver.
- `apps/gt_elixir/lib/gt_elixir/trackers/jira/error.ex` — Error struct.
- `apps/gt_elixir/lib/gt_elixir/trackers.ex` — added `:jira → Jira`.
- `apps/gt_elixir/test/gt_elixir/trackers/jira_test.exs` — 22 tests for
  adapter callbacks (Req.Test stubs only — never hits a real endpoint).
- `apps/gt_elixir/test/gt_elixir/trackers/jira/adf_test.exs` — 19 tests for
  the Markdown → ADF converter.
- `apps/gt_elixir/test/gt_elixir/trackers_test.exs` — updated for new
  registry shape.
- `config/test.exs` — added `:gt_elixir, :jira_http_stub, true`.

## Things the reviewer should pay attention to

### 1. Active-workspace via per-process dict (alternatives b/c rejected)

The `Tracker` callbacks take `ref :: String.t()` only. Jira needs host,
project_key, email, token, status_map, field_ids — all workspace-scoped.
Three approaches were considered:

- **(a) Process dict** (`Config.put_active/1`) — chosen. Mirrors
  `Vernacular.put_active/1` and is already familiar to the codebase. The
  contract: callers (request middleware, CLI commands, scheduler jobs) set
  it; the adapter reads it.
- **(b) Extra `Workspace` argument** — *rejected*: changing the behaviour
  signature forces every adapter (None, future Linear/GitHub) to either
  ignore the workspace or accept it too, and pushes workspace plumbing
  into every caller of `Trackers.fetch/1`.
- **(c) Resolve workspace from the bead via Ash inside the adapter** —
  *rejected*: the adapter only has the `ref` string, not the bead.
  Looking up the bead inside the adapter would couple the HTTP layer to
  Ash/Postgres and ruin testability.

A hybrid fallback is also wired: if the process dict is unset,
`Application.get_env(:gt_elixir, :jira_default_config)` is consulted next.
This lets CLI escripts / Mix tasks operate without a Workspace. If neither
is set, callbacks return `{:error, %Error{kind: :config_missing}}` — loud
but recoverable.

For convenience, `Jira.with_workspace/2` scopes the config to a block.

### 2. ADF coverage scope (in scope / out of scope)

**In scope** (every form has a passing test):
- Paragraphs (blank-line separated)
- ATX headings, h1 through h4
- Bullet lists (`-` and `*` markers)
- Ordered lists (`1.` / `2.`)
- Fenced code blocks (with optional language hint)
- Inline `**bold**`, `*italic*`, `` `code` ``

**Out of scope** (deliberate — not needed for QA Notes / Deployment Notes):
- Nested lists
- Blockquotes
- Tables
- Links, images, hard-breaks
- HTML, raw embeds
- h5/h6 (Jira clamps anyway)
- Setext headings (=== / --- underlines)

Bumping scope means extending `parse_inline/1` and `parse_blocks/1`; the
state machine is small and additive. **Earmark was deliberately NOT added
as a dependency** — the supported subset is small enough that a hand-rolled
line-based parser is cheaper than wiring up a Markdown AST library across
the umbrella, and we get exact control over the ADF shape.

### 3. `Trackers.@adapters` edit and the existing test

`Trackers.adapters/0` previously returned `%{none: None}`. The pre-existing
test that asserted exactly this map, *and* the test that asserted
`for_type(:jira)` *raises*, both had to flip. I updated them to:

- `for_type(:jira)` returns `Jira` (new positive test).
- `for_type(:linear)` still raises (still pre-Phase-5).
- `adapters/0 == %{none: None, jira: Jira}`.

`Trackers.for_type(:jira)` now resolves cleanly. No raise.

### 4. Tests never hit any real Atlassian endpoint

All HTTP calls go through `Req.Test` stubs, gated by
`:gt_elixir, :jira_http_stub, true` in `config/test.exs`. Pattern is
identical to the existing `GtElixir.GitHub` test wiring. No network calls
in CI; the suite is hermetic.

### 5. Status mapping is workspace-configurable with sensible defaults

Defaults: `:open → "To Do"`, `:in_progress → "In Progress"`,
`:closed → "Done"`. Verus needs `:closed → "Approved and merged"` — set in
the workspace's `tracker.config.status_map`. The Phase 4 polecat that
moves Verus beads through merge will set this once per workspace.

`list_transitions/1` reverse-maps Jira transition names back to bead-status
atoms via the same `status_map`. Names without a mapping (e.g. an
in-progress sub-state Verus uses but bead doesn't model) are dropped — the
caller sees only the bead-vocabulary atoms it can act on.

### 6. `parse_ref/1` is conservative

- `"VR-17585"` (bare key) is only accepted when the active workspace's
  `project_key` matches — otherwise we refuse to guess whether it's a Jira
  or Linear ref.
- `"jira:VR-17585"` (explicit prefix) is always accepted, even cross-project
  — the prefix is the caller saying "I know this is for Jira."
- `"https://*.atlassian.net/browse/VR-17585"` matches by URL pattern.
- Anything else → `:error`.

## Test results

```
trackers/jira/adf_test     19 tests, 0 failures
trackers/jira_test         22 tests, 0 failures
trackers_test               9 tests, 0 failures (updated)
gt_elixir                 272 tests, 0 failures
gt_elixir_web              36 tests, 0 failures (unchanged)
gt_elixir_cli              48 tests, 0 failures (unchanged)
total                     356 tests, 0 failures
```

`mix compile --warnings-as-errors` clean.
`mix format --check-formatted` clean.

## Follow-ups (not in this PR)

- Plug the workspace-context setup into the request/CLI lifecycle so
  callers don't have to invoke `Jira.Config.put_active/1` by hand.
  Likely a tiny Plug for the web app + a wrapper in the escript entry.
- Rate-limit observability (`:persistent_term` cache like
  `GtElixir.GitHub.rate_limit/0`) for Jira. Jira's headers differ
  (`X-RateLimit-NearLimit`, `Retry-After`); deferred until we see real
  rate-pressure.
- Round-trip test wiring a real Issue resource → `Trackers.update_fields/2`
  → ADF assertion. Punt to whichever bead first uses
  `Trackers.update_fields/2` for QA Notes — too synthetic to write here.
- ADF subset is intentionally narrow; revisit if a non-QA-Notes caller
  appears that needs links or nested lists.
