# Turning on provider accounts on a release install

**Audience:** an operator running Arbiter as an OTP release
(`~/.arbiter/current/bin/arbiter`, managed by `arbiter.service`), which has no
Mix toolchain. On a source checkout, the `mix arbiter.accounts.*` tasks do the
same things. They are thin wrappers over the functions used here.

`:provider_accounts_enabled` ships **off**. While it is off, workers take
provider credentials from each workspace's `worker_env` and the legacy token
chain, exactly as before. To turn it on you must first move each workspace's
credential into a provider account. This is the P2 migration in
[`provider-account-design.md`](provider-account-design.md) §7. With the flag on,
a workspace whose credential was never migrated raises
`Arbiter.Accounts.MissingCredentialError` at spawn time. It does not dispatch a
worker without a credential.

The migration is the provider-accounts point of no return. Every step below is
either read-only or has a written undo. Read the whole page before starting.

## What the operations print

The census, migrate and rollback operations print, log and return only
workspace names, env var **names**, counts and sha256 fingerprints. They never
print a credential value. The plan file they read and write is mode `0600` and
holds fingerprints, not values.

## Before you start

1. **Run a release that has `Arbiter.Release.accounts_census/1`.** Check
   which release is live with `readlink ~/.arbiter/current`.
2. **Rotate first if you need to** (§7.6). If `ARBITER_CLOAK_KEY` or the
   credential itself is considered exposed, rotate the key
   ([`cloak-key-rotation.md`](cloak-key-rotation.md)) and re-issue the
   credential **before** migrating. Otherwise the migration writes fresh
   ciphertext under a key you are about to retire.
3. **Put server-env-only tokens into a workspace.** The census only sees
   credentials stored in a workspace's `worker_env`. A
   `CLAUDE_CODE_OAUTH_TOKEN` that only lives in `~/.arbiter/arbiter.env` is
   invisible to it. Set it on at least one workspace first, in the dashboard's
   workspace environment editor.
4. **Load the server's environment in the shell you run `eval` from.**
   `bin/arbiter eval` starts a separate VM, not the service. It needs the
   same `ARBITER_CLOAK_KEY` (to decrypt `worker_env`), `SECRET_KEY_BASE`
   (`config/runtime.exs` refuses to load without it) and, if you set one,
   `DATABASE_PATH`:

   ```sh
   set -a; . ~/.arbiter/arbiter.env; set +a
   ARB=~/.arbiter/current/bin/arbiter
   PLAN=~/.arbiter/accounts.json      # any absolute path, or one starting with ~
   ```

Each `eval` starts only config, Ash, the Ecto repo and the Cloak vault
(`Arbiter.Release.start_release_vault!/0`). It never starts the endpoint,
Autopilot, patrols or the worker fleet, so it cannot collide with a running
server's port or advisory lock. A refusal prints `** (Arbiter.Release.Refused)
<reason>` and exits non-zero.

## Procedure

### 1. Census (read-only, safe with the server running)

```sh
$ARB eval "Arbiter.Release.accounts_census(plan: \"$PLAN\")"
# optionally fingerprint the operator's own Claude login as a suggestion:
$ARB eval "Arbiter.Release.accounts_census(plan: \"$PLAN\", operator_credential: \"$HOME/.claude/.credentials.json\")"
```

The census prints every workspace, which provider-credential keys it holds, and
the candidate accounts, grouped by `(provider, sha256)`. It then writes a
**candidate** plan to `$PLAN` and writes nothing to the database. It will not
overwrite an existing plan unless you add `force?: true`, because an edited
plan is the record of your decisions.

### 2. Edit the plan

Rename the slugs, and merge any candidates you know to be one account. Two
different tokens can belong to one Anthropic plan (§2.2). Fingerprints alone
cannot tell you that.

### 3. Dry run (writes nothing, safe with the server running)

```sh
$ARB eval "Arbiter.Release.accounts_migrate(plan: \"$PLAN\", dry_run?: true)"
```

The dry run runs every validation the real run does. It reports the accounts,
credentials and workspace attachments it would create, and the keys it would
move out of each `worker_env`. If it refuses, fix the plan, or re-run the
census with `force?: true`, and repeat. Nothing has been written.

### 4. Stop the server and back up the database

```sh
systemctl --user stop arbiter.service
mkdir -p ~/.arbiter/pre-accounts-backup
cp -p ~/.arbiter/arbiter.sqlite3* ~/.arbiter/pre-accounts-backup/   # or your DATABASE_PATH
```

Stop the server because the migration removes the key from `worker_env`, and
until the flag is on nothing supplies it from the account. A worker spawned
between the migration and the restart would run without the workspace's
credential. With the server stopped, the migration is also the only writer on
the SQLite file, and the copy is consistent. The glob also picks up any
`-wal` / `-shm` files next to the database.

### 5. Migrate

```sh
$ARB eval "Arbiter.Release.accounts_migrate(plan: \"$PLAN\")"
```

For each affected workspace, the migration:

1. creates the account, credential and workspace-join rows;
2. writes a **Vault-encrypted backup** of the workspace's `worker_env`
   (`provider_account_migration_backups`) **before** touching it;
3. removes only the allowlisted provider-credential keys from that `worker_env`.

Every check runs before the first write, so a refusal writes nothing. The
output ends with the **migration id** and the exact rollback command. Keep
both. Add `delete_plan?: true` if you want the plan file removed after a
successful apply.

### 6. Set the flag

```sh
echo "ARBITER_PROVIDER_ACCOUNTS=1" >> ~/.arbiter/arbiter.env
```

`config/runtime.exs` reads `ARBITER_PROVIDER_ACCOUNTS` (`1`/`true` for on,
`0`/`false` for off, unset for the shipped default). Any other value stops the
boot rather than guessing. The service reads `arbiter.env` through
`EnvironmentFile=`, so the new value takes effect on the next start.

### 7. Start the server

```sh
systemctl --user start arbiter.service
```

### 8. Verify

- **The flag is on.** The dashboard's `/providers` page no longer shows the
  "Accounts not enabled on this install" banner, and it lists the migrated
  accounts with their credential health.
- **The rows are there.** `arb account list` shows each account from the
  plan.
- **Workers get their credential from the account.** Dispatch a task in each
  migrated workspace. It should run normally, and the log should show no
  `MissingCredentialError`:

  ```sh
  journalctl --user -u arbiter.service --since "10 min ago" | grep -i MissingCredentialError
  ```

  A hit names the workspace. Either migrate its credential (census, then
  migrate again) or roll back as described below.
- **The undo is still available.**
  `$ARB eval 'Arbiter.Release.accounts_rollback(list?: true)'` lists the backup
  rows as `pending`.

Once everything is verified, remove `CLAUDE_CODE_OAUTH_TOKEN` from
`~/.arbiter/arbiter.env` if it was there. It is inert with the flag on, and a
stale credential in a secrets file is a risk of its own.

## Rolling back

There are two levels of rollback. You can use either one, or both.

**Turn the read path off.** Set `ARBITER_PROVIDER_ACCOUNTS=0` in
`~/.arbiter/arbiter.env`, or delete the line, then run
`systemctl --user restart arbiter.service`. Workers go back to the legacy
chain. The migrated keys are **not** in `worker_env` any more, so this only
fully restores the old behaviour if the server's own environment still
supplies the credential. Otherwise also do the next step.

**Put the credentials back into `worker_env`.** Stop the server and dry-run
the restore first:

```sh
systemctl --user stop arbiter.service
$ARB eval 'Arbiter.Release.accounts_rollback(list?: true)'
$ARB eval 'Arbiter.Release.accounts_rollback(migration_id: "<id from step 5>", dry_run?: true)'
$ARB eval 'Arbiter.Release.accounts_rollback(migration_id: "<id from step 5>")'
# then turn the flag off (above) and start the server
systemctl --user start arbiter.service
```

The restore re-merges each backup through the same `MergeWorkerEnv` change the
migration used, including each key's secret flag. By default it restores
**only the keys that migration removed**, so later edits to other keys are
kept. Pass `all_keys?: true` to re-merge the entire snapshot instead. The
selectors are:

- `migration_id: ID`: every backup from one migrate run.
- `backup_id: UUID`: one backup row.
- `workspace: NAME`: that workspace's latest un-restored backup.
- `all: true`: every un-restored backup.

The rollback leaves the `provider_accounts` / `provider_credentials` rows in
place. Nothing reads them with the flag off. The last resort is the database
copy from step 4, restored with the server stopped.

## Source-checkout equivalents

| Release (`bin/arbiter eval`)                                   | Source checkout                                        |
| -------------------------------------------------------------- | ------------------------------------------------------ |
| `Arbiter.Release.accounts_census(plan: P)`                     | `mix arbiter.accounts.census --plan P`                 |
| `…accounts_census(plan: P, force?: true, operator_credential: C)` | `… --force --operator-credential C`                  |
| `Arbiter.Release.accounts_migrate(plan: P, dry_run?: true)`    | `mix arbiter.accounts.migrate --plan P --dry-run`      |
| `…accounts_migrate(plan: P, delete_plan?: true)`               | `… --plan P --delete-plan`                             |
| `Arbiter.Release.accounts_rollback(list?: true)`               | `mix arbiter.accounts.rollback --list`                 |
| `…accounts_rollback(migration_id: ID, dry_run?: true)`         | `… --migration-id ID --dry-run`                        |
| `…accounts_rollback(all: true, all_keys?: true)`               | `… --all --all-keys`                                   |

The Mix tasks also start only config, Ash, the repo and the vault, never the
full application. The flag is set with the same `ARBITER_PROVIDER_ACCOUNTS`
variable, in `.arbiter.env` or the service unit.
