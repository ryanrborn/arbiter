# GT → gt-elixir cutover plan

**Status:** Draft, awaiting parallel-run period (gte-027).
**Author:** Mayor
**Last updated:** 2026-05-20

This is the playbook for switching from the Go GT (in `~/dev/gt/`) to the
Elixir gt-elixir port as the source of truth for bead tracking, polecat
orchestration, and merge queuing.

## Pre-flight checklist

Run through this before starting the cutover window.

- [ ] `mix test` is clean on `main` (latest commit).
- [ ] `mix gt_elixir.import_from_dolt --hq-path ... --server-path ... --sync-status`
      has been run within the last hour and reports `0 errors`.
- [ ] All gte-* beads in Postgres match Dolt status (cross-check via SQL):
      ```bash
      gt dolt sql -d hq "SELECT id, status FROM issues WHERE id LIKE 'gte-%' ORDER BY id"
      # vs
      cd ~/dev/gt-elixir/apps/gt_elixir
      mix run -e 'import Ecto.Query; q = from(i in "issues", where: like(i.id, "gte-%"), select: {i.id, i.status}, order_by: i.id); GtElixir.Repo.all(q) |> Enum.each(&IO.inspect/1)'
      ```
- [ ] `bd2 doctor` is green (Phoenix up, workspaces reachable, active workspace
      resolves).
- [ ] Phoenix is supervised by something (systemd, foreman, dev-server) — if
      this is dev-only, accept that bd2 silently dies when the dev shell
      closes. (Phase 5 supervisor work covers production.)
- [ ] At least 3 days of parallel run completed (gte-027 closed).
- [ ] Ryan has signed off on the cutover (gte-027 acceptance).

## Cutover steps

Do these in order. Each step has a verification check before moving on.

### 1. Stop GT

GT is several pieces (mayor session, polecat workers, refineries,
witnesses, deacon, Dolt server). The right command depends on whether you
want a reversible pause or a permanent shutdown:

```bash
gt down                      # reversible pause: stops infra, KEEPS worktrees
# OR
gt shutdown                  # done-for-the-day: stops infra AND cleans up
                             # polecat worktrees/branches (uncommitted work
                             # is protected). Use this for cutover.
gt dolt status               # confirm Dolt server is also down
```

`gt down` and `gt shutdown` both stop the global mayor, per-rig
refineries/witnesses/crew, the deacon/boot watchdogs, the Go daemon,
and the Dolt SQL server. `gt down` leaves polecat worktrees on disk so
in-progress work can be resumed; `gt shutdown` cleans them up (skipping
any with uncommitted changes).

For the cutover you generally want **`gt shutdown`** — you're committing
to the new world, not pausing.

**Verify:** `pgrep -af 'gt mayor|polecat|refinery|witness|dolt sql-server'`
returns nothing.

### 2. Run the importer one last time

This catches any beads created in GT after the most recent sync.

```bash
cd ~/dev/gt-elixir
mix gt_elixir.import_from_dolt \
    --hq-path /home/rborn/dev/gt/.dolt-data/hq \
    --server-path /home/rborn/dev/gt/.dolt-data/server \
    --sync-status
```

**Verify:** "Import complete" with `0 errors`. Compare bead counts:

```bash
# Dolt
gt dolt sql -d hq "SELECT COUNT(*) FROM issues"
gt dolt sql -d server "SELECT COUNT(*) FROM issues"

# Postgres
cd ~/dev/gt-elixir/apps/gt_elixir
mix run -e 'IO.inspect(GtElixir.Repo.aggregate({"issues", GtElixir.Beads.Issue}, :count, :id))'
```

The Postgres count must equal `hq + server` Dolt counts (minus any cross-rig
orphan ids, which are expected to be filtered — see the import task's
`bulk_insert_issues` for the filter logic).

### 3. Switch shell aliases

Edit `~/.zshrc`:

```bash
# OLD (delete):
#   alias bd='gt bd'
#   alias gt='~/dev/gt/bin/gt'

# NEW (add):
alias bd='~/dev/gt-elixir/apps/gt_elixir_cli/bd2'
alias bd2='~/dev/gt-elixir/apps/gt_elixir_cli/bd2'
# Phoenix must be running for bd2 to work; consider a per-shell autostart:
# alias gts='cd ~/dev/gt-elixir && mix phx.server'
```

Then:

```bash
exec zsh -l        # reload shell
bd doctor          # green = success
bd list | head     # smoke test
```

### 4. Disable GT autostart

```bash
# If GT was running under systemd:
systemctl --user disable gt-mayor.service
systemctl --user stop gt-mayor.service

# If it was just a shell-startup hook:
# remove the relevant lines from ~/.zshrc / ~/.zprofile.
```

**Verify:** new shell, `pgrep -f 'gt mayor'` is empty.

### 5. Archive `.dolt-data/`

```bash
mkdir -p ~/archive/gt-cutover-$(date +%Y%m%d)
mv ~/dev/gt/.dolt-data ~/archive/gt-cutover-$(date +%Y%m%d)/
```

**Important**: archive, don't delete. Keep for at least 90 days in case
gt-elixir surfaces a data-loss bug and we need to re-import.

### 6. Update CLAUDE.md files

Anywhere a CLAUDE.md mentions `gt`, `bd`, `~/dev/gt/`, swap to the gt-elixir
equivalent:

- `~/dev/gt/CLAUDE.md` → either delete or replace with a pointer note:
  "This workspace was archived 2026-MM-DD. Active work moved to
  ~/dev/gt-elixir/."
- `~/.claude/CLAUDE.md` — global notes referencing GT operational details
  should be updated.

### 7. Write the post-mortem

In `~/dev/gt-elixir/docs/postmortem-cutover.md`. Cover:

- Total elapsed time from Phase 0 to cutover.
- Beads completed vs Phase 0 estimate (28-42 days).
- Bugs surfaced during parallel run.
- What was harder than expected.
- What was easier than expected.
- Anything the Phase 0 decision-doc got wrong.

## Rollback plan

If something breaks within 7 days of cutover:

1. **Stop Phoenix**: `pkill -f 'mix phx.server'`.
2. **Restore `.dolt-data/`** from the archive:
   ```bash
   mv ~/archive/gt-cutover-<date>/.dolt-data ~/dev/gt/
   ```
3. **Revert `~/.zshrc`** (the `bd` alias).
4. **Re-enable GT autostart** (`systemctl --user enable gt-mayor.service`).
5. **Start GT**: `gt start`.
6. **File a bead in the new (working) world** describing the cutover blocker,
   then re-attempt cutover once it's resolved.

Postgres data is NOT discarded on rollback — it remains available for
forensics. Re-cutover will re-sync from Dolt via `--sync-status`.

## Cutover criteria (Definition of Done)

The cutover is complete when:

- [ ] `pgrep -f 'gt mayor'` returns nothing for 24 hours.
- [ ] `bd2 list` is the only working CLI; the old `bd` alias no longer exists.
- [ ] At least one polecat has been slung via `bd2 sling` and reached `:done`.
- [ ] At least one PR has been opened + merged via the Refinery merge queue.
- [ ] No bead has been edited in the archived Dolt for 24 hours.
- [ ] gte-028 (Decommission GT) is closed.

## What's NOT in this plan

- **Data shape changes**: the gte-007 importer maps Dolt → Postgres
  field-for-field. There's no schema migration to plan for at cutover time.
- **Authentication / multi-tenancy**: out of scope. Single-user system.
- **Backup automation**: out of scope. The `.dolt-data/` archive is a manual
  one-time snapshot; Postgres backups are a separate concern (Phase 5).

## Open questions

- Should we keep GT's bd writes flowing to Dolt during the parallel-run period
  for an extra safety net? Current plan: yes, until gte-028 fires.
- Do we need a "dual-write" mode where bd2 commands also append to Dolt?
  Current plan: no, the importer's `--sync-status` is enough.
- What happens to in-flight polecat work at cutover-start? Current plan: stop
  the world (`gt stop`); restart polecats in gt-elixir after cutover.
