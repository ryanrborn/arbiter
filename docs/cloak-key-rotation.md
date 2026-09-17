# Rotating `ARBITER_CLOAK_KEY`

Runbook for rotating the AES-256-GCM key `Arbiter.Vault` uses to encrypt
`ash_cloak`-protected columns at rest (`workspaces.encrypted_secrets`,
`workspaces.encrypted_worker_env`, `provider_credentials.encrypted_secret`
— see `Arbiter.Vault.Rotation` for the authoritative, generated-from-code
list).

Use this whenever the current key is considered exposed (leaked into a
transcript, log, or shared terminal), on a routine schedule, or ahead of any
work that will write fresh ciphertext under the current key (e.g.
`docs/provider-account-design.md` §7.6 requires this to run **before**
provider-account credential extraction begins — bd-7df8nh Phase P2).

This is Cloak's native two-cipher rotation: the new key becomes `:default`
(used for all new encryption), the old key stays registered read-only until
every row has been re-encrypted, then it's dropped.

Ciphertext is tagged with a **generation number** (`AES.GCM.V<n>`), tracked
by `ARBITER_CLOAK_KEY_GENERATION` (defaults to `1` — an install that has
never rotated needs no rotation env vars at all, and this ticket's code
change alone is a no-op for it). This is what makes the procedure below
repeatable for a *future* rotation too, not just this one: each rotation
just bumps the generation by one.

**The three rotation env vars must change together, in the same deploy** —
`ARBITER_CLOAK_KEY`, `ARBITER_CLOAK_KEY_OLD`, and
`ARBITER_CLOAK_KEY_GENERATION`. Bumping the generation without also setting
`ARBITER_CLOAK_KEY_OLD` (or vice versa) leaves the previous generation's
data without a matching cipher — nothing decrypts it. See
`Arbiter.Vault`'s moduledoc for the full mechanics.

## Procedure

Rotating from generation N to N+1:

1. **Generate a new key** and keep the current (soon-to-be-old) key at hand:

   ```sh
   NEW_KEY="$(openssl rand -base64 32)"
   OLD_KEY="$ARBITER_CLOAK_KEY"   # the currently-deployed (generation N) key
   ```

2. **Deploy with all three rotation vars set together**:

   ```sh
   ARBITER_CLOAK_KEY="$NEW_KEY"
   ARBITER_CLOAK_KEY_OLD="$OLD_KEY"
   ARBITER_CLOAK_KEY_GENERATION="<N+1>"
   ```

   On boot, `Arbiter.Vault.init/1` now registers **two** ciphers: `:default`
   (tag `AES.GCM.V<N+1>`, the new key — used for all new writes) and
   `:retired` (tag `AES.GCM.V<N>`, the old key — decrypt-only). Existing
   rows keep decrypting correctly; nothing needs to happen synchronously
   with the deploy.

3. **Check what's outstanding** (read-only, safe to run any time):

   ```sh
   mix arbiter.rotate_cloak_key --verify
   ```

4. **Sweep** — re-encrypts every `ash_cloak` column under the new cipher.
   Safe to interrupt and re-run: rows already on the new cipher are skipped.

   ```sh
   mix arbiter.rotate_cloak_key --sweep
   ```

5. **Verify again** — must report zero rows left on the retired cipher
   before the next step:

   ```sh
   mix arbiter.rotate_cloak_key --verify
   ```

6. **Drop the old key** — remove `ARBITER_CLOAK_KEY_OLD` from the
   environment, **leave `ARBITER_CLOAK_KEY_GENERATION` at `<N+1>`
   permanently**, and redeploy. `Arbiter.Vault.init/1` then registers only
   the `:default` cipher (still tag `AES.GCM.V<N+1>`, matching the now
   fully-migrated data); the retired key is no longer reachable from a
   running process. Reverting the generation here would strand the swept
   data — nothing would register a cipher for the tag it's actually under.

## Notes

- Steps 3–5 talk to the database directly (`Ecto.Adapters.SQL`), bypassing
  Ash actions — this is an at-rest re-encryption of opaque ciphertext, not a
  domain write, so it doesn't go through resource changes or paper-trail
  versioning (and workspace paper-trail already ignores the encrypted
  columns for exactly this reason).
- Nothing here ever logs plaintext or writes it to disk — the sweep task
  prints only table/column names and row counts.
- New resources that add a `cloak do ... end` block must be added to
  `Arbiter.Vault.Rotation`'s `@columns` list — it is not auto-discovered.
- This rotates the *storage* key only. Rotating the underlying provider
  credential itself (e.g. a fresh `claude setup-token` grant) is a separate,
  manual operator action — see `docs/provider-account-design.md` §7.6.
