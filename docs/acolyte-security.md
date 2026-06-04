# Acolyte security: configurable permissions & sandboxing

**Bead:** bd-9u10op · **Builds on:** bd-c6xf18 (pluggable agent harness),
bd-3y2mda (config-dir isolation)

## The problem this fixes

An acolyte (a worker or reviewer) is an autonomous coding agent spawned in a
git worktree via `claude --print …`. Before this change it ran with **no
permission flags**, so it silently inherited the **host operator's** global
`~/.claude/settings.json` — which on a developer install routinely carried
`defaultMode: auto` with an **empty deny list** — and it ran **un-sandboxed**
on the host, with full filesystem and network reach, contained to its worktree
only by convention.

On 2026-06-03 that posture bit us: with an empty deny and no sandbox, a
stack-lifecycle acolyte's `git merge` wedged the live server. There was no
Arbiter-level way to say "an acolyte in this domain may do X but not Y, and is
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

| Mode      | Meaning                                                        | Deny enforced? |
|-----------|---------------------------------------------------------------|----------------|
| `:auto`   | Safe default. Works autonomously; edits auto-accepted.        | **yes**        |
| `:strict` | Only explicitly-allowed tools run; everything else is blocked.| **yes**        |
| `:bypass` | Escape hatch — *all* checks skipped, including the deny list.  | no             |

`:auto` is the safe default: an acolyte can get its job done without a human in
the loop, but the destructive-op deny list is **still enforced**. `:bypass`
requires deliberate opt-in and should only be used for a run you already trust
(e.g. one wrapped in external OS isolation).

### Safe-by-default deny

`safe_defaults` is the **non-empty** baseline every adapter must deny, even in
`auto`. The categories:

| Category             | Blocks (examples)                                         |
|----------------------|-----------------------------------------------------------|
| `:no_destructive_fs` | `rm -rf`, `mkfs`, `dd`                                     |
| `:no_force_push`     | `git push --force` / `-f` (`--force-with-lease` is allowed)|
| `:no_secret_reads`   | reading `.env`, `*.pem`, `~/.ssh/**`, cloud creds          |
| `:no_outside_writes` | writing `/etc/**`, `~/.ssh/**`, `~/.claude/**`, …          |

Set `safe_defaults: []` to opt a domain out (not recommended).

### Sandbox

`filesystem: :worktree` keeps file access scoped to the handed worktree;
`network: false` cuts the agent's network-egress tools (`WebFetch`,
`WebSearch`, `curl`, `wget`, `nc`, …).

> **Enforcement level — be honest about it.** For the Claude provider these are
> *permission-layer* guards inside the agent (it won't run a denied command),
> not a kernel jail. They stop the failure mode of the motivating incident (the
> agent's own destructive op) and are a strict improvement over inheriting an
> empty deny. Genuine OS-level isolation (network namespaces, a real fs jail)
> is a documented follow-up; the `sandbox.enabled` field is the seam for it.

## Configuring it

### Per-domain (the common case)

Set it in the workspace `config` JSON under `agent.security` — no source edits,
no touching anyone's `~/.claude`:

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

### Per-bead / per-dispatch override

`Arbiter.Polecat.Sling.sling/2` accepts a `:security` map (same shape as
`agent.security`) or a `:security_mode` shorthand, layered last.

### Resolution precedence

`base/0` → `:acolyte_security_policy` app env → `workspace.config["agent"]["security"]`
→ per-dispatch override. `allow`/`deny` **union** across layers; `mode`,
`safe_defaults`, and `sandbox` fields are **replaced** by the highest layer
that sets them.

## How the Claude adapter maps it

`Arbiter.Agents.Claude.Security` translates the normalized policy into the CLI:

* **mode** → `--permission-mode auto|default` (or
  `--dangerously-skip-permissions` for `:bypass`).
* **allow / deny / safe_defaults / sandbox** → an inline
  `--settings '<json>'` permission document (the CLI accepts a JSON string, so
  there is no shared-file race and nothing is read from `~/.claude`).

### No more host inheritance

`Arbiter.Agents.Claude.ConfigDir` runs every acolyte against an isolated
`CLAUDE_CONFIG_DIR`. It now:

* **symlinks only `.credentials.json`** (OAuth/token refresh) from the operator
  dir,
* **generates `settings.json`** from the install-default policy — a hardened,
  non-empty-deny floor — instead of symlinking the operator's, and
* writes its own task-focused `CLAUDE.md` (never the operator's persona).

So no acolyte spawn — worker, reviewer, or bare ad-hoc run — inherits the host
operator's permission posture.

## Provider-agnostic by construction

`SecurityPolicy` carries no Claude-specific syntax. A second provider (e.g.
antigravity) implements the same contract: take the normalized policy, fold in
its own non-empty destructive-op deny baseline (except in `:bypass`), and emit
its own flags. The dispatcher, the workspace config shape, `arb prime`, and the
dashboard are unchanged by adding a provider.

## Where the posture is surfaced

* **`arb prime`** — a `security:` block in the active-workspace section (mode,
  sandbox, deny counts).
* **Dashboard** — a per-acolyte permission-mode badge on the active workers
  list (ghost for `auto`, warning for `strict`, error for `bypass`).
* **REST** — `GET /api/workspaces/:id` includes a resolved `security_posture`
  object (the single source of truth both surfaces read).
