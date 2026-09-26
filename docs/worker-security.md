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
                    :no_secret_reads, :no_outside_writes],
    safe_defaults_exclude: []   # names dropped from the current default set
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
`auto`. It always resolves to the **current full set of default categories
minus any explicit exclusions** — a workspace can only shrink it by naming
categories in `safe_defaults_exclude`, never by pinning a fixed list. This
means a workspace config written before a new category existed still picks
that category up automatically the moment it ships (see bd-4420va: a pinned
`safe_defaults` from before v0.1.78 silently missed `:no_public_upload` until
this rule was added). The legacy `permissions.safe_defaults` config key is
still accepted for backward compatibility but is **inert** — its value is
ignored entirely, since the resolved set is always computed from the current
defaults. The categories:

| Category             | Blocks (examples)                                         |
|----------------------|-----------------------------------------------------------|
| `:no_destructive_fs` | `rm -rf`, `mkfs`, `dd`                                     |
| `:no_force_push`     | `git push --force` / `-f` (`--force-with-lease` is allowed)|
| `:no_secret_reads`   | reading `.env`, `*.pem`, `~/.ssh/**`, cloud creds          |
| `:no_outside_writes` | writing `/etc/**`, `~/.ssh/**`, `~/.claude/**`, …          |
| `:no_pr_create`      | `gh pr create`, `glab mr create` (the MergeQueue owns PRs) |
| `:no_async_wait`     | the `Monitor` / `ScheduleWakeup` tools (Claude only)       |
| `:no_public_upload`  | public upload/paste hosts                                  |
| `:no_gh_publish`     | `gh gist create`/`edit`, `gh issue comment` (workers only) |

### Public upload and paste hosts (`:no_public_upload`, `:no_gh_publish`, bd-80talz)

On bd-aro53b an agy worker made a public gist on the operator's account and
uploaded mockup "screenshots" to files.catbox.moe. It also tried 0x0.st,
transfer.sh and envs.sh. A public, anonymous host accepts repo content, logs
or secrets as easily as images, and usually keeps them for good.
`SecurityPolicy.public_upload_hosts/0` is the documented host list, as bare
domains:

> catbox.moe (and litterbox, litter.catbox.moe), 0x0.st, transfer.sh,
> file.io, envs.sh, x0.at, temp.sh, tmpfiles.org, uguu.se, bashupload.com,
> oshi.at, keep.sh, filebin.net, pixeldrain.com, gofile.io, pastebin.com,
> paste.ee, paste.rs, dpaste.com, dpaste.org, hastebin.com, termbin.com,
> ix.io, sprunge.us, rentry.co, controlc.com, justpaste.it, privatebin.net,
> imgur.com, imgbb.com, postimages.org

| Provider | URL tools | Shell | Commands |
|----------|-----------|-------|----------|
| Claude | `WebFetch(domain:<host>)` + `WebFetch(domain:*.<host>)` | `Bash(<tool> *<host>*)` for `curl`, `wget`, `http`, `nc` | `gh gist create`/`edit`, `gh issue comment` |
| agy | `read_url(<host>)` + `execute_url(<host>)` (a bare domain covers its subdomains; probed) | **by host: not expressible** (`command(...)` is a literal prefix, a glob in it matches nothing; probed). Upload-shaped `curl -F`/`--form`/`-T`/`--upload-file` prefixes are denied instead | same |
| Codex | **not enforced**: Codex has no deny-list mechanism (`security_enforced? = false`) | — | — |

The `gh` rules in the Commands column are a separate category,
`:no_gh_publish`, that binds headless workers only. Interactive operator and
coordinator sessions (`SecurityPolicy.interactive_session/0`) keep the host
denies but may still comment on issues and use gists: that is ordinary work
for them, and the incident was a worker. `gh pr comment` stays allowed for
workers too: the review-thread follow-up protocol uses it.
These are permission-layer rules, like the rest of this page: an upload through
`python -c`, or a `curl` whose flags come in another order on agy, is not
matched. The worker prompt's `NO PUBLIC UPLOADS` rule
(`Arbiter.Worker.EvidenceIntegrity.worker_block/0`) says the same thing to
every provider, Codex included.

To opt a domain out of specific categories, name them in
`permissions.safe_defaults_exclude` (e.g. `["no_destructive_fs"]`, not
recommended). This is the **only** way to drop a default category —
`safe_defaults_exclude` unions across resolution layers (workspace, repo
override, per-dispatch), so once a category is excluded anywhere in the
chain it stays excluded; nothing can re-add it back except removing the
exclusion. The old `permissions.safe_defaults: []` key (a literal, replacing
list) is **inert** — it is still accepted so existing configs keep parsing,
but its value has no effect on the resolved deny set, which is always
`safe_default_categories() -- safe_defaults_exclude`. `arb server doctor` and
`arb prime` flag any workspace whose resolved policy is missing a current
default category, naming which ones. **Effective floor caveat:** the isolated
`CLAUDE_CONFIG_DIR/settings.json` is generated once from the install-default
policy (which includes every safe-default category) and Claude unions deny
lists across settings sources. Excluding a category in workspace config
removes it from the per-spawn `--settings` deny list, but the config-dir
floor still carries it. The practical effect is that the config-dir
safe-default denies are a **hard minimum** that cannot be removed through
workspace config alone — only changing `SecurityPolicy.base/0` or the
install-level `:worker_security_policy` app env removes them.

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
config :arbiter, :worker_security_policy, %{
  "permissions" => %{"mode" => "auto"},
  "sandbox" => %{"network" => false}
}
```

The hardcoded safe baseline lives in `Arbiter.Agents.SecurityPolicy.base/0`.

### Per-task / per-dispatch override

`Arbiter.Worker.Dispatch.dispatch/2` accepts a `:security` map (same shape as
`agent.security`) or a `:security_mode` shorthand, layered last.

### Resolution precedence

`base/0` → `:worker_security_policy` app env → `workspace.config["agent"]["security"]`
→ `workspace.config["agent"]["security"]["repos"][repo]` (only when a repo name
is passed) → per-dispatch override. `allow`/`deny`/`safe_defaults_exclude`
**union** across layers; `mode` and `sandbox` fields are **replaced** by the
highest layer that sets them. `safe_defaults` itself is never set directly —
it is always recomputed as `safe_default_categories() -- safe_defaults_exclude`
after every layer is applied, so it always reflects the current default set
minus whatever any layer has excluded by name. The legacy `safe_defaults`
config key is parsed for backward compatibility but does not affect
resolution.

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

## How the agy (Gemini) adapter maps it

`Arbiter.Agents.Gemini.Security` is the agy analogue of the Claude module above
(bd-7s29yq / T6b). agy has **no** `--settings` flag and **no** config-dir
environment variable: its permission posture comes from
`$HOME/.gemini/antigravity-cli/settings.json` and nothing else. So the mapping
has two halves that must agree:

| Mode      | agy argv                          | generated `toolPermission` | deny enforced? |
| --------- | --------------------------------- | -------------------------- | -------------- |
| `:bypass` | `--dangerously-skip-permissions`  | `always-proceed`           | **yes**        |
| `:auto`   | *(none)*                          | `always-proceed`           | **yes**        |
| `:strict` | *(none)*                          | `proceed-in-sandbox`       | **yes** — and unallowed ⇒ blocked |

`:strict` deliberately maps onto agy's own `"proceed-in-sandbox"` value, not
its `"strict"` value, and omits the `--sandbox` argv flag — see bd-25ivqe
below; both were probed live and the obvious-looking alternative (agy
`toolPermission: "strict"` + `--sandbox`) turned out to auto-deny every tool
call in headless mode regardless of `permissions.allow`.

`Arbiter.Agents.Gemini.ConfigDir` supplies the `$HOME` the settings document
lands in: one directory per worktree under `~/.cache/arbiter/worker-agy/`,
seeded on every spawn with

* the **generated** `settings.json` (never the operator's),
* an Arbiter-owned, persona-forbidding `GEMINI.md`,
* `.gemini/config/mcp_config.json` when the dispatch has an MCP scope token, and
* symlink passthrough for everything else in the operator's `$HOME` *except*
  `.gemini`, `.agents` and `.antigravity` — the three trees agy reads its
  config, memory, skills and plugins from.

The home root itself lives under `~/.cache`, i.e. *inside* the operator's
`$HOME`, so a directory that contains the root (`.cache`, `.cache/arbiter`) is
mirrored as a real directory and its children linked individually rather than
being linked flat — a flat `<home>/.cache -> ~/.cache` would make
`<home>/.cache/arbiter/worker-agy/<key>` resolve back to `<home>`, an unbounded
symlink cycle inside the worker's own `$HOME`.

Rules are rewritten into agy's own grammar (`command(...)`, `read_file(...)`,
`write_file(...)`, `read_url(...)`, `execute_url(...)`). A *bare* Claude tool
name (no `(...)`) maps onto the equivalent whole-path rule where agy has one —
`Write`/`Edit`/`MultiEdit`/`NotebookEdit` → `write_file(**)`, `Read` →
`read_file(**)`, `WebFetch`/`WebSearch` → `read_url(*)`, and
`WebFetch(domain:<host>)` → `read_url(<host>)`. Until bd-80talz these were
emitted as `url(*)`, which is not an agy rule kind: agy rewrites
`settings.json` on load and silently drops it (probed on 1.2.11), so the
network-off deny and the reviewer's `WebFetch` deny never reached agy. That is what keeps the reviewer read-only
posture (`Arbiter.Worker.Dispatch.review_security_policy/2` denies
`Edit`/`Write`/`NotebookEdit` on every worktree-backed review dispatch) working
for agy as well as for Claude. A rule with no agy analogue at all — `Monitor`,
`ScheduleWakeup`, for which agy has no tool-name rule kind — is dropped rather
than emitted uninterpretably.

### What was verified live, and what agy does *not* enforce

Probed against the installed `agy` while implementing bd-7s29yq, each with a
throwaway `$HOME`:

* The generated `settings.json` **is** read in place of the operator's, and
  `toolPermission` is echoed verbatim as `init.permission_mode` on the
  stream-json `init` event. `apps/arbiter/test/fixtures/agy_init_strict.json`
  is a real captured event (`permission_mode: "proceed-in-sandbox"`);
  `agy_init_inherited.json` is the pre-fix control (`"always-proceed"`).
* `permissions.deny` is a **hard block in every mode**, including under
  `--dangerously-skip-permissions`: with `deny: ["command(rm)"]`, a
  `rm ./inside.txt` came back `permission check failed for unsandboxed ...` and
  the file survived. This is why `security_enforced?/0` can answer `true`.
* **`toolPermission: "strict"` is a dead end for headless use (bd-25ivqe).**
  This was the original mapping for Arbiter's `:strict` mode, and it looked
  right in review and in unit tests that only asserted on the generated
  settings document — but live, `permissions.allow` is never consulted under
  agy's own `"strict"` value in headless/print mode. A bare `command(arb)`, a
  wildcard `command(*)`, and even the literal full command string all still
  came back auto-denied. Only `always-proceed` (`--dangerously-skip-permissions`)
  let anything through. `apps/arbiter/test/fixtures/agy_run_command_denied.json`
  and `agy_run_command_allowed.json` are real captured `run_command` steps
  pinning the *working* mapping below.
* **`toolPermission: "proceed-in-sandbox"` is the value that actually
  enforces an allowlist headlessly.** Same settings document, only
  `toolPermission` changed: an allow-listed command ran, and a command with
  no matching allow rule was denied with agy's own
  `permission check failed for unsandboxed ...` wording — reported on
  stderr and via `denied_actions` on the `result` event, and it does not hang
  to the print timeout. `:strict` maps onto this value, not agy's own
  `"strict"`, and is genuinely allowlist-only as a result: a `:strict` agy
  worker gets no shell at all unless the workspace policy names the commands
  it may run.
* **`allowNonWorkspaceAccess: false` does not work.** With it set, a
  `touch <outside-the-worktree>/marker` via `run_command` still succeeded, and
  so did a `view_file` read of a file outside the workspace. The key is still
  emitted (it is the documented switch and costs nothing).
* **`write_file(...)` deny rules do not gate agy's native `write_to_file`
  tool at all (bd-25ivqe AC6, agy 1.2.11).** A prior revision of this doc
  claimed `write_file` was "deny-list-gated" like `command`/`read_file`; that
  was never confirmed against a real match, only against `/etc/**`, which a
  non-root user cannot write to regardless of agy's own gating. Re-probed
  against a path the user genuinely can write: an exactly-matching
  `write_file(<dir>/**)` deny, a blanket `write_file(**)` deny, and
  `--sandbox` (which bwraps `run_command` but not the native tool) all still
  let `write_to_file` write outside the worktree with no denial.
  `disabledTools` (a real `settings.json` key) doesn't stop it either — that
  key gates MCP-server tools, not agy's own built-ins. There is currently no
  `settings.json` lever that confines `write_to_file` to the worktree; this
  is exactly what post-merge probe bd-7h2cuk observed (arb/notes worked, but
  an out-of-worktree `write_to_file` was not denied). Closing it needs an
  upstream agy fix or real OS isolation, not a settings change — see AC6 in
  bd-25ivqe, explicitly post-merge and non-blocking for this reason.
* **`--sandbox` disables the allowlist gate under `"proceed-in-sandbox"`
  (bd-25ivqe).** With `--sandbox` on argv, agy runs the command inside a real
  `bwrap` jail and *auto-proceeds* there regardless of `permissions.allow` —
  a command with no matching allow rule that was denied without `--sandbox`
  succeeded with it. Only `permissions.deny` still gated it. `--sandbox` is
  therefore omitted from `:strict`'s argv entirely; the original mapping
  (`--sandbox` + `toolPermission: "strict"`) predates this finding.

As on the Claude side these are *permission-layer* guards inside the agent, not
OS isolation.

### Credentials are untouched by the `$HOME` redirect

On a host with a working freedesktop Secret Service, agy keeps its live Google
grant in the **keyring**, which is scoped to the Linux user session and not to
`$HOME` — the T6a spike proved a brand-new `$HOME` with zero credential files
still authenticates. `ConfigDir.keyring_available?/0` detects that and seeds
nothing. Only when no Secret Service is reachable do we **copy** (never
symlink, which a refresh would write back through) `oauth_creds.json`,
`jetski-standalone-oauth-token` and `google_accounts.json`.

## Provider-agnostic by construction

`SecurityPolicy` carries no Claude-specific syntax. The `Arbiter.Agents.Agent`
behaviour contract requires any adapter to:

1. Map the normalized `:security` policy to its provider's mechanism.
2. Enforce a non-empty destructive-op deny baseline (the policy's
   `safe_defaults`) in `:auto` and `:strict` modes.
3. Not fall through to the host operator's personal agent config.
4. Implement `security_enforced?/0` returning `true` once it honors the above.

**Current status:** `Claude` enforces the policy unconditionally
(`security_enforced? = true`). `Gemini` enforces it when — and only when — the
CLI on `PATH` is `agy` *and* worker config isolation is on, since without an
Arbiter-owned `$HOME` there is nowhere to put the generated settings document;
it answers `false` otherwise, including for the upstream `gemini` CLI, which has
no allow/deny mechanism at all. `Codex` does not implement the contract yet and
answers `false`. The REST `security_posture.policy_enforced` field reports each
adapter's own answer, so operators can see whether the declared posture is
actually being enforced by the running adapter.

## Where the posture is surfaced

* **`arb prime`** — a `security:` block in the active-workspace section (mode,
  sandbox, deny counts).
* **Dashboard** — a per-worker permission-mode badge on the active workers
  list (ghost for `auto`, warning for `strict`, error for `bypass`).
* **REST** — `GET /api/workspaces/:id` includes a resolved `security_posture`
  object with `provider`, `policy_enforced`, and the full policy summary. This
  is the single source of truth both surfaces read.

## Related: the durable log root is secret-bearing

Worker output — including each run's archived session JSONL — lands in
`output_log_root` (default `~/dev/arbiter-worker-logs`). Archives are redacted
on ingest through `Arbiter.Redaction`, but that only covers secrets a human
marked; a key printed by a subprocess is not covered. The root is therefore
also protected by filesystem permissions (`0700` root, `0600` archives) and
must be treated as secret-bearing storage. See `docs/session-archive.md`.
