# agy `:strict` write isolation: decision

**Task:** bd-ca7xko (decision) · **Epic:** bd-3sa0y9 (agy provider parity) ·
**Builds on:** bd-25ivqe (PR #2070), bd-7h2cuk (live probe) ·
**Status:** decided 2026-09-26. Follow-ups filed: bd-1abj7u, bd-5gvqgc,
bd-8xy1mf, bd-3s82pf.

## Decision

Enforce `:strict` write isolation for agy **at the OS level with
bubblewrap**, and **fail closed until then**:

1. **Now (bd-1abj7u):** a `:strict` scope never dispatches to a provider
   that cannot confine writes to the worktree. That means agy (until the
   jail lands), the upstream `gemini` CLI, and Codex. Dispatch refuses with
   an explanatory error, and automatic provider selection skips ineligible
   providers. The posture surfaces report it. This is option 4, used as the
   fallback rather than as the final answer.
2. **Next (bd-5gvqgc):** run agy under `bwrap` so that only the worktree,
   the git common dir and the worker's own agy `$HOME` are writable. Once a
   host passes the jail self-test, agy becomes `:strict`-eligible there.
   This is option 2.
3. **Then (bd-8xy1mf):** `arb server doctor` runs the jail self-test and
   explains why a host can't jail. The same check runs on the laptop and on
   the RHEL 8 dev EC2.
4. **After soak (bd-3s82pf):** extend the jail to agy's `:bypass`/`:auto`
   modes, and make agy review dispatches read-only at the OS level. The
   escape is not specific to `:strict` (see below).
5. **In parallel, operator action (not a worker task):** report the bug to
   Antigravity. A draft is in [Upstream report](#upstream-report-draft).
   This is option 1, but it is **not** on the critical path: nothing waits
   for it.

Option 3 (detect and revert) is **rejected**.

## Why

The finding (bd-25ivqe, re-confirmed below): agy's native `write_to_file`
ignores every `write_file(...)` deny, `disabledTools`, and `--sandbox`.
agy has no setting that confines it, so any fix inside agy's own settings
is off the table. That leaves three places to enforce the boundary: the
vendor, the kernel, or Arbiter's dispatch.

| Option | Prevents the escape? | Cost | Risk | Verdict |
|---|---|---|---|---|
| 1. Upstream fix, meanwhile no agy in `:strict` | Eventually, on the vendor's schedule | Near zero for us | Unbounded wait. A fix must also be re-verified on every agy release, since agy has already silently changed settings grammar (`url(*)` dropped on load, bd-80talz) | File it, don't depend on it |
| 2. OS isolation (bwrap) | **Yes, for every write path**: native tools, `run_command`, and any child process. The kernel returns EROFS. Proven live below | One adapter change plus a doctor check. `bwrap` is packaged on every target checked | Toolchain caches need writable paths. Unprivileged user namespaces must be enabled on the host (checked by the self-test) | **Chosen** |
| 2'. Restricted Unix user | Yes | High: a second account, keyring/OAuth for that user, and group-writable worktrees and `.git` | Breaks the same-user keyring auth agy relies on (see worker-security.md, "Credentials are untouched") | No |
| 2''. Container (podman) | Yes | High: image per toolchain, keyring over D-Bus into the container, UID mapping on bind mounts | Heavier start-up per spawn. Duplicates what bwrap does with one binary | No, for now |
| 3. Detect and revert | **No.** The write has already happened by the time it's noticed. A write to `~/.arbiter` (the live install and DB), the main checkout (hot-reload cascade) or `~/.ssh` does its damage before any audit | inotify can't watch "everything outside the worktree", and a snapshot diff of `$HOME` is slow and noisy | False sense of safety. "Revert" can't undo a secret already read and sent, or a DB already corrupted | **Rejected** |
| 4. agy ineligible for `:strict` | Yes, by never running agy there | Small | agy never carries `:strict` load, which contradicts the operator's 2026-09-25 ruling that agy is ready only when `:strict` works | **Kept as the fail-closed fallback** for hosts that can't jail |

Option 4 also exposes a gap beyond agy. Codex answers
`security_enforced? = false`, so "route strict work to claude/codex" would
have been wrong. The gate in bd-1abj7u covers every provider through one
capability callback, so it doesn't hard-code agy.

## Evidence (probed 2026-09-26)

All of these were run on the Fedora 44 laptop (kernel 7.2, SELinux
enforcing), with agy 1.2.11 and bubblewrap 0.12.0 (non-setuid, using
unprivileged user namespaces; `user.max_user_namespaces = 126539`).

### A/B: agy `write_to_file` jailed vs. unjailed

Each run used a throwaway `$HOME`, `--dangerously-skip-permissions` (so the
OS is the only barrier), model `gemini-3.8-flash-low`, and a prompt asking
for exactly two native `write_to_file` calls: one to
`~/.cache/agy-bwrap-probe-bd-ca7xko-*.txt`, which is outside the workspace
and writable by the user, and one to `<workspace>/inside.txt`.

Jailed:

    bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp \
      --bind $HOME_DIR $HOME_DIR --bind $WS $WS \
      --die-with-parent --chdir $WS --setenv HOME $HOME_DIR -- \
      agy -p "..." --dangerously-skip-permissions --output-format stream-json

| Run | Outside write | Inside write |
|---|---|---|
| **jailed** | `state: "ERROR"`, `open /home/ryan/.cache/agy-bwrap-probe-bd-ca7xko-jail.txt: read-only file system`. No file on the host | `DONE`, file present |
| control (same, no `bwrap`) | `DONE`. The file **was created on the host** (removed after the probe) | `DONE`, file present |

Other results from the jailed run:

* agy **authenticated** inside the jail with a brand-new `$HOME` and no
  extra binds. The keyring is reached over the D-Bus session socket, which
  `--ro-bind / /` already exposes, and connecting to a socket needs no
  write access to the filesystem.
* All of agy's own state landed under the jailed `$HOME`: `cli.log`,
  `conversations/<id>.db`, `brain/`, `presence/`. That `$HOME` is the
  `ConfigDir` key dir and is bound read-write, so the host-side log readers
  and `--conversation` resume keep working unchanged.

### Real worker operations inside the jail

In this worktree, with the git common dir bound read-write and
`.git/hooks` plus `.git/config` re-bound read-only on top:

| Operation | Result |
|---|---|
| `git hash-object -w` (writes into the main `.git/objects`) | ok |
| write to `.git/hooks/pre-commit` | **denied**, read-only file system |
| `git config --local` | **denied**, `Device or resource busy` (git renames a lockfile over the bind-mounted file) |
| `mix compile` (writes `_build` in the worktree) | ok, exit 0 |
| `curl http://localhost:4848/api/version` (arb, MCP) | 200 |
| write to `$HOME`, or to the main checkout `~/dev/arbiter` | **denied**, read-only file system |
| write to `/tmp` | ok, but in a private tmpfs: nothing appeared in the host `/tmp` |
| `ps -e` with `--unshare-pid` | 5 processes: only the jail's own |

### Feasibility by install target

| Target | `bwrap` package | Setuid? | Recipe runs? | Open question |
|---|---|---|---|---|
| Laptop: Fedora 44 | bubblewrap 0.12.0, installed | no | **yes**: agy A/B above | none |
| Dev EC2: RHEL 8 (glibc 2.28) | bubblewrap **0.4.0** in RHEL 8 BaseOS. Checked in a Rocky Linux 8 container; **not** in the UBI 8 repos | no (`-rwxr-xr-x root`) | **yes**: the el8 0.4.0 binary, extracted and run on the laptop kernel with the same recipe, gave inside write ok and outside EROFS. Every flag in the recipe exists in 0.4.0 | The EC2's **kernel** setting `user.max_user_namespaces` hasn't been read yet. RHEL 8 enables unprivileged user namespaces by default (RHEL 7 did not), but that must be confirmed on the host (bd-8xy1mf) |
| Amazon Linux 2023 | bubblewrap 0.10.0 in the AL2023 repo | not checked | not run | Same kernel check |
| Ubuntu 24.04 | bubblewrap 0.9.0 in the archive | not checked | not run | Ubuntu ≥ 23.10 defaults to `kernel.apparmor_restrict_unprivileged_userns = 1`, which can block bwrap's user namespace unless an AppArmor profile allows it. Needs a real probe before anyone relies on it |

This is why the availability check must **execute the recipe and observe
EROFS**. Checking for the binary or reading a sysctl is not enough: the
binary, the userns sysctl, AppArmor and a setuid bwrap each change the
answer. A host that fails the self-test isn't broken. It just keeps agy out
of `:strict` (step 1), and doctor says why.

## Jail design

Starting recipe for bd-5gvqgc:

    bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs /dev/shm \
      --bind <worktree> <worktree> \
      --bind <git-common-dir> <git-common-dir> \
      --ro-bind <git-common-dir>/hooks <git-common-dir>/hooks \
      --ro-bind <git-common-dir>/config <git-common-dir>/config \
      --bind <agy worker HOME> <agy worker HOME> \
      [--bind <each sandbox.writable_paths entry>] \
      --unshare-pid --die-with-parent --chdir <worktree> -- agy -p ...

* **Read-only `/`.** Everything else in the operator's `$HOME`, including
  the `ConfigDir` symlink passthrough targets, is visible but not writable.
  That also protects `~/.arbiter` (the live release and DB) and the main
  checkout, where a stray worker write has cascaded into every running
  worker before.
* **Git common dir read-write.** Commits need it, because worktree objects
  and refs live in the main `.git`. `hooks/` and `config` are re-bound
  read-only because a hook or `core.hooksPath` written from inside would
  later run *unjailed* on the host.
* **Private `/tmp`.** agy's `/tmp` escape (bd-7h2cuk) lands in a tmpfs that
  disappears with the jail. As a side effect this also ends cross-worker
  `/tmp` collisions, e.g. the test DB under `System.tmp_dir!/0`.
* **`--unshare-pid` + `--die-with-parent`.** Killing the `bwrap` process
  that Arbiter spawned takes down agy *and* anything agy backgrounded
  (`run_command` goes async), which is tighter teardown than today.
* **Toolchain caches.** `~/.hex`, `~/.mix`, `~/.cache/rebar3` and similar
  are read-only in the jail. `mix compile` doesn't need them, but a
  `deps.get` that fetches does. Prefer per-worker `HEX_HOME` / `MIX_HOME` /
  `XDG_CACHE_HOME` under the agy `$HOME` over binding the shared ones
  writable: a writable shared cache is a persistence path (for example,
  `~/.mix/archives` runs code in the operator's later mix runs).
  `sandbox.writable_paths` is the operator's escape hatch.
* **Argv seam.** `Gemini.default_argv/2` already wraps the command in
  `sh -c 'exec "$@" < /dev/null'`. The jail goes between `sh` and `agy`.
  `splice_prompt/2` finds the executable as the element before `-p`, which
  is still `agy`, so resume and nudge are unaffected.

**What the jail does not do** (accepted, and documented in bd-5gvqgc):

* The network stays shared, because `arb`, MCP and `git push` need it.
  `sandbox.network: false` is still only the tool-level deny.
* Reads are not restricted. Later, `--tmpfs` over `~/.ssh` and cloud
  credential dirs could make `:no_secret_reads` an OS guarantee too.
* The main `.git` is writable, so a jailed worker could still write
  sibling worktrees' refs. The same is true today.
* It is not a defence against a hostile kernel exploit. The threat model is
  a misdirected same-user agent, the same as the rest of
  [worker-security](../worker-security.md).

## Rollout

`:strict` first, because the operator's ruling needs it and the blast
radius is small: `:strict` is opt-in per workspace or repo. Once `:strict`
agy runs have been clean for a while, bd-3s82pf makes the jail the agy
default in every mode, keyed on the existing
`sandbox.enabled` / `sandbox.filesystem: :worktree` base defaults. The
reasons:

* The escape is the same in `:bypass`/`:auto`. An agy worker in the default
  mode can write anywhere the operator can.
* The reviewer read-only posture (`Dispatch.review_security_policy/2`
  denies `Edit`/`Write`) is **not** enforced for agy's native writes today.
  An `--ro-bind` of the worktree for review dispatches enforces it.

The jail module is provider-agnostic, since `sandbox.enabled` is the
documented seam. Claude's `:strict` currently relies on permission-layer
gating. It could opt into the same jail later, but that is out of scope
here.

## Upstream report (draft)

For the operator to file with Antigravity if they choose to. Workers do
not post externally.

> **agy 1.2.11: `write_file(...)` permission rules don't gate the native
> `write_to_file` tool.** With `permissions.deny: ["write_file(**)"]` (and
> also an exact `write_file(<dir>/**)`), under every `toolPermission` value
> including `proceed-in-sandbox`, and with `--sandbox`, `write_to_file`
> writes to paths outside the workspace without a denial.
> `disabledTools` doesn't stop it either (it only applies to MCP tools),
> and `allowNonWorkspaceAccess: false` failed to confine `run_command`
> writes and `view_file` reads in our probes. By contrast, `command(...)`
> deny rules do gate `run_command`. Expected: `write_file` deny rules (and
> `allowNonWorkspaceAccess: false`) apply to `write_to_file`, and to the
> other native file-editing tools, the same way `read_file` rules apply to
> reads.

If upstream fixes it, the jail stays anyway: it covers every write path at
once, and it doesn't depend on each agy release keeping its settings
grammar.
