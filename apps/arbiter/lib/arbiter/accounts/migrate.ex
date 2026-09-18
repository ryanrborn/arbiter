defmodule Arbiter.Accounts.Migrate do
  @moduledoc """
  Phase P2 of the provider-accounts migration (`docs/provider-account-design.md`
  §7.2–§7.5): applies an operator-edited census plan.

  `Arbiter.Accounts.Census` (P0) proposes; this applies. Given the plan file the
  census wrote and the operator edited, `apply_plan/2`:

    1. creates the `provider_accounts` / `provider_credentials` /
       `workspace_provider_accounts` rows the plan describes (§3.1–§3.3);
    2. writes a Vault-encrypted `provider_account_migration_backups` row per
       affected workspace, **before** that workspace is touched (§7.5);
    3. removes the moved keys from that workspace's `worker_env` by patching
       each to `nil` through the existing
       `Arbiter.Tasks.Workspace.Changes.MergeWorkerEnv` (§7.3).

  `rollback/1` reverses step 3 from the backup row.

  ## This release is additive (§7.5's "Release N")

  Nothing reads the new tables. `workspaces.encrypted_worker_env` is still the
  source of truth for every spawn path, `Arbiter.Accounts.enabled?/0` is
  `false`, and rolling this release back is "drop the new tables", with zero
  data loss. The read flip is P3.

  Two consequences worth being explicit about, because they look like bugs
  otherwise:

    * After applying a plan on a live install, a worker spawned from an
      affected workspace no longer receives that env var — the value now lives
      only in `provider_credentials`, which nothing reads yet. On an install
      where the credential also reaches workers by another route (the
      operator's `~/.claude/.credentials.json`, a `config` entry) that is
      invisible; where it does not, **run `mix arbiter.accounts.rollback` or
      wait for P3**. The task says so in its own output.
    * §7.6 requires `ARBITER_CLOAK_KEY` to have been rotated, and the provider
      credential itself re-issued, *before* this runs — otherwise it writes
      fresh ciphertext under a key considered exposed.

  ## The allowlist, and why validation happens before any write

  The keys that may move are exactly `Arbiter.Accounts.Census.credential_keys/0`
  (§7.3's explicit, versioned list). A plan asking to move anything else is
  rejected — the failure mode of guessing is moving an unrelated secret into a
  provider-credential table.

  Every check — plan shape, fingerprint agreement, allowlist membership,
  account/credential conflicts — runs against the whole plan *first*. Only then
  does anything get written. `AshSqlite` gives no usable outer transaction for a
  multi-resource run of this shape, so "validate everything, then write" is what
  makes a refusal leave the database exactly as it found it.

  ## No plaintext leaves the database (§7.4)

  Secret values appear in exactly two places at runtime: the decrypted
  `worker_env` map held in a process's own memory, and the ciphertext written
  to `provider_credentials.encrypted_secret` /
  `provider_account_migration_backups.encrypted_worker_env`. Nothing in the
  report, the returned result, the log lines or the plan file is derived from a
  value — only from fingerprints, key names and counts.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Accounts.Census
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderAccountMigrationBackup, as: Backup
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Tasks.Workspace

  @plan_kind "arbiter.accounts.plan"
  @supported_versions [1]

  @providers %{
    "claude" => :claude,
    "codex" => :codex,
    "gemini_cli" => :gemini_cli,
    "antigravity" => :antigravity
  }

  @kinds %{
    "oauth_token" => :oauth_token,
    "api_key" => :api_key,
    "cli_credentials_file" => :cli_credentials_file
  }

  @typedoc "What `apply_plan/2` reports back. Counts and names only — never a value."
  @type result :: %{
          migration_id: String.t(),
          dry_run?: boolean(),
          accounts_created: non_neg_integer(),
          credentials_created: non_neg_integer(),
          workspaces_attached: non_neg_integer(),
          workspaces_modified: non_neg_integer(),
          keys_removed: non_neg_integer(),
          backups_written: non_neg_integer(),
          lines: [String.t()]
        }

  @doc "The plan document kind `apply_plan/2` accepts."
  @spec plan_kind() :: String.t()
  def plan_kind, do: @plan_kind

  @doc """
  Reads and decodes a plan file written by `mix arbiter.accounts.census`.

  Errors describe the *shape* of the problem and never quote file content —
  the plan carries no secret, but a decoder message quoting arbitrary bytes of
  an operator-edited file is not a habit worth having (§7.4).
  """
  @spec read_plan(String.t()) :: {:ok, map()} | {:error, String.t()}
  def read_plan(path) when is_binary(path) do
    with {:ok, body} <- read_file(path),
         {:ok, json} <- decode_json(body, path) do
      {:ok, json}
    end
  end

  @doc """
  Applies `plan`.

  Returns `{:ok, t:result/0}` or `{:error, message}`. On `{:error, _}` nothing
  has been written: every check runs before the first write.

  ## Options

    * `:dry_run?` — validate and report, write nothing. The counts are what a
      real run *would* do.
  """
  @spec apply_plan(map(), keyword()) :: {:ok, result()} | {:error, String.t()}
  def apply_plan(plan, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run?, false)

    with {:ok, accounts} <- validate_plan(plan),
         :ok <- check_allowlist(accounts),
         :ok <- check_active_credential_collisions(accounts),
         {:ok, workspaces} <- load_workspaces(accounts),
         existing = existing_accounts(accounts),
         :ok <- check_existing_credentials(accounts, existing),
         :ok <- check_existing_joins(accounts, existing, workspaces),
         {:ok, accounts} <- resolve_secrets(accounts, workspaces, existing) do
      {:ok, write(accounts, workspaces, dry_run?)}
    end
  end

  @doc """
  Re-merges a backup row's snapshot into its workspace through `MergeWorkerEnv`.

  ## Options (exactly one selector is required)

    * `:migration_id` — every un-restored backup one `apply_plan/2` run wrote.
    * `:backup_id` — one specific backup row.
    * `:workspace` — a workspace name or id; its most recent un-restored backup.
    * `:all` — every un-restored backup, whichever run wrote it.

  ## Other options

    * `:all_keys?` — re-merge the *entire* snapshot rather than only the keys
      the migration removed. Off by default, and deliberately: a merge patch of
      just `removed_keys` restores what was taken without clobbering anything
      the operator has legitimately changed since.
    * `:dry_run?` — report what would be restored, write nothing.
  """
  @spec rollback(keyword()) :: {:ok, map()} | {:error, String.t()}
  def rollback(opts) do
    with {:ok, backups} <- select_backups(opts) do
      {:ok, restore(backups, opts)}
    end
  end

  @doc """
  Every backup row, newest first, as display rows — names, counts and
  timestamps only.
  """
  @spec list_backups() :: [map()]
  def list_backups do
    workspaces = Map.new(Ash.read!(Workspace), &{&1.id, &1.name})

    Backup
    |> Ash.read!()
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
    |> Enum.map(fn backup ->
      %{
        id: backup.id,
        migration_id: backup.migration_id,
        workspace: Map.get(workspaces, backup.workspace_id, backup.workspace_id),
        removed_keys: backup.removed_keys,
        created_at: backup.created_at,
        restored_at: backup.restored_at
      }
    end)
  end

  # ------------------------------------------------------------- plan reading

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode_json(body, path) do
    case Jason.decode(body) do
      {:ok, json} when is_map(json) -> {:ok, json}
      {:ok, _} -> {:error, "#{path}: not a JSON object"}
      {:error, _} -> {:error, "#{path}: not valid JSON"}
    end
  end

  # ---------------------------------------------------------- plan validation

  defp validate_plan(%{"kind" => @plan_kind, "version" => version} = plan)
       when version in @supported_versions do
    case Map.get(plan, "accounts") do
      accounts when is_list(accounts) -> parse_accounts(accounts)
      nil -> {:error, "plan has no \"accounts\" list"}
      _ -> {:error, "plan \"accounts\" must be a list"}
    end
  end

  defp validate_plan(%{"kind" => @plan_kind, "version" => version}),
    do:
      {:error,
       "unsupported plan version #{inspect(version)}; this build understands " <>
         "version #{Enum.join(@supported_versions, ", ")}"}

  defp validate_plan(%{"kind" => kind}),
    do: {:error, "not an #{@plan_kind} document (kind: #{inspect(kind)})"}

  defp validate_plan(_),
    do: {:error, "not an #{@plan_kind} document (no \"kind\" field)"}

  defp parse_accounts(accounts) do
    accounts
    |> Enum.reduce_while({:ok, []}, fn account, {:ok, acc} ->
      case parse_account(account) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> check_duplicate_slugs(Enum.reverse(parsed))
      {:error, _} = error -> error
    end
  end

  defp parse_account(%{"slug" => slug, "provider" => provider} = account)
       when is_binary(slug) and is_binary(provider) do
    with {:ok, provider} <- parse_provider(provider, slug),
         {:ok, credentials} <- parse_credentials(Map.get(account, "credentials", []), slug),
         {:ok, workspaces} <- parse_workspaces(Map.get(account, "workspaces", []), slug) do
      {:ok,
       %{
         slug: slug,
         label: Map.get(account, "label") || slug,
         provider: provider,
         plan: Map.get(account, "plan"),
         max_concurrent: Map.get(account, "max_concurrent"),
         quota_config: Map.get(account, "quota_config") || %{},
         credentials: credentials,
         workspaces: workspaces
       }}
    end
  end

  defp parse_account(account),
    do:
      {:error,
       "each plan account needs a string \"slug\" and \"provider\" (got #{keys(account)})"}

  defp parse_provider(provider, slug) do
    case Map.fetch(@providers, provider) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error,
         "account #{slug}: unknown provider #{inspect(provider)} " <>
           "(expected one of #{Enum.join(Map.keys(@providers), ", ")})"}
    end
  end

  defp parse_credentials([], slug),
    do: {:error, "account #{slug} has no credentials; delete the account or give it one"}

  defp parse_credentials(credentials, slug) when is_list(credentials) do
    credentials
    |> Enum.reduce_while({:ok, []}, fn credential, {:ok, acc} ->
      case parse_credential(credential, slug) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _} = error -> error
    end
  end

  defp parse_credentials(_, slug), do: {:error, "account #{slug}: \"credentials\" must be a list"}

  defp parse_credential(
         %{"fingerprint" => fingerprint, "kind" => kind, "env_var" => env_var} = credential,
         slug
       )
       when is_binary(fingerprint) and is_binary(kind) and is_binary(env_var) do
    with {:ok, kind} <- parse_kind(kind, slug),
         {:ok, source} <- parse_source(Map.get(credential, "source"), slug, env_var) do
      {:ok,
       %{
         fingerprint: String.downcase(fingerprint),
         kind: kind,
         env_var: env_var,
         active: Map.get(credential, "active", true) != false,
         scopes: Map.get(credential, "scopes"),
         source: source,
         secret: nil
       }}
    end
  end

  defp parse_credential(credential, slug),
    do:
      {:error,
       "account #{slug}: each credential needs \"fingerprint\", \"kind\" and \"env_var\" " <>
         "(got #{keys(credential)})"}

  defp parse_kind(kind, slug) do
    case Map.fetch(@kinds, kind) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error,
         "account #{slug}: unknown credential kind #{inspect(kind)} " <>
           "(expected one of #{Enum.join(Map.keys(@kinds), ", ")})"}
    end
  end

  # §7.2: a credential's material is *not* in the plan. The source says where to
  # re-read it from, and the fingerprint is what proves we read the right thing.
  defp parse_source(%{"type" => "workspace_worker_env"}, _slug, _env_var),
    do: {:ok, %{type: :workspace_worker_env}}

  defp parse_source(%{"type" => "operator_credentials_file", "path" => path}, _slug, _env_var)
       when is_binary(path),
       do: {:ok, %{type: :operator_credentials_file, path: path}}

  defp parse_source(nil, _slug, env_var),
    do: {:ok, %{type: :workspace_worker_env, assumed_for: env_var}}

  defp parse_source(source, slug, env_var),
    do:
      {:error,
       "account #{slug}, credential #{env_var}: unrecognised \"source\" #{keys(source)}; " <>
         "expected workspace_worker_env or operator_credentials_file"}

  defp parse_workspaces(workspaces, slug) when is_list(workspaces) do
    workspaces
    |> Enum.reduce_while({:ok, []}, fn
      %{"id" => id, "env_key" => env_key} = workspace, {:ok, acc}
      when is_binary(id) and is_binary(env_key) ->
        {:cont,
         {:ok,
          [
            %{
              id: id,
              name: Map.get(workspace, "name") || id,
              env_key: env_key,
              share: Map.get(workspace, "share")
            }
            | acc
          ]}}

      workspace, {:ok, _} ->
        {:halt,
         {:error,
          "account #{slug}: each workspace entry needs a string \"id\" and \"env_key\" " <>
            "(got #{keys(workspace)})"}}
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _} = error -> error
    end
  end

  defp parse_workspaces(_, slug), do: {:error, "account #{slug}: \"workspaces\" must be a list"}

  defp check_duplicate_slugs(accounts) do
    duplicates =
      accounts
      |> Enum.frequencies_by(&{&1.provider, &1.slug})
      |> Enum.filter(fn {_, count} -> count > 1 end)
      |> Enum.map(fn {{provider, slug}, _} -> "#{provider}/#{slug}" end)

    case duplicates do
      [] ->
        # §3.4: one account per (workspace, provider). The census reports this
        # as a CONFLICT note; here it is a refusal, since the unique index
        # would fail mid-run and leave a half-applied plan behind.
        check_workspace_provider_conflicts(accounts)

      slugs ->
        {:error,
         "plan has more than one account with the same (provider, slug): #{Enum.join(slugs, ", ")}"}
    end
  end

  defp check_workspace_provider_conflicts(accounts) do
    conflicts =
      for account <- accounts, workspace <- account.workspaces do
        {{workspace.name, account.provider}, account.slug}
      end
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.filter(fn {_, slugs} -> length(Enum.uniq(slugs)) > 1 end)

    case conflicts do
      [] ->
        {:ok, accounts}

      list ->
        detail =
          Enum.map_join(list, "; ", fn {{name, provider}, slugs} ->
            "#{name}/#{provider} → #{Enum.join(Enum.uniq(slugs), ", ")}"
          end)

        {:error,
         "§3.4 allows one account per (workspace, provider), but the plan points some at " <>
           "several: #{detail}. Merge those candidates before migrating."}
    end
  end

  # ------------------------------------------------------ workspaces + secrets

  defp load_workspaces(accounts) do
    wanted =
      accounts
      |> Enum.flat_map(fn account -> Enum.map(account.workspaces, & &1.id) end)
      |> Enum.uniq()

    found = Workspace |> Ash.read!() |> Map.new(&{&1.id, &1})

    case Enum.reject(wanted, &Map.has_key?(found, &1)) do
      [] ->
        {:ok, Map.take(found, wanted)}

      missing ->
        {:error, "plan references workspace(s) that no longer exist: #{Enum.join(missing, ", ")}"}
    end
  end

  # Re-reads each credential's material from the source the plan names and
  # refuses unless it hashes to the fingerprint the census recorded. This is
  # the check that lets the plan be a plain file: it carries instructions, not
  # material, and a stale or hand-edited instruction cannot silently move the
  # wrong secret.
  defp resolve_secrets(accounts, workspaces, existing) do
    accounts
    |> Enum.reduce_while({:ok, []}, fn account, {:ok, acc} ->
      case resolve_account_secrets(account, workspaces, already_written(account, existing)) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, _} = error -> error
    end
  end

  defp resolve_account_secrets(account, workspaces, already_written) do
    account.credentials
    |> Enum.reduce_while({:ok, []}, fn credential, {:ok, acc} ->
      # A credential this run would not write anyway — because an identical
      # row is already there — needs no material, and must not be resolved:
      # after a successful run the key it came from is gone from `worker_env`,
      # and re-running the same plan has to stay a clean no-op.
      if MapSet.member?(
           already_written,
           {credential.kind, credential.env_var, credential.fingerprint}
         ) do
        {:cont, {:ok, [credential | acc]}}
      else
        case resolve_secret(credential, account, workspaces) do
          {:ok, secret} -> {:cont, {:ok, [%{credential | secret: secret} | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, credentials} -> {:ok, %{account | credentials: Enum.reverse(credentials)}}
      {:error, _} = error -> error
    end
  end

  defp already_written(account, existing) do
    case Map.get(existing, {account.provider, account.slug}) do
      nil -> MapSet.new()
      row -> existing_fingerprints(row.id)
    end
  end

  defp resolve_secret(%{source: %{type: :workspace_worker_env}} = credential, account, workspaces) do
    candidates =
      account.workspaces
      |> Enum.filter(&(&1.env_key == credential.env_var))
      |> Enum.map(&Map.fetch!(workspaces, &1.id))

    values =
      candidates
      |> Enum.map(&Workspace.worker_env_map/1)
      |> Enum.map(&Map.get(&1, credential.env_var))
      |> Enum.reject(&is_nil/1)

    case Enum.find(values, &(Census.fingerprint(&1) == credential.fingerprint)) do
      nil when values == [] ->
        {:error,
         "account #{account.slug}: no workspace in the plan still holds #{credential.env_var}. " <>
           "Re-run `mix arbiter.accounts.census` and re-edit the plan."}

      nil ->
        {:error,
         "account #{account.slug}: #{credential.env_var} no longer matches the plan's " <>
           "fingerprint #{Census.short_fingerprint(credential.fingerprint)} — the credential " <>
           "changed since the census. Re-run `mix arbiter.accounts.census`."}

      secret ->
        {:ok, secret}
    end
  end

  defp resolve_secret(
         %{source: %{type: :operator_credentials_file, path: path}} = credential,
         account,
         _workspaces
       ) do
    with {:ok, token} <- read_operator_token(path) do
      if Census.fingerprint(token) == credential.fingerprint do
        {:ok, token}
      else
        {:error,
         "account #{account.slug}: the token at #{path} no longer matches the plan's " <>
           "fingerprint #{Census.short_fingerprint(credential.fingerprint)}. Re-run the census, " <>
           "or delete that suggested credential row from the plan."}
      end
    end
  end

  # Mirrors `Census.operator_credential/1`, but keeps the token instead of
  # discarding it: this is the one caller that needs the material itself, to
  # write it into `provider_credentials`. Errors never quote file content.
  defp read_operator_token(path) do
    expanded = Path.expand(path)

    with {:ok, body} <- read_file(expanded),
         {:ok, json} <- decode_json(body, expanded) do
      case json do
        %{"claudeAiOauth" => %{"accessToken" => token}} when is_binary(token) and token != "" ->
          {:ok, token}

        _ ->
          {:error, "#{expanded}: no claudeAiOauth.accessToken"}
      end
    end
  end

  # ------------------------------------------------------------------- checks

  # §7.3's allowlist, enforced on the *plan* rather than inferred from the env:
  # an operator-edited file is exactly the place a non-credential key could be
  # pointed at by hand.
  defp check_allowlist(accounts) do
    allowlist = Census.credential_keys()

    offenders =
      for account <- accounts,
          workspace <- account.workspaces,
          not Map.has_key?(allowlist, workspace.env_key),
          do: "#{workspace.name}:#{workspace.env_key}"

    mismatched =
      for account <- accounts,
          workspace <- account.workspaces,
          spec = Map.get(allowlist, workspace.env_key),
          is_map(spec),
          Map.fetch!(@providers, spec.provider) != account.provider,
          do:
            "#{workspace.env_key} is a #{spec.provider} key but #{account.slug} is #{account.provider}"

    cond do
      offenders != [] ->
        {:error,
         "refusing to move #{Enum.join(Enum.uniq(offenders), ", ")}: not on the §7.3 " <>
           "allowlist (#{Enum.join(Enum.sort(Map.keys(allowlist)), ", ")}). Non-allowlisted " <>
           "keys stay on the workspace, even credential-looking ones."}

      mismatched != [] ->
        {:error, "provider mismatch in the plan: #{Enum.join(Enum.uniq(mismatched), "; ")}"}

      true ->
        :ok
    end
  end

  # §3.2's partial unique index allows one *active* credential per
  # (account, kind). The census can legitimately emit two — one secret
  # configured under two env var names — so catch it here with an actionable
  # message rather than as a constraint error half way through the run.
  defp check_active_credential_collisions(accounts) do
    collisions =
      for account <- accounts,
          {kind, credentials} <-
            account.credentials |> Enum.filter(& &1.active) |> Enum.group_by(& &1.kind),
          length(credentials) > 1,
          do:
            "#{account.slug} has #{length(credentials)} active #{kind} credentials " <>
              "(#{Enum.map_join(credentials, ", ", & &1.env_var)})"

    case collisions do
      [] ->
        :ok

      list ->
        {:error,
         "§3.2 allows one active credential per (account, kind): #{Enum.join(list, "; ")}. " <>
           "Split them onto separate accounts, or set \"active\": false on all but one."}
    end
  end

  # Re-running a plan must be a no-op, not a constraint error. Anything that
  # already exists and *disagrees* with the plan is a refusal, because silently
  # re-pointing a workspace at a different account is exactly the kind of thing
  # an operator should confirm.
  defp existing_accounts(accounts) do
    slugs = Enum.map(accounts, & &1.slug)

    ProviderAccount
    |> Ash.Query.filter(slug in ^slugs)
    |> Ash.read!()
    |> Map.new(&{{&1.provider, &1.slug}, &1})
  end

  defp check_existing_credentials(accounts, existing_accounts) do
    accounts
    |> Enum.flat_map(fn account ->
      case Map.get(existing_accounts, {account.provider, account.slug}) do
        nil -> []
        row -> [{account, active_credentials(row.id)}]
      end
    end)
    |> Enum.flat_map(fn {account, existing} ->
      for credential <- account.credentials,
          credential.active,
          clash = Map.get(existing, credential.kind),
          is_map(clash),
          clash.fingerprint != credential.fingerprint,
          do:
            "#{account.slug} already has an active #{credential.kind} credential with a " <>
              "different fingerprint (#{Census.short_fingerprint(clash.fingerprint)} vs the " <>
              "plan's #{Census.short_fingerprint(credential.fingerprint)})"
    end)
    |> case do
      [] ->
        :ok

      list ->
        {:error,
         "#{Enum.join(list, "; ")}. That is a rotation, not a migration — retire the existing " <>
           "credential first."}
    end
  end

  defp active_credentials(account_id) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account_id and active == true)
    |> Ash.read!()
    |> Map.new(&{&1.kind, &1})
  end

  defp check_existing_joins(accounts, existing_accounts, workspaces) do
    existing =
      WorkspaceProviderAccount
      |> Ash.read!()
      |> Map.new(&{{&1.workspace_id, &1.provider}, &1})

    accounts
    |> Enum.flat_map(fn account ->
      account_id =
        case Map.get(existing_accounts, {account.provider, account.slug}) do
          nil -> nil
          row -> row.id
        end

      for workspace <- account.workspaces,
          join = Map.get(existing, {workspace.id, account.provider}),
          is_map(join),
          join.provider_account_id != account_id,
          do:
            "#{workspace_name(workspaces, workspace)} is already attached to a different " <>
              "#{account.provider} account than the plan's #{account.slug}"
    end)
    |> case do
      [] -> :ok
      list -> {:error, "#{Enum.join(Enum.uniq(list), "; ")}. Detach it first, or fix the plan."}
    end
  end

  defp workspace_name(workspaces, %{id: id, name: name}),
    do: (workspaces[id] && workspaces[id].name) || name

  # -------------------------------------------------------------------- write

  defp write(accounts, workspaces, dry_run?) do
    migration_id = migration_id()

    {accounts_created, credentials_created, workspaces_attached, lines} =
      Enum.reduce(accounts, {0, 0, 0, []}, fn account, {a, c, w, lines} ->
        {created?, account_id} = upsert_account(account, dry_run?)
        credentials = create_credentials(account, account_id, dry_run?)
        attached = attach_workspaces(account, account_id, dry_run?)

        {a + if(created?, do: 1, else: 0), c + credentials, w + attached,
         lines ++
           [
             "  #{account.slug} [#{account.provider}]: " <>
               "#{if created?, do: "created", else: "already present"}, " <>
               "#{credentials} credential(s) written, #{attached} workspace(s) attached"
           ]}
      end)

    {modified, removed, backups, removal_lines} =
      remove_keys(accounts, workspaces, migration_id, dry_run?)

    %{
      migration_id: migration_id,
      dry_run?: dry_run?,
      accounts_created: accounts_created,
      credentials_created: credentials_created,
      workspaces_attached: workspaces_attached,
      workspaces_modified: modified,
      keys_removed: removed,
      backups_written: backups,
      lines: lines ++ removal_lines
    }
  end

  # Human-readable, sortable, and unique enough that two runs in the same
  # second cannot collide.
  defp migration_id do
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(:basic)
    "#{stamp}-#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}"
  end

  defp upsert_account(account, dry_run?) do
    case find_account(account) do
      nil when dry_run? ->
        {true, nil}

      nil ->
        created =
          Ash.create!(ProviderAccount, %{
            provider: account.provider,
            slug: account.slug,
            label: account.label,
            plan: account.plan,
            # §4.4: no account ceiling unless the operator asked for one.
            max_concurrent: account.max_concurrent,
            quota_config: account.quota_config,
            identity_source: :operator
          })

        {true, created.id}

      existing ->
        {false, existing.id}
    end
  end

  defp find_account(%{provider: provider, slug: slug}) do
    ProviderAccount
    |> Ash.Query.filter(provider == ^provider and slug == ^slug)
    |> Ash.read_one!()
  end

  defp create_credentials(account, account_id, dry_run?) do
    existing = if account_id, do: existing_fingerprints(account_id), else: MapSet.new()

    Enum.count(account.credentials, fn credential ->
      key = {credential.kind, credential.env_var, credential.fingerprint}

      cond do
        MapSet.member?(existing, key) ->
          false

        dry_run? ->
          true

        true ->
          Ash.create!(ProviderCredential, %{
            provider_account_id: account_id,
            kind: credential.kind,
            env_var: credential.env_var,
            fingerprint: credential.fingerprint,
            scopes: credential.scopes,
            active: credential.active,
            secret: credential.secret
          })

          true
      end
    end)
  end

  defp existing_fingerprints(account_id) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.read!()
    |> MapSet.new(&{&1.kind, &1.env_var, &1.fingerprint})
  end

  defp attach_workspaces(account, account_id, dry_run?) do
    existing =
      WorkspaceProviderAccount
      |> Ash.read!()
      |> MapSet.new(&{&1.workspace_id, &1.provider})

    account.workspaces
    |> Enum.uniq_by(& &1.id)
    |> Enum.count(fn workspace ->
      cond do
        MapSet.member?(existing, {workspace.id, account.provider}) ->
          false

        dry_run? ->
          true

        true ->
          Ash.create!(WorkspaceProviderAccount, %{
            workspace_id: workspace.id,
            provider: account.provider,
            provider_account_id: account_id,
            share: workspace.share
          })

          true
      end
    end)
  end

  # §7.3 + §7.5. Per workspace: snapshot first, then a `nil` merge patch for
  # exactly the moved keys. A key the plan names but the workspace no longer
  # holds is simply not in `removed`, which is what makes a re-run a no-op
  # instead of a second empty backup row.
  defp remove_keys(accounts, workspaces, migration_id, dry_run?) do
    accounts
    |> Enum.flat_map(fn account -> Enum.map(account.workspaces, &{&1.id, &1.env_key}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(fn {id, _} -> workspaces[id].name end)
    |> Enum.reduce({0, 0, 0, []}, fn {id, keys}, {modified, removed, backups, lines} ->
      workspace = Map.fetch!(workspaces, id)
      env = Workspace.worker_env_map(workspace)
      present = keys |> Enum.uniq() |> Enum.sort() |> Enum.filter(&Map.has_key?(env, &1))

      case present do
        [] ->
          {modified, removed, backups,
           lines ++ ["  #{workspace.name}: no allowlisted key left to move"]}

        moving ->
          unless dry_run? do
            write_backup!(workspace, env, moving, migration_id)
            strip_keys!(workspace, moving)
          end

          {modified + 1, removed + length(moving), backups + 1,
           lines ++
             [
               "  #{workspace.name}: moved #{Enum.join(moving, ", ")} " <>
                 "(#{map_size(env) - length(moving)} key(s) left in place), backup written"
             ]}
      end
    end)
  end

  # §7.5: the snapshot is written *before* the workspace is modified and is
  # encrypted with the same Vault. Never a plaintext file.
  defp write_backup!(workspace, env, moving, migration_id) do
    Ash.create!(Backup, %{
      workspace_id: workspace.id,
      migration_id: migration_id,
      removed_keys: moving,
      worker_env: env,
      worker_env_meta: workspace.worker_env_meta || %{}
    })
  end

  # §7.3: the removal is a normal `Workspace` update through the existing
  # `MergeWorkerEnv` change, with each moved key set to nil. No new crypto
  # code, and `worker_env_meta` stays in lockstep for free.
  defp strip_keys!(workspace, moving) do
    Ash.update!(workspace, %{worker_env: Map.new(moving, &{&1, nil})})
  end

  # ----------------------------------------------------------------- rollback

  defp select_backups(opts) do
    cond do
      id = Keyword.get(opts, :backup_id) ->
        case Backup |> Ash.Query.filter(id == ^id) |> Ash.read!() do
          [] -> {:error, "no backup row #{id}"}
          [backup] -> {:ok, [backup]}
        end

      id = Keyword.get(opts, :migration_id) ->
        case Backup |> Ash.Query.filter(migration_id == ^id) |> Ash.read!() do
          [] -> {:error, "no backup rows for migration #{id}"}
          backups -> {:ok, Enum.sort_by(backups, & &1.created_at, DateTime)}
        end

      reference = Keyword.get(opts, :workspace) ->
        select_workspace_backup(reference)

      Keyword.get(opts, :all, false) ->
        case Backup |> Ash.Query.filter(is_nil(restored_at)) |> Ash.read!() do
          [] -> {:error, "no un-restored provider-account migration backups"}
          backups -> {:ok, Enum.sort_by(backups, & &1.created_at, DateTime)}
        end

      true ->
        {:error, "give one of --migration-id, --backup-id, --workspace or --all"}
    end
  end

  defp select_workspace_backup(reference) do
    case Enum.find(Ash.read!(Workspace), &(&1.name == reference or &1.id == reference)) do
      nil ->
        {:error, "no workspace named #{reference}"}

      workspace ->
        Backup
        |> Ash.Query.filter(workspace_id == ^workspace.id and is_nil(restored_at))
        |> Ash.read!()
        |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
        |> case do
          [] -> {:error, "no un-restored backup for workspace #{reference}"}
          [latest | _] -> {:ok, [latest]}
        end
    end
  end

  defp restore(backups, opts) do
    dry_run? = Keyword.get(opts, :dry_run?, false)
    all_keys? = Keyword.get(opts, :all_keys?, false)
    workspaces = Map.new(Ash.read!(Workspace), &{&1.id, &1})

    Enum.reduce(
      backups,
      %{restored: 0, skipped: 0, keys_restored: 0, lines: [], dry_run?: dry_run?},
      fn backup, acc ->
        workspace = Map.get(workspaces, backup.workspace_id)
        name = (workspace && workspace.name) || backup.workspace_id

        cond do
          backup.restored_at ->
            %{
              acc
              | skipped: acc.skipped + 1,
                lines: acc.lines ++ ["  #{name}: already restored at #{backup.restored_at}"]
            }

          is_nil(workspace) ->
            %{
              acc
              | skipped: acc.skipped + 1,
                lines: acc.lines ++ ["  #{name}: workspace no longer exists"]
            }

          true ->
            patch = restore_patch(backup, all_keys?)

            unless dry_run? do
              Ash.update!(workspace, %{worker_env: patch})
              Ash.update!(backup, %{}, action: :mark_restored)
            end

            %{
              acc
              | restored: acc.restored + 1,
                keys_restored: acc.keys_restored + map_size(patch),
                lines:
                  acc.lines ++
                    ["  #{name}: restored #{Enum.join(Enum.sort(Map.keys(patch)), ", ")}"]
            }
        end
      end
    )
  end

  # A merge patch of just the keys the migration took (or the whole snapshot
  # under `:all_keys?`), carrying each key's original secret flag back with it.
  defp restore_patch(backup, all_keys?) do
    env = Backup.worker_env_map(backup)
    meta = backup.worker_env_meta || %{}
    keys = if all_keys?, do: Map.keys(env), else: backup.removed_keys

    for key <- keys, value = Map.get(env, key), into: %{} do
      {key, %{"value" => value, "secret" => Map.get(meta, key, %{})["secret"] == true}}
    end
  end

  defp keys(map) when is_map(map), do: "keys: #{Enum.join(Enum.sort(Map.keys(map)), ", ")}"
  defp keys(other), do: inspect(other)
end
