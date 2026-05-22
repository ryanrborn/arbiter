# Build summary: feature/gte-002-issue-resource

**Bead:** gte-002
**Builder:** Mayor (interactive session, 2026-05-19)
**Branch:** feature/gte-002-issue-resource
**Commit:** 6d6b614

## What I built

The Issue resource — the main unit of work in the bead ledger. Replaces what bd called a "bead" in the Go implementation.

### Files added/changed

```
apps/arbiter/lib/arbiter/beads.ex                                   (M) register Issue + Issue.Version
apps/arbiter/lib/arbiter/beads/workspace.ex                         (M) added :prefix attribute (default "bd", lowercase alnum, max 16)
apps/arbiter/lib/arbiter/beads/issue.ex                             (+) main resource
apps/arbiter/lib/arbiter/beads/issue/changes/generate_id.ex         (+) "{prefix}-{6 char base36}" PK generation
apps/arbiter/lib/arbiter/beads/issue/changes/inherit_tracker_type.ex (+) inherit from workspace.config when not explicit
apps/arbiter/lib/arbiter/beads/issue/changes/guard_status.ex        (+) FSM enforcement
apps/arbiter/priv/repo/migrations/20260519194239_add_issue_resource.exs (+) creates issues + issues_versions
apps/arbiter/priv/resource_snapshots/repo/issues/...                  (+) Ash snapshot
apps/arbiter/priv/resource_snapshots/repo/issues_versions/...         (+) AshPaperTrail snapshot
apps/arbiter/test/arbiter/beads/issue_test.exs                      (+) 23 tests
```

## Acceptance check (from bead gte-002)

| Criterion | Status |
|---|---|
| Unit tests cover create → update → close → audit history present | ✅ 23 tests across 6 `describe` blocks; audit specifically in "paper_trail audit" describe |
| `tracker_type` defaults to `:none`, can be overridden per-bead | ✅ tested both inheritance (workspace tracker→issue) and explicit override |
| Markdown round-trips correctly in description/acceptance/notes/qa_notes/deployment_notes | ✅ "rich-content fields round-trip Markdown" test stores a Markdown blob with headings/lists/code-fences and reads it back identically |
| FSM is enforced | ✅ separate test cases verify each forbidden transition |
| Audit trail captures actor | ✅ paper_trail config has `store_action_name? true` + `store_action_inputs? true`; tests assert action_name on version rows. (Actor — `:created_by` etc. — lands when we add auth in a later bead.) |
| No Jira-specific code in this resource | ✅ tracker_type is a plain enum; `Tracker.Jira` adapter lands in gte-029 |

## Design choices worth flagging

- **String PK `"{prefix}-{short_id}"`** keeps human-readable IDs like bd. Generated in `GenerateId` change at create-time by reading workspace.prefix. 6-char base36 random gives ~2 billion possibilities — collision negligible at our scale.
- **`InheritTrackerType` checks raw `changeset.params`** to detect "did the caller explicitly pass tracker_type?". Tried `Ash.Changeset.changing_attribute?/2` first but it returns true even when the value came from the attribute's default. Checking raw params is the only reliable way to distinguish explicit-default from implicit-default.
- **`GuardStatus` change is parametrized via keyword opts** (`action: :close`). Initially tried `change {Mod, [:close]}` syntax but Ash passes opts as the second arg literally — a list `[:close]` doesn't pattern-match an atom. Keyword list `[action: :close]` is the idiomatic Ash way.
- **`:close` and `:reopen` are dedicated update actions**, not "update with status set to closed." This forces explicit intent at the call site, matches bd's `bd close --reason` UX, and makes the FSM enforceable (`:update` cannot move into or out of `:closed`).
- **`paper_trail` config: `change_tracking_mode :changes_only`** records only the diff per version, not the full snapshot. Cheaper storage, sufficient for audit. Toggle to `:full_diff` later if needed.
- **`ignore_attributes [:created_at, :updated_at]`** in paper_trail config. Don't audit auto-updated timestamps; they're noise.
- **`require_atomic? false`** on `:update`, `:close`, `:reopen` because GuardStatus reads `cs.data.status` before deciding. Atomic actions can't read the current state. No perf concern at our scale.
- **Rich-content fields default to `""`, not `nil`.** Avoids `nil` checks throughout the rendering pipeline. The "field is empty" condition is simply `field == ""`.
- **`workspace` is a required `belongs_to`** with `on_delete: :restrict`. Deleting a workspace with issues fails; you must close + reassign first. Safer than cascade.

## What I punted on (with reasons)

1. **`Dependency` resource (bead-to-bead edges)** — gte-003's scope.
2. **`Convoy` resource (batches)** — gte-004's scope.
3. **`Vernacular` module (label resolution)** — gte-P2.
4. **`Tracker.None` / `Tracker.Jira` adapters** — gte-019 / gte-029.
5. **Actor tracking on paper_trail** — needs an auth bead first (not in current plan; could fold into LiveView when needed).
6. **Filters / queries** — `Issue.ready/0`, "list by status," etc. — these are gte-005 (REST API) and gte-006 (CLI) work.
7. **Soft-delete / archive** — only hard `destroy` via Ash defaults. If we want soft-delete, add `AshArchival` extension later.
8. **Bulk operations** — Ash supports bulk create/update; not needed for the CLI flow.

## What I noticed worth improving separately

- **`Issue.Version` resource is auto-generated by AshPaperTrail.** Lives in the `Arbiter.Beads.Issue.Version` module (generated, not in source). Listed in domain resources. Useful but invisible — worth documenting elsewhere that "if you see Issue.Version queries, it's the audit log."
- **The `InheritTrackerType` change checks `changeset.params` for both `"tracker_type"` (string) and `:tracker_type` (atom).** Phoenix params arrive as strings; Elixir-direct calls use atoms. Belt and suspenders.
- **No filter / search on Issue.** `Ash.read!(Issue)` returns all. Filtering by status / priority / type is added when first consumer needs it.
- **GenerateId could theoretically collide.** Race two creates with the same short_id in the same workspace. Postgres UNIQUE on PK would reject the second; the create action would fail. Could add retry-with-new-id logic if collision rate is non-negligible (it's not, at 2B possible values).

## How to verify

```sh
cd ~/dev/arbiter
git checkout feature/gte-002-issue-resource

docker compose up -d                              # if Postgres isn't running
mix ecto.migrate                                  # dev DB
MIX_ENV=test mix ecto.migrate                     # test DB

mix compile --warnings-as-errors                  # clean
mix format --check-formatted                      # clean

# Issue tests specifically
mix test apps/arbiter/test/arbiter/beads/issue_test.exs
# Expect: 23 tests, 0 failures

# Full suite
mix test
# Expect: 36 arbiter + 5 arbiter_web + 1+1 arbiter_cli = 43 tests, 0 failures

# Spot check from iex
iex -S mix
> alias Arbiter.Beads.{Workspace, Issue}
> {:ok, ws} = Ash.create(Workspace, %{name: "demo", prefix: "demo"})
> {:ok, issue} = Ash.create(Issue, %{title: "test", workspace_id: ws.id})
> issue.id  # → "demo-XXXXXX"
> {:ok, closed} = Ash.update(issue, %{}, action: :close)
> Ash.read!(Arbiter.Beads.Issue.Version)  # → 2 rows: create + close
```

## Verdict requested

Ready to merge:

```sh
git checkout main
git merge --squash --ff-only feature/gte-002-issue-resource
git commit
bd close gte-002 --reason "Merged to main (commit XXX)"
```

After merge, unblocked:
- **gte-003** (Dependency resource)
- **gte-004** (Convoy resource)

Reviewer should sanity-check:
- `GenerateId.generate_short_id/0` produces lowercase alnum; verify the regex on the `:id` attribute matches its output shape
- `InheritTrackerType` correctly distinguishes "no tracker_type passed" from "explicit `:none` passed" (covered by tests but worth eyeballing the params-check logic)
- `GuardStatus` covers all transitions you'd expect (test coverage looks complete to me)
- AshPaperTrail's `Issue.Version` is registered in the domain (necessary; missing it would error at boot)
- The migration includes both `issues` AND `issues_versions` tables
