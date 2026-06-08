defmodule ArbiterCli.Cmd.ServerTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Server

  describe "migrate" do
    test "runs migrations and reports the applied count" do
      Process.put(:bd2_cmd_runner, fn _cmd, _args, _opts ->
        {~s({"migrations_applied":3,"status":"ok"}), 0}
      end)

      System.put_env("ARB_HOME", System.tmp_dir!())
      on_exit(fn -> System.delete_env("ARB_HOME") end)

      {out, _err, code} = capture(fn -> Server.run(["migrate"]) end)
      assert code == 0
      assert out =~ "Applied 3 migration(s)"
    end

    test "reports a current schema when nothing to apply" do
      Process.put(:bd2_cmd_runner, fn _cmd, _args, _opts ->
        {~s({"migrations_applied":0,"status":"ok"}), 0}
      end)

      System.put_env("ARB_HOME", System.tmp_dir!())
      on_exit(fn -> System.delete_env("ARB_HOME") end)

      {out, _err, code} = capture(fn -> Server.run(["migrate"]) end)
      assert code == 0
      assert out =~ "already current"
    end
  end

  test "unknown subcommand errors with a usage hint" do
    {_out, err, code} = capture(fn -> Server.run(["frobnicate"]) end)
    assert code == 1
    assert err =~ "unknown server subcommand"
  end

  test "no subcommand errors" do
    {_out, err, code} = capture(fn -> Server.run([]) end)
    assert code == 1
    assert err =~ "server requires a subcommand"
  end
end
