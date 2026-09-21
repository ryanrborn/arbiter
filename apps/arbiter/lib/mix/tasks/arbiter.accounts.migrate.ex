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
  `false`. So the order is: migrate every workspace that carries a provider
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
  """

  use Mix.Task

  require Logger

  alias Arbiter.Accounts.Migrate

  @switches [plan: :string, dry_run: :boolean, delete_plan: :boolean]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    execute(argv)
  end

  @doc """
  Everything `run/1` does after the application has booted.

  Split out so the migration can be exercised against a real, seeded,
  sandboxed database in tests — `Mix.Task.run("app.start")` cannot run under
  the Ecto sandbox.
  """
  @spec execute([String.t()]) :: :ok
  def execute(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    unless invalid == [] do
      Mix.raise("unrecognised option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    plan_path = Keyword.get(opts, :plan) || Mix.raise("--plan PATH is required")
    dry_run? = Keyword.get(opts, :dry_run, false)

    plan =
      case Migrate.read_plan(plan_path) do
        {:ok, plan} -> plan
        {:error, reason} -> Mix.raise(reason)
      end

    case Migrate.apply_plan(plan, dry_run?: dry_run?) do
      {:ok, result} ->
        report(result, plan_path, opts)

      {:error, reason} ->
        Mix.raise("""
        #{reason}

        Nothing was written. Fix the plan (or re-run `mix arbiter.accounts.census`
        to regenerate it) and try again.\
        """)
    end
  end

  defp report(result, plan_path, opts) do
    Mix.shell().info(body(result))

    if result.dry_run? do
      Mix.shell().info("\nNothing was written (dry run). Re-run without --dry-run to apply.")
    else
      maybe_delete_plan(plan_path, opts)
      Mix.shell().info(next_steps(result))

      # Counts and ids only — see §7.4's "Logs" row.
      Logger.info(
        "Arbiter.Accounts.Migrate: migration #{result.migration_id} — " <>
          "#{result.accounts_created} account(s), #{result.credentials_created} credential(s), " <>
          "#{result.workspaces_attached} workspace attachment(s), " <>
          "#{result.keys_removed} key(s) moved out of #{result.workspaces_modified} worker_env blob(s), " <>
          "#{result.backups_written} backup row(s)"
      )
    end

    :ok
  end

  defp body(result) do
    """
    Provider account migration#{if result.dry_run?, do: " (dry run)", else: ""} — #{result.migration_id}

    #{Enum.join(result.lines, "\n")}

    #{summary(result)}\
    """
  end

  defp summary(result) do
    "#{result.accounts_created} account(s) created, " <>
      "#{result.credentials_created} credential(s) written, " <>
      "#{result.workspaces_attached} workspace(s) attached, " <>
      "#{result.keys_removed} key(s) moved out of #{result.workspaces_modified} worker_env blob(s), " <>
      "#{result.backups_written} encrypted backup row(s)."
  end

  defp maybe_delete_plan(plan_path, opts) do
    if Keyword.get(opts, :delete_plan, false) do
      File.rm!(plan_path)
      Mix.shell().info("\nDeleted #{plan_path}.")
    end
  end

  defp next_steps(%{workspaces_modified: 0} = result) do
    """

    No worker_env was modified, so there is nothing to undo. Rollback handle:
    #{result.migration_id}\
    """
  end

  defp next_steps(result) do
    """

    The moved key is no longer in the workspace's worker_env. The account row
    supplies it to a spawn only with `:provider_accounts_enabled` set to true
    (P3's read flip; it ships false) — so migrate every workspace that carries
    a provider credential, then flip the flag. To undo this migration instead:

        mix arbiter.accounts.rollback --migration-id #{result.migration_id}\
    """
  end
end
