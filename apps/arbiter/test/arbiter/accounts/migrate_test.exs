defmodule Arbiter.Accounts.MigrateTest do
  @moduledoc """
  Phase P2 (`docs/provider-account-design.md` §7.2–§7.5): applying an
  operator-edited census plan.

  These drive `Arbiter.Accounts.Migrate` directly (the mix task's own coverage
  lives in `Mix.Tasks.Arbiter.Accounts.MigrateTest`). The invariants under test
  are the ones §7.3/§7.5 name: only allowlisted keys move, a Vault-encrypted
  backup row is written *before* the workspace is touched, and the whole thing
  is idempotent enough to re-run after a partial failure.

  P2 folded §7.5's Release N+2 (the destructive `worker_env` removal, its
  gating backup row, and `mix arbiter.accounts.rollback`) into this same
  release rather than shipping it as a separate phase — see the design doc's
  "What P2 actually shipped" note. So this file's "removes only the
  allowlisted keys from worker_env" and "restores the removed keys through
  MergeWorkerEnv" tests already stand as P4's (bd-cblemv) acceptance 1, 2 and
  4 evidence: no allowlisted key survives in `worker_env` post-migration, the
  backup row is written unconditionally before any strip (so removal without
  a backup cannot happen), and rollback restores a workspace's credential
  after the destructive step. P4's own work is in `ConfigDir` — per the
  operator's ruling on PR #1947 (bd-cblemv round 2), the flag-off legacy
  chain (server env, then install-wide-unambiguous workspace token) is kept
  rather than deleted until `:provider_accounts_enabled` flips for good; see
  `config_dir_test.exs` and `config_dir_workspace_test.exs`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.Census
  alias Arbiter.Accounts.Migrate
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderAccountMigrationBackup, as: Backup
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Tasks.Workspace

  @token "sk-ant-oat01-qZ7fLx2NvUwJh4Tk9RmDbYcE6sApGnX1"
  @openai "sk-proj-9mXvQ2rTzKpLbN4wYhJdCgA6eSuF8oRi"

  defp seed!(name, env) do
    worker_env = Map.new(env, fn {k, v} -> {k, %{"value" => v, "secret" => true}} end)
    Ash.create!(Workspace, %{name: name, worker_env: worker_env})
  end

  defp plan_for_current_install do
    Census.run() |> Census.plan()
  end

  defp reload!(workspace), do: Ash.get!(Workspace, workspace.id)

  describe "apply_plan/2 — accounts, credentials and join rows (acceptance 1)" do
    test "creates the rows the plan describes" do
      ws = seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token, "LOG_LEVEL" => "debug"})

      {:ok, result} = Migrate.apply_plan(plan_for_current_install())

      assert [account] = Ash.read!(ProviderAccount)
      assert account.provider == :claude
      assert account.slug == "claude-1"
      # §4.4: the migration default is no account ceiling.
      assert account.max_concurrent == nil

      assert [credential] = Ash.read!(ProviderCredential)
      assert credential.provider_account_id == account.id
      assert credential.env_var == "CLAUDE_CODE_OAUTH_TOKEN"
      assert credential.kind == :oauth_token
      assert credential.fingerprint == Census.fingerprint(@token)
      assert credential.active
      assert ProviderCredential.secret(credential) == @token

      assert [join] = Ash.read!(WorkspaceProviderAccount)
      assert join.workspace_id == ws.id
      assert join.provider_account_id == account.id
      assert join.provider == :claude

      assert result.accounts_created == 1
      assert result.credentials_created == 1
      assert result.workspaces_attached == 1
    end

    test "removes only the allowlisted keys from worker_env (acceptance 1, 6)" do
      ws =
        seed!("default", %{
          "CLAUDE_CODE_OAUTH_TOKEN" => @token,
          "LOG_LEVEL" => "debug",
          "GITHUB_TOKEN" => "ghp_not_a_provider_credential",
          "MY_SECRET" => "hunter2"
        })

      {:ok, _} = Migrate.apply_plan(plan_for_current_install())

      env = ws |> reload!() |> Workspace.worker_env_map()

      refute Map.has_key?(env, "CLAUDE_CODE_OAUTH_TOKEN")

      assert env == %{
               "LOG_LEVEL" => "debug",
               "GITHUB_TOKEN" => "ghp_not_a_provider_credential",
               "MY_SECRET" => "hunter2"
             }

      # worker_env_meta is kept in lockstep by MergeWorkerEnv (§7.3).
      names = ws |> reload!() |> Workspace.worker_env_keys() |> Enum.map(& &1.name)
      assert Enum.sort(names) == ["GITHUB_TOKEN", "LOG_LEVEL", "MY_SECRET"]
    end

    test "one account per distinct fingerprint, across providers and workspaces" do
      a = seed!("alpha", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      b = seed!("beta", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token, "OPENAI_API_KEY" => @openai})

      {:ok, result} = Migrate.apply_plan(plan_for_current_install())

      accounts = ProviderAccount |> Ash.read!() |> Enum.sort_by(& &1.slug)
      assert Enum.map(accounts, & &1.slug) == ["claude-1", "codex-1"]
      assert result.accounts_created == 2

      joins = WorkspaceProviderAccount |> Ash.read!()
      assert length(joins) == 3

      claude = Enum.find(accounts, &(&1.provider == :claude))

      assert joins
             |> Enum.filter(&(&1.provider_account_id == claude.id))
             |> Enum.map(& &1.workspace_id)
             |> Enum.sort() == Enum.sort([a.id, b.id])
    end

    test "is idempotent — re-applying the same plan creates nothing new" do
      seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      plan = plan_for_current_install()

      {:ok, _} = Migrate.apply_plan(plan)
      {:ok, second} = Migrate.apply_plan(plan)

      assert second.accounts_created == 0
      assert second.credentials_created == 0
      assert second.workspaces_attached == 0
      assert length(Ash.read!(ProviderAccount)) == 1
      assert length(Ash.read!(ProviderCredential)) == 1
      assert length(Ash.read!(WorkspaceProviderAccount)) == 1
    end
  end

  describe "apply_plan/2 — the backup row (acceptance 2)" do
    test "writes an encrypted backup of the pre-change worker_env" do
      ws = seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token, "LOG_LEVEL" => "debug"})

      {:ok, result} = Migrate.apply_plan(plan_for_current_install())

      assert [backup] = Ash.read!(Backup)
      assert backup.workspace_id == ws.id
      assert backup.migration_id == result.migration_id
      assert backup.removed_keys == ["CLAUDE_CODE_OAUTH_TOKEN"]
      assert backup.restored_at == nil

      assert Backup.worker_env_map(backup) == %{
               "CLAUDE_CODE_OAUTH_TOKEN" => @token,
               "LOG_LEVEL" => "debug"
             }

      assert backup.worker_env_meta == %{
               "CLAUDE_CODE_OAUTH_TOKEN" => %{"secret" => true},
               "LOG_LEVEL" => %{"secret" => true}
             }
    end

    test "no plaintext secret survives in any TEXT column (§7.4's sweep)" do
      seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})

      {:ok, _} = Migrate.apply_plan(plan_for_current_install())

      needle = String.slice(@token, 0, 12)

      for table <- ~w(provider_accounts provider_credentials workspace_provider_accounts
                      provider_account_migration_backups workspaces) do
        %{rows: rows} = Arbiter.Repo.query!("SELECT * FROM #{table}")

        dump =
          rows
          |> List.flatten()
          |> Enum.map_join(" ", fn
            value when is_binary(value) -> value
            value -> inspect(value)
          end)

        refute String.contains?(dump, needle), "#{table} contains the plaintext secret"
      end
    end
  end

  describe "apply_plan/2 — refusals" do
    test "refuses a plan whose credential fingerprint no longer matches the workspace" do
      seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      plan = plan_for_current_install()

      tampered =
        update_in(plan, ["accounts", Access.at(0), "credentials", Access.at(0)], fn credential ->
          Map.put(credential, "fingerprint", String.duplicate("0", 64))
        end)

      assert {:error, message} = Migrate.apply_plan(tampered)
      assert message =~ "fingerprint"
      assert Ash.read!(ProviderAccount) == []
    end

    test "refuses to move a key that is not on the §7.3 allowlist" do
      seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token, "GITHUB_TOKEN" => "ghp_abc"})
      plan = plan_for_current_install()

      tampered =
        update_in(plan, ["accounts", Access.at(0), "workspaces", Access.at(0)], fn workspace ->
          Map.put(workspace, "env_key", "GITHUB_TOKEN")
        end)

      assert {:error, message} = Migrate.apply_plan(tampered)
      assert message =~ "GITHUB_TOKEN"
      assert message =~ "allowlist"
    end

    test "refuses a document that is not an accounts plan" do
      assert {:error, message} = Migrate.apply_plan(%{"kind" => "something.else", "version" => 1})
      assert message =~ "arbiter.accounts.plan"
    end

    test "refuses a plan version it does not understand" do
      seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      plan = plan_for_current_install() |> Map.put("version", 99)

      assert {:error, message} = Migrate.apply_plan(plan)
      assert message =~ "version"
    end
  end

  describe "apply_plan/2 — dry run" do
    test "writes nothing and reports what it would do" do
      ws = seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})

      {:ok, result} = Migrate.apply_plan(plan_for_current_install(), dry_run?: true)

      assert result.dry_run?
      assert result.accounts_created == 1
      assert Ash.read!(ProviderAccount) == []
      assert Ash.read!(Backup) == []
      assert Map.has_key?(Workspace.worker_env_map(reload!(ws)), "CLAUDE_CODE_OAUTH_TOKEN")
    end
  end

  describe "rollback/2 (acceptance 3)" do
    test "restores the removed keys through MergeWorkerEnv" do
      ws = seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token, "LOG_LEVEL" => "debug"})

      {:ok, %{migration_id: migration_id}} = Migrate.apply_plan(plan_for_current_install())
      refute Map.has_key?(Workspace.worker_env_map(reload!(ws)), "CLAUDE_CODE_OAUTH_TOKEN")

      {:ok, result} = Migrate.rollback(migration_id: migration_id)

      assert result.restored == 1

      assert Workspace.worker_env_map(reload!(ws)) == %{
               "CLAUDE_CODE_OAUTH_TOKEN" => @token,
               "LOG_LEVEL" => "debug"
             }

      assert [backup] = Ash.read!(Backup)
      assert backup.restored_at

      # Re-running is a no-op: a restored backup is not applied twice.
      {:ok, again} = Migrate.rollback(migration_id: migration_id)
      assert again.restored == 0
    end

    test "leaves keys the operator added after the migration alone" do
      ws = seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      {:ok, %{migration_id: migration_id}} = Migrate.apply_plan(plan_for_current_install())

      ws
      |> reload!()
      |> Ash.update!(%{worker_env: %{"ADDED_LATER" => %{"value" => "1", "secret" => false}}})

      {:ok, _} = Migrate.rollback(migration_id: migration_id)

      assert Workspace.worker_env_map(reload!(ws)) == %{
               "CLAUDE_CODE_OAUTH_TOKEN" => @token,
               "ADDED_LATER" => "1"
             }
    end

    test "errors when there is no backup for the given migration id" do
      assert {:error, message} = Migrate.rollback(migration_id: "nope")
      assert message =~ "nope"
    end
  end

  describe "the flag still ships off (acceptance 4)" do
    test ":provider_accounts_enabled ships false and defaults false when unset" do
      # The shipped default is what an install gets before an operator opts in;
      # `config/test.exs` overrides it per matrix leg (P3 / bd-aiodva), so the
      # runtime value is not the thing to assert here.
      config = File.read!(Path.join(File.cwd!(), "../../config/config.exs"))
      assert config =~ "config :arbiter, :provider_accounts_enabled, false"

      prev = Application.get_env(:arbiter, :provider_accounts_enabled)
      Application.delete_env(:arbiter, :provider_accounts_enabled)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:arbiter, :provider_accounts_enabled)
          value -> Application.put_env(:arbiter, :provider_accounts_enabled, value)
        end
      end)

      assert Arbiter.Accounts.enabled?() == false
    end

    test "the read flip (P3) is confined to the surfaces §5 names" do
      # Claude's config dir and WorkerEnv are §5 rows 15–17 and do read the
      # tables now. Gemini's config dir is not in that table and must not have
      # grown a read of its own.
      source = File.read!(Path.join(File.cwd!(), "lib/arbiter/agents/gemini/config_dir.ex"))

      refute source =~ "Arbiter.Accounts",
             "gemini/config_dir.ex reads the provider-account tables; §5 does not list it"
    end
  end
end
