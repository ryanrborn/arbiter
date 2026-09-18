defmodule Mix.Tasks.Arbiter.Accounts.MigrateTest do
  @moduledoc """
  End-to-end coverage for `mix arbiter.accounts.migrate` and
  `mix arbiter.accounts.rollback` against real, seeded, encrypted workspaces.

  As with the census task, `run/1` calls `Mix.Task.run("app.start")`, which
  cannot run under the test sandbox, so these drive `execute/1`.

  The bar §7.4 sets is "no plaintext is written anywhere", so the no-leak test
  greps stdout, stderr, captured Logger output *and* the plan file for every
  >= 8-character substring of each seeded secret.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Arbiter.Accounts.Census
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderAccountMigrationBackup, as: Backup
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Tasks.Workspace
  alias Mix.Tasks.Arbiter.Accounts.Migrate, as: MigrateTask
  alias Mix.Tasks.Arbiter.Accounts.Rollback, as: RollbackTask

  @token "sk-ant-oat01-qZ7fLx2NvUwJh4Tk9RmDbYcE6sApGnX1"
  @openai "sk-proj-9mXvQ2rTzKpLbN4wYhJdCgA6eSuF8oRi"
  @github "ghp_wR4nT0nLyTh3F1rSt0nEsMoV3dYkQ2pX"

  setup do
    # `config/test.exs` pins the primary Logger level to :warning, which drops
    # the tasks' Logger.info before capture_log can see it and makes the Logger
    # leg of the no-leak assertion vacuous. Raise it to what prod runs at.
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    dir = Path.join(System.tmp_dir!(), "accounts-migrate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, plan_path: Path.join(dir, "accounts.json"), dir: dir}
  end

  defp seed!(name, env) do
    worker_env = Map.new(env, fn {k, v} -> {k, %{"value" => v, "secret" => true}} end)
    Ash.create!(Workspace, %{name: name, worker_env: worker_env})
  end

  defp write_plan!(path) do
    Census.run() |> Census.write_plan!(path, true)
    path
  end

  # Runs a task's `execute/1`, returning everything an operator or a log
  # shipper could see: stdout, stderr and Logger.
  defp run(task, argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        log =
          capture_log(fn ->
            send(parent, {:stdout, capture_io(fn -> task.execute(argv) end)})
          end)

        send(parent, {:log, log})
      end)

    %{stdout: received(:stdout), stderr: stderr, log: received(:log)}
  end

  defp received(tag) do
    receive do
      {^tag, value} -> value
    after
      0 -> flunk("captured no #{tag}")
    end
  end

  defp reload!(workspace), do: Ash.get!(Workspace, workspace.id)

  describe "mix arbiter.accounts.migrate (acceptance 1, 2)" do
    test "applies the plan, writes a backup, and strips only allowlisted keys", ctx do
      ws =
        seed!("default", %{
          "CLAUDE_CODE_OAUTH_TOKEN" => @token,
          "GITHUB_TOKEN" => @github,
          "LOG_LEVEL" => "debug"
        })

      write_plan!(ctx.plan_path)

      out = run(MigrateTask, ["--plan", ctx.plan_path])

      assert out.stdout =~ "claude-1"
      assert out.stdout =~ "CLAUDE_CODE_OAUTH_TOKEN"

      assert [account] = Ash.read!(ProviderAccount)
      assert account.slug == "claude-1"
      assert [credential] = Ash.read!(ProviderCredential)
      assert credential.fingerprint == Census.fingerprint(@token)
      assert [backup] = Ash.read!(Backup)
      assert backup.removed_keys == ["CLAUDE_CODE_OAUTH_TOKEN"]

      env = ws |> reload!() |> Workspace.worker_env_map()
      assert env == %{"GITHUB_TOKEN" => @github, "LOG_LEVEL" => "debug"}
    end

    test "--dry-run writes nothing", ctx do
      ws = seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      write_plan!(ctx.plan_path)

      out = run(MigrateTask, ["--plan", ctx.plan_path, "--dry-run"])

      assert out.stdout =~ "dry run"
      assert Ash.read!(ProviderAccount) == []
      assert Ash.read!(Backup) == []
      assert Map.has_key?(Workspace.worker_env_map(reload!(ws)), "CLAUDE_CODE_OAUTH_TOKEN")
    end

    test "--plan is required" do
      assert_raise Mix.Error, ~r/--plan/, fn -> MigrateTask.execute([]) end
    end

    test "a missing plan file is a clean error", ctx do
      assert_raise Mix.Error, ~r/no such file/i, fn ->
        MigrateTask.execute(["--plan", Path.join(ctx.dir, "nope.json")])
      end
    end

    test "an unrecognised option is refused", ctx do
      assert_raise Mix.Error, ~r/unrecognised option/, fn ->
        MigrateTask.execute(["--plan", ctx.plan_path, "--wat"])
      end
    end

    test "--delete-plan removes the plan file after a successful apply", ctx do
      seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      write_plan!(ctx.plan_path)

      run(MigrateTask, ["--plan", ctx.plan_path, "--delete-plan"])

      refute File.exists?(ctx.plan_path)
      assert [_] = Ash.read!(ProviderAccount)
    end

    test "a refused plan leaves the database and the plan file alone", ctx do
      ws = seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token, "GITHUB_TOKEN" => @github})
      write_plan!(ctx.plan_path)

      # Point the plan at a non-allowlisted key, the way a hand edit could.
      ctx.plan_path
      |> File.read!()
      |> Jason.decode!()
      |> update_in(["accounts", Access.at(0), "workspaces", Access.at(0), "env_key"], fn _ ->
        "GITHUB_TOKEN"
      end)
      |> then(&File.write!(ctx.plan_path, Jason.encode!(&1)))

      assert_raise Mix.Error, ~r/allowlist/, fn ->
        MigrateTask.execute(["--plan", ctx.plan_path])
      end

      assert Ash.read!(ProviderAccount) == []
      assert File.exists?(ctx.plan_path)
      assert Map.has_key?(Workspace.worker_env_map(reload!(ws)), "GITHUB_TOKEN")
    end
  end

  describe "§7.4 — no plaintext anywhere (acceptance 5)" do
    test "no >= 8-char substring of any secret reaches stdout, stderr, logs or the plan", ctx do
      seed!("default", %{
        "CLAUDE_CODE_OAUTH_TOKEN" => @token,
        "GITHUB_TOKEN" => @github,
        "LOG_LEVEL" => "debug"
      })

      seed!("emricare", %{"OPENAI_API_KEY" => @openai})

      write_plan!(ctx.plan_path)
      plan_body = File.read!(ctx.plan_path)

      migrate = run(MigrateTask, ["--plan", ctx.plan_path])
      rollback = run(RollbackTask, ["--all"])

      haystack =
        Enum.join(
          [
            plan_body,
            File.read!(ctx.plan_path),
            migrate.stdout,
            migrate.stderr,
            migrate.log,
            rollback.stdout,
            rollback.stderr,
            rollback.log
          ],
          "\n"
        )

      for secret <- [@token, @openai, @github],
          start <- 0..(String.length(secret) - 8),
          fragment = String.slice(secret, start, 8) do
        refute String.contains?(haystack, fragment),
               "an 8-char fragment of a secret (offset #{start}) leaked into the operator-visible output"
      end
    end

    test "the plan file keeps mode 0600 and carries fingerprints, not values", ctx do
      seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      write_plan!(ctx.plan_path)

      run(MigrateTask, ["--plan", ctx.plan_path])

      %File.Stat{mode: mode} = File.stat!(ctx.plan_path)
      assert Bitwise.band(mode, 0o777) == 0o600

      plan = ctx.plan_path |> File.read!() |> Jason.decode!()
      credential = plan["accounts"] |> hd() |> Map.fetch!("credentials") |> hd()
      assert credential["fingerprint"] == Census.fingerprint(@token)
      refute Map.has_key?(credential, "secret")
    end
  end

  describe "mix arbiter.accounts.rollback (acceptance 3)" do
    test "--migration-id restores the workspace's pre-migration worker_env", ctx do
      ws = seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token, "LOG_LEVEL" => "debug"})
      write_plan!(ctx.plan_path)

      migrate = run(MigrateTask, ["--plan", ctx.plan_path])
      [migration_id] = Regex.run(~r/[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}/, migrate.stdout)

      refute Map.has_key?(Workspace.worker_env_map(reload!(ws)), "CLAUDE_CODE_OAUTH_TOKEN")

      out = run(RollbackTask, ["--migration-id", migration_id])
      assert out.stdout =~ "restored"

      assert Workspace.worker_env_map(reload!(ws)) == %{
               "CLAUDE_CODE_OAUTH_TOKEN" => @token,
               "LOG_LEVEL" => "debug"
             }

      # The restored key keeps its secret flag.
      assert ws
             |> reload!()
             |> Workspace.worker_env_keys()
             |> Enum.find(&(&1.name == "CLAUDE_CODE_OAUTH_TOKEN"))
             |> Map.fetch!(:secret?)
    end

    test "--workspace restores that workspace's latest backup", ctx do
      ws = seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      other = seed!("emricare", %{"OPENAI_API_KEY" => @openai})
      write_plan!(ctx.plan_path)
      run(MigrateTask, ["--plan", ctx.plan_path])

      run(RollbackTask, ["--workspace", "default"])

      assert Workspace.worker_env_map(reload!(ws)) == %{"CLAUDE_CODE_OAUTH_TOKEN" => @token}
      assert Workspace.worker_env_map(reload!(other)) == %{}
    end

    test "--list prints the backup rows without restoring anything", ctx do
      ws = seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      write_plan!(ctx.plan_path)
      run(MigrateTask, ["--plan", ctx.plan_path])

      out = run(RollbackTask, ["--list"])

      assert out.stdout =~ "default"
      assert out.stdout =~ "CLAUDE_CODE_OAUTH_TOKEN"
      assert Workspace.worker_env_map(reload!(ws)) == %{}
    end

    test "--dry-run restores nothing", ctx do
      ws = seed!("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token})
      write_plan!(ctx.plan_path)
      run(MigrateTask, ["--plan", ctx.plan_path])

      out = run(RollbackTask, ["--all", "--dry-run"])

      assert out.stdout =~ "dry run"
      assert Workspace.worker_env_map(reload!(ws)) == %{}
    end

    test "needs a selector" do
      assert_raise Mix.Error, ~r/--migration-id/, fn -> RollbackTask.execute([]) end
    end

    test "an unknown migration id is a clean error" do
      assert_raise Mix.Error, ~r/no backup rows/, fn ->
        RollbackTask.execute(["--migration-id", "20260101T000000Z-abcdef"])
      end
    end
  end
end
