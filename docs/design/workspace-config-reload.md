# Workspace-Config Reload Across Long-Lived GenServers — Design Note

**Status:** proposed (investigation + design; implementation deferred to a follow-up epic)
**Last updated:** 2026-07-06
**Task:** bd-hxom55
**Related:** PR #635 (`2d27c05`, PR-patrol per-tick refetch), PR #610 (`2b0ef62`, follow-up `source_pr`), bd-a8gxbj (investigate-then-propose precedent)

---

## Overview

Workspace-scoped configuration lives in a single JSON `config` column on the
`Arbiter.Tasks.Workspace` Ash resource and is edited at runtime through
`arb config set` / `workspace_config_set` (and the REST + dashboard editors).
Several long-lived GenServers cache values derived from that config in their
process state. When an operator changes config, how quickly does each process
notice — and are there processes that never notice until they restart?

This note answers that question with a **confirmed, per-module audit**, then
makes a decision: introduce **one shared PubSub-driven reload signal** that the
config-consuming GenServers subscribe to, rather than bolting a bespoke polling
interval onto each module. The write path funnels through exactly two Ash
actions, the three most-affected GenServers already subscribe to
`Phoenix.PubSub` in their `init`, and the codebase already has an
`after_action`-broadcast idiom — so the shared mechanism is both cheaper to
build and strictly better (near-instant, zero steady-state DB polling) than
tuning N independent timers.

Out of scope, and confirmed untouched: `Application.get_env(:arbiter, …)`
reads. Those (`conductor_system_max_concurrent`, `review_patrol_debounce_ms`,
`dispatch_queue_dispatcher`, `provider_pool_cooldown_ms`, credential-watchdog
config, `quota_refresh_probe`) are compile/deploy-time OTP application config,
not per-workspace DB config, and are *expected* to require a restart.

---

## Audit — every long-lived config-consuming GenServer

"Refetch" = re-reads the `Workspace` resource / its `config` map after `init`.
Line numbers are against the tree at the time of writing. All modules under
`apps/arbiter/lib/arbiter/`.

| Module | Loads config at `init`? | Refetches after `init`? | Trigger / granularity | Worst-case module-level staleness |
|---|---|---|---|---|
| `workflows/pr_patrol.ex` | seed only | **yes — every tick** (`do_tick/1` ~146) | periodic tick | one tick (`@default_interval_ms` = **60s**); `interval_ms` itself init-only |
| `workflows/review_patrol.ex` | seed only | **yes — every tick** (`do_tick/1` ~222) | periodic tick | one tick (interval); `interval_ms` itself init-only |
| `workflows/dispatch_queue.ex` | yes (~177) | **yes — every drain** (`reload_workspace/1` ~251) | hold/release/quota-reset drive a drain | one drain when active; **indefinite while idle** (nothing to gate) |
| `worker/review_gate.ex` | no | **yes — on demand** (`load_workspace/1` ~1455) | per reviewer/implementer spawn | always fresh at point of use |
| **`workflows/conductor.ex`** | **yes (~490)** | **no** | — | **never — needs restart** (`max_concurrent`) |
| **`workflows/merged_pr_finalizer.ex`** | **yes (~108)** | **no** | — | **never — needs restart** (merger adapter) |
| **`workflows/merge_queue.ex`** | yes (~1269) | **partial — per enqueue only** (~425) | on new task enqueue; **not** on the periodic `:tick` | `poll_interval_ms` never; merge/adapter config stale until next enqueue, **indefinite if queue idle** |
| `worker/watchdog.ex` | yes, passed-in struct (~296) | no | — | never for the process, but **per-PR short-lived** — each new watch gets a fresh workspace, so harmless |
| `worker.ex` | receives struct in opts (~348) | reads at processing time | per task spawn | per-task ephemeral — no persistent tunable to go stale |
| `worker/driver.ex` | — | — | — | **out of scope** — reads no workspace config (only opts/app config) |

Not GenServers, verified fresh-per-call (no cached state, no action needed):
`workflows/merge_queue/conflict_resolver.ex` and
`workflows/merge_queue/fix_pass_dispatcher.ex` both call `maybe_load_workspace/1`
(`Ash.get(Workspace, …)`) on every invocation.

Other GenServers that touch `Workspace` but **not** its config map (out of
scope): `agents/credential_watchdog.ex` (enumerates workspaces via
`Ash.read!`), `agents/provider_pool.ex` (`Application.get_env` only),
`quota/refresh_probe.ex` (enumerates IDs / base URLs), `single_instance.ex`
(no config).

### The three that are actually broken

1. **`conductor.ex` — the real bug.** `workspace_max_concurrent` is computed
   once in `init` (`resolve_workspace_max/3` → `workspace_config_max/1`, the
   sole `Ash.get(Workspace)` at ~490) and stored in `state`. It is never
   recomputed. An operator raising or lowering
   `config["conductor"]["max_concurrent"]` via `arb config set` has **no
   effect until the Conductor restarts.** This is the same class of bug PR
   patrol used to have.

2. **`merged_pr_finalizer.ex`.** `state.workspace` is loaded once in `init`
   (~108) and every `do_tick/1` reuses it. Lower stakes — it only reads the
   merger adapter, which rarely changes — but it is genuinely
   restart-to-reload.

3. **`merge_queue.ex` — partial.** The periodic `:tick`/`poll_all` path never
   reloads; only a *new enqueue* refreshes `state.workspace`/`state.adapter`.
   So merge-strategy / adapter changes are picked up "eventually" but can hang
   stale indefinitely on an idle-but-not-empty queue, and `poll_interval_ms`
   is frozen at `init` outright.

### A note on the "good" modules

`pr_patrol` and `review_patrol` refetch every tick, but their default tick is
**60s** — above the ≤20s propagation target this ticket sets. They are correct,
just not *fast*. `dispatch_queue` (per-drain) and `review_gate` (on-demand) are
fresh whenever it matters. None of these are broken, but all of them would
converge to <1s propagation for free under the shared mechanism below, because
they already run `handle_info` loops — see "Optional convergence."

---

## The write path — a single chokepoint

Every runtime config write converges on the `Workspace` resource's update
actions (`apps/arbiter/lib/arbiter/tasks/workspace.ex`):

| Caller | Action |
|---|---|
| MCP `workspace_config_set` / `_unset` (`mcp/tools.ex:290,317`) | `:patch_config` |
| REST `PATCH /api/workspaces/:id/config` (`arbiter_web/.../workspace_controller.ex:81`) | `:patch_config` |
| Dashboard config editor (`arbiter_web/.../workspace_detail_live.ex:167`) | `:patch_config` |
| CLI `arb config set/unset` (`arbiter_cli`) → HTTP → the REST endpoint above | `:patch_config` |
| REST `PATCH /api/workspaces/:id` + dashboard secrets/whole-object | `:update` (whole-config replace) |
| `skills/seeds.ex:150` | `:patch_config` |

The CLI is a separate app that talks to the server **over HTTP**, so it has no
direct Ash access — it rides the REST endpoint. That is the point: the
**resource actions, not any individual caller, are the true chokepoint.** A
hook on `:patch_config` and `:update` covers 100% of write paths with zero
per-caller changes.

There is already a mirror idiom to copy — `Arbiter.Messages.Message` attaches
an inline `after_action` change to its actions that calls a module broadcast
helper (`message.ex:66-88, 168-186`). There is no `Ash.Notifier.PubSub`
extension anywhere in the tree; the established convention is
`after_action` + a swallow-on-failure broadcast helper.

---

## Decision

**Adopt a shared PubSub "config changed" signal. Reject per-module polling as
the primary mechanism.**

### Why not "just tune each module to refetch ≤20s"?

It is the obvious simpler option, so it deserves a fair hearing — and it loses:

- It means adding a **bespoke 20s timer + refetch to `conductor` and
  `merged_pr_finalizer`, and reworking `merge_queue`'s tick** — three more
  independent polling loops, each re-reading the DB every 20s per workspace,
  forever, for config that changes maybe once a day.
- It is *still* up to 20s laggy by construction, and it never converges: the
  next module added will invent its own interval again (exactly the "every
  GenServer inventing its own ad hoc polling interval" problem this ticket was
  opened to stop).
- It is, counter-intuitively, **more code than the shared hook**, because the
  three affected long-lived GenServers (`conductor`, `dispatch_queue`,
  `merge_queue`) *already* `Phoenix.PubSub.subscribe/2` in their `init` and
  already run `handle_info` loops. Adding one subscribe line + one
  `handle_info` clause is smaller than standing up a timer.

### Why PubSub wins here specifically

- **Near-instant** (<1s typical) vs a 20s floor.
- **Zero steady-state polling** — a broadcast fires only on an actual write.
- **One contract, one chokepoint** — new config-consumers subscribe to a known
  topic instead of each re-deriving a safe interval.
- The infrastructure already exists (PubSub `Arbiter.PubSub`, the subscribe
  seams, the `after_action` broadcast idiom), so build cost is low.

### Where periodic refetch stays

We do **not** rip out the existing per-tick / per-drain / on-demand refetches.
They remain as a coarse backstop (see "Missed-event handling"), and the modules
that already refetch naturally need no polling *added*. The ≤20s
periodic-self-refresh fallback the ticket allows "for any component where an
immediate subscription genuinely isn't practical" turns out to be needed
**nowhere** in the current tree — every affected module has a `handle_info`
seam — so the design introduces no new timers at all.

---

## Design of the shared mechanism

### Topic

```
"workspace_config:" <> workspace_id
```

A **dedicated** topic, not a reuse of the coordinator `events:<ws_id>` stream.
Rationale: config-reload is an internal server-side concern with a different
payload contract and audience than the coordinator-facing event stream;
coupling them would drag `Arbiter.Events`' `{:event, map}` envelope and topic
filtering into an unrelated path. The 2-line subscribe cost per module is
trivial. (`conductor` happens to already subscribe to `events:<ws_id>`, but the
other consumers subscribe to `quota:<id>` / `merge_queue:<id>`, so no single
existing topic reaches all of them anyway.)

Centralize the topic string and broadcast in a small helper module (mirroring
`Arbiter.Events` / `Message.topic/1`), e.g. `Arbiter.Workspaces.ConfigEvents`:

```elixir
def topic(workspace_id) when is_binary(workspace_id),
  do: "workspace_config:" <> workspace_id

def broadcast_changed(workspace_id) when is_binary(workspace_id) do
  Phoenix.PubSub.broadcast(
    Arbiter.PubSub, topic(workspace_id), {:workspace_config_changed, workspace_id}
  )
  :ok
rescue
  e ->
    require Logger
    Logger.debug("ConfigEvents.broadcast_changed/1 swallowed: #{Exception.message(e)}")
    :ok
end
```

### Payload — signal, don't ship state

```elixir
{:workspace_config_changed, workspace_id}
```

Deliberately **just the id**, not the config map or the `Workspace` struct.
Reasons:

- **Single source of truth.** Subscribers re-read fresh from the DB through
  their existing load path, so two writes broadcasting out of order can never
  let a stale struct "win" a race — the last DB state always wins.
- **Small, cheap, forward-compatible** — the payload never needs to grow as new
  config keys are added.
- Matches the "notify, then re-read" shape already used elsewhere.

### Broadcast site — `after_action` on the write actions

Add one shared change module,
`Arbiter.Tasks.Workspace.Changes.BroadcastConfigChange`, wired into
`:patch_config` and `:update` (following the existing `Start*` change modules
in `tasks/workspace/changes/`):

```elixir
defmodule Arbiter.Tasks.Workspace.Changes.BroadcastConfigChange do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # Only fire when config actually changed (a name-only or secrets-only
    # :update shouldn't churn every subscriber).
    if Ash.Changeset.changing_attribute?(changeset, :config) do
      Ash.Changeset.after_action(changeset, fn _cs, ws ->
        Arbiter.Workspaces.ConfigEvents.broadcast_changed(ws.id)
        {:ok, ws}
      end)
    else
      changeset
    end
  end
end
```

- `after_action` fires only on a successful, committed write — never on a
  validation failure.
- Best-effort: a PubSub failure is swallowed and logged, never failing the
  operator's config write.
- `:create` does **not** need the hook — a freshly created workspace starts its
  GenServers from scratch with current config (the `Start*` changes).

### Subscription contract each consumer implements

In `init`:

```elixir
Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Workspaces.ConfigEvents.topic(workspace_id))
```

Add one handler that **recomputes the module's cached tunables** from a fresh
read (never trusts the message for state):

```elixir
def handle_info({:workspace_config_changed, _ws_id}, state) do
  {:noreply, reload_workspace_config(state)}
end
```

Per-module `reload_workspace_config/1`:

| Module | What it recomputes on the signal |
|---|---|
| `conductor.ex` | `state.workspace_max_concurrent` via `resolve_workspace_max/3` (re-reads `Workspace.max_concurrent/1`) — **the core fix** |
| `merged_pr_finalizer.ex` | `state.workspace` via `Ash.get(Workspace, id)` (refreshes the merger adapter) |
| `merge_queue.ex` | `state.workspace` + `state.adapter` (and `poll_interval_ms`) via its existing `load_adapter_for/1` |

`dispatch_queue`, `review_gate`, `pr_patrol`, `review_patrol` are already
adequately fresh and are **not required** for the fix — see below.

### Missed-event handling

PubSub is fire-and-forget: a subscriber that restarts just after a broadcast,
or a rare transient drop, could miss one event. This is bounded, not
unbounded, because:

- **Restart re-reads at `init`** — a process that (re)starts always loads
  current config, so it can only miss writes that land in the sub-second window
  during its own restart; the *next* write re-broadcasts and corrects it.
- The modules that already refetch (`pr_patrol` 60s tick, `merge_queue`
  per-enqueue, `dispatch_queue` per-drain) retain that refetch as a slow
  self-heal. For the two pure init-only modules, a missed event self-corrects
  on the next config write; if we want a hard bound there regardless of writes,
  a *long* (e.g. 60s) idempotent safety refetch can be added — but that is
  belt-and-suspenders, not the primary path, and can be decided per module at
  rollout.

---

## Optional convergence (nice-to-have, not required for the fix)

Because `pr_patrol` and `review_patrol` already run `handle_info` loops,
subscribing them to the same topic would tighten their config propagation from
"up to one 60s tick" to <1s at ~2 lines each, and let their periodic tick go
back to being purely about *polling the forge* rather than doubling as the
config-freshness mechanism. Worth doing in the same epic for uniformity, but it
fixes no bug on its own. The dashboard `workspace_detail_live` LiveView could
likewise subscribe to reflect config edits live in the UI — cosmetic, out of
core scope.

---

## Rollout plan (proposed follow-up epic)

Land in reviewable slices so each is independently verifiable:

1. **Primitive** — `Arbiter.Workspaces.ConfigEvents` (topic + broadcast helper)
   + `BroadcastConfigChange` change wired into `:patch_config` and `:update`,
   with a test asserting a broadcast fires on `arb config set` and does **not**
   fire on a name-only `:update`. No subscriber yet — pure, safe to merge.
2. **Conductor** (the actual bug) — subscribe + `reload_workspace_config/1`
   recomputing `workspace_max_concurrent`. Test: change `max_concurrent`, assert
   the effective cap moves without a restart.
3. **merged_pr_finalizer** and **merge_queue** — same pattern.
4. **Optional convergence** — subscribe `pr_patrol` / `review_patrol` (+ the
   LiveView) for uniform <1s propagation.

Each slice is small, mirrors an idiom already in the tree, and is independently
testable — matching the "design note before a wide mechanical rollout" framing
of bd-hxom55.

---

## Acceptance-criteria mapping

- **Per-module confirmed list w/ reload behaviour + worst-case staleness** →
  the Audit table above.
- **Decision w/ rationale (shared vs per-module polling)** → the Decision
  section (shared PubSub, with the honest case against polling).
- **If shared: topic/payload + subscription contract, as a reviewable design
  note before wide implementation** → this note (`docs/design/`), Design
  section.
- **`Application.get_env` app config confirmed out of scope, untouched** →
  Overview; no such code is modified by this ticket.
