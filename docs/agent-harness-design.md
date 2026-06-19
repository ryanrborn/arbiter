# Pluggable Agent/Worker harness + routing policy — design spike

**Status:** design proposal (this is the spike deliverable; not yet approved)
**Date:** 2026-06-03
**Bead:** bd-c6xf18
**Author:** acolyte
**Reviewer of record:** Tribunal (this branch)
**Depends on:** bd-3rdlgp (usage ledger — landed on `feature/77`, not yet on `main`)

## TL;DR

**Recommendation: build a thin `Agent` behaviour now (Phase B below), but ship
only the `Claude` adapter. Defer multi-vendor adapters (Gemini / Codex / Aider)
until we have ledger data showing that today's pain — cost or rate-limits —
isn't already cured by the two cheaper levers we have not yet pulled:**

1. **Anthropic model-tiering inside the existing Claude harness**
   (Haiku for trivial, Sonnet by default, Opus for hard / for Tribunal review).
   Claude Code already accepts `--model`; this is a one-line argv change plus a
   workspace config knob.
2. **Multi-key rotation inside the Claude adapter** for rate-limit relief, with
   no harness work at all.

Both are reversible and measurable through the existing `Arbiter.Usage.Event`
ledger. A multi-vendor adapter, by contrast, is ~3–5 days per harness *plus*
ongoing maintenance against an upstream CLI we don't control, *plus* the very
real risk that a weaker agent's higher Tribunal-rejection rate eats the cost
savings in rework.

The harness *abstraction* is still worth building now (it is also the seam where
model selection and key rotation live), but its first job is to make the cheap
wins legible, not to onboard a second vendor.

## 1. Motivation, restated

The bead description names three motivations:

| Motivation | Cheapest lever | Lever cost | Lever ceiling |
|---|---|---|---|
| Rate-limit / quota relief | Multi-key/account rotation | ~0.5 day inside Claude adapter | High — until per-account quota itself binds |
| Cost optimization | Anthropic model-tiering (Haiku/Sonnet/Opus) | ~1–2 days; pure config + one argv flag | High — Haiku is ~5× cheaper than Sonnet, ~30× cheaper than Opus per Anthropic's public pricing |
| Resilience / fallback | Multi-vendor | ~3–5 days per adapter, ongoing | Hardest to estimate; depends on outage frequency |

The full multi-vendor path is the most expensive of these, and the one we have
the least evidence supports its own cost. The design below makes room for it
without committing to it.

## 2. What ships today

`Arbiter.Polecat.ClaudeSession` is the only worker harness. Its surface is:

- **Spawn:** `Port.open/2` on `claude --print <prompt> --output-format stream-json --verbose`,
  wrapped in `sh -c 'exec "$@" < /dev/null'` so the child's stdin closes cleanly.
- **Owner:** the parent `Arbiter.Polecat` GenServer.
- **Stream:** per-line JSON events (`system/init`, `assistant`, `user`/tool_result,
  `result`). The session module parses these into display lines and pushes to
  PubSub topic `polecat:<bead_id>`.
- **Completion sentinel:** a regex `~r/\barb done\b/` matched only against
  assistant text (not tool output) — so an acolyte that greps for "arb done"
  can't false-complete.
- **Usage capture:** `ClaudeSession.absorb_usage/2` parses `init.model` and
  `result.usage`/`result.total_cost_usd` into a payload that the polecat writes
  to `Arbiter.Usage.Event` on session exit. The Event row already has a
  `provider` column ("claude" today) — the schema is pre-shaped for non-Claude
  agents.

The `Sling.maybe_start_claude/4` call in `apps/arbiter/lib/arbiter/polecat/sling.ex`
is the one site where Claude is named. Tribunal spawns its own
`ClaudeSession` for the reviewer pass — second site.

There is **no model knob** today. Whatever default model Claude Code picks is
the model used.

## 3. Why this is not a config flag (and why that bound matters less than it sounds)

The bead description argues that swapping providers means swapping the harness:
different CLIs, different stream formats, different tool protocols. That is
correct for *vendor* swaps (Gemini/Codex/Aider). It is **not** correct for
*model* swaps inside Anthropic — `claude --model haiku` is the same harness.

So the "must swap the whole harness" framing is true at the vendor boundary but
false at the model-tier boundary. Most of the cost-optimization story lives on
the model-tier side, which is the cheap side. The pluggable-harness work earns
its keep by *unblocking the vendor swap if we later decide we want one* — but it
is not the cheapest path to the cost win.

## 4. Proposed abstraction (mirrors `Trackers` and `Mergers`)

We already have two pluggable-adapter pairs in the codebase that share a shape
worth copying:

- `Arbiter.Trackers.Tracker` behaviour + `Arbiter.Trackers` dispatcher + per-workspace
  `config["tracker"]["type"]` + per-process `Adapter.Config.put_active/1` seed.
- `Arbiter.Mergers.Merger` behaviour + `Arbiter.Mergers` dispatcher + per-workspace
  `config["merge"]["strategy"]` + same per-process seed.

The proposal copies that shape verbatim. New names:

| Layer | Module | Mirror of |
|---|---|---|
| Behaviour | `Arbiter.Agents.Agent` | `Arbiter.Trackers.Tracker` |
| Dispatcher | `Arbiter.Agents` | `Arbiter.Trackers` |
| Adapter (MVP) | `Arbiter.Agents.Claude` | `Arbiter.Trackers.Jira` |
| Adapter config | `Arbiter.Agents.Claude.Config` | `Arbiter.Trackers.Jira.Config` |

### 4.1 `Arbiter.Agents.Agent` behaviour

The contract is intentionally narrow. The polecat is the port owner; the
adapter only *produces argv*, *parses events*, *recognizes completion*, and
*surfaces structured usage*. Everything stateful (port ownership, PubSub
broadcast, line-cap buffering, durable log append) stays in the polecat /
session module.

```elixir
defmodule Arbiter.Agents.Agent do
  @typedoc "Opaque per-session state the adapter threads through event parsing."
  @type session_state :: map()

  @typedoc "A normalized display-line: text plus whether it should arm the done sentinel."
  @type display_line :: {text :: String.t(), arm_done? :: boolean()}

  @typedoc "Structured usage attrs ready for Arbiter.Usage.Event.create/1."
  @type usage_attrs :: map() | nil

  @doc "Argv to spawn for `prompt`. Adapter may bake in model / streaming flags."
  @callback default_argv(prompt :: String.t(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc "Initial per-session state. Called once when the port is opened."
  @callback init_session(opts :: keyword()) :: session_state

  @doc "Parse one complete output line into display lines + updated session state."
  @callback parse_line(session_state, line :: String.t()) ::
              {[display_line], session_state}

  @doc "Regex (or list of regexes) matched against assistant text to detect completion."
  @callback done_sentinel() :: Regex.t() | [Regex.t()]

  @doc "Build the Usage.Event attrs from session state at port exit. nil ⇒ no row."
  @callback usage_attrs(session_state) :: usage_attrs

  @doc "Adapter's provider key for ledger / dashboards."
  @callback provider() :: String.t()
end
```

The `Claude` adapter is the existing `ClaudeSession` parsing logic, lifted
behind these callbacks. The behaviour is *intentionally smaller than the
existing Tracker behaviour*: agents don't need `fetch/transition/update_fields/
link_for` because the worker process is the source of truth — there's nothing
to fetch back.

### 4.2 `Arbiter.Agents` dispatcher

```elixir
defmodule Arbiter.Agents do
  @adapters %{
    claude: Arbiter.Agents.Claude
    # :codex, :aider, :gemini wired up only when their adapters ship
  }

  @spec for_workspace(Workspace.t()) :: module()
  def for_workspace(%Workspace{} = ws), do: for_type(workspace_agent_type(ws))

  @spec for_bead(Issue.t(), Workspace.t()) :: module()
  def for_bead(%Issue{agent_type: type}, _ws) when not is_nil(type), do: for_type(type)
  def for_bead(_bead, %Workspace{} = ws), do: for_workspace(ws)

  @spec prepare(Workspace.t() | nil) :: :ok
  # mirrors Trackers.prepare/2 — seed adapter Config from workspace
end
```

`Issue.agent_type` is a new optional enum column (default `nil` → "inherit from
workspace") — Stage 2 below.

### 4.3 Workspace config shape (extends today's `config` JSON)

```json
{
  "vernacular": { "..." },
  "tracker": { "..." },
  "merge": { "..." },
  "agent": {
    "type": "claude",
    "config": {
      "model": "sonnet",
      "credentials_ref": "env:ANTHROPIC_API_KEY",
      "api_keys": ["env:ANTHROPIC_API_KEY", "env:ANTHROPIC_API_KEY_2"]
    },
    "review_agent": {
      "type": "claude",
      "config": { "model": "opus" }
    },
    "routing": {
      "policy": "by_priority",
      "rules": {
        "P0": { "model": "opus" },
        "P1": { "model": "opus" },
        "P2": { "model": "sonnet" },
        "P3": { "model": "sonnet" },
        "P4": { "model": "haiku" }
      },
      "budget_usd_per_day": null
    }
  }
}
```

Missing keys fall back to `{type: "claude", config: {model: <CLI default>}}` —
no surprises for existing workspaces.

The `agent` block also carries a `security` sub-object — the normalized,
provider-agnostic acolyte permission + sandbox posture (`mode`, `allow`,
`deny`, `sandbox`). It is resolved by `Arbiter.Agents.SecurityPolicy` and
mapped per-adapter (`Arbiter.Agents.Claude.Security`). See
`docs/acolyte-security.md` (bd-9u10op) for the full shape and the safe
defaults; it is omitted here to keep this section focused on routing.

`review_agent` is independent of `agent`. The Tribunal-stronger-than-worker
pattern (cheap acolyte writes, stronger reviewer judges) is expressed by
asymmetric config. Same shape for both, so a workspace could also flip it
(strong worker, cheap reviewer) if data ever supports that.

### 4.4 Routing policy as a separate concern

Routing is a *function from bead + workspace + ledger → agent config*. It's
small enough to live as its own behaviour:

```elixir
defmodule Arbiter.Agents.Routing.Policy do
  @callback choose(bead :: Issue.t(), workspace :: Workspace.t(), ledger_snapshot :: map()) ::
              %{type: atom(), config: map()}
end
```

Initial policies:

| Policy | What it does | Reads |
|---|---|---|
| `:static` | Always returns `workspace.config["agent"]`. | Workspace only |
| `:by_priority` | Maps `bead.priority` (P0..P4) → `rules[<priority>]`. | Workspace + bead |
| `:by_difficulty` | Maps `bead.difficulty` (D0..D4) → abstract `{model_tier, thinking}` via `rules[<difficulty>]` with a built-in default mapping. Provider-agnostic — adapters resolve tier/thinking to their own knobs. | Workspace + bead |
| `:by_budget` | Wraps `:by_priority` (default) or `:by_difficulty` (set `routing.base_policy = "by_difficulty"`) until daily/weekly USD threshold; then degrade one tier on `"model_tier"` and/or `"model"`. | Workspace + bead + ledger |
| `:round_robin` | Cycle adapter list per dispatch. Useful for A/B. | Workspace + dispatch counter |

`:static`, `:by_priority`, and `:by_difficulty` ship for the worker
dispatch path (no ledger needed). `:by_budget` and `:round_robin` ship
as seams — `:by_budget` is only useful once the ledger feeds usage data
into a per-dispatch snapshot.

### 4.3.1 `:by_difficulty` — provider-agnostic tier + thinking routing

Priority answers "how urgent?"; difficulty answers "how hard?". The two
are orthogonal — both can be set on a bead, and a workspace picks one
policy (or wraps it in `:by_budget`).

The policy emits **abstract** knobs only:

* `"model_tier"` — `"economy" | "standard" | "premium"`.
* `"thinking"` — `"none" | "low" | "medium" | "high"` (reasoning effort).

Concrete model names live inside each adapter's `Config` and are
resolved at spawn time:

* **Claude** — tier → `haiku` / `sonnet` / `opus`; thinking →
  `--reasoning-effort <level>` (default; configurable per-workspace via
  `agent.config["thinking_argv"]`).
* **Gemini** — tier → `gemini-2.5-flash-lite` / `gemini-2.5-flash` /
  `gemini-2.5-pro`; thinking → `GEMINI_THINKING_LEVEL` env var
  (default; configurable per-workspace via `thinking_argv`).

Built-in default mapping (signed off by the Admiral; do not change
without re-litigation):

| Difficulty | model_tier | thinking |
|------------|------------|----------|
| D0 (trivial) | economy | none |
| D1 (simple) | economy | low |
| D2 (moderate, default for unset) | standard | medium |
| D3 (hard) | premium | high |
| D4 (extreme) | premium | high |

Bead with `difficulty = nil` is treated as D2.

Workspace override example:

```json
{
  "agent": { "type": "claude", "config": {} },
  "routing": {
    "policy": "by_difficulty",
    "rules": {
      "D0": { "thinking": "none" },
      "D4": { "model_tier": "premium", "thinking": "high" }
    }
  }
}
```

A rule merges on top of the default mapping for that tier — keys the
rule omits keep their defaults.

### 4.5 Where the seam cuts in `Sling`

Today (sling.ex:309–343):

```elixir
defp maybe_start_claude(%Issue{} = bead, polecat_pid, worktree_path, opts) do
  case Keyword.get(opts, :start_claude, false) do
    true ->
      session_opts = [...prompt: prompt_for(bead)]
      ClaudeSession.start(session_opts)
    ...
  end
end
```

After Phase B:

```elixir
defp maybe_start_agent(%Issue{} = bead, polecat_pid, worktree_path, opts) do
  case Keyword.get(opts, :start_agent, false) do
    true ->
      workspace = load_workspace(bead)
      agent_choice = Agents.Routing.choose(bead, workspace, ledger_snapshot())
      Agents.prepare(workspace)
      AgentSession.start(
        owner: polecat_pid,
        worktree_path: worktree_path,
        agent: agent_choice,                # %{type:, config:}
        prompt: prompt_for(bead),
        command: Keyword.get(opts, :agent_command)  # test escape hatch
      )
    ...
  end
end
```

`--with-claude` stays as a CLI alias to `--with-agent` for back-compat (cheap to
keep; no upgrade pain for muscle memory). The on-disk flag remains the same;
only the implementation moves.

## 5. Alternatives considered (the cheaper levers)

### 5.1 Anthropic model-tiering, no abstraction

**What it is:** add `--model haiku|sonnet|opus` to the existing default argv,
sourced from `workspace.config["agent"]["model"]` (or a workspace knob using the
existing config shape, with no new "agent" sub-object). Tribunal reviewer reads
the same knob from `review_agent.model`.

**Where it shines:** captures most of the cost win. Haiku is roughly 5× cheaper
than Sonnet on input tokens (per Anthropic's public pricing — verify before
committing), so a workspace that routes P3/P4 beads to Haiku can plausibly halve
its acolyte spend with zero new harness code. The Tribunal already spawns a
distinct second session, so making *that* one Opus while keeping the worker on
Sonnet is asymmetric routing for free.

**Where it fails:** doesn't address rate limits (single-account quota still
binds) and doesn't address resilience (Anthropic outages take the whole system
down).

**Cost:** ~1–2 days end-to-end, including a workspace migration and a CLI flag
on `arb sling`.

### 5.2 Multi-key / multi-account rotation, inside the Claude adapter

**What it is:** `workspace.config["agent"]["config"]["api_keys"]` is a list. The
Claude adapter rotates through them per session (or per HTTP request, if we ever
gain that level of control over the upstream CLI — today we only control argv,
so rotation is per-session via an env var injected into the `Port.open` call).

**Where it shines:** purest fix for rate limits; touches one module; no new
adapter; no new dispatcher.

**Where it fails:** doesn't help cost (every key is on the same pricing) and
doesn't help resilience (single vendor still).

**Cost:** ~0.5 day inside the Claude adapter, including a smoke test.

### 5.3 Full multi-vendor (the bead's headline proposal)

**What it is:** a second adapter, then a third — Codex, Aider, Gemini.

**Where it shines:** real resilience (a Claude outage stops being a stop-the-
world event). Real quota expansion (different vendors, different quotas). And
in principle, real cost optionality (if an OSS local model on Aider were good
enough for trivial beads, the per-token cost is ~zero).

**Where it fails:** quality variance is the silent tax. Claude Code is, today,
the strongest autonomous coding harness — that is the explicit framing in the
bead description and matches every benchmark we've seen. A bead that fails
Tribunal once costs two Claude-Code-Opus reviewer sessions plus one acolyte
session of whatever-we-routed-to. If routing a P3 bead to a weaker harness
raises the Tribunal-rejection rate from, say, 10% to 30%, the rework dominates
the per-token savings.

**Cost:** ~3–5 days *per adapter* to MVP, plus a permanent maintenance tax
against upstream CLI churn (each vendor's stream format and tool protocol moves
on its own clock). And, importantly, **no way to budget the rejection-rate
delta without running the experiment**.

## 6. Risks the spike was asked to address

| Risk | Treatment |
|---|---|
| Quality variance — weaker agent → more Tribunal rejections → *more* tokens, not fewer | **Cannot estimate without running the experiment.** Recommendation: gate any non-Claude adapter on a measured A/B: same set of representative beads, two cohorts, compare *cost-per-merged-bead* (not raw cost-per-token), using the existing `:work` + `:review` ledger split. |
| Maintenance cost of N adapters | Materially real. Each adapter is a CLI we don't own, a stream format that can change, a tool protocol that can change. Mitigation: do not ship an adapter for a vendor whose CLI doesn't have a stable stream-events flag and a versioned release cadence. |
| Normalized cost model | The Usage.Event schema (already shipped on `feature/77`) has `provider`, `tokens_in/out`, `cache_*`, `cost_usd`, `duration_ms`. That is the right shape — adapters just need to fill it. Normalization is a *write-time* concern in each adapter, not a runtime concern in the dispatcher. |
| Cheaper levers first | Adopted as the recommendation. Both ship before the first non-Claude adapter. |

## 7. Phasing

Each phase is independently shippable and reversible.

### Phase A — model-tiering, no abstraction (1–2 days) — **shipped (#84)**

- Add `:model` to the default Claude argv in `ClaudeSession`; read from
  `workspace.config["agent"]["model"]` (introduce the `"agent"` sub-object now
  even though there's no adapter machinery yet — same shape stays valid in
  Phase B). **Landed alongside Phase B's `Agents.Claude.default_argv/2`.**
- `arb sling --model <name>` as the one-shot override. **Threaded through
  CLI → `/api/polecats/sling` → `Sling.sling/2` → `apply_model_override/2`,
  wins over both the workspace default and any routing rule.**
- Tribunal reads `review_agent.model` similarly. Default unset means "use the
  CLI default" (no behavioral change for existing workspaces). **Implemented
  via `Tribunal.build_session_opts/5`: reviewer spawns route through
  `Agents.reviewer_for_workspace/1` + `Agents.prepare(ws, :review_agent)`;
  implementer (revise) spawns route through `Routing.choose/3` so a revise
  round honors the same policy the initial dispatch did.**
- `Usage.Event.model` already records the actual model in use, so the A/B
  measurement falls out for free — query via `arb usage --by model`.

### Phase B — `Agent` behaviour + Claude adapter (2–3 days)

- Introduce `Arbiter.Agents.Agent`, `Arbiter.Agents`, `Arbiter.Agents.Claude`.
- Lift `ClaudeSession`'s parsing into the `Claude` adapter, leaving the port-
  owner + buffering + PubSub plumbing in a renamed `AgentSession` module.
- `Sling.maybe_start_claude` → `Sling.maybe_start_agent`; flag rename with
  alias.
- Tribunal's reviewer spawn goes through the same path.
- `:static` and `:by_priority` routing policies.

Exit criteria: existing test suite passes unchanged; new tests cover the
dispatcher and the `:by_priority` policy.

### Phase C — multi-key rotation (0.5 day; can ship with Phase B)

- `workspace.config["agent"]["config"]["api_keys"]` accepted as a list of
  credential refs.
- Claude adapter selects per-session by round-robin (or
  least-recently-used; round-robin is fine for MVP).
- Smoke test that we can in fact run two beads concurrently with two keys.

### Phase D — second vendor (gated by Phase A+B+C ledger data)

- Pick **one** alternate vendor based on whichever has the most usable
  streaming CLI at evaluation time. Today, my read is:
  - **OpenAI Codex CLI**: stable, OpenAI controls the spec, but it's a younger
    harness with less coding scaffolding than Claude Code.
  - **Aider**: open-source, well-instrumented, but its CLI is conversation-
    oriented; would need a non-trivial adapter shim.
  - **gemini-cli**: a moving target; assess at the time.
- Build the adapter. Run the A/B (~10–20 representative beads each cohort).
- **Stop here** if the second adapter shows >20% Tribunal-rejection-rate delta
  on cohort beads — that is the "more tokens, not fewer" outcome and the
  recommendation is to revert.

### Phase E — `:by_budget` and `:round_robin` policies (gated by Phase D)

Only meaningful once there are two adapters in flight.

## 8. What this design does NOT do

- **Does not change the Tribunal protocol.** Same `VERDICT: APPROVE | REQUEST_CHANGES`
  sentinel; same `arb done` completion sentinel. Adapters that don't speak this
  protocol natively must be prompt-engineered to do so — same way we prompt-
  engineer Claude today.
- **Does not change `Arbiter.Usage.Event`.** The schema is already provider-
  neutral. Adapters just fill in `provider` and the structured fields they
  have. Missing fields → `nil` (already supported).
- **Does not introduce a queue or a scheduler.** Routing is a synchronous
  per-sling decision. If we later want capacity controls, a `Task.Supervisor`
  with `max_children` slots in cleanly — see decision-doc Tier 3.
- **Does not solve "rework attribution"** beyond what the ledger already gives
  us. The ledger writes a new `:work` row on every re-sling, so per-bead spend
  *including* rework is already queryable. Routing policy can read that — it
  just isn't useful until we have two adapters to swing between.

## 9. Open questions, deferred

These do not block Phase A or Phase B. They block Phase D.

1. **What's the measured Tribunal-rejection-rate delta between Claude-Sonnet
   and a second vendor?** Cannot answer without running the A/B.
2. **What's the per-token pricing normalization story across vendors?**
   The ledger schema supports `cost_usd`; adapters compute it. Per-cached-token
   semantics differ across vendors — we eat that complexity inside each
   adapter's `usage_attrs/1`.
3. **Should the routing policy be per-workspace, per-bead-type, or per-bead?**
   Stage 1: workspace-level + per-priority. Stage 2 (only if needed):
   `bead.agent_type` override column, mirroring `bead.tracker_type`.
4. **Failover semantics.** If the active agent's CLI is missing, do we fall
   back to a different agent or fail the sling? Recommendation: *fail* — silent
   fallback is a footgun for cost-routing decisions.

## 10. Recommendation, restated

**Build the abstraction in Phase B; ship the cheap wins in Phase A; do not ship
a second vendor until ledger data justifies it.** The Tribunal gate makes the
heterogeneous-agent experiment safer to *eventually* run than it would be
without a quality gate, but it does not make the experiment cheap or risk-free.
Measure first.

The single most useful thing this work unlocks is **legibility of cost**:
once a workspace can route P0 to Opus and P4 to Haiku and have those choices
show up cleanly in `arb usage`, we'll see the shape of the spend and the
multi-vendor question will answer itself.

## 11. Gemini usage scraping — findings (bd-guegdl)

`bd-guegdl` added the `provider` sling parameter (CLI `--provider`, MCP
`provider`) and, as part of it, spiked **what the Gemini CLI actually emits** so
we can decide a usage-parse strategy rather than guessing.

### What ships in bd-guegdl

* `provider: "gemini"` rows now land in `Arbiter.Usage.Event` with a concrete
  **model id** and a **wall-clock duration**. The model is resolved at dispatch
  time via the new optional `Agent.resolved_model/1` callback
  (`Arbiter.Agents.Gemini.resolved_model/1`) and threaded onto the session
  (`ClaudeSession` `:provider` / `:model` opts), because the Gemini CLI emits no
  model the polecat can read mid-stream on the current spawn path (`agy -p` /
  `gemini -p`, no `--output-format`).
* **Cost and token counts are NOT yet captured for Gemini.** See below.

### What the Gemini CLI emits (`@google/gemini-cli`)

The `gemini` CLI *does* support a Claude-like structured output mode —
`--output-format json` and `--output-format stream-json` — which we do **not**
currently pass. Per its `docs/cli/headless.md`:

* **`json`**: a single object `{ "response": string, "stats": object, "error"?:
  object }`. `stats` carries token usage + API latency.
* **`stream-json`**: newline-delimited events — `init` (session id + model),
  `message`, `tool_use`, `tool_result`, `error`, and a final `result` with
  *aggregated statistics and per-model token usage breakdowns*.

Token fields use Gemini's `usageMetadata` naming, **not** Claude's:
`promptTokenCount`, `candidatesTokenCount`, `totalTokenCount`,
`cachedContentTokenCount`, `thoughtsTokenCount`, `toolUsePromptTokenCount`.

Crucially, **the Gemini CLI emits no per-session dollar cost** — there is no
analogue to Claude's `result.total_cost_usd`. Cost must be *derived* from token
counts × a per-model price table, which Arbiter does not currently have for any
provider (Claude's cost comes straight from the CLI).

> Note: live capture against the installed CLI was blocked by an
> `IneligibleTierError` (the free Gemini Code Assist tier was deprecated mid-2026
> in favour of "Antigravity"), so the schema above is taken from the pinned
> CLI's bundled `docs/` + source constants rather than a live run. A real run
> on an API-key/Vertex path should confirm the exact `result.stats` shape before
> the parser below is committed.

### What shipped in bd-bbpm5e

Token usage + a *derived* cost now land on Gemini ledger rows. Three pieces:

1. **The Gemini spawn opts into structured output.** `default_argv/2` appends
   `--output-format stream-json` — **but only on the upstream `gemini` CLI
   path.** The `agy` fork has no such flag (it only does `--print` plain text),
   so agy spawns still stream raw text and degrade gracefully to
   `provider + model + duration` with `nil` tokens/cost, exactly as before.
2. **The session parser learned Gemini's schema.** `ClaudeSession` dispatches
   on the session's `provider`: `"gemini"` events route to
   `Arbiter.Agents.Gemini.Stream` (usage capture + display formatting +
   live-activity), keeping Gemini's schema out of the Claude parser. Only
   assistant message *text* opts into `arb done` detection.
3. **A price table derives cost.** `Arbiter.Agents.Gemini.Pricing` holds
   per-model input/output/cached rates and computes `cost_usd` from the token
   counts (the CLI emits no dollar figure). Unknown models yield `nil` cost
   rather than a fabricated figure.

**Schema correction (confirmed against the installed CLI).** The earlier note
above (sourced from the bundled `docs/`) said the per-model breakdown uses the
`usageMetadata` camelCase names. That is the CLI's *internal* accounting; the
actual `stream-json` `result.stats` payload — emitted by
`StreamJsonFormatter.convertToStreamStats` (gemini-cli v0.45.0) — is
**snake_case**:

```
{"type":"result","status":"success","stats":{
   "total_tokens":N, "input_tokens":N,   // input_tokens = prompt, INCLUDES cached
   "output_tokens":N,                      // = candidates
   "cached":N,                             // cache-read subset of input_tokens
   "input":N,                              // = max(0, input_tokens - cached) (non-cached)
   "duration_ms":N, "tool_calls":N,
   "models":{"gemini-2.5-pro":{...same buckets...}}}}
```

The `init` event carries `{session_id, model}`. Mapping to the ledger:
`tokens_in = input_tokens`, `tokens_out = output_tokens`,
`cache_read_tokens = cached`, `cache_creation_tokens = nil` (Gemini has no
cache-creation analogue). Cost is priced per-model from `stats.models`.
Gemini's thinking/tool tokens are folded into `total_tokens` but not broken out
by stream-json, so billable output is approximated as
`max(output_tokens, total_tokens - input_tokens)` to recover thinking cost (see
`Arbiter.Agents.Gemini.Pricing` for the documented caveats, incl. the
un-modelled >200k long-context premium).
