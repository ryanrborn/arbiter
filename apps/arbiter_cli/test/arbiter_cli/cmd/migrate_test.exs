defmodule ArbiterCli.Cmd.MigrateTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Migrate

  @migration_json ~s({"migrations_applied":0,"status":"ok"})
  @applied_json ~s({"migrations_applied":3,"status":"ok"})
  @failed_json ~s({"error":"oops","status":"failed"})

  defp stub_migrate(output, exit_code) do
    Process.put(:bd2_cmd_runner, fn _cmd, _args, _opts -> {output, exit_code} end)
  end

  describe "run/1 — output parsing" do
    test "pure JSON output: parses count from ok response" do
      stub_migrate(@migration_json, 0)
      assert {:ok, 0} = Migrate.run("/tmp/fake-root")
    end

    test "mixed log+JSON output: skips Logger lines and parses the JSON line" do
      mixed =
        "16:38:12.193 [info] Migrations already up\n" <>
          @migration_json <> "\n"

      stub_migrate(mixed, 0)
      assert {:ok, 0} = Migrate.run("/tmp/fake-root")
    end

    test "applied migrations: count parsed correctly from mixed output" do
      mixed = "16:38:12.193 [info] == Running 20260601 CreateFoo ==\n" <> @applied_json

      stub_migrate(mixed, 0)
      assert {:ok, 3} = Migrate.run("/tmp/fake-root")
    end

    test "non-zero exit code → error regardless of output" do
      stub_migrate(@migration_json, 1)
      assert {:error, _} = Migrate.run("/tmp/fake-root")
    end

    test "failed status JSON → error" do
      stub_migrate(@failed_json, 0)
      assert {:error, _} = Migrate.run("/tmp/fake-root")
    end

    test "output with no JSON line → error" do
      stub_migrate("16:38:12.193 [info] Migrations already up\n", 0)
      assert {:error, reason} = Migrate.run("/tmp/fake-root")
      assert reason =~ "Failed to parse migration output"
    end
  end
end
