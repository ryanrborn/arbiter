defmodule Mix.Tasks.Arbiter.Accounts.Rollback do
  @shortdoc "Restore a worker_env from a provider-account migration backup"

  @moduledoc """
  The undo half of `mix arbiter.accounts.migrate`
  (`docs/provider-account-design.md` §7.5). Re-merges the encrypted
  `provider_account_migration_backups` snapshot back into its workspace through
  the same `MergeWorkerEnv` change the migration used to remove it — so the
  restore writes no new crypto code either, and `worker_env_meta` (including
  each key's secret flag) comes back in lockstep.

  It restores **only the keys that migration removed**, as a merge patch. That
  is deliberate: re-merging the whole snapshot would clobber anything the
  operator has legitimately changed since. `--all-keys` opts into the full
  snapshot.

  This task does not delete anything from `provider_accounts` /
  `provider_credentials`. At P2 those rows are inert (nothing reads them), so
  leaving them is harmless and re-running the migration stays a no-op. Dropping
  the tables is §7.5's Release-N rollback, and it is a migration, not this.

  ## Usage

      mix arbiter.accounts.rollback --list
      mix arbiter.accounts.rollback --migration-id 20260918T120000Z-a1b2c3
      mix arbiter.accounts.rollback --workspace default
      mix arbiter.accounts.rollback --all --dry-run

  ## Options

  Exactly one selector:

    * `--migration-id ID` — every backup one migrate run wrote.
    * `--backup-id UUID` — one specific backup row.
    * `--workspace NAME` — that workspace's most recent un-restored backup.
    * `--all` — every un-restored backup, whichever run wrote it.

  And:

    * `--list` — print the backup rows and exit, restoring nothing.
    * `--all-keys` — re-merge the entire snapshot, not just the removed keys.
    * `--dry-run` — report what would be restored; write nothing.

  ## Release installs

  A thin wrapper over `Arbiter.Release.accounts_rollback/1`, which a release
  install (no Mix toolchain) runs directly:

      bin/arbiter eval 'Arbiter.Release.accounts_rollback(list?: true)'
      bin/arbiter eval 'Arbiter.Release.accounts_rollback(migration_id: "20260918T120000Z-a1b2c3")'
  """

  use Mix.Task

  @switches [
    migration_id: :string,
    backup_id: :string,
    workspace: :string,
    all: :boolean,
    list: :boolean,
    all_keys: :boolean,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    # Config only: `Arbiter.Release.accounts_rollback/1` starts Ash, the Repo
    # and the Vault itself, never the full application next to a live server.
    Mix.Task.run("app.config")
    execute(argv)
  end

  @doc """
  Everything `run/1` does after config is loaded: parse `argv` and hand off to
  `Arbiter.Release.accounts_rollback/1`. Split out for the same reason as the
  migrate task's.
  """
  @spec execute([String.t()]) :: :ok
  def execute(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    unless invalid == [] do
      Mix.raise("unrecognised option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    release_opts =
      Keyword.take(opts, [:migration_id, :backup_id, :workspace, :all]) ++
        [
          cli: :mix,
          list?: Keyword.get(opts, :list, false),
          all_keys?: Keyword.get(opts, :all_keys, false),
          dry_run?: Keyword.get(opts, :dry_run, false)
        ]

    _result = Arbiter.Release.accounts_rollback(release_opts)
    :ok
  rescue
    e in Arbiter.Release.Refused -> Mix.raise(e.message)
  end
end
