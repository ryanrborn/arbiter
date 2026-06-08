defmodule ArbiterCli.Cmd.InstallTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Install

  test "no target errors with a hint" do
    {_out, err, code} = capture(fn -> Install.run([]) end)
    assert code == 1
    assert err =~ "install requires a target"
    assert err =~ "cli, service"
  end

  test "unknown target errors" do
    {_out, err, code} = capture(fn -> Install.run(["banana"]) end)
    assert code == 1
    assert err =~ "unknown install target"
  end
end
