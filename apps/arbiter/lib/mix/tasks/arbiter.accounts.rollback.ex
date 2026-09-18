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
  """

  use Mix.Task

  require Logger

  alias Arbiter.Accounts.Migrate

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
    Mix.Task.run("app.start")
    execute(argv)
  end

  @doc """
  Everything `run/1` does after the application has booted. Split out for the
  same reason as the migrate task's: `app.start` cannot run under the sandbox.
  """
  @spec execute([String.t()]) :: :ok
  def execute(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    unless invalid == [] do
      Mix.raise("unrecognised option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    if Keyword.get(opts, :list, false), do: list(), else: restore(opts)
  end

  defp list do
    case Migrate.list_backups() do
      [] ->
        Mix.shell().info("No provider-account migration backups.")

      backups ->
        Mix.shell().info("""
        Provider account migration backups — names and counts only, no values.

        #{Enum.map_join(backups, "\n", &backup_line/1)}\
        """)
    end

    :ok
  end

  defp backup_line(backup) do
    state = if backup.restored_at, do: "restored #{backup.restored_at}", else: "pending"

    "  #{backup.migration_id}  #{backup.workspace}  " <>
      "[#{Enum.join(backup.removed_keys, ", ")}]  #{state}  (#{backup.id})"
  end

  defp restore(opts) do
    selector =
      Keyword.take(opts, [:migration_id, :backup_id, :workspace]) ++ all_selector(opts)

    if selector == [] do
      Mix.raise(
        "give one of --migration-id, --backup-id, --workspace or --all " <>
          "(or --list to see what there is)"
      )
    end

    rollback_opts =
      selector ++
        [
          all_keys?: Keyword.get(opts, :all_keys, false),
          dry_run?: Keyword.get(opts, :dry_run, false)
        ]

    case Migrate.rollback(rollback_opts) do
      {:ok, result} -> report(result)
      {:error, reason} -> Mix.raise(reason)
    end
  end

  # `--all` is expressed to `Migrate.rollback/1` as "every un-restored backup",
  # which is the same selector `--workspace` uses, widened.
  defp all_selector(opts) do
    if Keyword.get(opts, :all, false), do: [all: true], else: []
  end

  defp report(result) do
    Mix.shell().info("""
    Provider account rollback#{if result.dry_run?, do: " (dry run)", else: ""}

    #{Enum.join(result.lines, "\n")}

    #{result.restored} workspace(s) restored, #{result.keys_restored} key(s) merged back, \
    #{result.skipped} skipped.\
    """)

    if result.dry_run? do
      Mix.shell().info("\nNothing was written (dry run). Re-run without --dry-run to restore.")
    else
      # Counts and names only — §7.4.
      Logger.info(
        "Arbiter.Accounts.Migrate rollback: #{result.restored} workspace(s) restored, " <>
          "#{result.keys_restored} key(s) merged back, #{result.skipped} skipped"
      )
    end

    :ok
  end
end
