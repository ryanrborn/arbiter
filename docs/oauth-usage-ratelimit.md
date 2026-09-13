# /api/oauth/usage Rate-Limit Behaviour

**Measured in bd-3x0na3.** This documents undocumented upstream behavior discovered
during quota polling integration.

## Key observations

- **Rate limit is per account, not per token.** A second distinct OAuth token on
  the same account is rate-limited identically to the first. Workspace-scoped
  tokens are scope/rate-limited and will not work against this endpoint; only
  the operator's credentials-file token succeeds (confirmed in PR #1607).

- **Small burst bucket refilling at ~1 request / 5 minutes.** The rate limit
  horizon is account-wide. A second request ~1 second after a success responds
  with 429.

- **`retry-after: 0` header is uninformative.** Do not trust it for cooldown
  timing. `Arbiter.Quota.OAuthUsage` uses a fixed 180s cooldown instead (see
  `@cooldown_ms` in that module).

## Response shape and mapping

The endpoint returns quota data as JSON with these keys. They map to the
`anthropic-ratelimit-unified-*` headers that appear on worker responses:

### 5-hour window

- `five_hour_utilization_percentage` → `anthropic-ratelimit-unified-5h-utilization`
- `five_hour_quota_reset_at` → `anthropic-ratelimit-unified-5h-reset`
- `five_hour_status` → `anthropic-ratelimit-unified-5h-status`

### 7-day window

- `seven_day_utilization_percentage` → `anthropic-ratelimit-unified-7d-utilization`
- `seven_day_quota_reset_at` → `anthropic-ratelimit-unified-7d-reset`
- `seven_day_status` → `anthropic-ratelimit-unified-7d-status`

### Per-model breakdown (7-day)

- `usage_by_model`: map of model name to `{tokens_used, tokens_requested}`
  - Maps to stream items like `seven_day_sonnet`, `seven_day_opus`, etc.

### Account overage

- `representative_claim` → `anthropic-ratelimit-unified-representative-claim`
- `overage_status` → `anthropic-ratelimit-unified-overage-status`
- `extra_usage`: map with billing details for out-of-quota usage

## Implications

Because this endpoint rate-limits per account and refills slowly (~1 req/5min),
it is the primary constraint on quota polling. `Arbiter.Quota.CloudProbe` runs
once per cycle for the whole install (not per-workspace), authenticating with
the operator's credentials-file token, which is the only token that works.

When a 429 occurs, `Arbiter.Quota.OAuthUsage.fetch/1` cools down for 180s; during
this window, the gate's staleness margin absorbs the missed poll without losing
visibility into quota state (see `Arbiter.Quota.Gate.staleness_threshold_seconds/1`).

The header-capture source (`anthropic-ratelimit-unified-*` from worker responses)
continues unaffected by endpoint 429s, but only provides aggregate figures and
only updates when the fleet is actively making requests. The polling source
is the only way to maintain quota visibility for an idle or quota-held fleet.
