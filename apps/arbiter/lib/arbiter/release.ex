defmodule Arbiter.Release do
  @moduledoc """
  Release-time database tasks for the `arbiter` mix release.

  Mix (and therefore `mix ecto.migrate`) is not available inside a release, so
  an operator invokes these via `bin/arbiter eval Arbiter.Release.migrate`.
  """

  require Logger

  @app :arbiter

  @doc """
  Migrate the database to the latest version.

  The standard Phoenix mix-release migration entrypoint for deployments that
  run without Mix (the release is a standalone binary), invoked as
  `bin/arbiter eval Arbiter.Release.migrate`.

  **Only run this with the server stopped.** It opens its own writer against
  the database, and SQLite allows exactly one; against a live server it races
  the writer the server holds. `arb server deploy` deliberately does *not* call
  it for that reason (bd-bksulf) — the ordinary path is `Arbiter.Boot.Migrator`,
  which migrates synchronously during the new release's boot, before the
  endpoint opens. Reach for this eval only for a deliberate out-of-band
  migration with `systemctl --user stop arbiter.service` already done.
  """
  def migrate do
    Application.load(@app)

    for repo <- repos() do
      {:ok, _migrated_versions, _started_apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Run the workspace-config data migrations (currently `rig_paths` →
  `repo_paths`) without restarting the server.

  Called via `bin/arbiter eval Arbiter.Release.migrate_config`. Boot already
  runs these — `Arbiter.Boot.ConfigMigrator` — so a plain `arb server restart`
  is the simplest remediation; this exists because production installs are
  Mix-less releases where `mix arbiter.migrate_rig_paths` cannot run, and an
  operator staring at a broken install should not have to restart it to get
  repos back (bd-3pqzsa).

  Starts only the database layer, never the endpoint or worker fleet: an eval
  runs in a *separate* node from the live server, and booting the full app
  there would trip the single-instance guard and could disrupt in-flight
  workers. Mirrors `mix arbiter.loop.analyze`'s read-only startup.

  Prints one line per migrated workspace and returns the raw results.
  """
  def migrate_config do
    Application.load(@app)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)
    {:ok, _pid} = Arbiter.Repo.start_link()

    results = Arbiter.Boot.ConfigMigrator.migrate_rig_paths()

    case results do
      [] -> IO.puts("No workspace carries rig_paths — nothing to migrate.")
      results -> Enum.each(results, fn r -> IO.puts(format_config_result(r)) end)
    end

    results
  end

  defp format_config_result(%{status: :migrated} = r),
    do:
      "#{r.workspace}: migrated #{length(r.repos)} repo(s) -> repo_paths: #{Enum.join(r.repos, ", ")}"

  defp format_config_result(%{status: {:error, message}} = r),
    do: "#{r.workspace}: FAILED -- #{message}"

  defp format_config_result(r), do: "#{r.workspace}: #{inspect(r.status)}"

  @doc """
  Rollback a migration for the given repo to the specified version.

  Called via `bin/arbiter eval "Arbiter.Release.rollback(Arbiter.Repo, version)"`.
  """
  def rollback(repo, version) do
    Application.load(@app)

    {:ok, _migrated_versions, _started_apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  @doc """
  Run a data-maintenance backfill without Mix or the full application.

  Every `mix arbiter.backfill_*` task's logic lives here now, so a release
  install — which has no Mix toolchain — can run it via
  `bin/arbiter eval 'Arbiter.Release.backfill(:codex_usage)'` (dry-run) or
  `bin/arbiter eval 'Arbiter.Release.backfill(:codex_usage, apply?: true)'`.
  The Mix tasks under `lib/mix/tasks/arbiter.backfill_*.ex` are thin CLI
  wrappers over these same clauses for dev/source installs.

  Starts only Ash + `Arbiter.Repo` (`start_release_repo!/0`), never the full
  `Arbiter.Application` tree — booting the endpoint, Autopilot, and patrols
  a second time next to a live coordinator would fight it over the same
  database and port. Safe to call from an attached node that already has
  the app running too, since the repo start is a no-op in that case.

  Every backfill defaults to a dry run (no writes; reports what it would
  change) unless `apply?: true` is passed. Supported names and their
  option keys mirror the corresponding library module:

    * `:codex_usage` → `Arbiter.Usage.CodexUsageBackfill.backfill/1`
      (`:apply?`, `:since`, `:until`, `:limit`, `:tolerance_ms`)
    * `:gemini_usage_note` → `Arbiter.Usage.GeminiUsageNote.backfill/1`
      (`:apply?`, `:since`, `:until`, `:limit`)
    * `:issue_repos` → `Arbiter.Tasks.RepoBackfill.plan/0` + `apply!/1`
      (`:apply?`)
    * `:run_steps` → `Arbiter.Workers.StepBackfill.backfill/1`
      (`:apply?`, `:repo`, `:since`, `:until`, `:limit`)
    * `:task_statuses` → `Arbiter.Tasks.StatusBackfill.proposals/1` +
      `apply!/1` (`:apply?`, `:branch`, `:repo_path`) — `:repo_path` defaults
      to `File.cwd!()`, which under `bin/arbiter eval` is wherever the
      operator invoked `bin/arbiter`, not the arbiter checkout. Always pass
      it explicitly in a release eval, e.g.
      `bin/arbiter eval 'Arbiter.Release.backfill(:task_statuses, repo_path: "/path/to/arbiter")'`

  Returns the underlying module's raw result and prints a short summary to
  stdout for the `bin/arbiter eval` operator.
  """
  @spec backfill(atom(), keyword()) :: term()
  def backfill(name, opts \\ [])

  def backfill(:codex_usage, opts) do
    start_release_repo!()
    apply? = Keyword.get(opts, :apply?, false)

    result = Arbiter.Usage.CodexUsageBackfill.backfill(opts)

    IO.puts(banner("codex usage", apply?, opts[:hint]))

    IO.puts("""

    codex rows scanned:  #{result.scanned}
    #{String.pad_trailing(if(apply?, do: "backfilled", else: "would backfill") <> ":", 22)}#{result.backfilled + result.would_backfill}
    no rollout file:      #{result.no_rollout_file}
    no token_count line:  #{result.no_token_count}
    unreadable file:      #{result.unreadable}
    write failures:        #{result.failed}
    """)

    result
  end

  def backfill(:gemini_usage_note, opts) do
    start_release_repo!()
    apply? = Keyword.get(opts, :apply?, false)

    result = Arbiter.Usage.GeminiUsageNote.backfill(opts)

    IO.puts(banner("gemini usage note", apply?, opts[:hint]))

    IO.puts("""

    gemini rows scanned:  #{result.scanned}
    #{String.pad_trailing(if(apply?, do: "noted", else: "would note") <> ":", 22)}#{result.noted + result.would_note}
    write failures:        #{result.failed}
    """)

    result
  end

  def backfill(:issue_repos, opts) do
    start_release_repo!()
    apply? = Keyword.get(opts, :apply?, false)

    plan = Arbiter.Tasks.RepoBackfill.plan()

    if apply? do
      reports = Arbiter.Tasks.RepoBackfill.apply!(plan)
      IO.puts(banner("issue repos", true, opts[:hint]))
      emit_issue_repos_report(reports, :apply)
      reports
    else
      IO.puts(banner("issue repos", false, opts[:hint]))
      emit_issue_repos_report(plan, :dry_run)
      plan
    end
  end

  def backfill(:run_steps, opts) do
    start_release_repo!()
    apply? = Keyword.get(opts, :apply?, false)

    result = Arbiter.Workers.StepBackfill.backfill(opts)

    IO.puts(banner("run steps", apply?, opts[:hint]))

    IO.puts("""

    runs scanned:      #{result.scanned}
    steps #{String.pad_trailing(if(apply?, do: "inserted", else: "would insert") <> ":", 13)}#{result.inserted}
    already present:   #{result.existing}
    no session file:   #{result.no_session_file}
    no session id:     #{result.no_session_id}
    unreadable file:   #{result.unreadable}
    write failures:    #{result.failed}
    """)

    result
  end

  def backfill(:task_statuses, opts) do
    start_release_repo!()
    apply? = Keyword.get(opts, :apply?, false)
    hint = opts[:hint] || "apply?: true / --apply"
    proposals_opts = Keyword.take(opts, [:branch, :repo_path, :git_log_lines])
    proposals = Arbiter.Tasks.StatusBackfill.proposals(proposals_opts)

    cond do
      proposals == [] ->
        IO.puts("No drifted tasks found. Nothing to do.")
        {[], []}

      apply? ->
        IO.puts("Closing #{length(proposals)} task(s):")
        emit_task_statuses_table(proposals)
        {closed, errors} = Arbiter.Tasks.StatusBackfill.apply!(proposals)
        IO.puts("\nClosed #{length(closed)} task(s).")

        unless errors == [] do
          IO.puts(:stderr, "Failed on #{length(errors)} task(s):")
          for {id, reason} <- errors, do: IO.puts(:stderr, "  #{id}: #{inspect(reason)}")
        end

        {closed, errors}

      true ->
        IO.puts("Would close #{length(proposals)} task(s):")
        emit_task_statuses_table(proposals)
        IO.puts("\nDry-run only. Pass #{hint} to commit these changes.")
        proposals
    end
  end

  defp emit_task_statuses_table(proposals) do
    width = proposals |> Enum.map(&String.length(&1.task_id)) |> Enum.max(fn -> 0 end)

    for p <- proposals do
      padded = String.pad_trailing(p.task_id, width)
      short_sha = String.slice(p.commit_sha, 0, 7)
      IO.puts("  #{padded}  #{short_sha}  #{p.commit_subject}")
    end
  end

  defp emit_issue_repos_report(reports, mode) do
    IO.puts(issue_repos_header(mode))

    for report <- reports, report.null_repo_count > 0 or report.resolved_repo != nil do
      IO.puts("  " <> issue_repos_line(report, mode))

      for {id, message} <- report.errors do
        IO.puts(:stderr, "      #{id}: #{message}")
      end
    end

    IO.puts("\n" <> issue_repos_totals(reports, mode))
  end

  defp issue_repos_header(:dry_run), do: "Issues with a null repo, by workspace:\n"
  defp issue_repos_header(:apply), do: "Backfilling repo by workspace:\n"

  defp issue_repos_line(%{resolved_repo: nil} = r, _mode) do
    "#{r.workspace_name}: #{r.null_repo_count} null — LEFT NULL " <>
      "(no single repo and no default_repo; set one and re-run)"
  end

  defp issue_repos_line(r, :dry_run),
    do: "#{r.workspace_name}: #{r.null_repo_count} null → #{r.resolved_repo}"

  defp issue_repos_line(r, :apply) do
    "#{r.workspace_name}: set #{r.updated} to #{r.resolved_repo}" <>
      if(r.errors == [], do: "", else: " (#{length(r.errors)} failed)")
  end

  defp issue_repos_totals(reports, :dry_run) do
    would = reports |> Enum.map(& &1.null_repo_count) |> Enum.sum()
    left = Arbiter.Tasks.RepoBackfill.remaining_null_count(reports)
    "#{would - left} issue(s) would be backfilled; #{left} would remain null."
  end

  defp issue_repos_totals(reports, :apply) do
    updated = reports |> Enum.map(& &1.updated) |> Enum.sum()

    "Backfilled #{updated} issue(s); #{Arbiter.Tasks.RepoBackfill.remaining_null_count(reports)} remain null."
  end

  defp banner(label, true, _hint), do: "Backfilling #{label} (writing)…"

  defp banner(label, false, hint) do
    "Backfilling #{label} — DRY RUN, no writes. Pass #{hint || "apply?: true / --apply"} to write.\n"
  end

  @doc """
  Load config and start only Ash + `Arbiter.Repo` (`pool_size: 1`), never
  the full `Arbiter.Application` tree — no endpoint, no Autopilot, no
  patrols. Shared by every `backfill/2` clause and safe to call repeatedly
  or from a node that already has the app running (`start_link` returning
  `{:error, {:already_started, _}}` is treated as success).
  """
  @spec start_release_repo! :: :ok
  def start_release_repo! do
    Application.load(@app)
    {:ok, _} = Application.ensure_all_started(:ash)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)

    case Arbiter.Repo.start_link(pool_size: 1) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  `start_release_repo!/0` plus `Arbiter.Vault` — the Cloak vault the
  provider-account operations need to decrypt `worker_env` and to write the
  encrypted credential and backup rows. Still never the full
  `Arbiter.Application` tree, and equally safe to call repeatedly or from a
  node that already has the app running.

  The vault resolves `ARBITER_CLOAK_KEY` from the environment, so a
  `bin/arbiter eval` needs `~/.arbiter/arbiter.env` loaded first; a missing
  key raises `Arbiter.Vault.key!/0`'s own explanation before anything starts.
  """
  @spec start_release_vault! :: :ok
  def start_release_vault! do
    :ok = start_release_repo!()
    _key = Arbiter.Vault.key!()

    case Arbiter.Vault.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # ------------------------------------------------------- provider accounts

  @default_accounts_plan "accounts.json"

  @doc """
  Provider-accounts P0 census, release-callable: the logic behind
  `mix arbiter.accounts.census` (a thin wrapper over this).

      bin/arbiter eval 'Arbiter.Release.accounts_census(plan: "/home/me/.arbiter/accounts.json")'

  Decrypts every workspace's `worker_env` in memory, prints the census
  (workspace names, env var names, counts, truncated sha256 fingerprints — never
  a value) and writes the candidate plan at mode `0600`. Writes nothing to the
  database. See `Arbiter.Accounts.Census`.

  ## Options

    * `:plan` — plan path. Default `accounts.json` in the current directory,
      which under `bin/arbiter eval` is wherever the operator ran it, so pass
      it explicitly. A leading `~` is expanded.
    * `:force?` — overwrite an existing plan (an edited plan is the artefact
      of record, so the default refuses).
    * `:operator_credential` — path to a Claude CLI `.credentials.json` whose
      `claudeAiOauth.accessToken` is fingerprinted and offered as a suggested
      second credential. Only the fingerprint leaves the reader.

  Starts only Ash, the Repo and the Vault (`start_release_vault!/0`). Returns
  the census map, which carries fingerprints and names only. Raises
  `Arbiter.Release.Refused` on a refusal.
  """
  @spec accounts_census(keyword()) :: map()
  def accounts_census(opts \\ []) do
    plan_path = opts |> Keyword.get(:plan, @default_accounts_plan) |> expand_home()

    if File.exists?(plan_path) and not Keyword.get(opts, :force?, false) do
      raise Arbiter.Release.Refused,
            "#{plan_path} already exists; " <>
              hint(opts, "re-run with --force", "pass force?: true") <> " to overwrite it"
    end

    start_release_vault!()

    census = Arbiter.Accounts.Census.run(operator_credential_opts(opts))

    IO.puts(Arbiter.Accounts.Census.report(census))

    Arbiter.Accounts.Census.write_plan!(census, plan_path, true)

    IO.puts("""

    Candidate plan written to #{plan_path} (mode 0600). It is a proposal:
    rename the slugs, merge any candidates you know to be one account, then run
    the migrate step against it. Nothing was written to the database.\
    """)

    # Fingerprints and counts only — see §7.4's "Logs" row.
    Logger.info(
      "Arbiter.Accounts.Census: scanned #{census.totals.workspaces} workspace(s), " <>
        "#{census.totals.credential_keys} provider-credential key(s), " <>
        "#{census.totals.accounts} candidate account(s); plan written to #{plan_path}"
    )

    census
  end

  # A read failure is a note on the census, not an abort: the rest of the
  # inventory is still worth having.
  defp operator_credential_opts(opts) do
    case Keyword.fetch(opts, :operator_credential) do
      :error ->
        []

      {:ok, path} ->
        case Arbiter.Accounts.Census.operator_credential(path) do
          {:ok, credential} ->
            [operator_credential: credential]

          {:error, reason} ->
            IO.puts("\nOperator credential: could not read #{path} (#{reason}).")
            [operator_credential_error: reason]
        end
    end
  end

  @doc """
  Provider-accounts P2 extraction, release-callable: the logic behind
  `mix arbiter.accounts.migrate` (a thin wrapper over this).

      bin/arbiter eval 'Arbiter.Release.accounts_migrate(plan: "/home/me/.arbiter/accounts.json", dry_run?: true)'
      bin/arbiter eval 'Arbiter.Release.accounts_migrate(plan: "/home/me/.arbiter/accounts.json")'

  Applies an operator-edited census plan: creates the account, credential and
  workspace-join rows, writes a Vault-encrypted backup row per affected
  workspace **before** touching it, then removes only the allowlisted keys
  from that workspace's `worker_env`. Every check runs before the first write,
  so a refusal leaves the database and the plan file as they were. See
  `Arbiter.Accounts.Migrate`.

  ## Options

    * `:plan` — **required.** The edited plan path. A leading `~` is expanded.
    * `:dry_run?` — validate and report what would happen; write nothing.
    * `:delete_plan?` — delete the plan file after a successful apply.

  Starts only Ash, the Repo and the Vault. Prints counts, workspace names and
  env var names — never a value — and returns `t:Arbiter.Accounts.Migrate.result/0`
  (the same, as data). Raises `Arbiter.Release.Refused` on a refusal.
  """
  @spec accounts_migrate(keyword()) :: Arbiter.Accounts.Migrate.result()
  def accounts_migrate(opts) do
    plan_path =
      case Keyword.get(opts, :plan) do
        nil ->
          raise Arbiter.Release.Refused,
                hint(
                  opts,
                  "--plan PATH is required",
                  "plan: PATH is required, e.g. " <>
                    ~s|Arbiter.Release.accounts_migrate(plan: "/path/to/accounts.json")|
                )

        path ->
          expand_home(path)
      end

    dry_run? = Keyword.get(opts, :dry_run?, false)

    plan =
      case Arbiter.Accounts.Migrate.read_plan(plan_path) do
        {:ok, plan} -> plan
        {:error, reason} -> raise Arbiter.Release.Refused, reason
      end

    start_release_vault!()

    case Arbiter.Accounts.Migrate.apply_plan(plan, dry_run?: dry_run?) do
      {:ok, result} ->
        report_migration(result, plan_path, opts)
        result

      {:error, reason} ->
        raise Arbiter.Release.Refused, """
        #{reason}

        Nothing was written. Fix the plan (or re-run #{hint(opts, "`mix arbiter.accounts.census`", "`Arbiter.Release.accounts_census/1`")}
        to regenerate it) and try again.\
        """
    end
  end

  defp report_migration(result, plan_path, opts) do
    IO.puts("""
    Provider account migration#{if result.dry_run?, do: " (dry run)", else: ""} — #{result.migration_id}

    #{Enum.join(result.lines, "\n")}

    #{migration_summary(result)}\
    """)

    if result.dry_run? do
      IO.puts(
        "\nNothing was written (dry run). Re-run without " <>
          hint(opts, "--dry-run", "dry_run?: true") <> " to apply."
      )
    else
      if Keyword.get(opts, :delete_plan?, false) do
        File.rm!(plan_path)
        IO.puts("\nDeleted #{plan_path}.")
      end

      IO.puts(migration_next_steps(result, opts))

      # Counts and ids only — see §7.4's "Logs" row.
      Logger.info(
        "Arbiter.Accounts.Migrate: migration #{result.migration_id} — " <>
          "#{result.accounts_created} account(s), #{result.credentials_created} credential(s), " <>
          "#{result.workspaces_attached} workspace attachment(s), " <>
          "#{result.keys_removed} key(s) moved out of #{result.workspaces_modified} worker_env blob(s), " <>
          "#{result.backups_written} backup row(s)"
      )
    end
  end

  defp migration_summary(result) do
    "#{result.accounts_created} account(s) created, " <>
      "#{result.credentials_created} credential(s) written, " <>
      "#{result.workspaces_attached} workspace(s) attached, " <>
      "#{result.keys_removed} key(s) moved out of #{result.workspaces_modified} worker_env blob(s), " <>
      "#{result.backups_written} encrypted backup row(s)."
  end

  defp migration_next_steps(%{workspaces_modified: 0} = result, _opts) do
    """

    No worker_env was modified, so there is nothing to undo. Rollback handle:
    #{result.migration_id}\
    """
  end

  defp migration_next_steps(result, opts) do
    rollback =
      hint(
        opts,
        "mix arbiter.accounts.rollback --migration-id #{result.migration_id}",
        ~s|bin/arbiter eval 'Arbiter.Release.accounts_rollback(migration_id: "#{result.migration_id}")'|
      )

    """

    The moved key is no longer in the workspace's worker_env. The account row
    supplies it to a spawn only with `:provider_accounts_enabled` set to true
    (ARBITER_PROVIDER_ACCOUNTS=1 in the server's environment, then a restart;
    it ships false) — so migrate every workspace that carries a provider
    credential, then flip the flag. To undo this migration instead:

        #{rollback}\
    """
  end

  @doc """
  Provider-accounts P2 undo, release-callable: the logic behind
  `mix arbiter.accounts.rollback` (a thin wrapper over this).

      bin/arbiter eval 'Arbiter.Release.accounts_rollback(list?: true)'
      bin/arbiter eval 'Arbiter.Release.accounts_rollback(migration_id: "20260918T120000Z-a1b2c3")'

  Re-merges a `provider_account_migration_backups` snapshot into its
  workspace through the same `MergeWorkerEnv` change the migration used —
  only the keys that migration removed, unless `all_keys?: true`. Leaves the
  `provider_accounts` / `provider_credentials` rows in place. See
  `Arbiter.Accounts.Migrate.rollback/1`.

  ## Options

  Exactly one selector — `migration_id: ID`, `backup_id: UUID`,
  `workspace: NAME` (its latest un-restored backup) or `all: true` (every
  un-restored backup) — or `list?: true` to print the backup rows and restore
  nothing. And:

    * `:all_keys?` — re-merge the whole snapshot, not just the removed keys.
    * `:dry_run?` — report what would be restored; write nothing.

  Starts only Ash, the Repo and the Vault. Prints names and counts only.
  Returns the rollback report (or, with `list?: true`, the backup rows).
  Raises `Arbiter.Release.Refused` on a refusal.
  """
  @spec accounts_rollback(keyword()) :: map() | [map()]
  def accounts_rollback(opts) do
    if Keyword.get(opts, :list?, false) do
      start_release_vault!()
      list_account_backups()
    else
      restore_account_backups(opts)
    end
  end

  defp list_account_backups do
    case Arbiter.Accounts.Migrate.list_backups() do
      [] ->
        IO.puts("No provider-account migration backups.")
        []

      backups ->
        IO.puts("""
        Provider account migration backups — names and counts only, no values.

        #{Enum.map_join(backups, "\n", &backup_line/1)}\
        """)

        backups
    end
  end

  defp backup_line(backup) do
    state = if backup.restored_at, do: "restored #{backup.restored_at}", else: "pending"

    "  #{backup.migration_id}  #{backup.workspace}  " <>
      "[#{Enum.join(backup.removed_keys, ", ")}]  #{state}  (#{backup.id})"
  end

  defp restore_account_backups(opts) do
    selector =
      Keyword.take(opts, [:migration_id, :backup_id, :workspace]) ++
        if(Keyword.get(opts, :all, false), do: [all: true], else: [])

    if selector == [] do
      raise Arbiter.Release.Refused,
            hint(
              opts,
              "give one of --migration-id, --backup-id, --workspace or --all " <>
                "(or --list to see what there is)",
              "give one of migration_id:, backup_id:, workspace: or all: true " <>
                "(or list?: true to see what there is)"
            )
    end

    start_release_vault!()

    rollback_opts =
      selector ++
        [
          all_keys?: Keyword.get(opts, :all_keys?, false),
          dry_run?: Keyword.get(opts, :dry_run?, false)
        ]

    case Arbiter.Accounts.Migrate.rollback(rollback_opts) do
      {:ok, result} ->
        report_rollback(result, opts)
        result

      {:error, reason} ->
        raise Arbiter.Release.Refused, reason
    end
  end

  defp report_rollback(result, opts) do
    IO.puts("""
    Provider account rollback#{if result.dry_run?, do: " (dry run)", else: ""}

    #{Enum.join(result.lines, "\n")}

    #{result.restored} workspace(s) restored, #{result.keys_restored} key(s) merged back, \
    #{result.skipped} skipped.\
    """)

    if result.dry_run? do
      IO.puts(
        "\nNothing was written (dry run). Re-run without " <>
          hint(opts, "--dry-run", "dry_run?: true") <> " to restore."
      )
    else
      # Counts and names only — §7.4.
      Logger.info(
        "Arbiter.Accounts.Migrate rollback: #{result.restored} workspace(s) restored, " <>
          "#{result.keys_restored} key(s) merged back, #{result.skipped} skipped"
      )
    end
  end

  # The accounts operations phrase their hints for whichever entrypoint the
  # operator actually used: the Mix wrappers pass `cli: :mix`, a
  # `bin/arbiter eval` gets the keyword-option spelling.
  defp hint(opts, mix_text, release_text) do
    if Keyword.get(opts, :cli) == :mix, do: mix_text, else: release_text
  end

  # `bin/arbiter eval 'accounts_migrate(plan: "~/accounts.json")'` gets no
  # shell expansion, so do the one expansion an operator will reach for.
  defp expand_home("~" <> _ = path), do: Path.expand(path)
  defp expand_home(path), do: path

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end
end
