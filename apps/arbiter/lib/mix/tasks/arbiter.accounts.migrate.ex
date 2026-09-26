defmodule Mix.Tasks.Arbiter.Accounts.Migrate do
  @shortdoc "Apply an operator-edited provider-account plan (P2 extraction)"

  @moduledoc """
  Phase P2 of the provider-accounts migration (`docs/provider-account-design.md`
  §7.2–§7.5). Applies the plan `mix arbiter.accounts.census` proposed and the
  operator edited:

    1. creates the `provider_accounts` / `provider_credentials` /
       `workspace_provider_accounts` rows the plan describes;
    2. writes a Vault-encrypted `provider_account_migration_backups` row per
       affected workspace **before** touching it (§7.5);
    3. removes only the §7.3-allowlisted keys from that workspace's
       `worker_env`, via the existing `MergeWorkerEnv` change.

  Every check runs before the first write, so a refusal leaves the database and
  the plan file exactly as it found them. The task prints counts, workspace
  names and env var names — never a value (§7.4).

  ## Before you run this (§7.6)

  `ARBITER_CLOAK_KEY` should already have been rotated **and the provider
  credential itself re-issued**. Otherwise this writes fresh ciphertext under a
  key considered exposed, and the rotation sweep then has to cover the new
  tables too.

  ## Turning the new tables on (§7.5's "Release N+1")

  Moving a key out of the blob stops a worker spawned from that workspace
  receiving it from the blob. Since P3 (bd-aiodva) the account row supplies it
  instead, but only once `:provider_accounts_enabled` is `true` — it ships
  `false`; set `ARBITER_PROVIDER_ACCOUNTS=1` in the server's environment and
  restart to turn it on. So the order is: migrate every workspace that carries a provider
  credential, then flip the flag.

  With the flag on, a workspace whose blob still carries a credential that no
  account supplies raises `Arbiter.Accounts.MissingCredentialError` at spawn
  time rather than dispatching a worker with no credential. Both undos are
  cheap: flip the flag back, or run `mix arbiter.accounts.rollback` (the
  backup row is written for exactly this).

  ## Usage

      mix arbiter.accounts.migrate --plan accounts.json
      mix arbiter.accounts.migrate --plan accounts.json --dry-run
      mix arbiter.accounts.migrate --plan accounts.json --delete-plan

  ## Options

    * `--plan PATH` — **required.** The edited plan file.
    * `--dry-run` — validate and report what would happen; write nothing.
    * `--delete-plan` — delete the plan file after a successful apply. §7.4
      suggests it; it is opt-in here rather than the default, because the file
      is the operator's own edited artefact and it contains no secret (only
      fingerprints and key names), so destroying it unasked buys nothing.

  ## Release installs

  A thin wrapper over `Arbiter.Release.accounts_migrate/1`, which a release
  install (no Mix toolchain) runs directly:

      bin/arbiter eval 'Arbiter.Release.accounts_migrate(plan: "/home/me/.arbiter/accounts.json", dry_run?: true)'
      bin/arbiter eval 'Arbiter.Release.accounts_migrate(plan: "/home/me/.arbiter/accounts.json")'

  See `docs/provider-accounts-release-runbook.md` for the full procedure,
  including setting the flag.
  """

  use Mix.Task

  @switches [plan: :string, dry_run: :boolean, delete_plan: :boolean]

  @impl Mix.Task
  def run(argv) do
    # Config only: `Arbiter.Release.accounts_migrate/1` starts Ash, the Repo
    # and the Vault itself, never the full application next to a live server.
    Mix.Task.run("app.config")
    execute(argv)
  end

  @doc """
  Everything `run/1` does after config is loaded: parse `argv` and hand off to
  `Arbiter.Release.accounts_migrate/1`, which holds the logic so a release
  install can run the same migration through `bin/arbiter eval`.

  Split out so the migration can be exercised against a real, seeded,
  sandboxed database in tests.
  """
  @spec execute([String.t()]) :: :ok
  def execute(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    unless invalid == [] do
      Mix.raise("unrecognised option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    release_opts = [
      cli: :mix,
      plan: opts[:plan],
      dry_run?: Keyword.get(opts, :dry_run, false),
      delete_plan?: Keyword.get(opts, :delete_plan, false)
    ]

    _result = Arbiter.Release.accounts_migrate(release_opts)
    :ok
  rescue
    e in Arbiter.Release.Refused -> Mix.raise(e.message)
  end
end
