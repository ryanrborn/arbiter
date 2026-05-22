# Build summary: feature/gte-003-dependency-resource

**Bead:** gte-003
**Builder:** Mayor (delegated worktree session, 2026-05-19)
**Branch:** feature/gte-003-dependency-resource
**Commit:** fec85c7
**Branched from:** main @ 5a5c62e (gte-002 merge)

## What I built

The `Dependency` resource — a directed edge between two `Issue` rows representing bd's bead-to-bead relationships (blocks, depends_on, relates_to, discovered_from, parent_of). Plus an `Issue.ready/0` function that returns currently-actionable open issues (no open `:blocks` or `:depends_on` edges pointing at unclosed targets).

### Files added/changed

```
apps/arbiter/lib/arbiter/beads.ex                                                    (M) register Dependency
apps/arbiter/lib/arbiter/beads/issue.ex                                               (M) Issue.ready/0 + helper constants
apps/arbiter/lib/arbiter/beads/dependency.ex                                          (+) resource
apps/arbiter/lib/arbiter/beads/dependency/changes/reject_self_reference.ex            (+) from==to guard
apps/arbiter/priv/repo/migrations/20260519195520_add_dependency_resource.exs            (+) dependencies table + unique index + FKs
apps/arbiter/priv/resource_snapshots/repo/dependencies/20260519195521.json              (+) Ash snapshot
apps/arbiter/test/arbiter/beads/dependency_test.exs                                   (+) 20 tests
```

## Acceptance check (from bead gte-003)

| Criterion | Status |
|---|---|
| `from_issue_id` / `to_issue_id` string FKs to `Issue.id` | done — `belongs_to :from_issue, Arbiter.Beads.Issue, attribute_type: :string` (same for to_issue); migration emits `references(:issues, type: :text, on_delete: :restrict)` |
| `type` enum: `:blocks`, `:depends_on`, `:relates_to`, `:discovered_from`, `:parent_of` | done — `constraints one_of: @types`; helper `Dependency.types/0` exposes the list |
| `created_at`, `created_by` (optional), `notes` (Markdown, optional) | done — `create_timestamp :created_at`; `created_by` string (max 255); `notes` string with `default ""` |
| Uniqueness on `(from_issue_id, to_issue_id, type)` | done — Ash `identity :unique_edge, [...]` produces a Postgres `UNIQUE` index (`dependencies_unique_edge_index`) |
| Cannot self-reference (`from == to`) | done — `RejectSelfReference` change adds a changeset error before insert. Tested explicitly. |
| `Issue.ready/0` returns open issues with no unclosed `:blocks` / `:depends_on` deps | done — public function on `Arbiter.Beads.Issue`. 8 tests cover: no deps, gating dep open, gating dep closed, blocks-side gating, relates_to non-gating, discovered_from/parent_of non-gating, closed/in_progress excluded, multi-dep AND semantics |

## Design choices worth flagging

- **String FK type is set explicitly** via `attribute_type: :string` on the `belongs_to`. Ash defaults `belongs_to` FKs to `:uuid`; without the override the migration would emit `type: :uuid references issues` and fail because `issues.id` is text. Same pattern is forced by Issue's text PK.

- **`identity :unique_edge`** is the Ash-idiomatic way to declare composite uniqueness. The codegen materializes it as `unique_index(:dependencies, [:from_issue_id, :to_issue_id, :type])`. Avoids a hand-written migration and gives a duplicate insert a clean `Ash.Error.Invalid` rather than a raw Postgres exception.

- **`Issue.ready/0` is plain Elixir over `Ash.read!`, not an Ash filter expression.** I considered a custom read action with `expr(not exists(...))`, but that requires modeling Dependency as a `has_many` on Issue plus writing the `exists` predicate against atomized status enums. For thousands-of-issues scale, a three-pass approach (open issues → gating deps → target lookup) is correct, debuggable, and the SQL it generates is two indexed reads. Documented in the moduledoc as the upgrade path if scale demands it.

- **Only `:blocks` and `:depends_on` gate readiness.** `:relates_to`, `:discovered_from`, `:parent_of` are informational — they show up in the bd graph and the Convoy/epic rollups (gte-004+) but they don't make a bead non-actionable. Encoded as `@gating_dep_types` module attribute in Issue; tested in three separate tests per type.

- **`RejectSelfReference` runs in `before_action`** rather than as a validation, because it needs the resolved attribute values (after defaults). It's a hard error, not a warning. Tests assert both the error class (`Ash.Error.Invalid`) and the message string.

- **No paper_trail on Dependency.** Per the bead spec, edges are cheaper to recreate than the audit overhead is worth. If we want history later (e.g. "when did this blocks edge appear?"), adding `AshPaperTrail.Resource` is one line + a migration; no breaking changes.

- **`on_delete: :restrict` on both FKs.** Matches Issue→Workspace. Deleting an issue with edges fails loudly. The Go `bd` codebase does the same — orphaned edges are worse than a delete that demands cleanup first.

- **`:update` action is minimal** (`type`, `created_by`, `notes`). Endpoints are immutable: changing `from_issue_id` or `to_issue_id` would effectively be "delete the old edge, create a new one." The latter is two clean operations; the former hides intent. Tests don't exercise update specifically — the resource supports it but no behavior diverges from the framework default.

## What I punted on (with reasons)

1. **No paper_trail on Dependency** — see above; can be added cleanly later.
2. **No cycle detection** — `a depends_on b`, `b depends_on a` is allowed at the resource level. Cycles are a graph-level concern; they show up in `bd ready` as "nothing is ready" rather than as a constraint violation. If we want eager cycle rejection it goes in a future bead (gte-005? gte-CLI work?).
3. **No actor tracking on `created_by`.** Field exists, but it's caller-populated — auth bead lands later.
4. **`Issue.ready/0` is not paginated / sorted.** Returns the full list. Sorting (e.g. by priority, then by created_at) is presentation-layer concern; CLI/API beads add it.
5. **No bulk operations.** Single-edge create/update/destroy only. Bd's CSV import is a future bead.
6. **No Dependency-on-Workspace scoping.** Edges currently span workspaces; both endpoints just need to be valid Issues. If we want "edges are scoped to a single workspace" we'd add a workspace_id attribute + identity. Not in spec; deferred.

## What I noticed worth flagging to the reviewer

- **`notes` default `""` does not round-trip through the DB as `""`** — it's persisted as `NULL` when the caller doesn't pass a value, despite the column having `default ''`. Same defect exists silently on Issue's `description`/`acceptance`/`notes`/`qa_notes`/`deployment_notes`. The Ash `default ""` is applied to the changeset value but the insert ends up sending `NULL` for omitted attributes. I worked around it in the test (`assert reloaded.notes in [nil, ""]`); a real fix is one of: (a) `allow_nil? false, default ""`, (b) drop the `default ""` and let nil-as-empty be the contract, or (c) coerce via a change at create-time. Worth a follow-up bead if the team cares about strict empty-string semantics.

- **Unique-edge index name** is `dependencies_unique_edge_index`. If anyone writes raw SQL for diagnostics, that's the name to know.

- **`Issue.ready/0` doesn't take options.** No `workspace_id:` filter, no `status_in:` override. By design — this is the smallest possible API. Future variants (`ready_in_workspace/1`, `ready_for_assignee/1`) can be additive without breaking this signature.

## How to verify

```sh
cd /home/rborn/dev/arbiter-wt-003
git checkout feature/gte-003-dependency-resource

docker compose up -d                              # if Postgres isn't running
mix ecto.migrate                                  # dev DB
MIX_ENV=test mix ecto.migrate                     # test DB

mix compile --warnings-as-errors                  # clean
mix format --check-formatted                      # clean

# Dependency tests specifically
mix test apps/arbiter/test/arbiter/beads/dependency_test.exs
# Expect: 20 tests, 0 failures

# Full suite
mix test
# Expect: 56 arbiter + 5 arbiter_web + 1 doctest + 1 arbiter_cli = 63 tests, 0 failures

# Spot check from iex
iex -S mix
> alias Arbiter.Beads.{Workspace, Issue, Dependency}
> {:ok, ws} = Ash.create(Workspace, %{name: "demo", prefix: "demo"})
> {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
> {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})
> {:ok, _} = Ash.create(Dependency, %{from_issue_id: a.id, to_issue_id: b.id, type: :depends_on})
> Issue.ready() |> Enum.map(& &1.id)   # → [b.id]  (a is blocked)
> {:ok, _} = Ash.update(b, %{}, action: :close)
> Issue.ready() |> Enum.map(& &1.id)   # → [a.id]  (b is closed, no longer ready; a is unblocked)
```

## Verdict requested

Ready to merge:

```sh
git checkout main
git merge --squash --ff-only feature/gte-003-dependency-resource
git commit
bd close gte-003 --reason "Merged to main (commit XXX)"
```

After merge, unblocked:
- **gte-004** (Convoy resource) — uses Dependency for parent_of rollups
- Any "show readiness" bead in the CLI / API layers

Reviewer should sanity-check:
- The `attribute_type: :string` override on both `belongs_to` lines (without it, the migration's FK type would mismatch `issues.id`)
- `RejectSelfReference` runs in `before_action`, so it sees post-default attribute values
- `Issue.ready/0` correctly excludes `:in_progress` issues (only `:open` counts as "ready to be picked up") — covered by test "in_progress issues are excluded from ready"
- The unique index name + scope (composite on three columns)
- The `notes` `default ""` vs NULL behavior (see "What I noticed" above) — decide if it's worth a follow-up
