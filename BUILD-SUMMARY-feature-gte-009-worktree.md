# gte-009 — Polecat.Worktree module

Bead: gte-009
Branch: `feature/gte-009-worktree`

## What

Foundational Phase 2 piece for the future "polecat orchestrator" (Phase 4): a
thin, well-tested wrapper around `git worktree`, invoked via `System.cmd/3`.
No supervisors, no GenServer, just pure functions returning tagged tuples.

Five public functions on `GtElixir.Polecat.Worktree`:

- `create/3` — `git worktree add <path> -b <branch> <base>`; idempotent when
  the target dir already exists on the requested branch.
- `cleanup/1` — `git worktree remove --force` plus a defensive `File.rm_rf/1`
  so we get back to a clean slate even if git's metadata is already gone.
  Idempotent: no error if the worktree never existed.
- `current_branch/1` — `git rev-parse --abbrev-ref HEAD`.
- `has_uncommitted?/1` — `git status --porcelain`, wrapped as `{:ok, bool}`
  for shape-consistency with the other functions.
- `push/2` — `git push`, with `:remote` and `:set_upstream` opts.

## Files

- `apps/gt_elixir/lib/gt_elixir/polecat/worktree.ex` — new module (~170 LOC).
- `apps/gt_elixir/test/gt_elixir/polecat/worktree_test.exs` — new test module,
  11 tests, `async: false` (mutates `Application` env).

The `GtElixir.Polecat` namespace is brand-new. No other modules in it yet —
this is the seed.

## Design notes

### Worktree root is configurable

Default is `/home/rborn/dev/gt-elixir-worktrees` (per spec). Override via:

```elixir
Application.put_env(:gt_elixir, :worktree_root, "/some/other/dir")
```

Tests rely on this to point at a per-test temp dir. The spec said
"creates a worktree at `/home/rborn/dev/gt-elixir-worktrees/<branch_name>/`"
but pinning that path into the module would have made the tests unwieldy
and would have hard-coded one developer's home directory into production
code. Configurability is cheap and keeps the spec's default behavior.

Branch names containing `/` (e.g. `feature/gte-009-worktree`) are mapped to
directory leaves by replacing `/` with `-`. Public helper
`worktree_path/1` exposes this mapping so callers (and tests) can predict
paths without invoking git.

### Idempotency

- `create/3` short-circuits to `{:ok, path}` if the dir already exists and is
  on the right branch. Different branch → `{:error, {:git_failed, _}}`.
- `cleanup/1` always tries both git and `File.rm_rf/1`. Either step is allowed
  to fail; the contract is "after this call, the directory is gone."

### `run_git/2` helper

Single private wrapper for all `System.cmd` calls:

- `stderr_to_stdout: true` so we can fold stderr into the error reason.
- Pre-checks `cd:` existence to avoid spawning git with a missing cwd
  (which would emit `spawn: Could not cd to ...` directly to stderr —
  noisy in test output).
- Rescues `ErlangError` for the "git isn't on PATH" case.

## Tests

Built against a real fixture (no `System.cmd` mocks), per the bead spec:

- `setup` builds a real `git init -b main` repo with one commit and a bare
  `remote.git` to push to, all inside `System.tmp_dir!()`.
- `on_exit` restores any prior `:worktree_root` setting (or
  `Application.delete_env/2` if none) and `File.rm_rf!`s the temp dir.

Coverage:

- create returns predicted path, dir exists, branch set correctly
- create is idempotent (same args twice)
- create rejects `""` and `nil` branch names with `:invalid_branch_name`
- create on a missing base branch surfaces `{:error, {:git_failed, _}}`
- current_branch returns the branch we created with
- has_uncommitted? false on clean, true after touching a file
- cleanup removes the dir; second cleanup is `:ok`
- cleanup on a never-existed path is `:ok`
- push with `set_upstream: true` puts the branch on the bare remote (verified
  via direct `git branch --list` on the remote)
- push to an unknown remote returns `{:error, {:git_failed, _}}`

```
$ mix test apps/gt_elixir/test/gt_elixir/polecat/worktree_test.exs
11 tests, 0 failures
```

## Verification

```
$ mix compile --warnings-as-errors
(clean)

$ mix format --check-formatted apps/gt_elixir/lib/gt_elixir/polecat/worktree.ex \
                                apps/gt_elixir/test/gt_elixir/polecat/worktree_test.exs
(clean)

$ mix test apps/gt_elixir/test/gt_elixir/polecat/worktree_test.exs
11 tests, 0 failures
```

(There are pre-existing `mix format` diffs in an unrelated migration file
under `priv/repo/migrations/` — not touched by this bead.)

## Followups

- No retry / exponential-backoff on `push/2` — Phase 2 doesn't need it,
  but the orchestrator (Phase 4) may want a `:retries` opt before it runs
  push against a flaky remote at scale.
- `cleanup/1` doesn't delete the branch — intentional separation of concerns,
  but worth a thin `delete_branch/2` helper later if the orchestrator wants
  one-call teardown.
