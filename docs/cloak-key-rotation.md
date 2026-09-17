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

## Procedure

1. **Generate a new key** and keep the current (soon-to-be-old) key at hand:

   ```sh
   NEW_KEY="$(openssl rand -base64 32)"
   OLD_KEY="$ARBITER_CLOAK_KEY"   # the currently-deployed key
   ```

2. **Deploy with both keys set** — `ARBITER_CLOAK_KEY` to the new key,
   `ARBITER_CLOAK_KEY_OLD` to the old one:

   ```sh
   ARBITER_CLOAK_KEY="$NEW_KEY"
   ARBITER_CLOAK_KEY_OLD="$OLD_KEY"
   ```

   On boot, `Arbiter.Vault.init/1` now registers **two** ciphers: `:default`
   (tag `AES.GCM.V2`, the new key — used for all new writes) and `:retired`
   (tag `AES.GCM.V1`, the old key — decrypt-only). Existing rows keep
   decrypting correctly; nothing needs to happen synchronously with the
   deploy.

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
   environment and redeploy. `Arbiter.Vault.init/1` then registers only the
   `:default` cipher again; the retired key is no longer reachable from a
   running process.

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
