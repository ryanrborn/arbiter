# Provider accounts — extracting credentials, quota and cost out of the workspace

**Status:** design proposal (this is the design deliverable for #1593; not yet
approved, no implementation)
**Date:** 2026-09-12
**Task:** bd-7df8nh · **Tracker:** github:1593
**Author:** worker
**Builds on:** bd-3x0na3's measurements (the proxy/`/api/oauth/usage` evaluation),
and the in-flight quota work bd-5xuneh / bd-3uwku6 / bd-b0zody / bd-atyrrq /
bd-7cvh8z and the usage-ledger work bd-adyhvn.

## TL;DR

Introduce **`ProviderAccount`** — a first-class entity for the thing Anthropic,
OpenAI and Google actually meter — and move credentials, quota snapshots, probe
timers, rate-limit cooldowns, overage settings and the concurrency ceiling onto
it. Workspaces reference an account per provider and keep everything that is
genuinely theirs (repos, trackers, review gate, routing policy).

Three answers up front, because they are the ones that decide whether this
works:

1. **Account identity is operator-asserted, never derived from the credential.**
   A spike run for this RFC (§2.1) established that the credential Arbiter
   actually injects into workers — the workspace `sk-ant-oat01-…`
   `CLAUDE_CODE_OAUTH_TOKEN` — **cannot be asked who it belongs to**:
   `/api/oauth/profile` and `/api/oauth/validate` both return
   `403 oauth_scope_insufficient` for it. So provider-reported identity is not
   available for the credential that matters, and any design keyed on the
   credential fragments on rotation. The account row is the identity; the
   credential hangs off it as an append-only version; the fingerprint is
   *evidence*, not a key.

2. **Concurrency: the account owns the ceiling, the workspace owns a share of
   it.** `effective_cap` gains an `account_headroom` term computed from one
   authoritative live count. "Three workspaces at `max_concurrent: 4` on one
   account" becomes "one account ceiling, with per-workspace caps under it."
   The ceiling is **opt-in on migration** (so nobody's fleet silently loses 3×
   throughput); the **quota hold becomes account-wide immediately**, because
   that one can only ever reduce dispatch against an exhausted account, which is
   the whole point.

3. **Sequencing: `usage_events` and the quota tables each get re-keyed exactly
   once.** bd-5xuneh ships now unchanged; bd-adyhvn lands before the
   `usage_events` account column; bd-atyrrq and bd-7cvh8z **delete** two
   workspace-keyed surfaces before the re-key, so the re-key never has to
   migrate code that is about to be deleted. bd-5xuneh's fingerprint grouping is
   **promoted, not deleted** — the grouping code survives, its inferred key is
   replaced by the real one.

---

## 1. Motivation, in one paragraph

Workspaces own their credentials (`workspaces.encrypted_worker_env`,
`apps/arbiter/lib/arbiter/tasks/workspace.ex:256`), so every quota, probe, budget
and cost mechanism in the tree is keyed to a workspace. The resource being
metered is not a workspace — it is a provider account. On this install, three
workspaces carry a fingerprint-identical token, so `anthropic_quotas` holds three
rows of the same numbers with independently drifting `captured_at` values,
`CloudProbe` fires three requests per cycle for one account-wide figure against a
limit that is *per account*, and three Conductors each believe they own the whole
budget. The gate is only sound if the budget and the cap live on the same object
as the quota. All of this was measured on 2026-09-12 under bd-3x0na3; this RFC
does not re-derive it.

The one thing this RFC adds to that evidence base is the **identity** answer,
which bd-3x0na3 correctly flagged as unanswered. §2.1 is new measurement.

---

## 2. Account identity

> **What identifies an account, such that identity survives credential
> rotation?**

### 2.1 What was measured (new, 2026-09-12)

A throwaway read-only spike was run for this RFC. It decrypted
`workspaces.encrypted_worker_env` from the live DB (Exqlite `:readonly`, via
`mix run --no-start`), then made **four** HTTP requests. No token, Authorization
header or credential value appears in this document or was written to any file.
Exactly what was run is in Appendix A.

| Probe | Result |
|---|---|
| `~/.claude/.credentials.json` → `claudeAiOauth` block, key names only | `accessToken`, `refreshToken`, `expiresAt`, `refreshTokenExpiresAt`, `scopes`, `subscriptionType: "max"`, `rateLimitTier: "default_claude_max_5x"` — **no account, email, or organisation identifier of any kind** |
| Workspace tokens, `default` / `emricare` / `vstim` | 1 distinct token across 3 workspaces (sha256 prefix `d82e44fc13d0`, 108 bytes); each `worker_env` holds that key and nothing else — confirms bd-3x0na3 |
| Operator `~/.claude` token vs workspace token | **different** tokens (`96cf89b03c3c` vs `d82e44fc13d0`), same account — the rotation counter-example, reconfirmed |
| `GET /api/oauth/profile` with the **operator's** interactive grant | **200.** Returns `account.uuid`, `account.email`, `account.created_at`, `account.has_claude_max`, `organization.uuid`, `organization.name`, `organization.billing_type`, `organization.rate_limit_tier`, `organization.subscription_status` |
| `GET /api/oauth/profile` with the **workspace** `sk-ant-oat01-…` token | **403** — `oauth_scope_insufficient`, `required_scopes: ["user:profile", "user:office"]`. That grant does not carry them (the operator's grant does: `user:profile` is in its `scopes` list) |
| `POST /api/oauth/validate` with the workspace token | **403**, same scope error |
| `/api/oauth/usage` response body (full key dump, bd-3x0na3 §1) | `five_hour`, `seven_day`, `limits`, `extra_usage`, `spend`, `member_dashboard_available`, per-model `seven_day_*` keys — **no account identifier** |

Two conclusions, and they point in opposite directions:

* **A provider-reported account identity exists** — `account.uuid` /
  `organization.uuid`, stable across token rotation, and it is exactly what the
  Claude Code CLI caches into `~/.claude.json`'s `oauthAccount` block.
* **The credential Arbiter injects into workers cannot obtain it.** The
  long-lived `sk-ant-oat01-…` grant minted by `claude setup-token` is
  inference-scoped. Every endpoint that would name its account rejects it.

So "ask the provider who this credential belongs to" is **not available for the
credential that matters**. Any design that depends on it is designing against a
capability we do not have.

### 2.2 Rejected: credential-fingerprint identity

`account_id = sha256(secret)` — the shape bd-5xuneh's stopgap uses at runtime.

**Rejected as identity.** It fragments on exactly the case already present on
this host: the operator's `~/.claude` token (`96cf89b0…`) and the workspace token
(`d82e44fc…`) are different secrets on one account, and bd-3x0na3 measured them
reporting identical utilisation. Under fingerprint identity that is two accounts,
two quota rows, two budgets, two ceilings and two ledgers for one plan — which is
the bug this RFC exists to remove, reintroduced one layer down. Worse, it is
*silent*: a routine `claude setup-token` refresh would split every rollup at an
arbitrary moment with no error and no log line.

Fingerprint equality does prove *sameness*. Fingerprint inequality proves
**nothing**. An identity scheme needs both directions.

### 2.3 Rejected: provider-reported identity as the primary key

`account_id = account.uuid from /api/oauth/profile`.

**Rejected as the primary key**, for three reasons:

1. It is unobtainable for the worker credential (§2.1) — the primary key of the
   central entity would be `nil` for the only credential that exists on this
   install today.
2. It is Anthropic-shaped. Codex and Gemini/Antigravity have their own identity
   endpoints, or none. A key that only one provider can populate is not a key.
3. It is an undocumented endpoint on a CLI-internal API surface. bd-3x0na3
   already found `/api/oauth/usage`'s shape is stable-but-unversioned; making a
   primary key depend on it means an upstream change can orphan every row.

It is, however, **excellent corroboration**, and §2.4 keeps it in that role.

### 2.4 Chosen: the account row *is* the identity

**`provider_accounts.id` is a locally-minted UUID. Nothing about it is derived
from any credential.** The operator names the account (`slug`), the same way they
name a workspace. That is the whole answer, and it survives rotation trivially:
rotating a credential inserts a row in `provider_credentials` pointing at the
same `account_id`. Quota rows, ledger rows, timers, cooldowns and the ceiling all
keep pointing at the same account, because none of them ever pointed at the
credential.

The two derived signals keep working, demoted to their honest roles:

* **Fingerprint → rotation and duplicate *evidence*.** `provider_credentials.fingerprint`
  (sha256 of the secret) powers (a) de-duplication at migration time, (b) an
  attach-time warning — "this credential is already active on account `X`; attach
  here too, or did you mean to reference `X`?" — and (c) rotation detection: a
  new fingerprint under an existing account is logged as a rotation **event**,
  never as a new account.
* **Provider profile → *verification*, when obtainable.** `provider_account_ref`
  and `provider_org_ref` are nullable columns filled opportunistically — from
  `/api/oauth/profile` when a credential carries `user:profile`, or from the
  operator's `~/.claude.json` `oauthAccount` cache when it is the same account.
  They are used to **warn on mismatch** ("the credential you attached to
  `personal-max` profiles as a different `account.uuid`"), never to split or
  merge automatically. `identity_source ∈ operator | provider_profile` and
  `identity_verified_at` record how much we actually know.

This inverts the usual instinct — the *measured* value is advisory and the
*asserted* value is authoritative — and that is correct here, because the
measurement is unavailable precisely where it would matter most.

### 2.5 When a rotation is only recognised afterwards

The failure this design must survive is not "rotation happened" — that is a
non-event above. It is: **the operator created two account rows and later
realises they are one plan.**

That is a real risk with operator-asserted identity, so it gets a real,
transactional operation rather than a manual SQL session:

```
arb account merge <from-slug> --into <into-slug>
```

What happens to the historical rows:

| Table | On merge |
|---|---|
| `usage_events` | `provider_account_id` re-pointed `from → into`. **Historical cost rollups become correct retroactively**, with no re-derivation, because the account id lives on the *event*. |
| `provider_credentials` | rows move across and stay distinct. An account legitimately has several credentials; this is the normal end state, not a cleanup step. |
| `anthropic_quotas` / `codex_quotas` / `cloud_code_quotas` | collide on `(provider_account_id, provider)`. These are **caches of the latest reading, not time series** (`apps/arbiter/lib/arbiter/quota/anthropic_quota.ex:12`), so keep the freshest and discard the rest — with the per-column-group caveat in §6. |
| `workspace_provider_accounts` | re-pointed; a workspace that pointed at `from` now points at `into`. If both rows existed for one `(workspace, provider)`, that was already impossible (unique index), so no conflict. |
| the `from` account row | soft-deleted with `merged_into_id` set, so an audit trail survives and a mistaken merge is traceable. |

**Design rule that makes this work: never pre-aggregate by account.** Every
account-dimensioned figure is computed from `usage_events` on read. The moment a
materialised per-account rollup table exists, a merge stops being a re-point and
becomes a rebuild. Do not add one.

**The reverse case — a split** — is why `usage_events` also carries
`provider_credential_id` (§3.2, §8). If an operator discovers that one account
row actually covered two plans, the credential stamped on each event is the only
thing that can tell them apart after the fact. This is also why rotation
**inserts a new credential row** rather than updating in place: an in-place
update would make every event before and after a rotation indistinguishable, and
would discard the one fact a split needs.

---

## 3. Data model

### 3.1 `provider_accounts`

| Field | Type | Notes |
|---|---|---|
| `id` | uuid, pk | locally minted; the identity of record (§2.4) |
| `provider` | string | `claude` / `codex` / `gemini` / `antigravity` — the codes `Arbiter.Quota.provider_code/1` already speaks (`apps/arbiter/lib/arbiter/quota.ex:181`) |
| `slug` | string | operator handle, unique per provider — `arb quota --account personal-max` |
| `label` | string | display name |
| `plan` | string, nullable | `max_5x` / `max_20x` / `pro` / `team` — operator-stated, or from `claudeAiOauth.rateLimitTier` / the profile when known |
| `provider_account_ref` | string, nullable | `account.uuid` when obtainable (§2.4) |
| `provider_org_ref` | string, nullable | `organization.uuid` when obtainable |
| `identity_source` | atom | `operator` \| `provider_profile` |
| `identity_verified_at` | utc_datetime, nullable | when the profile last corroborated |
| `max_concurrent` | integer, nullable | **the account ceiling** (§4). `nil` = no account ceiling; that is the migration default and reproduces today's behaviour exactly |
| `quota_config` | map | account-scoped gate settings: `throttle_threshold`, `weekly_threshold`, `weekly_warning_policy`, overage opt-in |
| `enabled?` | boolean | an account can be parked without deleting it |
| `merged_into_id` | uuid, nullable | set by `arb account merge` (§2.5) |
| `inserted_at` / `updated_at` | timestamps | |

Identity: `identity :provider_slug, [:provider, :slug]`.

### 3.2 `provider_credentials` — append-only versions

| Field | Type | Notes |
|---|---|---|
| `id` | uuid, pk | stamped onto `usage_events` so a late-discovered split is recoverable (§2.5) |
| `provider_account_id` | uuid | FK |
| `kind` | atom | `oauth_token` \| `api_key` \| `cli_credentials_file` |
| `env_var` | string | the variable a worker receives it as, e.g. `CLAUDE_CODE_OAUTH_TOKEN`. Keeps `Dispatch`'s spawn env a pure projection with no provider `case` statement |
| `encrypted_secret` | binary | `ash_cloak` + `Arbiter.Vault`, the same pattern as `workspaces.encrypted_worker_env`. `public? false`, `sensitive? true` |
| `fingerprint` | string | sha256 hex of the secret — evidence only (§2.4) |
| `active?` | boolean | exactly one active per `(account, provider, kind)`, enforced by a partial unique index |
| `scopes` | list, nullable | recorded when known; explains *why* a credential cannot self-profile |
| `created_at` / `retired_at` | timestamps | rotation = insert active + mark predecessor retired |

Rotation is an insert, never an update. That buys the audit trail, the split
recovery path, and an answerable "when did this last rotate" for free.

### 3.3 The workspace → account reference

A join row, `workspace_provider_accounts`:

| Field | Type | Notes |
|---|---|---|
| `workspace_id` | string | |
| `provider` | string | |
| `provider_account_id` | uuid | |
| `share` | integer, nullable | this workspace's cap on the account's ceiling (§4) |

Unique on `(workspace_id, provider)`.

Why a join table and not three nullable FK columns on `workspaces`: the provider
set grows (Antigravity is recent), a column per provider does not scale, and the
join row is the natural home for `share`. It is also the same `(workspace_id,
provider)` shape the quota tables are keyed by today, which makes the backfill in
§6 a straight join rather than an inference.

### 3.4 Cardinality — the explicit answers

* **One account per provider per workspace.** Enforced by the unique index.
* **A workspace may have `claude` on account A and `codex` on account B.** Yes —
  that is the whole reason the reference is per-provider rather than a single
  `workspace.provider_account_id`.
* **Multiple accounts per provider across the install:** yes. That is the
  operator's "separate accounts per workspace" case, and it works by pointing
  workspaces at different account rows.
* **Multiple accounts per provider for *one* workspace:** **no** in v1. That is
  multi-account load balancing, an explicit non-goal. The unique index on
  `(workspace_id, provider)` is the single hinge that would have to be relaxed,
  and nothing else in this design assumes cardinality one — the probes iterate
  accounts, the gate takes an account, the ledger stamps an account. Naming that
  now is the future-work statement the ticket asks for; building it is not in
  scope.

### 3.5 What stays on the workspace

Repos, trackers and tracker secrets, review-gate config, routing and dispatch
policy, `conductor.max_concurrent` (with changed *semantics*, §4), the default
provider (`Arbiter.Quota.default_provider/1`,
`apps/arbiter/lib/arbiter/quota.ex:199`), exhaustion routing
(`default_workspace_on_exhaustion/0`, `apps/arbiter/lib/arbiter/quota.ex:728`),
and every non-credential key in `worker_env`.

---

## 4. Concurrency

### 4.1 What actually happens today (worse than the ticket states)

```
effective_cap = min(workspace_max, system_max, quota_headroom)
```
(`apps/arbiter/lib/arbiter/workflows/conductor.ex:9`, computed at
`apps/arbiter/lib/arbiter/workflows/conductor.ex:513`)

* `workspace_max` ← `workspace.config["conductor"]["max_concurrent"]`
  (`apps/arbiter/lib/arbiter/tasks/workspace.ex:579`, read at
  `apps/arbiter/lib/arbiter/workflows/conductor.ex:491`).
* `system_max` ← `Arbiter.Settings.conductor_system_max_concurrent/0`
  (`apps/arbiter/lib/arbiter/settings.ex:36`), default 16
  (`apps/arbiter/lib/arbiter/workflows/conductor.ex:150`).
* `quota_headroom` ← `Arbiter.Workflows.QuotaGate.Default.quota_headroom/1`
  (`apps/arbiter/lib/arbiter/workflows/quota_gate.ex:83`), which reads the
  **workspace's own** snapshot row and defers to `Gate.over_cap?/2`
  (`apps/arbiter/lib/arbiter/quota/gate.ex:310`).

The ticket says three workspaces at 4 give three gates. The code says something
stronger: **a Conductor is per-Graph**
(`apps/arbiter/lib/arbiter/workflows/conductor.ex:3`), and `workspace_max` is
resolved per Conductor. Two running graphs in one workspace at
`max_concurrent: 4` already permit 8 on that workspace alone. The account-facing
ceiling today is `graphs × workspaces × max_concurrent`, bounded only by
`system_max`, which knows nothing about accounts.

### 4.2 The decision

**The account owns the ceiling. The workspace owns a cap on its use of that
ceiling.**

```
effective_cap(graph) = min(
    workspace_max,                          # unchanged
    system_max,                             # unchanged
    account_headroom(account, workspace),   # NEW
    quota_headroom(account)                 # re-keyed: workspace -> account
)

account_headroom(a, ws) =
    max(0, min(a.max_concurrent, share(ws, a)) - live_count(a))
```

* `live_count(a)` is **one authoritative counter**: workers currently registered
  in `Arbiter.Worker.Registry` whose workspace points at account `a` for the
  provider they were dispatched with. Not per-Conductor state — that is precisely
  the bug. Being registry-derived, it is also crash-safe in the same way the
  Conductor's other state is (rebuilt from live processes, not remembered).
* `quota_headroom` takes an **account**, so a 90% weekly hold on the account
  holds every workspace on it. This is the correctness fix: `default` held while
  `vstim` keeps dispatching against the same exhausted account becomes
  impossible.
* Gate **thresholds split**: the account carries the default
  (`quota_config.weekly_threshold` etc.), a workspace may set a *stricter* one,
  and the effective value is `min(account, workspace)` — never looser. That makes
  differentiated thresholds the way an operator expresses priority when several
  workspaces share one budget ("`vstim` stops at 70% so `default` can run to
  90%"), while keeping the account's number a hard floor nobody can raise.
  Today's readers are `Gate.threshold/1`
  (`apps/arbiter/lib/arbiter/quota/gate.ex:97`), `weekly_threshold/1`
  (`apps/arbiter/lib/arbiter/quota/gate.ex:116`) and `weekly_warning_policy/1`
  (`apps/arbiter/lib/arbiter/quota/gate.ex:139`).

### 4.3 "vstim may use at most 2 of my 4 slots"

```
arb account set personal-max --max-concurrent 4
arb workspace set-account vstim claude personal-max --share 2
```

`share` is a **cap, not a reservation**. Shares may sum to more than the ceiling
— that is the useful configuration, because it lets a quiet workspace's slots be
taken by a busy one while still bounding any single workspace. The account
ceiling is the hard stop. With shares-as-caps under a shared ceiling, slots are
first-come-first-served between Conductors, which is exactly the policy
`system_max` already has today, so this introduces no new fairness regression —
but it is a real property and it is stated here rather than discovered later. An
operator who wants a *guarantee* rather than a cap wants a reservation, which
needs cross-Conductor admission ordering Arbiter does not have; that is named as
future work in §10, not designed here.

### 4.4 Migration default: the ceiling is opt-in, the hold is not

Setting `max_concurrent` from existing config on migration is a trap in both
directions. `max(4, 4, 4) = 4` cuts this install's fleet throughput by 3× on the
day of the upgrade; `sum = 12` enshrines the broken status quo as an explicit
setting.

So: **migrate `provider_accounts.max_concurrent` to `nil`** (no account ceiling,
today's behaviour bit-for-bit) and have the migration print one advisory line —
"account `personal-max` is referenced by 3 workspaces whose caps total 12
concurrent workers; consider `arb account set personal-max --max-concurrent N`".
The operator opts in with a number they chose.

The **quota hold becomes account-wide immediately**, with no opt-in. The
asymmetry is deliberate and the reasoning is one sentence: an account-wide
ceiling can reduce throughput below what an operator intended, but an
account-wide *hold* can only ever stop dispatch against a budget that is already
exhausted, which is the thing that is broken today.

---

## 5. Every workspace-keyed quota/cost surface

`moves` = the workspace key is replaced by an account key. `stays` = genuinely
workspace-scoped. `splits` = part moves, part stays.

| # | Surface | `file:line` | Keyed by today | Verdict | Note |
|---|---|---|---|---|---|
| 1 | `anthropic_quotas` table + identity | `apps/arbiter/lib/arbiter/quota/anthropic_quota.ex:25`, `:161` | `(workspace_id, provider)` | **moves** | → `(provider_account_id, provider)`; §6 |
| 2 | `codex_quotas` table + identity | `apps/arbiter/lib/arbiter/quota/codex_quota.ex:31`, `:99` | `(workspace_id, provider)` | **moves** | same shape |
| 3 | `cloud_code_quotas` table + identity | `apps/arbiter/lib/arbiter/quota/google_quota.ex:36`, `:118` | `(workspace_id, provider)` | **moves** | same shape |
| 4 | `Quota.Gate.over_cap?/2` | `apps/arbiter/lib/arbiter/quota/gate.ex:310` | workspace + its snapshot | **splits** | snapshot moves to account; thresholds become `min(account, workspace)` (§4.2) |
| 5 | `Gate.threshold/1`, `weekly_threshold/1`, `weekly_warning_policy/1` | `apps/arbiter/lib/arbiter/quota/gate.ex:97`, `:116`, `:139` | `workspace.config["quota"]` | **splits** | account default, workspace may tighten only |
| 6 | `Gate.Snapshot.normalize/1` | `apps/arbiter/lib/arbiter/quota/gate/snapshot.ex:79` | — | **stays** | pure shape normaliser; takes whatever row it is handed |
| 7 | `Gate.stale?/1`, `long_window_stale?/1`, staleness threshold | `apps/arbiter/lib/arbiter/quota/gate.ex:215`, `:259`, `:292` | workspace snapshot | **stays** | logic unchanged; the input row becomes the account's |
| 8 | `Quota.Gate.Continue` / overage decision | `apps/arbiter/lib/arbiter/quota/gate.ex:310` via `Arbiter.Quota.Gate.Continue` | workspace | **moves** | `extra_usage` is an account-level plan feature in the `/api/oauth/usage` body |
| 9 | `Quota.Overage.windowed_spend/2` | `apps/arbiter/lib/arbiter/quota/overage.ex:36`, sum at `:42` | `by: :workspace` | **splits** | window from the account snapshot; spend sums `by: :provider_account` |
| 10 | `CloudProbe.default_refresh/1` + `list_workspaces/0` | `apps/arbiter/lib/arbiter/quota/cloud_probe.ex:179`, `:189` | one request **per workspace** | **moves** | iterate accounts; bd-4fbpto deleted bd-5xuneh's grouping (the workspace token it grouped on turned out unable to authenticate this endpoint at all), so P6 now builds account iteration fresh rather than re-keying it (§9) |
| 11 | `RefreshProbe.due_for_probe?/1`, `default_probe/2` | `apps/arbiter/lib/arbiter/quota/refresh_probe.ex:219`, `:256` | per workspace | **moves — if it still exists** | bd-atyrrq deletes it; do **not** re-key it first (§9) |
| 12 | `OAuthUsage` 429 cooldown key | `apps/arbiter/lib/arbiter/quota/oauth_usage.ex:207` | `phash2(token)` | **moves** | → account id. Closes bd-3x0na3's gap: the limit is per *account*, so two tokens on one account currently get two cooldowns for one shared budget |
| 13 | `usage_events` table | `apps/arbiter/lib/arbiter/usage/event.ex:50`, `workspace_id` at `:104` | `workspace_id`, non-null `task_id` | **splits** | keep `workspace_id`; **add** `provider_account_id` + `provider_credential_id` (§8) |
| 14 | `Usage.summarize/1` group keys | `apps/arbiter/lib/arbiter/usage.ex:203`–`:210` | `:task`/`:workspace`/… | **splits** | one new clause: `:provider_account` |
| 15 | `ConfigDir.oauth_token/1` precedence chain | `apps/arbiter/lib/arbiter/agents/claude/config_dir.ex:205`, chain at `:206` | workspace `worker_env` → server env → "unambiguous install-wide" | **moves, then collapses** | becomes a join read. The three-step chain exists *only* because accounts have no first-class answer; steps 2–3 become migration inputs and are then deleted |
| 16 | `ConfigDir.env/1` | `apps/arbiter/lib/arbiter/agents/claude/config_dir.ex:151` | workspace | **stays** | still projects to env pairs; sources from the account |
| 17 | `Worker.WorkerEnv.resolve/1` | `apps/arbiter/lib/arbiter/worker/worker_env.ex:63`, reads at `:68` | workspace `worker_env` | **splits** | non-credential vars stay; provider credentials come from the account |
| 18 | `Workspace.worker_env_map/1` | `apps/arbiter/lib/arbiter/tasks/workspace.ex:331` | workspace | **stays** | minus the moved credential keys |
| 19 | `workspaces.encrypted_worker_env` + `worker_env_meta` | `apps/arbiter/lib/arbiter/tasks/workspace.ex:256`, `:270` | workspace | **splits** | §7 |
| 20 | `Dispatch` spawn env + `anthropic_proxy_opts/2` | `apps/arbiter/lib/arbiter/worker/dispatch.ex:2073`, `:2085`, call sites `:1496`, `:1877` | workspace | **stays** | shape unchanged (credentials still arrive as env pairs); the proxy opts die with bd-7cvh8z regardless of this RFC |
| 21 | `Conductor.resolve_workspace_max/3` + `effective_cap/1` | `apps/arbiter/lib/arbiter/workflows/conductor.ex:474`, `:491`, `:513` | workspace + system | **splits** | gains the `account_headroom` term (§4.2) |
| 22 | `Workflows.QuotaGate` behaviour callback | `apps/arbiter/lib/arbiter/workflows/quota_gate.ex:36`, default impl `:83` | `workspace_id` | **moves** | **breaking callback change** to a documented swappable behaviour — call it out in the phase that does it |
| 23 | `Board.Snapshot.effective_max_concurrent/1` | `apps/arbiter/lib/arbiter/board/snapshot.ex:305`, used at `:238` | workspace + system | **splits** | must fold in account headroom or the board lies about slots |
| 24 | `Quota.latest/2`, `latest_for_provider/2`, `serialize/2`, `list_latest/1` | `apps/arbiter/lib/arbiter/quota.ex:290`, `:162`, `:307`, `:579` | `workspace_id` | **moves** | take an account |
| 25 | `Quota.capture_oauth_usage/2` | `apps/arbiter/lib/arbiter/quota.ex:513` | `workspace_id` | **moves** | one call per account per cycle |
| 26 | `Quota.provider_spend/1` | `apps/arbiter/lib/arbiter/quota.ex:607` | `workspace_id` | **splits** | account total is the headline; workspace breakdown stays available |
| 27 | `Quota.default_workspace_id/0`, `default_workspace_on_exhaustion/0` | `apps/arbiter/lib/arbiter/quota.ex:702`, `:728` | workspace | **stays** | workspace routing, not metering |
| 28 | `arb quota` | `apps/arbiter_cli/lib/arbiter_cli/cmd/quota.ex:28`, output at `:96` | `--workspace` | **splits** | gains `--account`; §8 |
| 29 | `arb usage` | `apps/arbiter_cli/lib/arbiter_cli/cmd/usage.ex:13` | `--by …`, `--workspace` | **splits** | gains `--by account`, `--account`; §8 |
| 30 | Web quota/usage surfaces | `apps/arbiter_web/lib/arbiter_web/controllers/api/quota_controller.ex`, `apps/arbiter_web/lib/arbiter_web/live/usage_live.ex`, `apps/arbiter_web/lib/arbiter_web/live/workspace_detail_live.ex` | workspace | **splits** | workspace detail keeps a workspace view that names its account |
| 31 | `MergeWorkerEnv` change | `apps/arbiter/lib/arbiter/tasks/workspace/changes/merge_worker_env.ex` | workspace | **splits** | reused verbatim by the migration to remove moved keys (§7.3) |

---

## 6. Re-keying the quota tables

Three tables, one shape, one migration each:

1. Add nullable `provider_account_id`.
2. Backfill from `workspace_provider_accounts` — a straight join, because the
   existing key `(workspace_id, provider)` is exactly the join's key (§3.3).
3. Collapse duplicates, then flip the identity to
   `(provider_account_id, provider)` and drop `workspace_id`.

**Which row survives the collapse.** The snapshot tables are caches of the latest
reading, not time series (`apps/arbiter/lib/arbiter/quota/anthropic_quota.ex:12`),
so freshest-wins loses nothing: on this install the three rows' header figures
differ only by capture jitter (0.24 / 0.24 / 0.22 at 06:28, per bd-3x0na3 §6).

**The subtlety that a naive collapse gets wrong:** `anthropic_quotas` is written
by *two* actions with **disjoint** `upsert_fields` — `:upsert` (header capture)
and `:record_oauth_usage`
(`apps/arbiter/lib/arbiter/quota/anthropic_quota.ex:32`, `:57`), which is why
there are two independent timestamps, `captured_at` and `oauth_captured_at`
(`apps/arbiter/lib/arbiter/quota/anthropic_quota.ex:113`, `:150`). Newest-row-wins
can therefore silently discard a fresher oauth block. **Collapse per column
group:** header columns from the row with the newest `captured_at`, oauth columns
from the row with the newest `oauth_captured_at`. `codex_quotas` and
`cloud_code_quotas` have a single writer and need no such care.

**How `arb quota` output changes.** Today the header is
`Anthropic quota (workspace <uuid>)`
(`apps/arbiter_cli/lib/arbiter_cli/cmd/quota.ex:96`), printed three times with the
same numbers if you ask three times. After:

```
Anthropic quota (account personal-max · claude · 3 workspaces: default, emricare, vstim)
  representative window: five_hour
  ...
  recent spend (30d): $NN.NN            ← account total
    default $A · emricare $B · vstim $C ← workspace breakdown
```

`--workspace` is kept as a lookup shorthand that resolves to that workspace's
account and adds a "via workspace X" line, so muscle memory and existing scripts
keep working. `--json` gains `account` and `workspaces` keys and retains
`workspace_id` for one release as a deprecated alias (the value of the workspace
that was asked for), so the LiveView and any operator scripts do not break
mid-sequence.

---

## 7. Migrating the encrypted credential material

### 7.1 Census first — read-only, fingerprints only

`mix arbiter.accounts.census` decrypts each workspace's `worker_env` in memory,
partitions its keys into provider-credential keys and everything else, and prints
**counts, key names and fingerprints — never values**. It writes a candidate plan
file (`accounts.json`) the operator edits.

This step exists because the de-duplication rule alone cannot finish the job
(§7.2). Run it, read it, then migrate.

### 7.2 The de-duplication rule, and why the operator confirms it

Group by `(provider, sha256(secret))`. Each distinct fingerprint becomes one
**candidate** account, defaulted to `<provider>-<n>`.

That grouping is sound in one direction only. Fingerprint equality proves
sameness; inequality proves nothing (§2.2), and the counter-example is already on
this host. So the plan is **proposed, not applied**: the operator renames the
candidates and merges any they know to be one plan, then
`mix arbiter.accounts.migrate --plan accounts.json` applies it.

On this install the plan is one line — one account, one credential, three
workspaces — and the migration should proactively offer the operator's
`~/.claude/.credentials.json` token as a **second credential row on the same
account**, since §2.1 establishes it is the same plan. Pre-empting that is
strictly better than letting it be discovered as a merge later.

### 7.3 Splitting a mixed `worker_env` blob

On this install `worker_env` holds only the token. That will not be true in
general, so the rule is conservative:

* **Only allowlisted provider-credential keys move**: `CLAUDE_CODE_OAUTH_TOKEN`,
  `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, the Codex/Gemini/Antigravity
  equivalents. The list is explicit and versioned in the migration.
* **Everything else stays**, including keys that *look* credential-ish. A
  non-allowlisted key is reported by the census, never moved.
* The removal is a **normal `Workspace` update through the existing
  `MergeWorkerEnv` change**
  (`apps/arbiter/lib/arbiter/tasks/workspace/changes/merge_worker_env.ex`), with
  each moved key set to `nil` — that change already treats a null value as
  "remove" (`apps/arbiter/lib/arbiter/tasks/workspace.ex:113`). The encrypted
  column is re-encrypted by the existing code path and `worker_env_meta`
  (`apps/arbiter/lib/arbiter/tasks/workspace.ex:270`) is kept in lockstep
  automatically. **The migration writes no new crypto code**, which is the single
  most valuable property of this plan.

### 7.4 Verifying no plaintext is written anywhere

| Risk | Control |
|---|---|
| Plan file | contains fingerprints and key *names* only. Asserted by a test that feeds a known token through the census and greps the emitted plan for it. Written mode `0600`; deleted after apply. |
| New table | `provider_credentials.encrypted_secret` is `public? false, sensitive? true`, `ash_cloak`-encrypted, and added to the resource's audit `ignore_attributes` — mirroring `apps/arbiter/lib/arbiter/tasks/workspace.ex:95`, which already excludes `encrypted_secrets` and `encrypted_worker_env` from the audit trail. |
| Logs | run the migration with `Logger` at `:info`; the census prints fingerprints only. A test asserts the migration emits no log line containing the secret. |
| Post-migration sweep | scan every `TEXT` column of `provider_accounts`, `provider_credentials` and `workspaces` for the secret's first 12 characters; assert zero hits. |
| SQLite WAL / backups | contain the old **ciphertext** only, which is the pre-existing situation and unchanged by this work. Note however §7.6: that ciphertext is under a key currently considered exposed. |
| Worker process env | unchanged — workers already receive the token as an env var. Changing spawn delivery is an explicit non-goal. |

### 7.5 Rollback

Three releases, with exactly one point of no return, and it is late:

* **Release N — additive.** Create the three tables, populate them, **leave
  `workspaces.encrypted_worker_env` untouched**. Reads still come from the
  workspace; `:provider_accounts_enabled` defaults `false`. *Rollback: flip the
  flag or drop the new tables. Zero data loss.*
* **Release N+1 — read flip.** `ConfigDir.oauth_token/1` and
  `WorkerEnv.resolve/1` source from the account behind the flag. The workspace
  blob is still present and still correct. *Rollback: flip the flag back.*
* **Release N+2 — destructive.** Remove the moved keys from `worker_env`. Before
  deleting, the migration writes the pre-change `worker_env` to a
  `provider_account_migration_backups` row, **encrypted with the same Vault** —
  never a plaintext file on disk. `mix arbiter.accounts.rollback` re-merges it
  through `MergeWorkerEnv`. *Rollback from here is a restore, and is gated on
  that backup row existing.*

Splitting the read flip from the destructive step is what makes N+1 free to
reverse. Do not collapse them to save a release.

### 7.6 `ARBITER_CLOAK_KEY` rotation: **keep it separate, and do it first**

The key is considered exposed (printed into a transcript, 2026-09-12). The
question is whether a re-encryption pass should ride along with this migration.

**Recommendation: strictly separate, and sequenced *before* extraction.**

1. **Urgency mismatch.** This RFC's migration is a three-release sequence gated
   on an operator reviewing a census — that is weeks. Key rotation is a
   credential-hygiene action that should happen now. Coupling them delays the
   urgent thing for no benefit.
2. **Different blast radius, different rollback.** Rotation touches **every**
   encrypted column — `encrypted_secrets` and `encrypted_worker_env`
   (`apps/arbiter/lib/arbiter/tasks/workspace.ex:240`, `:256`) — and its failure
   mode is "nothing decrypts". Extraction touches one key inside one column and
   its failure mode is "a worker spawns without a token". Fused, a failure is
   ambiguous: you cannot tell which half broke, and the rollback for one is not
   the rollback for the other.
3. **Cloak already supports rotation natively**, as two ciphers with distinct
   tags: add the new cipher as `:default`, keep the old one for decryption, sweep
   to re-encrypt, drop the old. `Arbiter.Vault.init/1` builds a single-element
   `ciphers` list (`apps/arbiter/lib/arbiter/vault.ex:26`), so rotation is a
   small self-contained change plus a re-encrypt task. It does not need this RFC,
   and `apps/arbiter/lib/arbiter/vault.ex:17` already declares the runbook a
   separate concern — **file it as its own ticket**.
4. **But the exposure means something concrete for this work, and the order
   matters.** Rotating the Cloak key protects future ciphertext; it does not help
   a provider token that may already have been read. So the correct order is:
   **(a) rotate `ARBITER_CLOAK_KEY`, (b) rotate the provider credential itself (a
   fresh `claude setup-token` grant), (c) then extract.** Extraction is also what
   makes (b) a one-place operation instead of three — a reason to do it *soon*,
   not a reason to fuse it with (a).
5. **Do not invert (a) and (c).** Extraction re-encrypts the moved value into a
   new row. Running it before the key rotation writes fresh ciphertext under a
   known-exposed key, and then the rotation sweep has to cover the new table too.
   Stated explicitly here so nobody sequences it the other way.

---

## 8. Cost rollups per account

The operator's actual question is *"how much of this plan did I spend?"* That is
an account question, and today nothing can answer it.

**Schema.** `usage_events` gains `provider_account_id` (uuid, nullable) and
`provider_credential_id` (uuid, nullable), written wherever `workspace_id` is
written today (`apps/arbiter/lib/arbiter/usage/event.ex:104`). Backfill from
`workspace_provider_accounts`. The backfill is exact for any period in which a
workspace's account for that provider did not change — trivially true
pre-migration, since accounts did not exist.

**CLI.** `arb usage --by account` is one new clause in
`Arbiter.Usage.summarize/1`'s `group_events/2`
(`apps/arbiter/lib/arbiter/usage.ex:203`–`:210`); `--account <slug>` mirrors the
existing `--workspace` filter
(`apps/arbiter_cli/lib/arbiter_cli/cmd/usage.ex:13`). `arb quota --account`
reports the account total via a re-keyed `Quota.provider_spend/1`
(`apps/arbiter/lib/arbiter/quota.ex:607`) with the per-workspace breakdown under
it (§6).

**Composition with bd-adyhvn.** The two dimensions are orthogonal and
multiplicative — bd-adyhvn's `source` answers *what spent it*, the account
answers *whose plan paid* — and because both are columns on the same row, the
seam is a schema ordering question, not an integration.

The seam, stated concretely so bd-adyhvn can document it:

* bd-adyhvn makes `task_id` nullable and adds
  `source ∈ task | probe | preflight | coordinator_session | terminal_session`.
* **A probe or preflight row has no meaningful workspace, but it always has an
  account** — a probe is issued *as* a credential. So once both land,
  `provider_account_id` should be **non-null for `source: probe | preflight`**
  even while `workspace_id` and `task_id` are null. That is the falsifiable
  statement of the seam.
* Consequence for rollups: `arb usage --by account` must **include** probe rows,
  or it under-reports the plan — which is exactly the bias bd-adyhvn measured
  (unmetered probes consume window percentage without contributing ledger
  dollars, understating `$ per 1%`).
* **Ordering consequence: bd-adyhvn lands first.** Its nullable `task_id` is what
  lets probe rows exist at all, and landing it first means `usage_events` gets
  its account column added once, to a table already in its final nullability
  shape. The reverse order migrates `usage_events` twice. This feeds §9.

---

## 9. Sequencing against work in flight

**The invariant: `usage_events` and the quota tables each get re-keyed exactly
once.**

| Order | Work | Why here |
|---|---|---|
| 1 | **bd-5xuneh** — de-dup `/api/oauth/usage` by token | Ship now, **unchanged**. It is a live overdraw and this RFC is weeks from landing anything. It changes no schema, so it cannot cause a double re-key. |
| 2 | **bd-3uwku6** — parse `resets_at` / claim / overage / status out of the body | Independent of keying. Parallel with 1. |
| 3 | **bd-adyhvn** — nullable `task_id` + `source` | Before any `usage_events` re-key (§8). |
| 4 | **bd-b0zody** — polled figures into the primary quota columns | Touches `anthropic_quotas` **columns**; must **not** touch its `(workspace_id, provider)` identity. Stated as an explicit constraint on that ticket. |
| 5 | **bd-atyrrq** — delete `RefreshProbe` | Deleting a workspace-keyed surface is strictly cheaper than re-keying it and then deleting it. Row 11 of §5 disappears entirely. |
| 6 | **bd-7cvh8z** — remove the proxy | Same argument: removes `worker_base_url/1` and the `Dispatch` proxy-opts clause before the re-key has to reason about them. |
| 7 | **This RFC's phases P0–P12** | The re-key happens once, against a smaller surface than exists today. |

**bd-5xuneh's fingerprint grouping: deleted by bd-4fbpto, not promoted.**

This section originally argued the grouping's *shape* was right and only its
*key* was a guess — group by `provider_account_id` instead of
`ConfigDir.oauth_token/1`, keep the fetch-once-per-group code otherwise
verbatim. bd-4fbpto found that premise wrong, not just imprecise: the
`worker_env` token bd-5xuneh grouped on cannot authenticate
`/api/oauth/usage` at all (it 429s distinctly from the credentials-file
token — see PR #1607 for the status codes), so grouping workspaces by that
token was never a valid de-duplication of a *shared* fetch — every group was
going to fail regardless of key. bd-4fbpto deleted the grouping function
entirely; `CloudProbe` now fetches once per cycle for the whole install using
the credentials-file token unconditionally, because today's install has
exactly one account.

That means **P6 is not a re-key of surviving code — it has to build account
iteration from scratch.** Once `ProviderAccount` exists, P6 iterates accounts
(not tokens) and, for each, calls `/api/oauth/usage` with that account's
credential; the workspace-token grouping bd-5xuneh wrote is gone and
contributes nothing to that loop. Re-keying `OAuthUsage.fetch/1`'s 429
cooldown (`apps/arbiter/lib/arbiter/quota/oauth_usage.ex:207`, currently
keyed on `phash2(token)`) to the account id is unaffected by the deletion and
still belongs in P6 — it closes the gap bd-3x0na3 flagged, where two distinct
tokens on one account get two independent cooldowns for one shared
per-account limit.

So: **P6 is now sized like a normal phase, not a small substitution.**

---

## 10. Phase table

Each phase is sized to be one child ticket.

| Phase | What | Depends on | Priority | Difficulty |
|---|---|---|---|---|
| **P0** | `mix arbiter.accounts.census` — read-only; fingerprints and key names only; emits the candidate plan | — | P2 | D2 |
| **P1** | `ProviderAccount` / `ProviderCredential` / `WorkspaceProviderAccount` resources + migration. Tables only; nothing reads them | P0 | P2 | D2 |
| **P2** | Plan-driven extraction: move allowlisted keys, encrypted backup row, `mix arbiter.accounts.rollback`. Flag off; workspace blob still authoritative | P1 | P2 | D3 |
| **P3** | Read-path flip behind `:provider_accounts_enabled` — `ConfigDir.oauth_token/1`, `ConfigDir.env/1`, `WorkerEnv.resolve/1` source from the account | P2 | P2 | D3 |
| **P4** | Destructive step: remove moved keys from `worker_env`; delete `ConfigDir`'s server-env and install-wide-unambiguous fallbacks | P3 | P2 | D2 |
| **P5** | Re-key the three quota tables to `(provider_account_id, provider)`; per-column-group collapse (§6) | P3, bd-b0zody, bd-7cvh8z | **P1** | D3 |
| **P6** | Build account iteration in the probes: `CloudProbe` fetches `/api/oauth/usage` once per account (bd-4fbpto deleted bd-5xuneh's per-token grouping; this is new code, not a re-key of it — §9); `OAuthUsage` cooldown keyed by account | P5 | P2 | D2 |
| **P7** | Account-wide quota hold: `QuotaGate` callback takes an account (**breaking behaviour change**); thresholds `min(account, workspace)` | P5 | **P1** | D3 |
| **P8** | Account concurrency ceiling + per-workspace share; registry-derived live count; `Board.Snapshot` folds it in | P7 | P2 | D3 |
| **P9** | `usage_events.provider_account_id` + `provider_credential_id` + backfill | bd-adyhvn, P2 | P2 | D2 |
| **P10** | `arb usage --by account` / `--account`; `arb quota --account`; JSON + LiveView surfaces | P9, P5 | P3 | D2 |
| **P11** | `arb account` CLI: list / show / create / attach / rotate / **merge** (§2.5) | P2 | P2 | D2 |
| **P12** | Docs + moduledocs: retire the "quota is per workspace" mental model | P10 | P3 | D1 |

P5 and P7 are P1 because they are the correctness fixes — the gate is only sound
once the budget, the cap and the quota live on the same object.

---

## 11. Non-goals, and what they unlock later

**Non-goals for this design:**

* **Credential rotation as a feature.** P11's `rotate` is "insert a new
  credential version and retire the old" — a data operation, not automated
  rotation.
* **Multi-account load balancing.** Not designed. The model *allows* it: nothing
  here assumes one account per workspace-provider except one unique index on
  `workspace_provider_accounts (workspace_id, provider)`. Relaxing it plus a
  selection policy is the whole of that future feature.
* **Changing how workers receive credentials at spawn.** They still arrive as env
  pairs; only the source moves.
* **`ARBITER_CLOAK_KEY` rotation.** Separate ticket, sequenced *before* this work
  (§7.6).
* **Reservations (as opposed to caps) for per-workspace shares.** Needs
  cross-Conductor admission ordering that does not exist. Named in §4.3.

---

## Appendix A — what was run for this RFC

A throwaway read-only spike, 2026-09-12, on the dogfood host. No files were
written outside `/tmp`, no code was changed, and no credential value was printed,
logged or committed.

1. **Credential file shape** — parsed `~/.claude/.credentials.json` and
   `~/.claude.json` in Python, printing key names, types and sha256 prefixes
   only. Established that `claudeAiOauth` carries **no** account identifier, and
   that `~/.claude.json`'s `oauthAccount` block (the CLI's own cache) carries
   `accountUuid` / `emailAddress` / `organizationUuid`.
2. **Endpoint discovery** — `strings` over the Claude Code CLI binary
   (`~/.local/share/claude/versions/2.1.269`) for `/api/` paths, then a bounded
   byte-slice read around the match. Found `/api/oauth/profile` ("Failed to fetch
   oauth profile from OAuth token"), `/api/claude_cli_profile` (API-key variant)
   and `/api/oauth/validate`.
3. **Workspace credential census** — `mix run --no-start` with
   `Exqlite.Sqlite3.open(..., mode: :readonly)` against the live
   `~/dev/arbiter_dev.sqlite3`, decrypting `workspaces.encrypted_worker_env`
   through `Arbiter.Vault` exactly as
   `Arbiter.Tasks.Workspace.worker_env_map/1` does
   (`Base.decode64!` → `Vault.decrypt!` → `non_executable_binary_to_term`).
   Printed sha256 prefixes and key names only. Result: 3 workspaces, 1 distinct
   token, `["CLAUDE_CODE_OAUTH_TOKEN"]` and nothing else in each.
4. **Four HTTP requests**, all `GET` except where noted:
   `/api/oauth/profile` with the workspace token → **403 oauth_scope_insufficient**;
   `/api/oauth/profile` with the operator token → **200** (shape in §2.1);
   `GET /api/oauth/validate` with the workspace token → **405** (POST-only);
   `POST /api/oauth/validate` with the workspace token → **403**, same scope error.
   **`/api/oauth/usage` was deliberately not called** — it is rate-limited to
   roughly one request per five minutes *per account* and the live coordinator
   polls it, so probing it would have degraded the running fleet's quota capture
   (bd-3x0na3 §4 measured exactly that effect).

**Not established, and stated as such:** whether any scope combination lets a
`claude setup-token` grant read its own profile — only the two endpoints above
were tried, and both rejected the grant it has. If a future CLI mints
profile-scoped worker grants, `provider_account_ref` can be populated
automatically; the design does not depend on it ever happening.
