defmodule Arbiter.ReleaseAccountsTest do
  @moduledoc """
  bd-1zceei: the provider-accounts census / migrate / rollback operations are
  callable as `Arbiter.Release.accounts_*` functions — no Mix, no full
  `Arbiter.Application` tree — so a release install can run them through
  `bin/arbiter eval` and turn `:provider_accounts_enabled` on.

  Every test here greps the operator-visible output (stdout, stderr, Logger)
  *and* the returned term for the seeded fixture credential: acceptance 5's
  "no secret values in any output", on the release-eval path.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Arbiter.Accounts.Census
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderAccountMigrationBackup, as: Backup
  alias Arbiter.Release
  alias Arbiter.Tasks.Workspace

  @token "sk-ant-oat01-Rl7uWq3ZpXe9KcTn2VbYsHdM4gJaF6oL"
  @github "ghp_Yb8cN2vQkL5tRz0WmXpJ7hFsDgA3eUoI"

  @release_source File.read!("lib/arbiter/release.ex")
  @start_release_vault_body Regex.run(
                              ~r/def start_release_vault! do(.*?)\n  end/s,
                              @release_source
                            )
                            |> List.wrap()
                            |> Enum.at(1, "")

  setup do
    # config/test.exs pins Logger at :warning, which would make the Logger leg
    # of the no-leak assertions vacuous. Raise it to what prod runs at.
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    dir = Path.join(System.tmp_dir!(), "release-accounts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, plan_path: Path.join(dir, "accounts.json"), dir: dir}
  end

  defp seed!(name, env) do
    worker_env = Map.new(env, fn {k, v} -> {k, %{"value" => v, "secret" => true}} end)
    Ash.create!(Workspace, %{name: name, worker_env: worker_env})
  end

  defp reload!(workspace), do: Ash.get!(Workspace, workspace.id)

  # Runs `fun`, returning its result plus everything an operator (or a log
  # shipper) could see: stdout, stderr and Logger.
  defp observe(fun) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        log =
          capture_log(fn ->
            stdout = capture_io(fn -> send(parent, {:result, fun.()}) end)
            send(parent, {:stdout, stdout})
          end)

        send(parent, {:log, log})
      end)

    %{
      result: received(:result),
      stdout: received(:stdout),
      stderr: stderr,
      log: received(:log)
    }
  end

  defp received(tag) do
    receive do
      {^tag, value} -> value
    after
      0 -> flunk("captured no #{tag}")
    end
  end

  # Acceptance 5: no >= 8-char fragment of a fixture secret in the output
  # streams or anywhere in the returned term.
  defp refute_secrets_leak(observed, extra \\ []) do
    haystack =
      Enum.join(
        [
          observed.stdout,
          observed.stderr,
          observed.log,
          inspect(observed.result, limit: :infinity, printable_limit: :infinity)
        ] ++ extra,
        "\n"
      )

    for secret <- [@token, @github],
        start <- 0..(String.length(secret) - 8),
        fragment = String.slice(secret, start, 8) do
      refute String.contains?(haystack, fragment),
             "an 8-char fragment of a fixture secret (offset #{start}) leaked"
    end
  end

  describe "start_release_vault!/0" do
    test "is a no-op when the repo and vault are already started" do
      assert Release.start_release_vault!() == :ok
    end

    test "reuses start_release_repo!/0 and adds only the Vault" do
      assert @start_release_vault_body =~ "start_release_repo!()"
      assert @start_release_vault_body =~ "Arbiter.Vault.start_link"

      refute @start_release_vault_body =~ "Arbiter.Application"
      refute @start_release_vault_body =~ "Arbiter.Supervisor"
      refute @start_release_vault_body =~ ~r/ensure_all_started\(:arbiter\)/
      refute @start_release_vault_body =~ "app.start"
      # A second copy of the Repo start would defeat the shared helper.
      refute @start_release_vault_body =~ "Arbiter.Repo.start_link"
    end

    test "at runtime, in a fresh node, runs census → migrate → rollback without the app tree",
         ctx do
      # Same shape as `Arbiter.ReleaseTest`'s peer check: `mix test` boots the
      # full app in *this* node, so only a separate, undistributed `:peer`
      # node can show what these functions actually need — here the whole
      # provider-accounts round trip against a scratch database.
      code_paths = Enum.map(:code.get_path(), &to_charlist/1)

      {:ok, peer_pid, _nonode} =
        :peer.start_link(%{args: [~c"-pa" | code_paths], connection: :standard_io})

      on_exit(fn ->
        try do
          :peer.stop(peer_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      tmp_db = Path.join(ctx.dir, "peer.sqlite3")

      # A real pool, not the test sandbox: the migrator runs in its own task.
      peer_repo_config = fn repo ->
        repo
        |> Keyword.drop([:pool, :ownership_timeout])
        |> Keyword.put(:database, tmp_db)
      end

      peer_arbiter_env =
        Application.get_all_env(:arbiter)
        |> Keyword.update!(Arbiter.Repo, peer_repo_config)

      :ok =
        :peer.call(peer_pid, Application, :put_all_env, [
          [
            arbiter: peer_arbiter_env,
            ash: Application.get_all_env(:ash),
            ash_sqlite: Application.get_all_env(:ash_sqlite),
            logger: [level: :error]
          ]
        ])

      # One `:peer.call/4`: the Repo and Vault link to the calling process,
      # which exits when the call returns. stdout goes to a StringIO so it can
      # be grepped for the secret like the in-node tests do.
      {observed, _binding} =
        :peer.call(
          peer_pid,
          Code,
          :eval_string,
          [
            """
            {:ok, io} = StringIO.open("")
            Process.group_leader(self(), io)

            :ok = Arbiter.Release.start_release_vault!()
            Ecto.Migrator.run(Arbiter.Repo, :up, all: true, log: false)

            ws =
              Ash.create!(Arbiter.Tasks.Workspace, %{
                name: "peer-default",
                worker_env: %{
                  "CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => token, "secret" => true}
                }
              })

            census = Arbiter.Release.accounts_census(plan: plan)
            dry = Arbiter.Release.accounts_migrate(plan: plan, dry_run?: true)
            migrated = Arbiter.Release.accounts_migrate(plan: plan)
            after_migrate = Arbiter.Tasks.Workspace.worker_env_map(Ash.get!(Arbiter.Tasks.Workspace, ws.id))
            rolled = Arbiter.Release.accounts_rollback(migration_id: migrated.migration_id)
            after_rollback = Arbiter.Tasks.Workspace.worker_env_map(Ash.get!(Arbiter.Tasks.Workspace, ws.id))

            {_, stdout} = StringIO.contents(io)

            %{
              results: {census.totals, dry, migrated, rolled},
              after_migrate: after_migrate,
              restored?: after_rollback == %{"CLAUDE_CODE_OAUTH_TOKEN" => token},
              stdout: stdout,
              endpoint: Process.whereis(ArbiterWeb.Endpoint),
              autopilot: Process.whereis(Arbiter.Board.Autopilot),
              pubsub: Process.whereis(Arbiter.PubSub),
              started_apps: Enum.map(Application.started_applications(), &elem(&1, 0))
            }
            """,
            [token: @token, plan: Path.join(ctx.dir, "peer-accounts.json")]
          ],
          60_000
        )

      {census_totals, dry, migrated, rolled} = observed.results

      assert census_totals.accounts == 1
      assert dry.dry_run? and dry.keys_removed == 1
      assert migrated.keys_removed == 1 and migrated.backups_written == 1
      assert observed.after_migrate == %{}
      assert rolled.restored == 1
      assert observed.restored?

      assert observed.endpoint == nil
      assert observed.autopilot == nil
      assert observed.pubsub == nil
      refute :arbiter in observed.started_apps

      refute_secrets_leak(%{
        stdout: observed.stdout,
        stderr: "",
        log: "",
        result: observed.results
      })
    end
  end

  describe "accounts_census/1" do
    test "prints the census, writes the candidate plan, and leaks no value", ctx do
      seed!("rel-default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token, "GITHUB_TOKEN" => @github})

      out = observe(fn -> Release.accounts_census(plan: ctx.plan_path) end)

      assert out.stdout =~ "rel-default"
      assert out.stdout =~ "CLAUDE_CODE_OAUTH_TOKEN"
      assert out.stdout =~ String.slice(Census.fingerprint(@token), 0, 12)
      assert out.stdout =~ ctx.plan_path
      assert out.log =~ "Arbiter.Accounts.Census: scanned"
      # The note names the option spelling a release eval takes, too.
      assert out.stdout =~ "operator_credential:"

      assert %{totals: %{accounts: 1}} = out.result
      assert File.exists?(ctx.plan_path)

      refute_secrets_leak(out, [File.read!(ctx.plan_path)])
    end

    test "refuses to overwrite an existing plan without force?: true", ctx do
      File.write!(ctx.plan_path, "{}")

      assert_raise Release.Refused, ~r/force\?: true/, fn ->
        capture_io(fn -> Release.accounts_census(plan: ctx.plan_path) end)
      end

      assert File.read!(ctx.plan_path) == "{}"

      capture_io(fn -> Release.accounts_census(plan: ctx.plan_path, force?: true) end)
      assert File.read!(ctx.plan_path) =~ "arbiter.accounts.plan"
    end

    test "fingerprints an operator credential file without leaking it", ctx do
      seed!("rel-default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      cred_path = Path.join(ctx.dir, "credentials.json")
      File.write!(cred_path, Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => @github}}))

      out =
        observe(fn ->
          Release.accounts_census(plan: ctx.plan_path, operator_credential: cred_path)
        end)

      assert out.stdout =~ "suggested"
      refute_secrets_leak(out, [File.read!(ctx.plan_path)])
    end
  end

  describe "accounts_migrate/1" do
    test "dry_run?: true reports the plan and writes nothing", ctx do
      ws = seed!("rel-default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      capture_io(fn -> Release.accounts_census(plan: ctx.plan_path) end)

      out = observe(fn -> Release.accounts_migrate(plan: ctx.plan_path, dry_run?: true) end)

      assert out.stdout =~ "dry run"
      assert out.stdout =~ "dry_run?: true"
      assert %{dry_run?: true, keys_removed: 1} = out.result
      assert Ash.read!(ProviderAccount) == []
      assert Ash.read!(Backup) == []
      assert Map.has_key?(Workspace.worker_env_map(reload!(ws)), "CLAUDE_CODE_OAUTH_TOKEN")

      refute_secrets_leak(out)
    end

    test "applies the plan, writes the backup, and names the release rollback", ctx do
      ws = seed!("rel-default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token, "GITHUB_TOKEN" => @github})
      capture_io(fn -> Release.accounts_census(plan: ctx.plan_path) end)

      out = observe(fn -> Release.accounts_migrate(plan: ctx.plan_path) end)

      assert %{dry_run?: false, migration_id: migration_id, keys_removed: 1} = out.result
      assert out.stdout =~ "Arbiter.Release.accounts_rollback(migration_id: \"#{migration_id}\")"
      refute out.stdout =~ "mix arbiter.accounts.rollback"
      assert out.log =~ "Arbiter.Accounts.Migrate: migration #{migration_id}"

      assert [_] = Ash.read!(ProviderAccount)
      assert [_] = Ash.read!(Backup)
      assert Workspace.worker_env_map(reload!(ws)) == %{"GITHUB_TOKEN" => @github}

      refute_secrets_leak(out)
    end

    test "delete_plan?: true removes the plan file after a successful apply", ctx do
      seed!("rel-default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      capture_io(fn -> Release.accounts_census(plan: ctx.plan_path) end)

      capture_io(fn -> Release.accounts_migrate(plan: ctx.plan_path, delete_plan?: true) end)

      refute File.exists?(ctx.plan_path)
    end

    test "plan: is required" do
      assert_raise Release.Refused, ~r/plan: PATH/, fn -> Release.accounts_migrate([]) end
    end

    test "a refused plan raises and writes nothing", ctx do
      ws = seed!("rel-default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token, "GITHUB_TOKEN" => @github})
      capture_io(fn -> Release.accounts_census(plan: ctx.plan_path) end)

      ctx.plan_path
      |> File.read!()
      |> Jason.decode!()
      |> update_in(["accounts", Access.at(0), "workspaces", Access.at(0), "env_key"], fn _ ->
        "GITHUB_TOKEN"
      end)
      |> then(&File.write!(ctx.plan_path, Jason.encode!(&1)))

      error =
        assert_raise Release.Refused, ~r/allowlist/, fn ->
          Release.accounts_migrate(plan: ctx.plan_path)
        end

      assert error.message =~ "Arbiter.Release.accounts_census"
      assert Ash.read!(ProviderAccount) == []
      assert Map.has_key?(Workspace.worker_env_map(reload!(ws)), "GITHUB_TOKEN")
    end
  end

  describe "accounts_rollback/1" do
    setup ctx do
      ws = seed!("rel-default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token, "LOG_LEVEL" => "debug"})
      capture_io(fn -> Release.accounts_census(plan: ctx.plan_path) end)
      {migrated, _stdout} = with_io(fn -> Release.accounts_migrate(plan: ctx.plan_path) end)
      {:ok, ws: ws, migration_id: migrated.migration_id}
    end

    test "list?: true lists backups by name and restores nothing", ctx do
      out = observe(fn -> Release.accounts_rollback(list?: true) end)

      assert out.stdout =~ ctx.migration_id
      assert out.stdout =~ "CLAUDE_CODE_OAUTH_TOKEN"
      assert [%{migration_id: id}] = out.result
      assert id == ctx.migration_id
      assert Workspace.worker_env_map(reload!(ctx.ws)) == %{"LOG_LEVEL" => "debug"}

      refute_secrets_leak(out)
    end

    test "dry_run?: true restores nothing", ctx do
      out =
        observe(fn ->
          Release.accounts_rollback(migration_id: ctx.migration_id, dry_run?: true)
        end)

      assert out.stdout =~ "dry run"
      assert %{dry_run?: true, restored: 1} = out.result
      assert Workspace.worker_env_map(reload!(ctx.ws)) == %{"LOG_LEVEL" => "debug"}
    end

    test "migration_id: restores the pre-migration worker_env without leaking it", ctx do
      out = observe(fn -> Release.accounts_rollback(migration_id: ctx.migration_id) end)

      assert out.stdout =~ "restored"
      assert %{restored: 1, keys_restored: 1} = out.result

      assert Workspace.worker_env_map(reload!(ctx.ws)) == %{
               "CLAUDE_CODE_OAUTH_TOKEN" => @token,
               "LOG_LEVEL" => "debug"
             }

      refute_secrets_leak(out)
    end

    test "all: true restores every pending backup", ctx do
      capture_io(fn -> Release.accounts_rollback(all: true) end)

      assert Map.has_key?(Workspace.worker_env_map(reload!(ctx.ws)), "CLAUDE_CODE_OAUTH_TOKEN")
    end

    test "needs a selector" do
      assert_raise Release.Refused, ~r/migration_id:/, fn -> Release.accounts_rollback([]) end
    end
  end

  describe "the Mix tasks are thin wrappers (acceptance 3)" do
    test "the release path calls nothing from Mix (a release ships without it)" do
      # The peer-node test cannot catch this: Mix is on its code path.
      for path <- [
            "lib/arbiter/release.ex",
            "lib/arbiter/accounts/census.ex",
            "lib/arbiter/accounts/migrate.ex"
          ] do
        refute File.read!(path) =~ ~r/\bMix\.[a-z]|\bMix\.[A-Z]\w*\.[a-z]/,
               "#{path} calls into Mix"
      end
    end

    for {task, fun} <- [
          {"arbiter.accounts.census", "accounts_census"},
          {"arbiter.accounts.migrate", "accounts_migrate"},
          {"arbiter.accounts.rollback", "accounts_rollback"}
        ] do
      test "mix #{task} delegates to Arbiter.Release.#{fun} and never boots the app" do
        source = File.read!("lib/mix/tasks/#{unquote(task)}.ex")

        assert source =~ "Arbiter.Release.#{unquote(fun)}("
        assert source =~ ~s|Mix.Task.run("app.config")|
        refute source =~ ~s|"app.start"|
        # The output and the Logger line live in Arbiter.Release, once.
        refute source =~ "Logger."
      end
    end
  end
end
