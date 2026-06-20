# Arbiter Operator Reference

Configuration and operational guidance for running an Arbiter workspace.

## Workspace config (`config` JSON column)

All keys are optional. Unknown keys are allowed (forward-compat).

---

### `tribunal` — Tribunal (code-review gate) settings

Controls the revise-and-rediscuss loop run by the Tribunal when a reviewer
requests changes.

#### `tribunal.max_rounds` (integer, optional)

Hard cap on the number of revise-and-rediscuss rounds before the Tribunal
escalates to the Admiral. Must be a positive integer (≥ 1).

When absent, the cap is derived from the task's difficulty:

| Difficulty | Label    | Default rounds |
|------------|----------|---------------|
| D0         | trivial  | 2             |
| D1         | simple   | 2             |
| D2         | moderate | 3 (default)   |
| D3         | hard     | 4             |
| D4         | extreme  | 4             |

When both a difficulty default and a workspace cap are set, the **lower** value
wins: `min(difficulty_default, max_rounds)`. The workspace cap can only tighten
the limit — it cannot raise it above the difficulty ceiling.

**Example** — cap all tasks at 2 rounds regardless of difficulty:

```json
{
  "tribunal": {
    "max_rounds": 2
  }
}
```

---

### `review` — review gate toggle

#### `review.required` (boolean, optional, default `false`)

Enable the Tribunal gate for this workspace. When `true`, a task's `arb done`
parks at `:awaiting_tribunal` and a distinct reviewer acolyte runs before
anything merges.

---

### `merge` — merge adapter settings

#### `merge.strategy` (string, optional, default `"direct"`)

One of `"direct"`, `"gitlab"`, `"github"`.

#### `merge.auto_merge` (boolean, optional, default `false`)

When `true`, an approved merge request is merged automatically by the Warden
without waiting for a human merge action.

#### `merge.warden_max_polls` (integer or `"infinity"`, optional)

Override the Warden watchdog poll limit. Defaults to the mode-specific value
(`auto_merge: true` uses a bounded default; `auto_merge: false` polls
indefinitely).

---

### `agent` / `review_agent` — model routing

#### `agent.type` (string or list, optional)

Which provider to use for worker acolytes: `"claude"` or `"gemini"` (or a list
for a multi-provider pool).

#### `agent.config` (map, optional)

Provider-specific model config (e.g. `"model"`, `"model_tier"`, `"thinking"`).

#### `review_agent.type` / `review_agent.config`

Same as `agent`, but applied to the reviewer acolyte. Falls back to the `agent`
block when absent.

---

### `routing` — model selection policy

#### `routing.policy` (string, optional, default `"static"`)

One of `"static"`, `"by_priority"`, `"by_difficulty"`, `"by_budget"`,
`"round_robin"`.

---

### `tracker` — external issue tracker

#### `tracker.type` (string, optional, default `"none"`)

One of `"none"`, `"jira"`, `"shortcut"`, `"linear"`, `"github"`.

#### `tracker.config` (map, optional)

Adapter-specific credentials and identifiers (e.g. `"host"`, `"project_key"`,
`"credentials_ref"`).
