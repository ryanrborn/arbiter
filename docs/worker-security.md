# Worker security: configurable permissions & sandboxing

**Task:** bd-9u10op · **Builds on:** bd-c6xf18 (pluggable agent harness),
bd-3y2mda (config-dir isolation)

## The problem this fixes

A worker (a worker or reviewer) is an autonomous coding agent spawned in a
git worktree via `claude --print …`. Before this change it ran with **no
permission flags**, so it silently inherited the **host operator's** global
`~/.claude/settings.json` — which on a developer install routinely carried
`defaultMode: auto` with an **empty deny list** — and it ran **un-sandboxed**
on the host, with full filesystem and network reach, contained to its worktree
only by convention.

On 2026-06-03 that posture bit us: with an empty deny and no sandbox, a
stack-lifecycle worker's `git merge` wedged the live server. There was no
Arbiter-level way to say "a worker in this domain may do X but not Y, and is
isolated to its worktree."

This change makes the posture **explicit, configurable, and
provider-agnostic**.

## The model

A single normalized, provider-agnostic policy —
`Arbiter.Agents.SecurityPolicy` — that every provider adapter maps to its own
mechanism. The policy names *intent*; it never speaks any provider's flag
syntax.

```elixir
%Arbiter.Agents.SecurityPolicy{
  permissions: %{
    mode: :auto | :strict | :bypass,
    allow: ["…"],            # operator-added allow rules
    deny:  ["…"],            # operator-added deny rules
    safe_defaults: [:no_destructive_fs, :no_force_push,
                    :no_secret_reads, :no_outside_writes]
  },
  sandbox: %{
    enabled: true,
    filesystem: :worktree | :none,
    network: true | false
  }
}
```

### Permission modes

| Mode      | Meaning                                                                     | Interactive classifier? | Deny enforced? |
|-----------|-----------------------------------------------------------------------------|------------------------|----------------|
| `:bypass` | **Headless-safe default.** No interactive classifier; deny list still on.   | **no** (headless-safe) | **yes**        |
| `:auto`   | Opt-in for supervised runs. Classifier active; can pause and ask approval.  | yes (can freeze)       | **yes**        |
| `:strict` | Only explicitly-allowed tools run; everything else is blocked.              | yes (collapses to deny)| **yes**        |

#### Why `:bypass` is the headless-safe default

Workers are headless — they run via `claude --print` with no human watching.
The interactive permission classifier in `:auto` mode was designed for
*interactive* sessions: it can pause and ask "do you want to allow this?" When
no human is present, that prompt has no one to answer it, and the worker
freezes mid-task. The task stalls silently.

`:bypass` uses `--dangerously-skip-permissions` to skip the interactive
classifier entirely, preventing headless freezes. Crucially, the deny list is a
**separate, orthogonal mechanism** — deny rules are hard tool-level blocks
enforced at the tool layer, and they are still applied via `--settings` even
in `:bypass` mode. So:

> **Worktree containment = blast-radius fence. Deny list = real security fence.
> `:bypass` = headless-safe, deny list on.**

Use `security.mode: auto` in workspace config if you want the interactive
classifier (and accept the freeze risk for headless runs). Use `:strict` for
the tightest allow-list posture.

### Safe-by-default deny

`safe_defaults` is the **non-empty** baseline every adapter must deny, even in
`auto`. The categories:

| Category             | Blocks (examples)                                         |
|----------------------|-----------------------------------------------------------|
| `:no_destructive_fs` | `rm -rf`, `mkfs`, `dd`                                     |
| `:no_force_push`     | `git push --force` / `-f` (`--force-with-lease` is allowed)|
| `:no_secret_reads`   | reading `.env`, `*.pem`, `~/.ssh/**`, cloud creds          |
| `:no_outside_writes` | writing `/etc/**`, `~/.ssh/**`, `~/.claude/**`, …          |

Set `safe_defaults: []` to opt a domain out (not recommended). **Effective floor
caveat:** the isolated `CLAUDE_CONFIG_DIR/settings.json` is generated once from
the install-default policy (which includes all four safe-default categories) and
Claude unions deny lists across settings sources. Setting `safe_defaults: []` in
workspace config removes those categories from the per-spawn `--settings` deny
list, but the config-dir floor still carries them. The practical effect is that
the config-dir safe-default denies are a **hard minimum** that cannot be removed
through workspace config alone — only changing `SecurityPolicy.base/0` or the
install-level `:acolyte_security_policy` app env removes them.

### Sandbox

`filesystem: :worktree` keeps file access scoped to the handed worktree;
`network: false` cuts the agent's **network-egress tools** (`WebFetch`,
`WebSearch`, `curl`, `wget`, `nc`, …). It does **not** block native OS network
traffic (`git push`, package installs, SSH) — those require a kernel-level
sandbox. The badge and surface show `net=tools-off` to make this scope explicit.

> **Enforcement level — be honest about it.** For the Claude provider these are
> *permission-layer* guards inside the agent (it won't run a denied command),
> not a kernel jail. They stop the failure mode of the motivating incident (the
> agent's own destructive op) and are a strict improvement over inheriting an
> empty deny. Genuine OS-level isolation (network namespaces, a real fs jail)
> is a documented follow-up; the `sandbox.enabled` field is the seam for it.

## Configuring it

### Per-domain (the common case)

Set it in the workspace `config` JSON under `agent.security` — no source edits,
no touching anyone's `~/.claude`. The default is `:bypass` (headless-safe). To
opt into the interactive classifier (and accept the freeze risk), set
`"mode": "auto"`:

```json
{
  "agent": {
    "type": "claude",
    "config": { "model": "sonnet" },
    "security": {
      "permissions": {
        "mode": "auto",
        "deny": ["Bash(docker:*)"],
        "allow": ["Bash(npm run test:*)"]
      },
      "sandbox": { "filesystem": "worktree", "network": false }
    }
  }
}
```

**⚠️ Deprecated paths — do not use in new configs:**

The following paths are accepted for backward compatibility with old configs
but **must not** be used in new work. Always use the canonical
`agent.security.permissions.mode` path shown above:

- `workspace.config["security"]["mode"]` — **deprecated**
- `workspace.config["agent"]["config"]["security_mode"]` — **deprecated**

These alternate paths exist only to avoid breaking old configs; no new
workspace should rely on them.

### Per-repo override (multi-repo workspaces)

A workspace whose repos need *different* postures — e.g. one repo runs stricter
or with network egress cut — adds a `"repos"` map under `agent.security`, keyed
by the same repo name used in `config["repo_paths"]`. The repo block is layered
over the workspace-wide posture for that repo only; every other repo resolves
the workspace-wide default unchanged. No new config surface — it's the same
generic `config` JSON (`arb config set` / `workspace_config_set`).

```json
{
  "agent": {
    "security": {
      "permissions": { "mode": "auto", "deny": ["Bash(docker:*)"] },
      "sandbox": { "network": true },
      "repos": {
        "device": {
          "permissions": { "mode": "strict", "deny": ["Bash(curl:*)"] },
          "sandbox": { "network": false }
        }
      }
    }
  }
}
```

Here the `device` repo resolves `mode: strict`, `network: false`, and a deny
list of *both* `Bash(docker:*)` (workspace) and `Bash(curl:*)` (repo) — deny
unions across layers, scalars replace. The dispatch threads the resolved repo
name (`Dispatch` `:repo` opt) into `SecurityPolicy.resolve/3`.

### Install-wide default

Override the floor every domain inherits via application config (see
`config/config.exs`):

```elixir
config :arbiter, :acolyte_security_policy, %{
  "permissions" => %{"mode" => "auto"},
  "sandbox" => %{"network" => false}
}
```

The hardcoded safe baseline lives in `Arbiter.Agents.SecurityPolicy.base/0`.

### Per-task / per-dispatch override

`Arbiter.Worker.Dispatch.dispatch/2` accepts a `:security` map (same shape as
`agent.security`) or a `:security_mode` shorthand, layered last.

### Resolution precedence

`base/0` → `:acolyte_security_policy` app env → `workspace.config["agent"]["security"]`
→ `workspace.config["agent"]["security"]["repos"][repo]` (only when a repo name
is passed) → per-dispatch override. `allow`/`deny` **union** across layers;
`mode`, `safe_defaults`, and `sandbox` fields are **replaced** by the highest
layer that sets them.

## How the Claude adapter maps it

`Arbiter.Agents.Claude.Security` translates the normalized policy into the CLI:

* **mode** → `--dangerously-skip-permissions` for `:bypass` (the default);
  `--permission-mode auto|default` for `:auto`/`:strict`. In all modes, deny
  rules are applied via `--settings` — bypass only skips the interactive
  classifier, not the deny list.
* **allow / deny / safe_defaults / sandbox** → an inline
  `--settings '<json>'` permission document (the CLI accepts a JSON string, so
  there is no shared-file race and nothing is read from `~/.claude`).

### No more host inheritance

`Arbiter.Agents.Claude.ConfigDir` runs every worker against an isolated
`CLAUDE_CONFIG_DIR`. It now:

* **symlinks only `.credentials.json`** (OAuth/token refresh) from the operator
  dir,
* **generates `settings.json`** from the install-default policy — a hardened,
  non-empty-deny floor — instead of symlinking the operator's, and
* writes its own task-focused `CLAUDE.md` (never the operator's persona).

So no worker spawn — worker, reviewer, or bare ad-hoc run — inherits the host
operator's permission posture.

## Provider-agnostic by construction

`SecurityPolicy` carries no Claude-specific syntax. The `Arbiter.Agents.Agent`
behaviour contract requires any adapter to:

1. Map the normalized `:security` policy to its provider's mechanism.
2. Enforce a non-empty destructive-op deny baseline (the policy's
   `safe_defaults`) in `:auto` and `:strict` modes.
3. Not fall through to the host operator's personal agent config.
4. Implement `security_enforced?/0` returning `true` once it honors the above.

**Current status:** only the `Claude` adapter enforces the policy
(`security_enforced? = true`). Future adapters (antigravity, Codex, …) implement
the same contract their own way. Until an adapter implements it, the REST
`security_posture.policy_enforced` field returns `false` so operators can see
whether the declared posture is actually being enforced by the running adapter.

## Where the posture is surfaced

* **`arb prime`** — a `security:` block in the active-workspace section (mode,
  sandbox, deny counts).
* **Dashboard** — a per-worker permission-mode badge on the active workers
  list (ghost for `auto`, warning for `strict`, error for `bypass`).
* **REST** — `GET /api/workspaces/:id` includes a resolved `security_posture`
  object with `provider`, `policy_enforced`, and the full policy summary. This
  is the single source of truth both surfaces read.
